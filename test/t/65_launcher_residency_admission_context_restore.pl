# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 65_launcher_residency_admission_context_restore.pl: regression coverage for
# ReconcileResidencyAdmission's PG_CATCH(), which must restore the caller's
# memory context. By the time SvsMemoryAdmitDatabase can throw, its own
# transaction has already committed, so IsTransactionState() is false and the
# conditional AbortCurrentTransaction() is skipped; nothing else switches
# CurrentMemoryContext back to whatever it was before PG_TRY(), so the catch
# must do it explicitly.
#
# A plain svs.default_residency_memory / svs.max_residency_memory shrink via
# SIGHUP is enough to make SvsMemoryAdmitDatabase throw on every reconcile
# cycle: no injection point is needed. On an assert build, the Assert in
# PublishMemoryOverrides's loop trips a TRAP on the very first reconcile
# cycle after the reload if the restore is missing.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

# Polls log_contains rather than wait_for_log, which croaks on timeout: a
# timeout here is a real (if unlikely) test failure, not a harness error.
sub wait_for_log_line
{
    my ($node, $regex, $offset, $timeout_s) = @_;
    $timeout_s //= 10;
    for (1 .. $timeout_s * 2)
    {
        return 1 if $node->log_contains($regex, $offset);
        usleep(500_000);
    }
    return 0;
}

sub launcher_pid
{
    my ($node) = @_;
    my $pid = $node->safe_psql('postgres',
        "SELECT pid FROM pg_stat_activity WHERE backend_type = 'vamana launcher' LIMIT 1;");
    chomp $pid;
    return $pid;
}

my $node = PostgreSQL::Test::Cluster->new('launcher_residency_admission_context');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 10");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres',
    "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

my $worker_pid = wait_for_worker($node, 30);
ok($worker_pid =~ /^\d+$/, "worker running (pid=$worker_pid)");

my $launcher_before = launcher_pid($node);
ok($launcher_before =~ /^\d+$/, "launcher running (pid=$launcher_before)");

# Enough rows that the index's committed residency clears the 1MB budget this
# test is about to shrink to.
$node->safe_psql('postgres', qq(
    CREATE TABLE residency_ctx_tbl (id serial PRIMARY KEY, val vector($dim));
    INSERT INTO residency_ctx_tbl (val)
        SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 20000);
    CREATE INDEX residency_ctx_idx ON residency_ctx_tbl USING vamana (val vector_l2_ops);
));
wait_for_worker($node);

my $relid = $node->safe_psql('postgres', "SELECT 'residency_ctx_idx'::regclass::oid;");
chomp $relid;
my $resident_bytes = $node->safe_psql('postgres',
    "SELECT resident_bytes FROM svs_index_residency WHERE index_relid = $relid;");
chomp $resident_bytes;
cmp_ok($resident_bytes, '>', 1024 * 1024,
    "the index's committed residency ($resident_bytes bytes) exceeds the 1MB budget "
  . "this test is about to shrink to");

my $log_pos = length($node->log_content());

$node->safe_psql('postgres', "ALTER SYSTEM SET svs.default_residency_memory = '1MB';");
$node->safe_psql('postgres', "ALTER SYSTEM SET svs.max_residency_memory = '1MB';");
$node->safe_psql('postgres', "SELECT pg_reload_conf();");

ok(wait_for_log_line($node,
        qr/residency budget cannot be lowered below its already-committed bytes/,
        $log_pos, 15),
    'the shrink is rejected: SvsMemoryAdmitDatabase throws on the next reconcile cycle');

# A missing restore leaves CurrentMemoryContext pointing at ErrorContext
# after the catch above runs, but VamanaLauncherReconcileWorkers's
# unconditional MemoryContextSwitchTo(oldCtx) at the end of every cycle heals
# that before anything else can observe it. The only observable symptom this
# test can assert on, besides the Assert in PublishMemoryOverrides's loop, is
# that the launcher process itself survives: an uncaught poisoned-context
# access would be a wild read, not a graceful degradation.
my $pids_seen = 0;
for (1 .. 10)
{
    usleep(300_000);
    my $pid = launcher_pid($node);
    $pids_seen++ if $pid eq $launcher_before;
}
is($pids_seen, 10,
    "the same launcher (pid=$launcher_before) is still alive after the rejected admission");

# Reset the GUCs and confirm a subsequent reconcile cycle re-admits the
# database cleanly: no new rejection line after the reset.
my $reset_log_pos = length($node->log_content());
$node->safe_psql('postgres', "ALTER SYSTEM RESET svs.default_residency_memory;");
$node->safe_psql('postgres', "ALTER SYSTEM RESET svs.max_residency_memory;");
$node->safe_psql('postgres', "SELECT pg_reload_conf();");

# Give the launcher a few reconcile cycles' worth of time to settle, then
# confirm the rejection does not recur.
sleep(3);
ok(!$node->log_contains(
        qr/residency budget cannot be lowered below its already-committed bytes/,
        $reset_log_pos),
    'after resetting the budget, the database is re-admitted with no further rejection');

is(launcher_pid($node), $launcher_before,
    'the same launcher process is still running after the full cycle');

$node->stop;

done_testing();
