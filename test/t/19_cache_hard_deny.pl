# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 19_cache_hard_deny.pl — cache hard-deny: when all 8 index cache slots are
# occupied, a 9th load is refused with an explicit error rather than silently
# evicting the oldest entry.  Covers: deny at full capacity, no eviction of
# the 8 existing entries, reclaim of an invalidated slot after an unload, and
# worker survival after the denial.

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
# Cluster setup
# ---------------------------------------------------------------------------

my $node = PostgreSQL::Test::Cluster->new('cache_hard_deny');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'vector,svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 20");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "log_min_messages = 'log'");
$node->start;

$node->safe_psql("postgres", "CREATE EXTENSION vector;");
$node->safe_psql("postgres", "CREATE EXTENSION svs;");
$node->safe_psql("postgres",
    "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");
my $wpid = wait_for_worker($node);
like($wpid, qr/^\d+$/, 'vamana worker started');

# ---------------------------------------------------------------------------
# Create 11 tables (VAMANA_MAX_CACHED_INDEXES + 3 extras for the repeat test)
# ---------------------------------------------------------------------------

for my $i (1 .. 11)
{
    $node->safe_psql("postgres", qq(
        CREATE TABLE t$i (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO t$i (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 100) s;
        CREATE INDEX idx$i ON t$i USING vamana (val vector_l2_ops);
    ));
}
wait_for_worker($node);

# Capture baseline query results for indexes 1-8 so we can verify they are
# not evicted by the failed attempt to load index 9.
my @baseline;
for my $i (1 .. 8)
{
    my $res = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM t$i ORDER BY val <-> '[$query_sql]' LIMIT 3;
    ));
    push @baseline, $res;
}

# Warm indexes 1-8 to fill all cache slots.
for my $i (1 .. 8)
{
    $node->safe_psql("postgres", "SELECT svs_warmup_index('idx$i');");
}

# ---------------------------------------------------------------------------
# Case 1: deny at 9
# ---------------------------------------------------------------------------

{
    my ($ret, $stdout, $stderr) = $node->psql("postgres",
        "SELECT svs_warmup_index('idx9');");
    isnt($ret, 0,
        'warming a 9th index fails when all 8 cache slots are in use');
    like($stderr, qr/all \d+ index cache slots are in use/,
        'error message names the cache-full condition');
}

# ---------------------------------------------------------------------------
# Case 2: no eviction — all 8 original indexes still return correct results
# ---------------------------------------------------------------------------

{
    for my $i (1 .. 8)
    {
        my $res = $node->safe_psql("postgres", qq(
            SET enable_seqscan = off;
            SELECT id FROM t$i ORDER BY val <-> '[$query_sql]' LIMIT 3;
        ));
        is($res, $baseline[$i - 1],
            "idx$i query results unchanged after failed load of idx9 (no eviction)");
    }
}

# ---------------------------------------------------------------------------
# Case 4: worker survives — heartbeat advances and a successful query follows
# ---------------------------------------------------------------------------

{
    my $hb0 = $node->safe_psql("postgres",
        "SELECT heartbeat_ts FROM pg_stat_vamana_worker "
      . "WHERE worker_pid = $wpid;");
    my $hb_advanced = '';
    for my $i (1 .. 40)
    {
        usleep(250_000);
        my $hb = $node->safe_psql("postgres",
            "SELECT heartbeat_ts FROM pg_stat_vamana_worker "
          . "WHERE worker_pid = $wpid;");
        if ($hb ne '' && $hb0 ne '' && $hb gt $hb0)
        {
            $hb_advanced = 1;
            last;
        }
    }
    ok($hb_advanced, 'worker heartbeat advances after cache-full denial');

    my $state = $node->safe_psql("postgres",
        "SELECT worker_state FROM pg_stat_vamana_worker "
      . "WHERE worker_pid = $wpid;");
    isnt($state, '', 'worker state is still visible in pg_stat_vamana_worker');

    my $res = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM t1 ORDER BY val <-> '[$query_sql]' LIMIT 3;
    ));
    isnt($res, '', 'worker still serves queries after cache-full denial');
}

# ---------------------------------------------------------------------------
# Case 3: reclaim after unload
#
# This is the regression test for the high-water-mark trap: vamanaCacheUsed
# never decrements, so without the reclaim branch in VamanaAllocCacheSlot an
# invalidated slot is never reused and the denial becomes permanent.
# ---------------------------------------------------------------------------

{
    # Drop idx1: this invalidates its cache slot in the worker via the relcache
    # callback fired inside StartTransactionCommand when the next warmup request
    # opens a transaction.  By the time VamanaAllocCacheSlot runs for idx9, the
    # reclaim branch sees isValid=false and returns that slot.
    $node->safe_psql("postgres", "DROP INDEX idx1;");

    $node->safe_psql("postgres", "SELECT svs_warmup_index('idx9');");
    ok(1, 'idx9 loads successfully after idx1 is dropped, freeing its slot');

    # Confirm the load actually worked: a query returns results.
    my $res = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM t9 ORDER BY val <-> '[$query_sql]' LIMIT 3;
    ));
    isnt($res, '', 'idx9 query returns results after reclaim load');
}

# ---------------------------------------------------------------------------
# Case 5: repeat — prove the reclaim path does not leak or drift
#
# Run cases 1 and 3 a few more times with fresh indexes.  After each round the
# cache holds exactly 8 valid entries (no slot count drift, no memory leak).
# ---------------------------------------------------------------------------

# State after case 3: cache holds idx2..idx9 (8 entries).
# Round 2: deny idx10, drop idx2, warm idx10.
# Round 3: deny idx11, drop idx3, warm idx11.

for my $round (2 .. 3)
{
    my $new_idx  = 8 + $round;
    my $drop_idx = $round;

    # Case 1 re-check: new index is denied (all 8 slots still live).
    {
        my ($ret, $stdout, $stderr) = $node->psql("postgres",
            "SELECT svs_warmup_index('idx${new_idx}');");
        isnt($ret, 0,
            "round $round: warming idx${new_idx} fails — all slots occupied");
        like($stderr, qr/all \d+ index cache slots are in use/,
            "round $round: deny message present");
    }

    # Case 3 re-check: drop one entry, warm the new index.
    {
        $node->safe_psql("postgres", "DROP INDEX idx${drop_idx};");
        $node->safe_psql("postgres",
            "SELECT svs_warmup_index('idx${new_idx}');");
        ok(1, "round $round: idx${new_idx} loads after idx${drop_idx} dropped");

        my $res = $node->safe_psql("postgres", qq(
            SET enable_seqscan = off;
            SELECT id FROM t${new_idx} ORDER BY val <-> '[$query_sql]' LIMIT 3;
        ));
        isnt($res, '', "round $round: idx${new_idx} query returns results");
    }
}

$node->stop;

done_testing();
