
# Copyright (c) 2024-2026, PostgreSQL Global Development Group
#
# 005_concurrent.pl
#   Concurrency tests for pg_stat_backtrace:
#     - two callers racing on the same target PID (at least one wins,
#       the loser gets EPERM / SQLSTATE 42501)
#     - many sessions capturing DIFFERENT targets in parallel succeed
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
# Allow more parallel connections than the default.
$node->append_conf('postgresql.conf', 'max_connections = 50');
$node->start;
$node->safe_psql('postgres', 'CREATE EXTENSION pg_stat_backtrace');

sub spawn_sleeper
{
	my ($node, $secs, $label) = @_;
	$label ||= 'sleeper';
	my $bg = $node->background_psql('postgres');
	$bg->query_until(qr/./, "SELECT 'ready'");
	# Embed label into query so we can find this specific sleeper.
	$bg->{stdin} .= "SELECT pg_sleep($secs) /* $label */;\n";
	$bg->{timeout}->start if $bg->{timeout};

	my $pid;
	for (my $i = 0; $i < 50; $i++)
	{
		$pid = $node->safe_psql('postgres',
			"SELECT pid FROM pg_stat_activity "
			. "WHERE query LIKE '%/* $label */%' "
			. "AND   pid <> pg_backend_pid() LIMIT 1");
		last if $pid =~ /^\d+$/;
		select undef, undef, undef, 0.1;
	}
	die "sleeper '$label' never appeared" unless $pid =~ /^\d+$/;
	return ($bg, $pid);
}

# -----------------------------------------------------------------------------
# 1. Two sessions racing on the same target PID.
#    Strategy: fire both captures back-to-back, at least one should
#    succeed.  Due to ptrace 1:1 constraint, some runs one might get
#    EPERM; we accept either "both win" (serialized by scheduler) or
#    "one wins, one gets 42501".
# -----------------------------------------------------------------------------
{
	my ($bg, $pid) = spawn_sleeper($node, 60, 'race_target');

	# Create two background capture sessions.
	my $c1 = $node->background_psql('postgres');
	my $c2 = $node->background_psql('postgres');
	$c1->query_until(qr/./, "SELECT 'c1'");
	$c2->query_until(qr/./, "SELECT 'c2'");

	# We use a repeated capture in a loop to maximize chance of overlap.
	my $q = <<SQL;
DO \$\$
DECLARE
    i int;
    t text;
BEGIN
    FOR i IN 1..20 LOOP
        BEGIN
            t := pg_get_backtrace($pid);
            RAISE NOTICE 'iter % ok len=%', i, length(t);
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'iter % err=%', i, SQLSTATE;
        END;
    END LOOP;
END
\$\$;
SQL

	$c1->{stdin} .= $q;
	$c2->{stdin} .= $q;
	$c1->{timeout}->start if $c1->{timeout};
	$c2->{timeout}->start if $c2->{timeout};

	# Collect output.
	sleep 3;

	my $o1 = $c1->{stdout} // '';
	my $o2 = $c2->{stdout} // '';

	my @errs1 = ($o1 =~ /err=(\w+)/g);
	my @errs2 = ($o2 =~ /err=(\w+)/g);

	my @oks1 = ($o1 =~ /iter \d+ ok/g);
	my @oks2 = ($o2 =~ /iter \d+ ok/g);

	# At least one success overall.
	cmp_ok(scalar(@oks1) + scalar(@oks2), '>', 0,
		'at least one concurrent capture succeeded');

	# If any errors happened, they should be the expected EPERM -> 42501
	# or state race -> 55000.  No INTERNAL_ERROR (XX000).
	for my $e (@errs1, @errs2)
	{
		like($e, qr/^(42501|55000)$/,
			"concurrent capture error is 42501 or 55000 (got $e)");
	}

	$c1->quit;
	$c2->quit;
	$bg->quit;
}

# -----------------------------------------------------------------------------
# 2. Many sessions, DIFFERENT targets: should all succeed, no mutual
#    interference.
# -----------------------------------------------------------------------------
{
	my @sleepers;
	my @pids;
	for my $i (1 .. 4)
	{
		my ($bg, $pid) = spawn_sleeper($node, 60, "multi_$i");
		push @sleepers, $bg;
		push @pids, $pid;
	}

	# Run 4 captures in parallel against the 4 different sleepers.
	my @cappers;
	for my $i (0 .. 3)
	{
		my $c = $node->background_psql('postgres');
		$c->query_until(qr/./, "SELECT 'c$i'");
		$c->{stdin} .=
		  "SELECT length(pg_get_backtrace($pids[$i])) AS len;\n";
		$c->{timeout}->start if $c->{timeout};
		push @cappers, $c;
	}

	sleep 2;

	for my $i (0 .. 3)
	{
		my $o = $cappers[$i]->{stdout} // '';
		like($o, qr/^\s*\d+\s*$/m,
			"parallel capture #$i against different target succeeded");
	}

	$_->quit for @cappers;
	$_->quit for @sleepers;
}

$node->stop;

done_testing();
