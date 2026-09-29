# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL
#
# 48_vamana_slot_consistency_blocker.pl — regression test for is#191 (R9).
#
# VamanaRunningXactsRecordWouldBlock defers slot-consistency-building while
# any unrelated transaction is in progress (src/vamana_replication.c), so an
# unrelated long-running transaction can hold a vamana index's replication
# slot non-consistent indefinitely -- not just briefly around CREATE INDEX.
# Before the fix, every batch inserted during that window (not just the
# first) was lost on a crash: three 5-row batches held under a blocker for
# ~30s, crashed, and all 15 rows were gone (only the original 50 survived).
# The fix in VamanaWorkerGetOrLoadIndex (src/vamanaworkerindex.c) detects a
# slot that never reached CONSISTENT on the first post-crash load and
# rebuilds from the heap, recovering every batch regardless of how long the
# window was open. See
# ~/workspace/pgv-svs-dev-scripts/docs/r9-fix/phase1-root-cause.md §2.4.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep time);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

my $node = PostgreSQL::Test::Cluster->new('r9_blocker');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 10");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->append_conf('postgresql.conf', "log_min_messages = 'debug1'");
$node->append_conf('postgresql.conf', "fsync = on");
$node->append_conf('postgresql.conf', "svs.worker_timeout_ms = 30000");
# Default checkpoint GUCs -- deliberately not overridden.
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres',
    "INSERT INTO vamana_databases (datname) VALUES ('postgres');");
wait_for_worker_db($node, 'postgres', 40);

# Hold an unrelated transaction open in a separate session for the whole
# window: VamanaRunningXactsRecordWouldBlock defers consistency-building while
# any xid is in progress, regardless of whether it touches the vamana table.
my $blocker = $node->background_psql('postgres');
$blocker->query_safe('BEGIN;');
$blocker->query_safe("CREATE TABLE unrelated_lock_holder (x int);");
$blocker->query_safe("INSERT INTO unrelated_lock_holder VALUES (1);");
# Leave the transaction open (no COMMIT) -- this is the blocker.

$node->safe_psql('postgres', qq{
    CREATE TABLE blk_tbl (id serial PRIMARY KEY, val vector($dim));
    INSERT INTO blk_tbl (val)
        SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 50);
    CREATE INDEX blk_idx ON blk_tbl USING vamana (val vector_l2_ops);
});
wait_for_worker_db($node, 'postgres', 30);

sub slot_confirmed_flush
{
    my $v = $node->safe_psql('postgres', qq{
        SELECT confirmed_flush_lsn FROM pg_replication_slots
        WHERE slot_name LIKE 'vamana_%';
    });
    chomp $v;
    return $v;
}

ok(slot_confirmed_flush() eq '', 'confirmed_flush_lsn is NULL right after CREATE INDEX (blocker held)');

my $rows = 50;
for my $batch (1 .. 3)
{
    $node->safe_psql('postgres', qq{
        INSERT INTO blk_tbl (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 5);
    });
    $rows += 5;
    sleep(10);
    my $cf = slot_confirmed_flush();
    diag("batch $batch inserted (heap=$rows), 10s later confirmed_flush_lsn='$cf'");
}

ok(slot_confirmed_flush() eq '',
    'confirmed_flush_lsn is STILL NULL after 3 batches over ~30s with the blocker held')
    or diag("confirmed_flush_lsn=" . slot_confirmed_flush());

# Crash now, with the blocker still open (and about to be killed with everything else).
$node->stop('immediate');
$node->start;
wait_for_worker_db($node, 'postgres', 30);

my $search_sql = qq{
    SET enable_seqscan = off;
    SELECT count(*), count(DISTINCT id) FROM (
        SELECT id FROM blk_tbl ORDER BY val <-> '[$query_sql]'
        LIMIT 100000
    ) s;
};
my ($total, $distinct) = ('', '');
for (1 .. 120)
{
    my $c = $node->safe_psql('postgres', $search_sql);
    chomp $c;
    ($total, $distinct) = split(/\|/, $c);
    last if $distinct eq "$rows" && $total eq "$rows";
    usleep(500_000);
}
is($total, $distinct, 'no duplicate TIDs after the crash');
diag("SEVERITY: heap=$rows (3 batches of 5 held under a blocker), "
    . "post-crash total=$total distinct=$distinct");
is($distinct, $rows,
    "all 3 batches inserted during the blocked window survive the crash");

$node->stop;

# ---------------------------------------------------------------------------
# Second node: how long does consistency actually take at defaults, with NO
# blocker? Times CREATE INDEX-return to confirmed_flush_lsn becoming non-null.
# ---------------------------------------------------------------------------
my $node2 = PostgreSQL::Test::Cluster->new('r9_blocker_timing');
$node2->init;
$node2->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node2->append_conf('postgresql.conf', "wal_level = logical");
$node2->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node2->append_conf('postgresql.conf', "fsync = on");
$node2->append_conf('postgresql.conf', "svs.worker_timeout_ms = 30000");
$node2->start;
$node2->safe_psql('postgres', "CREATE EXTENSION vector;");
$node2->safe_psql('postgres', "CREATE EXTENSION svs;");
$node2->safe_psql('postgres',
    "INSERT INTO vamana_databases (datname) VALUES ('postgres');");
wait_for_worker_db($node2, 'postgres', 40);

my $t0 = time();
$node2->safe_psql('postgres', qq{
    CREATE TABLE timing_tbl (id serial PRIMARY KEY, val vector($dim));
    INSERT INTO timing_tbl (val)
        SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 50);
    CREATE INDEX timing_idx ON timing_tbl USING vamana (val vector_l2_ops);
});
wait_for_worker_db($node2, 'postgres', 30);

my $elapsed = 0;
my $became_consistent = 0;
for (1 .. 200)    # up to 20s
{
    my $v = $node2->safe_psql('postgres', qq{
        SELECT confirmed_flush_lsn FROM pg_replication_slots
        WHERE slot_name LIKE 'vamana_%';
    });
    chomp $v;
    if ($v ne '')
    {
        $elapsed = time() - $t0;
        $became_consistent = 1;
        last;
    }
    usleep(100_000);
}
diag("TIMING: no-blocker window from CREATE INDEX return to confirmed_flush_lsn "
    . "becoming non-null: " . ($became_consistent ? sprintf("%.2fs", $elapsed) : "did not become consistent within 20s"));
ok($became_consistent, 'slot reaches consistency within 20s with no blocker');

$node2->stop;
done_testing();
