# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 46_vamana_slot_consistency_crash_recall.pl — regression test: three rounds
# of insert-then-immediate-crash must never permanently drop rows from a
# vamana index's search results.
#
# Before the fix in VamanaWorkerGetOrLoadIndex (src/vamanaworkerindex.c): an
# insert applied through the primary's write-IPC path while the index's
# replication slot had not yet reached its initial CONSISTENT point survives
# on a live server, but is unrecoverable by slot replay after a crash forces
# a reload -- logical decoding does not redeliver row-level changes for
# transactions that committed before CONSISTENT was reached. Round 1 (the
# first insert right after CREATE INDEX, before the slot has ever reached
# consistency) exercises exactly this window under aggressive checkpoint
# GUCs. The fix detects a slot that never reached CONSISTENT on the first
# post-crash load and rebuilds from the heap instead of trusting a replay
# that cannot recover that window; see the comment above
# VamanaWorkerGetOrLoadIndex in src/vamanaworkerindex.c for the full
# mechanism.
#
# This test derives from an earlier checkpoint-durability test's "Repeated
# crashes" block, which asserted only 0 < distinct <= rows after each round
# and never polled for replay to converge. This version polls the index
# count for up to 60s per round before judging it, and records the set of
# missing ids so a real defect and a "replay not caught up yet" false alarm
# are distinguishable.
#
# svs.worker_database was removed; enrollment is now via
# svs.launcher_database (default 'postgres') plus an INSERT into
# vamana_databases. The save path also moved from vamana_indexes/<relid>/
# to vamana_indexes/<dboid>/<relid>/.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

# ---------------------------------------------------------------------------
# wait_for_index_counts: poll until the index scan's (total, distinct) count
# stabilizes at ($want, $want), for up to $attempts * 0.5s. Returns the last
# (total, distinct) observed, so a timeout is visible to the caller.
# ---------------------------------------------------------------------------
sub wait_for_index_counts
{
    my ($node, $sql, $want, $attempts) = @_;
    $attempts //= 120;    # 60s

    my ($total, $distinct) = (-1, -1);
    for (1 .. $attempts)
    {
        my $counts = $node->safe_psql('postgres', $sql);
        chomp $counts;
        ($total, $distinct) = split(/\|/, $counts);
        return ($total, $distinct) if $distinct eq "$want" && $total eq "$want";
        usleep(500_000);
    }
    return ($total, $distinct);
}

# ---------------------------------------------------------------------------
# missing_ids: heap ids not present in the index scan's result set, for the
# post-mortem when a round's count does not converge.
# ---------------------------------------------------------------------------
sub missing_ids
{
    my ($node, $tbl) = @_;
    my $out = $node->safe_psql('postgres', qq{
        SET enable_seqscan = off;
        SELECT array_agg(h.id ORDER BY h.id) FROM $tbl h
        WHERE h.id NOT IN (
            SELECT id FROM $tbl ORDER BY val <-> '[$query_sql]' LIMIT 100000
        );
    });
    chomp $out;
    return $out;
}

my $node = PostgreSQL::Test::Cluster->new('r9_crashloop');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 10");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->append_conf('postgresql.conf', "log_min_messages = 'notice'");
$node->append_conf('postgresql.conf', "fsync = on");
$node->append_conf('postgresql.conf', "svs.worker_timeout_ms = 30000");
$node->append_conf('postgresql.conf', "svs.checkpoint_min_ops = 1");
$node->append_conf('postgresql.conf', "svs.checkpoint_debounce_window = 1");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres',
    "INSERT INTO vamana_databases (datname) VALUES ('postgres');");

my $worker_pid = wait_for_worker_db($node, 'postgres', 40);
ok($worker_pid =~ /^\d+$/, "worker running (pid=$worker_pid)");

is($node->safe_psql('postgres', 'SHOW fsync;'), 'on',
    'cluster runs with fsync enabled');

# Row counts stay under the default search window (100 candidates), so the
# counts below reflect what the index holds rather than where the graph
# search stopped looking.
$node->safe_psql('postgres', qq{
    CREATE TABLE loop_tbl (id serial PRIMARY KEY, val vector($dim));
    INSERT INTO loop_tbl (val)
        SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 50);
    CREATE INDEX loop_idx ON loop_tbl USING vamana (val vector_l2_ops);
});
wait_for_worker_db($node, 'postgres', 30);

my $search_sql = qq{
    SET enable_seqscan = off;
    SELECT count(*), count(DISTINCT id) FROM (
        SELECT id FROM loop_tbl ORDER BY val <-> '[$query_sql]'
        LIMIT 100000
    ) s;
};

my $rows = 50;

for my $round (1 .. 3)
{
    $node->safe_psql('postgres', qq{
        INSERT INTO loop_tbl (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 5);
    });
    $rows += 5;
    $node->stop('immediate');

    $node->start;
    wait_for_worker_db($node, 'postgres', 30);

    my ($total, $distinct) = wait_for_index_counts($node, $search_sql, $rows, 120);

    is($total, $distinct,
        "round $round: no duplicate TIDs from the reloaded index");
    is($distinct, $rows,
        "round $round: index converges to all $rows heap rows within 60s");

    if ($distinct ne "$rows")
    {
        diag("round $round: heap has $rows rows, index converged to "
            . "$distinct (total=$total)");
        diag("round $round: missing ids: " . missing_ids($node, 'loop_tbl'));
        my $log_tail = $node->log_content();
        diag("round $round: worker log tail:\n"
            . substr($log_tail, -4000));
    }
}

$node->stop;

done_testing();
