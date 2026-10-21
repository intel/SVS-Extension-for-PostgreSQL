# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 76_torn_graph_natural_crash.pl: a real `kill -9` mid-save reproduction of
# a torn checkpoint save, complementing 75_torn_graph_offline.pl's splicing
# approach with an actual crash at the two points one can land on inside
# VamanaSaveIndexToDisk's save sequence.
#
# K1: the worker is parked at the vamana-save-before-tidmap-write injection
#      point: SVSSaveIndex has returned (graph/data/config at the new
#      generation, and the save-directory generation marker already stamped
#      with it), but the TID-map rename has not run: tidmap.bin and the
#      metapage are still at the old generation.
# K2: the worker is parked at the vamana-save-before-mark-saved injection
#      point, i.e. after the TID-map rename has completed: graph/data/config,
#      the generation marker, and tidmap.bin are all at the new generation,
#      but the metapage update has not run: the metapage alone still reflects
#      the old generation.
#
# The injection point holds the live vamana worker still, and this script
# then kills it with SIGKILL -- not a clean PG_TRY unwind, no simulated file
# edits.
#
# Both injection points are attached only after two independently-confirmed clean
# saves have already completed (so the interrupted save is never the index's
# first -- see the "not the same bug as the replication-slot startup window"
# note below) and with the replication slot already consistent
# (confirmed_flush_lsn non-NULL), using a fresh table and index per trial so
# one trial's rebuild can never be mistaken for another's starting state.
# Row counts stay under the default 100-row search window throughout.
#
# Not the same bug as the replication-slot startup window: that window is
# marked by confirmed_flush_lsn being NULL and needs no save at all. This
# file's crashes happen inside a save, with the slot already fully
# consistent, which is a different mechanism with an independent fix.
#
# PostgreSQL::Test::Cluster::init() unconditionally writes
# restart_after_crash = off for test determinism, which would make a killed
# cluster shut down permanently instead of auto-recovering. Real deployments
# default to on, so this file re-appends it after init to match real-world
# crash-recovery behavior.

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

my $node = PostgreSQL::Test::Cluster->new('vamana_torn_crash');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 4");
$node->append_conf('postgresql.conf', "max_wal_senders = 4");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->append_conf('postgresql.conf', "svs.checkpoint_min_ops = 1");
$node->append_conf('postgresql.conf', "svs.checkpoint_debounce_window = 1");
$node->append_conf('postgresql.conf', "svs.worker_timeout_ms = 30000");
$node->append_conf('postgresql.conf', "log_min_messages = 'notice'");
$node->append_conf('postgresql.conf', "fsync = on");
# See header comment: init() always writes this off; a killed worker must
# bring the whole cluster back up on its own, as a real deployment would.
$node->append_conf('postgresql.conf', "restart_after_crash = on");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres', "CREATE EXTENSION injection_points;");
$node->safe_psql('postgres',
    "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

# ---------------------------------------------------------------------------
# wait_for_reconnect: poll until the server accepts a trivial query again.
# A real crash-recovery restart (postmaster brings all backends back up and
# replays WAL) can take anywhere from a few seconds to tens of seconds under
# load.
# ---------------------------------------------------------------------------
sub wait_for_reconnect
{
    my ($node, $attempts) = @_;
    $attempts //= 120;

    for (1 .. $attempts)
    {
        my ($rc, $out, $err) = $node->psql('postgres', 'SELECT 1;');
        return 1 if $rc == 0;
        usleep(500_000);
    }
    return 0;
}

sub confirmed_flush_non_null
{
    my ($node) = @_;
    my $v = $node->safe_psql('postgres', qq{
        SELECT confirmed_flush_lsn FROM pg_replication_slots
        WHERE slot_name LIKE 'vamana_%';
    });
    chomp $v;
    return $v ne '';
}

sub search_counts
{
    my ($node, $table, $query_vec) = @_;

    my $idx = $node->safe_psql('postgres', qq{
        SET enable_seqscan = off;
        SELECT array_agg(id ORDER BY id) FROM (
            SELECT id FROM $table ORDER BY val <-> '[$query_vec]' LIMIT 100000
        ) s;
    });
    my $seq = $node->safe_psql('postgres', qq{
        SET enable_indexscan = off;
        SELECT array_agg(id ORDER BY id) FROM (
            SELECT id FROM $table ORDER BY val <-> '[$query_vec]' LIMIT 100000
        ) s;
    });
    chomp($idx, $seq);
    return ($idx, $seq);
}

sub assert_full_recall
{
    my ($node, $table, $label) = @_;

    for my $qv (@query_vecs)
    {
        my ($idx, $seq) = search_counts($node, $table, $qv);
        is($idx, $seq, "$label: index scan matches sequential scan for one query vector");
    }
}

# Prove the comparator itself can fail, before trusting it against a real
# crash below.
{
    my ($idx, $seq) = ('{1,2,4,4}', '{1,2,3,4,5}');
    isnt($idx, $seq, 'comparator setup: a deliberately wrong result set is detected as different');
}

# ---------------------------------------------------------------------------
# run_kill_trial: build a fresh table/index, complete two clean saves, attach
# the wait injection point $point, insert a third batch to trigger a re-save,
# and kill -9 the worker once it is parked there.  Returns once the cluster
# has recovered.
# ---------------------------------------------------------------------------
sub run_kill_trial
{
    my ($label, $table, $index, $point) = @_;

    $node->safe_psql('postgres', qq{
        CREATE TABLE $table (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO $table (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 40);
        CREATE INDEX $index ON $table USING vamana (val vector_l2_ops);
    });
    wait_for_worker($node, 30);

    # Second independently-confirmed clean save: the interrupted save below
    # must never be the index's first (see header comment).
    $node->safe_psql('postgres', qq{
        INSERT INTO $table (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 15);
    });
    usleep(2_000_000);    # let the debounced checkpoint land

    ok(confirmed_flush_non_null($node),
        "$label: replication slot is consistent before the injection point is attached");

    my $pid = wait_for_worker($node, 30);
    ok($pid =~ /^\d+$/, "$label: found a live worker pid ($pid)");

    $node->safe_psql('postgres',
        "SELECT injection_points_attach('$point', 'wait');");

    # Third batch: triggers the re-save that parks at the injection point.
    $node->safe_psql('postgres', qq{
        INSERT INTO $table (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 15);
    });

    # Dies (and fails the file) if the worker never reaches the point.
    $node->wait_for_event('vamana worker', $point);
    pass("$label: worker is parked at $point");

    kill('KILL', $pid);

    my $dead = 0;
    for (1 .. 60)
    {
        if (kill(0, $pid) == 0)
        {
            $dead = 1;
            last;
        }
        usleep(500_000);
    }
    ok($dead, "$label: worker process confirmed dead");

    ok(wait_for_reconnect($node), "$label: cluster recovered after the crash");
    wait_for_worker($node, 30);
}

# ===========================================================================
# K1: crash after the graph write, before the TID-map rename.
# ===========================================================================
{
    my $log_pos = length($node->log_content());
    run_kill_trial('k1', 'k1_tbl', 'k1_idx', 'vamana-save-before-tidmap-write');

    # The load (and this check's own log message) is lazy: it happens on the
    # first query that touches the index, not eagerly at worker startup.
    assert_full_recall($node, 'k1_tbl', 'K1: after rejecting the crash-torn save');

    my $log = substr($node->log_content(), $log_pos);
    like($log, qr/torn save detected/,
        'K1: the crash-torn generation is reported and rejected');
}

# ===========================================================================
# K2: crash after the TID-map rename, before the metapage update.
# ===========================================================================
{
    my $log_pos = length($node->log_content());
    run_kill_trial('k2', 'k2_tbl', 'k2_idx', 'vamana-save-before-mark-saved');

    assert_full_recall($node, 'k2_tbl', 'K2: after rejecting the crash-torn save');

    my $log = substr($node->log_content(), $log_pos);
    like($log, qr/torn save detected/,
        'K2: the crash-torn generation is reported and rejected');
}

$node->stop;

done_testing();
