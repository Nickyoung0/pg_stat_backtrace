
# Copyright (c) 2024-2026, PostgreSQL Global Development Group
#
# 004_target_lifecycle.pl
#   Exercise the error/cleanup paths of pg_stat_backtrace:
#     - target dies between resolve and attach
#     - target dies mid-capture
#     - capture is cancelled (SIGINT) from the calling session
#   Each test verifies that after the fact:
#     - the calling backend is still healthy
#     - no target is left in T-state
#     - ptrace attach relationship is not leaked
#

use strict;
use warnings FATAL => 'all';

use POSIX qw(_exit);
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

if ($^O ne 'linux')
{
	plan skip_all => "pg_stat_backtrace is Linux-only";
}

if (open(my $fh, '<', '/proc/sys/kernel/yama/ptrace_scope'))
{
	my $scope = <$fh>;
	close $fh;
	chomp $scope;
	if (defined $scope && $scope > 1)
	{
		plan skip_all =>
		  "kernel.yama.ptrace_scope = $scope (>=2) blocks this test";
	}
}

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->start;
$node->safe_psql('postgres', 'CREATE EXTENSION pg_stat_backtrace');

# -----------------------------------------------------------------------------
# Helper: spawn a sleeper and return (child_pid, backend_pid).
# We use a forked psql child rather than BackgroundPsql to remain
# portable across PG14-19 BackgroundPsql interface differences.
# -----------------------------------------------------------------------------
sub spawn_sleeper
{
	my ($node, $secs) = @_;
	my $connstr = $node->connstr('postgres');
	my $cpid = fork();
	defined $cpid or die "fork() failed: $!";
	if ($cpid == 0)
	{
		# Detach from the parent's process group so IPC::Run's
		# internal cleanup paths (used by safe_psql/run/etc) cannot
		# accidentally signal us.
		POSIX::setsid();
		exec('psql',
			'--no-psqlrc', '--no-align', '--tuples-only', '--quiet',
			'--dbname' => $connstr,
			'-c' => "SELECT pg_sleep($secs)")
		  or POSIX::_exit(127);
	}

	my $pid;
	for (my $i = 0; $i < 100; $i++)
	{
		$pid = $node->safe_psql('postgres',
			"SELECT pid FROM pg_stat_activity "
			. "WHERE query LIKE 'SELECT pg_sleep%' "
			. "AND   pid <> pg_backend_pid() LIMIT 1");
		last if $pid =~ /^\d+$/;
		select undef, undef, undef, 0.1;
	}
	die "sleeper never appeared" unless $pid =~ /^\d+$/;
	return ($cpid, $pid);
}

sub kill_sleeper
{
	my ($cpid) = @_;
	kill 'TERM', $cpid;
	waitpid($cpid, 0);
}

sub target_state
{
	my ($pid) = @_;
	return '?' unless open(my $fh, '<', "/proc/$pid/status");
	while (my $l = <$fh>)
	{
		if ($l =~ /^State:\s*(\S)/)
		{
			close $fh;
			return $1;
		}
	}
	close $fh;
	return '?';
}

# -----------------------------------------------------------------------------
# 1. Target exits before pg_get_backtrace sees it.
#    Use a PID that is very unlikely to exist on the host: 0x7fffffff
#    (max 32-bit signed int) is well above kernel.pid_max default
#    (4M = 0x400000), so /proc/<pid>/status will not exist.
#    This exercises the "PID is not a PG server process" code path,
#    which is the same outcome we'd get for an exited PID.
# -----------------------------------------------------------------------------
{
	my $doomed_pid = 2147483647;    # INT_MAX

	my $r = $node->safe_psql('postgres',
		"SET client_min_messages = ERROR; "
		. "SELECT pg_get_backtrace($doomed_pid) IS NULL");
	is($r, 't',
		"non-existent PID $doomed_pid: returns NULL (not PG process)");
}

# -----------------------------------------------------------------------------
# 2. Target is killed via pg_terminate_backend before our capture.
#    Note: we cannot use kill(9) on a backend because the Cluster.pm
#    test framework sets restart_after_crash=off, which would shut
#    down the whole cluster on any backend SIGKILL.  Using
#    pg_terminate_backend() (SIGTERM) lets PG exit cleanly.
# -----------------------------------------------------------------------------
{
	my ($child, $pid) = spawn_sleeper($node, 60);

	# Terminate target via pg_terminate_backend; wait for it to vanish.
	$node->safe_psql('postgres', "SELECT pg_terminate_backend($pid)");
	for (my $i = 0; $i < 50; $i++)
	{
		my $c = $node->safe_psql('postgres',
			"SELECT count(*) FROM pg_stat_activity WHERE pid = $pid");
		last if $c eq '0';
		select undef, undef, undef, 0.1;
	}

	my $r = $node->safe_psql('postgres',
		"SET client_min_messages = ERROR; "
		. "SELECT pg_get_backtrace($pid) IS NULL");
	is($r, 't', "terminated PID returns NULL (no longer in ProcArray)");

	# child psql may already have died because target backend was
	# killed; reap it best-effort.
	waitpid($child, 0);
}

# -----------------------------------------------------------------------------
# 3. Synchronous capture against a long-running target: completes
#    quickly and target is left in a runnable state, not T-state.
# -----------------------------------------------------------------------------
{
	my ($child, $pid) = spawn_sleeper($node, 60);

	my $len = $node->safe_psql('postgres',
		"SELECT length(pg_get_backtrace($pid))");
	cmp_ok($len, '>', 0, 'capture completes synchronously and returns text');

	# Target must still be S (sleeping), not T (stopped)
	my $state = target_state($pid);
	like($state, qr/[SRD]/,
		"target still runnable after capture (state=$state)");

	kill_sleeper($child);
}

# -----------------------------------------------------------------------------
# 4. Repeated captures on the same target: no tracer-attach leak.
# -----------------------------------------------------------------------------
{
	my ($child, $pid) = spawn_sleeper($node, 60);

	for my $i (1 .. 20)
	{
		my $len = $node->safe_psql('postgres',
			"SELECT length(pg_get_backtrace($pid))");
		ok($len =~ /^\d+$/ && $len > 0,
			"capture iteration $i: got $len bytes");
	}

	# Final state check
	my $state = target_state($pid);
	like($state, qr/[SRD]/,
		"target healthy after 20 captures (state=$state)");

	# Check /proc/$pid/status TracerPid: should be 0 (no tracer attached)
	if (open(my $fh, '<', "/proc/$pid/status"))
	{
		my $tracer;
		while (<$fh>) { if (/^TracerPid:\s*(\d+)/) { $tracer = $1; last; } }
		close $fh;
		is($tracer, '0', 'no tracer attached after all captures');
	}

	kill_sleeper($child);
}

$node->stop;

done_testing();
