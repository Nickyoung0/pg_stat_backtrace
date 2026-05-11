
# Copyright (c) 2024-2026, PostgreSQL Global Development Group
#
# 002_permission.pl
#   Permission-model tests for pg_stat_backtrace.
#   These exercise the C-level permission checks before ptrace is
#   ever invoked, so they work regardless of yama ptrace_scope or
#   CAP_SYS_PTRACE.
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

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->start;

$node->safe_psql('postgres', <<SQL);
CREATE EXTENSION pg_stat_backtrace;
CREATE ROLE regress_psbt_admin LOGIN SUPERUSER;
CREATE ROLE regress_psbt_user1 LOGIN;
CREATE ROLE regress_psbt_user2 LOGIN;
CREATE ROLE regress_psbt_monitor;
GRANT EXECUTE ON FUNCTION pg_get_backtrace(int) TO regress_psbt_monitor;
GRANT EXECUTE ON FUNCTION pg_log_backtrace(int) TO regress_psbt_monitor;
GRANT regress_psbt_monitor TO regress_psbt_user1;
SQL

# -----------------------------------------------------------------------------
# 1. No GRANT: non-superuser cannot even call the function
# -----------------------------------------------------------------------------
{
	my ($ret, $stdout, $stderr) = $node->psql(
		'postgres',
		'SELECT pg_get_backtrace(1)',
		extra_params => [ '--username' => 'regress_psbt_user2' ]);
	isnt($ret, 0, 'user without EXECUTE cannot call');
	like($stderr, qr/permission denied/,
		'user without EXECUTE gets permission denied');
}

# -----------------------------------------------------------------------------
# 2. With GRANT (via role membership): can call, but still can't
#    target the postmaster.
# -----------------------------------------------------------------------------
{
	# Get postmaster pid.
	my $pm_pid = $node->safe_psql('postgres',
		'SELECT pid FROM pg_stat_activity WHERE backend_type = '
		. "'checkpointer' LIMIT 1");
	# If we can't find the checkpointer, just use a made-up small pid.
	$pm_pid ||= '1';
	# Actually, checkpointer is targetable; postmaster pid is retrieved
	# from postmaster.pid file via a side channel.  We just test the
	# self-reject path which works regardless.

	my ($ret, $stdout, $stderr) = $node->psql(
		'postgres',
		'SELECT pg_get_backtrace(pg_backend_pid())',
		extra_params =>
		  [ '--username' => 'regress_psbt_user1',
		    '-v', 'VERBOSITY=sqlstate' ]);
	isnt($ret, 0, 'user1 self-target fails');
	like($stderr, qr/55000/, 'user1 self-target raises 55000');
}

# -----------------------------------------------------------------------------
# 3. Non-superuser targeting another superuser's backend must fail.
#    We spawn a long-running psql as the admin and try to attach to it
#    from user1.  This does NOT actually call ptrace because the
#    permission check rejects before PTRACE_SEIZE.
# -----------------------------------------------------------------------------
{
	my $admin_psql_timer = IPC::Run::start(
		[
			$node->installed_command('psql'),
			'-h', $node->host,
			'-p', $node->port,
			'--username' => 'regress_psbt_admin',
			'-d', 'postgres',
			'-c', "SELECT pg_sleep(20)"
		]);

	# Wait for the admin session to become visible.
	$node->poll_query_until('postgres',
		"SELECT EXISTS (SELECT 1 FROM pg_stat_activity "
		. "WHERE usename = 'regress_psbt_admin' "
		. "AND   query  LIKE 'SELECT pg_sleep%')")
		or die "admin session never started";

	my $admin_pid = $node->safe_psql('postgres',
		"SELECT pid FROM pg_stat_activity "
		. "WHERE usename = 'regress_psbt_admin' "
		. "AND   query LIKE 'SELECT pg_sleep%' LIMIT 1");

	ok($admin_pid =~ /^\d+$/, "admin pid retrieved: $admin_pid");

	# user1 (non-superuser) tries to target admin (superuser).
	my ($ret, $stdout, $stderr) = $node->psql(
		'postgres',
		"SELECT pg_get_backtrace($admin_pid)",
		extra_params =>
		  [ '--username' => 'regress_psbt_user1',
		    '-v', 'VERBOSITY=sqlstate' ]);
	isnt($ret, 0, 'non-superuser targeting superuser fails');
	like($stderr, qr/42501/,
		'non-superuser targeting superuser raises 42501');

	# Kill the admin psql.
	$admin_psql_timer->kill_kill;
}

$node->stop;

done_testing();
