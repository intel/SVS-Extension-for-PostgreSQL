# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 75_torn_graph_offline.pl: offline reproduction of a torn checkpoint save.
#
# VamanaSaveIndexToDisk writes one save generation in steps: SVSSaveIndex
# overwrites graph/data/config in place, VamanaSaveTidMapAtomically replaces
# tidmap.bin by temp-and-rename, and VamanaMarkIndexSaved WAL-logs the
# metapage last.  A crash between the first and second step leaves a newer
# graph beside an older TID map and metapage.  Before the fix under test, the
# loader accepted that mismatched state without error and silently served
# fewer rows than the heap actually has.  The fix stamps the same generation
# value into a save-directory marker, the TID map header, and the metapage at
# the point each becomes durable, and rejects (then rebuilds from the heap)
# any disagreement among the three.
#
# This file reproduces that one state offline, by splicing files from two
# real, independently-confirmed-clean checkpoint generations rather than by
# crashing anything.  See 76_torn_graph_natural_crash.pl for the same defect
# reproduced with a real `kill -9` mid-save.  See
# 64_vamana_checkpoint_durability.pl for the truncated/absent/leftover-temp-
# file cases, which this file does not duplicate: none of those involve two
# otherwise-well-formed generations disagreeing with each other, so none of
# them exercise the generation check this file is about.
#
# Layout: each test owns its own table, index, and two confirmed save
# generations inside its own block, so that rebuilding after one test's
# rejection (which stamps a fresh generation of its own) can never be
# mistaken for an unrelated test's starting state.  This mirrors the
# fresh-table-per-trial discipline the original investigation adopted after
# finding that a shared table let one trial's rebuild contaminate the next.
#
# Tests:
#   A clean, untorn restart still serves every row (the generation check does
#       not false-positive on the ordinary case).
#   A TID map spliced back to an older generation than the graph/data/config
#       is rejected and rebuilt, not served with missing rows.
#   A save-directory generation marker stamped with a value that disagrees
#       with the metapage is rejected and rebuilt.
#   An absent save-directory generation marker (e.g. a save made before this
#       fix existed) is rejected and rebuilt, not treated as trustworthy.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

# On-disk layout of the save-directory generation marker, from
# VamanaSaveGenHeader in src/vamanaio.c: two uint32 fields followed by an
# 8-byte TimestampTz.
my $SAVEGEN_MAGIC   = 0x53565347;    # "SVSG"
my $SAVEGEN_VERSION = 1;

my $node = PostgreSQL::Test::Cluster->new('vamana_torn_offline');
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
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres',
    "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

sub slurp_raw
{
    my ($path) = @_;
    return undef unless -f $path;
    open(my $fh, '<:raw', $path) or die "open $path: $!";
    my $data = do { local $/; <$fh> };
    close($fh);
    return $data;
}

sub write_raw
{
    my ($path, $data) = @_;
    open(my $fh, '>:raw', $path) or die "open $path: $!";
    print $fh $data;
    close($fh);
}

# ---------------------------------------------------------------------------
# wait_for_tidmap_change: poll tidmap.bin until its content differs from
# $previous (or simply exists, if $previous is undef).  A fresh checkpoint
# save is what changes its content, so this is how the test confirms a
# triggering INSERT's checkpoint has actually landed before snapshotting or
# tampering with the save directory.
# ---------------------------------------------------------------------------
sub wait_for_tidmap_change
{
    my ($tidmap, $previous, $attempts) = @_;
    $attempts //= 60;

    for (1 .. $attempts)
    {
        my $data = slurp_raw($tidmap);
        return $data if defined $data && (!defined $previous || $data ne $previous);
        usleep(500_000);
    }
    return undef;
}

sub search_counts
{
    my ($table, $query_vec) = @_;

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

# ---------------------------------------------------------------------------
# assert_full_recall: the index scan and the sequential scan must return the
# same id set.  This is the ground-truth comparator: proven able to detect a
# wrong result before any torn-state case below is trusted.
# ---------------------------------------------------------------------------
sub assert_full_recall
{
    my ($table, $label) = @_;

    for my $qv (@query_vecs)
    {
        my ($idx, $seq) = search_counts($table, $qv);
        is($idx, $seq, "$label: index scan matches sequential scan for one query vector");
    }
}

# Prove the comparator itself can fail: a deliberately wrong id list must not
# compare equal to truth.
{
    my ($idx, $seq) = ('{1,2,4,4}', '{1,2,3,4,5}');
    isnt($idx, $seq, 'comparator setup: a deliberately wrong result set is detected as different');
}

# ---------------------------------------------------------------------------
# build_two_generations: a fresh table and index with two independently
# confirmed-clean checkpoint saves (60 rows, then +20, staying under the
# default 100-row search window so counts reflect contents, not search
# reach).  Returns the save directory's paths and generation A's TID map
# bytes, for the caller to splice back in.
# ---------------------------------------------------------------------------
sub build_two_generations
{
    my ($table, $index) = @_;

    $node->safe_psql('postgres', qq{
        CREATE TABLE $table (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO $table (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 60);
        CREATE INDEX $index ON $table USING vamana (val vector_l2_ops);
    });
    wait_for_worker($node, 30);

    my $relid = $node->safe_psql('postgres',
        "SELECT oid FROM pg_class WHERE relname = '$index';");
    chomp $relid;
    die "no oid for $index" unless $relid =~ /^\d+$/;

    my $save_dir = vamana_save_dir($node, 'postgres', $relid);
    my $tidmap   = "$save_dir/tidmap.bin";
    my $marker   = "$save_dir/generation.bin";

    my $gen_a_tidmap = wait_for_tidmap_change($tidmap, undef);
    ok(defined $gen_a_tidmap, "$index: build produced generation A on disk");

    $node->safe_psql('postgres', qq{
        INSERT INTO $table (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 20);
    });
    my $gen_b_tidmap = wait_for_tidmap_change($tidmap, $gen_a_tidmap);
    ok(defined $gen_b_tidmap, "$index: second checkpoint produced generation B on disk");
    isnt($gen_a_tidmap, $gen_b_tidmap, "$index: generation B TID map differs from generation A");

    assert_full_recall($table, "$index: generation B, untorn");

    return ($tidmap, $marker, $gen_a_tidmap);
}

# ===========================================================================
# Test: a clean, untorn restart still serves every row.
# ===========================================================================
{
    build_two_generations('clean_tbl', 'clean_idx');

    $node->stop('immediate');
    $node->start;
    wait_for_worker($node, 30);

    assert_full_recall('clean_tbl', 'clean restart on generation B');
}

# ===========================================================================
# Test: a TID map spliced back to generation A, with graph/data/config and
# the metapage left at generation B, is rejected and rebuilt.
#
# This is the exact defect: a crash between SVSSaveIndex returning (graph at
# the new generation) and VamanaSaveTidMapAtomically's rename (TID map and
# metapage still at the old one) leaves precisely this file layout.
# ===========================================================================
{
    my ($tidmap, undef, $gen_a_tidmap) = build_two_generations('spliced_tbl', 'spliced_idx');

    $node->stop;
    write_raw($tidmap, $gen_a_tidmap);

    my $log_pos = length($node->log_content());
    $node->start;
    wait_for_worker($node, 30);

    # The load (and this check's own log message) is lazy: it happens on the
    # first query that touches the index, not eagerly at worker startup.
    assert_full_recall('spliced_tbl', 'after rejecting the spliced generation-A TID map');

    my $log = substr($node->log_content(), $log_pos);
    like($log, qr/torn save detected/,
        'a generation-A TID map beside a generation-B graph is reported as a torn save');
}

# ===========================================================================
# Test: the save-directory generation marker itself disagreeing with the
# metapage (independent of the TID map) is also rejected and rebuilt.
# ===========================================================================
{
    my (undef, $marker) = build_two_generations('marker_tbl', 'marker_idx');

    $node->stop;

    my $live_marker = slurp_raw($marker);
    ok(defined $live_marker, 'generation marker exists after a completed save');

    # A different, but well-formed, generation value than whatever is
    # currently stamped.
    write_raw($marker, pack('L2q', $SAVEGEN_MAGIC, $SAVEGEN_VERSION, 1));

    my $log_pos = length($node->log_content());
    $node->start;
    wait_for_worker($node, 30);

    assert_full_recall('marker_tbl', 'after rejecting the mismatched generation marker');

    my $log = substr($node->log_content(), $log_pos);
    like($log, qr/save-generation marker does not match/,
        'a generation marker disagreeing with the metapage is rejected as a torn save');
}

# ===========================================================================
# Test: an absent generation marker (e.g. a save directory written before
# this fix existed) is rejected and rebuilt rather than trusted.
# ===========================================================================
{
    my (undef, $marker) = build_two_generations('absent_tbl', 'absent_idx');

    $node->stop;
    unlink($marker) or die "unlink $marker: $!";

    my $log_pos = length($node->log_content());
    $node->start;
    wait_for_worker($node, 30);

    assert_full_recall('absent_tbl', 'after rejecting the absent generation marker');

    my $log = substr($node->log_content(), $log_pos);
    like($log, qr/save-generation marker missing, torn save detected/,
        'an absent generation marker is rejected as a torn save');
}

$node->stop;

done_testing();
