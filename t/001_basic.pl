
# Copyright (c) 2024-2026, PostgreSQL Global Development Group
#
# 001_basic.pl
#   Metadata and argument-validation tests for pg_stat_backtrace.
#   These do NOT exercise the actual unwind path, so they are safe
#   to run on any Linux host (even one with yama ptrace_scope = 1
#   or inside a non-CAP_SYS_PTRACE container) and on non-Linux hosts
#   as long as the extension built.
#

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

# Skip everything on non-Linux: the module contains a #error for
# non-Linux, so nothing to test.
if ($^O ne 'linux')
{
	plan skip_all => "pg_stat_backtrace is Linux-only";
}

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->start;

$node->safe_psql('postgres', 'CREATE EXTENSION pg_stat_backtrace');

# -----------------------------------------------------------------------------
# 1. Function signatures
# -----------------------------------------------------------------------------
my $sig = $node->safe_psql('postgres', <<SQL);
SELECT proname
       || ',' || pronargs::text
       || ',' || provolatile::text
       || ',' || (CASE WHEN proisstrict THEN 't' ELSE 'f' END)
       || ',' || proparallel::text
       || ',' || prorettype::regtype::text
FROM   pg_proc
WHERE  proname IN ('pg_get_backtrace', 'pg_log_backtrace')
ORDER  BY proname;
SQL

is($sig,
	"pg_get_backtrace,1,v,t,r,text\npg_log_backtrace,1,v,t,r,boolean",
	'both functions exist with correct signatures');

# -----------------------------------------------------------------------------
# 2. Default privileges: REVOKE FROM PUBLIC
# -----------------------------------------------------------------------------
my $priv = $node->safe_psql('postgres', <<SQL);
SELECT bool_or(has_function_privilege('public', oid, 'EXECUTE'))
FROM   pg_proc
WHERE  proname IN ('pg_get_backtrace', 'pg_log_backtrace');
SQL

is($priv, 'f', 'PUBLIC has no EXECUTE privilege by default');

# -----------------------------------------------------------------------------
# 3. STRICT NULL handling
# -----------------------------------------------------------------------------
my $null1 = $node->safe_psql('postgres',
	'SELECT pg_get_backtrace(NULL::int) IS NULL');
is($null1, 't', 'pg_get_backtrace(NULL) returns NULL via STRICT');

my $null2 = $node->safe_psql('postgres',
	'SELECT pg_log_backtrace(NULL::int) IS NULL');
is($null2, 't', 'pg_log_backtrace(NULL) returns NULL via STRICT');

# -----------------------------------------------------------------------------
# 4. Non-positive PID handling (WARNING + NULL/false, no ptrace)
# -----------------------------------------------------------------------------
for my $bad_pid (0, -1, -123456)
{
	my $r = $node->safe_psql('postgres',
		"SET client_min_messages = ERROR; "
		. "SELECT pg_get_backtrace($bad_pid) IS NULL");
	is($r, 't', "pg_get_backtrace($bad_pid) returns NULL");

	$r = $node->safe_psql('postgres',
		"SET client_min_messages = ERROR; "
		. "SELECT pg_log_backtrace($bad_pid)");
	is($r, 'f', "pg_log_backtrace($bad_pid) returns false");
}

# -----------------------------------------------------------------------------
# 5. Self-PID is rejected with SQLSTATE 55000
# -----------------------------------------------------------------------------
{
	my ($ret, $stdout, $stderr) = $node->psql('postgres',
		'SELECT pg_get_backtrace(pg_backend_pid())',
		extra_params => [ '-v', 'VERBOSITY=sqlstate' ]);
	isnt($ret, 0, 'self-target fails');
	like($stderr, qr/55000/, 'self-target raises SQLSTATE 55000');
}

# -----------------------------------------------------------------------------
# 6. Non-PG PID is rejected with WARNING + NULL / false
# -----------------------------------------------------------------------------
# 99999999 is vanishingly unlikely to be a live PID on any test host.
{
	my $r = $node->safe_psql('postgres',
		'SET client_min_messages = ERROR; '
		. 'SELECT pg_get_backtrace(99999999) IS NULL');
	is($r, 't', 'non-PG PID returns NULL');

	$r = $node->safe_psql('postgres',
		'SET client_min_messages = ERROR; '
		. 'SELECT pg_log_backtrace(99999999)');
	is($r, 'f', 'non-PG PID returns false');
}

# -----------------------------------------------------------------------------
# 7. Extension can be dropped cleanly
# -----------------------------------------------------------------------------
$node->safe_psql('postgres', 'DROP EXTENSION pg_stat_backtrace');

# Reinstall to be sure cycle works
$node->safe_psql('postgres', 'CREATE EXTENSION pg_stat_backtrace');

$node->stop;

done_testing();
