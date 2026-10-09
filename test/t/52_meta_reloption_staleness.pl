# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 52_meta_reloption_staleness.pl — of three reads that use a build-time-frozen
# reloption (graph_degree, alpha, use_search_history) live from
# indexRel->rd_options instead of from the index's metapage, only one is a
# live correctness bug with an observable effect, and that is the one this
# file tests:
#
#   1. src/vamana.c:425-432 (VamanaGetGraphDegree), the only input to the
#      per-insert residency-growth charge (src/vamanainsert.c:72). FIXED:
#      redirected to VamanaReadMetaPage, the accessor already used
#      elsewhere for every other build-time-frozen value. Asserted below
#      via the residency charge on a parked insert.
#
#   2. src/vamanacache.c:631-657, the OAT_POST_ALTER hook's recheck of the
#      memoized search-scratch cost against use_search_history. This read
#      being live rather than metapage-sourced is not a bug: see
#      test/t/27_search_scratch_accounting.pl's "Case 5" / "Trigger 2",
#      which documents this as intentional -- the hook deliberately
#      invalidates the memoized cost on any reloption change, as a
#      conservative "when in doubt, recompute" trigger, not because the
#      stale value would otherwise be wrong (the actual recompute, via
#      VamanaRefreshIndexSearchScratchCost -> VamanaAssembleBuildConfig,
#      already reads use_search_history from the metapage regardless of
#      which value triggered it). Not fixed; not tested here.
#
#   3. src/vamanaworkerindex.c:107-117 (CacheEmptyTableIndex). FIXED for
#      consistency (now also reads via VamanaReadMetaPage) but not
#      independently tested: the fields it seeds (entry->graph_degree /
#      entry->alpha, src/vamanacache.c:224-225) are written once by
#      VamanaCacheIndex and never read anywhere else in the codebase (grep
#      confirms no other site reads cache->graph_degree or cache->alpha),
#      so this read currently has no observable effect either way. While
#      fixing this one, also applied the VAMANA_ALPHA_TO_FLOAT scaling
#      every other VamanaCacheIndex caller already applies to its alpha
#      argument (e.g. src/vamanabuild.c:1324) -- the old code passed the
#      int-encoded, scaled-by-100 reloption value straight through as a
#      float, a second, unrelated bug in the same dead-store field.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

if (($ENV{enable_injection_points} // 'no') ne 'yes')
{
    plan skip_all => 'server not built with --enable-injection-points';
}

my $node = PostgreSQL::Test::Cluster->new('meta_reloption_staleness');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'vector,svs'");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 20");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "log_min_messages = 'debug1'");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres', "CREATE EXTENSION injection_points;");
$node->safe_psql('postgres',
    "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");
wait_for_worker($node);

sub committed_bytes
{
    my $bytes = $node->safe_psql('postgres',
        "SELECT residency_bytes_committed FROM pg_stat_vamana_worker "
      . "WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');");
    chomp $bytes;
    return $bytes;
}

# ---------------------------------------------------------------------------
# Case 1: VamanaGetGraphDegree (src/vamana.c:425-432) charges a post-build
# insert's residency growth using the live graph_degree reloption, not the
# metapage's build-time value.
#
# Build an empty-table index at graph_degree = 32. CacheEmptyTableIndex
# (src/vamanaworkerindex.c:107-117) seeds its cache entry with
# capacityHeadroomVectors = 0 for an empty table, so the very first insert's
# growth charge is never absorbed by headroom
# (SvsMemoryReserveInsert's consumesHeadroom check, src/svs_memory.c:959) and
# lands in residency_bytes_committed exactly as VamanaEstimateInsertGrowthBytes
# computes it. ALTER the index to graph_degree = 128 (the metapage still
# says 32), then park the first insert mid-flight -- after
# SvsMemoryReserveInsert has already charged it, but before the worker's
# real measurement reanchors the committed total away from that charge --
# and read the charge directly.
# ---------------------------------------------------------------------------
{
    $node->safe_psql('postgres', qq(
        CREATE TABLE meta_empty_tbl (id serial PRIMARY KEY, val vector($dim));
        CREATE INDEX meta_empty_idx ON meta_empty_tbl USING vamana (val vector_l2_ops)
            WITH (graph_degree = 32);
    ));
    wait_for_worker($node);

    $node->safe_psql('postgres',
        "ALTER INDEX meta_empty_idx SET (graph_degree = 128);");

    my $committed_before = committed_bytes();

    $node->safe_psql('postgres',
        "SELECT injection_points_attach('vamana-enqueue-before-publish', 'wait');");

    my $parked = $node->background_psql('postgres', on_error_stop => 0);
    $parked->query_until(qr/insert_started/, qq(
        \\echo insert_started
        INSERT INTO meta_empty_tbl (val) VALUES ('[$query_sql]');
    ));
    $node->wait_for_event('client backend', 'vamana-enqueue-before-publish');

    my $committed_while_parked = committed_bytes();
    my $charge = $committed_while_parked - $committed_before;

    # (dim + graph_degree) * sizeof(float4): what the live-reloption value
    # (128) actually charges today (the bug), vs. what the metapage's
    # frozen build-time value (32) would charge instead (the fix).
    my $charge_if_live_degree_used   = ($dim + 128) * 4;
    my $charge_if_frozen_degree_used = ($dim + 32) * 4;

    is($charge, $charge_if_frozen_degree_used,
        'insert growth charge after ALTER graph_degree uses the metapage-frozen '
      . 'build-time value (32), not the live reloption (src/vamana.c:425-432)')
      or diag("committed_before=$committed_before committed_while_parked=$committed_while_parked");
    isnt($charge, $charge_if_live_degree_used,
        'the charge does not match what the live-reloption degree (128) would give');

    $node->safe_psql('postgres',
        "SELECT injection_points_wakeup('vamana-enqueue-before-publish');");
    $parked->query('SELECT 1');
    $parked->quit;
    $node->safe_psql('postgres',
        "SELECT injection_points_detach('vamana-enqueue-before-publish');");

    $node->safe_psql('postgres', "DROP TABLE meta_empty_tbl;");
}

$node->stop;

done_testing();
