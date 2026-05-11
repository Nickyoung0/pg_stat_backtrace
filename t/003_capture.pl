
# Copyright (c) 2024-2026, PostgreSQL Global Development Group
#
# 003_capture.pl
#   End-to-end capture test for pg_stat_backtrace.
#   Requires actual ptrace permission on the host:
#     - Linux kernel.yama.ptrace_scope <= 1, AND
#     - tracer and tracee under the same UID (which is the case for
#       PG backends, by construction).
#   The test auto-skips when ptrace is blocked, so CI on locked-down
#   hosts (e.g. GitHub Actions without privileged) won't fail.
#

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

if ($^O ne 'linux')
{
	plan skip_all => "pg_stat_backtrace is Linux-only";
}

# Check yama ptrace_scope.  0 or 1 allows same-UID attach; 2 or 3 we
# cannot exercise the capture path.
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
# Helper: spawn a background psql running a long query, return its
# backend pid.
# -----------------------------------------------------------------------------
sub spawn_sleeper
{
	my ($node, $secs) = @_;

	# Use BackgroundPsql so the session stays alive and we can kill it
	# deterministically at the end.
	my $bg = $node->background_psql('postgres');
	$bg->query_until(qr/./, "SELECT 'ready'");

	# Issue the sleep asynchronously; do NOT wait for its result.
	$bg->{stdin} .= "SELECT pg_sleep($secs);\n";
	$bg->{timeout}->start if $bg->{timeout};

	# Wait until pg_stat_activity reflects the sleeping query.
	my $pid;
	for (my $i = 0; $i < 50; $i++)
	{
		$pid = $node->safe_psql('postgres',
			"SELECT pid FROM pg_stat_activity "
			. "WHERE query LIKE 'SELECT pg_sleep%' "
			. "AND   pid <> pg_backend_pid() LIMIT 1");
		last if $pid =~ /^\d+$/;
		select undef, undef, undef, 0.1;
	}
	die "sleeper never appeared in pg_stat_activity"
	  unless $pid =~ /^\d+$/;

	return ($bg, $pid);
}

# -----------------------------------------------------------------------------
# 1. Capture an idle backend.  We sleep long enough to cover capture.
# -----------------------------------------------------------------------------
{
	my ($bg, $pid) = spawn_sleeper($node, 30);

	# Do the capture from the main superuser session.
	my $trace = $node->safe_psql('postgres',
		"SELECT pg_get_backtrace($pid)");

	ok(length($trace) > 0, 'pg_get_backtrace returned non-empty text');

	# Must contain at least one frame in pstack format "#N  0xADDR in SYM+0xOFF"
	like($trace, qr/^#0\s+0x[0-9a-f]+\s+in\s+\S+\+0x[0-9a-f]+/m,
		'frame #0 matches pstack format');

	# Should contain multiple frames (deep PG backend stack)
	my $frame_count = 0;
	$frame_count++ while $trace =~ /^#\d+\s+0x/mg;
	cmp_ok($frame_count, '>=', 3, "captured >= 3 frames (got $frame_count)");

	# target should still be alive and sleeping
	my $still_alive = $node->safe_psql('postgres',
		"SELECT count(*) FROM pg_stat_activity WHERE pid = $pid");
	is($still_alive, '1', 'target still alive after capture');

	# target should NOT be stuck in T-state (ptrace-stopped)
	if (open(my $fh, '<', "/proc/$pid/status"))
	{
		my $state_line;
		while (<$fh>) { if (/^State:/) { $state_line = $_; last; } }
		close $fh;
		# Accept S (sleeping), R (running), D (disk wait).  Reject T (stopped).
		like($state_line, qr/^State:\s*[SRD]/,
			"target not in T-state (got: $state_line)");
	}

	$bg->quit;
}

# -----------------------------------------------------------------------------
# 2. pg_log_backtrace writes to server log and returns true
# -----------------------------------------------------------------------------
{
	my ($bg, $pid) = spawn_sleeper($node, 30);

	my $log = $node->logfile();
	my $offset = -s $log;

	my $ret = $node->safe_psql('postgres',
		"SELECT pg_log_backtrace($pid)");
	is($ret, 't', 'pg_log_backtrace returns true on success');

	# Give the log writer a moment.
	select undef, undef, undef, 0.2;

	my $log_contents = slurp_file($log, $offset);
	like($log_contents, qr/backtrace of PID $pid/,
		'server log contains backtrace banner');
	like($log_contents, qr/#\d+\s+0x[0-9a-f]+\s+in\s+\S+/,
		'server log contains at least one frame');

	$bg->quit;
}

# -----------------------------------------------------------------------------
# 3. Capture aux process (checkpointer) as superuser
# -----------------------------------------------------------------------------
{
	my $ckpt_pid = $node->safe_psql('postgres',
		"SELECT pid FROM pg_stat_activity "
		. "WHERE backend_type = 'checkpointer' LIMIT 1");

	if ($ckpt_pid =~ /^\d+$/)
	{
		my $trace = $node->safe_psql('postgres',
			"SELECT pg_get_backtrace($ckpt_pid)");
		ok(length($trace) > 0,
			'superuser can capture aux process (checkpointer)');
		like($trace, qr/^#0\s+0x/m, 'aux capture has frame #0');
	}
	else
	{
		diag("checkpointer pid not found, skipping aux capture test");
	}
}

# -----------------------------------------------------------------------------
# 4. Frame cap: captured output size is bounded
# -----------------------------------------------------------------------------
{
	my ($bg, $pid) = spawn_sleeper($node, 30);

	my $trace = $node->safe_psql('postgres',
		"SELECT pg_get_backtrace($pid)");

	# 256 frames * ~80 chars = ~20 KB upper bound.  Normal stacks
	# are 10-30 frames, so output should be well under 10 KB.
	cmp_ok(length($trace), '<', 32 * 1024,
		'captured text is bounded (< 32 KB)');

	$bg->quit;
}

$node->stop;

done_testing();
