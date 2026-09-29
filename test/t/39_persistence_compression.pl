# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 39_persistence_compression.pl -- on-disk persistence for LeanVec- and
# LVQ-compressed indexes. Split out of 01_persistence.pl because SVS refuses
# to build LeanVec or LVQ storage on hardware that lacks the required
# instruction set; run this file only on hardware that supports it.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use File::Path qw(remove_tree);
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

# ===========================================================================
# LeanVec-compressed persistence — compression survives rebuild round-trip
# ===========================================================================
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_leanvec_persist');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "log_min_messages = 'notice'");
    $node->start;

    $node->safe_psql("postgres", "CREATE EXTENSION vector;");
    $node->safe_psql("postgres", "CREATE EXTENSION svs;");
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    $node->safe_psql("postgres", qq(
        CREATE TABLE lv_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO lv_tbl (val)
            SELECT ARRAY[$array_sql]::vector
            FROM generate_series(1, 200) i;
        CREATE INDEX lv_idx ON lv_tbl USING vamana (val vector_l2_ops)
            WITH (compression_type = 1, compression_primary = 8, compression_secondary = 8);
    ));

    my $index_oid = $node->safe_psql("postgres",
        "SELECT oid FROM pg_class WHERE relname = 'lv_idx';");
    chomp $index_oid;
    my $index_dir = vamana_save_dir($node, 'postgres', $index_oid);

    ok(-d $index_dir, "on-disk index directory exists after CREATE INDEX with LeanVec");
    my @initial_files = glob("$index_dir/*");
    ok(scalar @initial_files > 0, 'on-disk index directory non-empty with LeanVec');

    my $baseline = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM lv_tbl ORDER BY val <-> '[$lv_query_sql]' LIMIT 5;
    ));
    isnt($baseline, '', 'pre-restart LeanVec query returns results');

    my $initial_size = dir_size($index_dir);

    my $log_pos_before_restart = length($node->log_content());
    $node->restart;

    my $after_restart = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM lv_tbl ORDER BY val <-> '[$lv_query_sql]' LIMIT 5;
    ));
    is($after_restart, $baseline, 'LeanVec results after restart match baseline');

    my $new_log = substr($node->log_content(), $log_pos_before_restart);

    unlike($new_log, qr/rebuilding vamana index from table data/,
        'no table rebuild on post-restart LeanVec query');
    like($new_log, qr/vamana index \d+ loaded from disk/,
        'LeanVec index loaded from disk');
    like($new_log, qr/vamana index \d+: loading TID map for \d+ vectors/,
        'TID map load start logged (LeanVec)');
    like($new_log, qr/vamana index \d+: TID map loaded/,
        'TID map load completion logged (LeanVec)');

    $node->safe_psql("postgres", qq(
        INSERT INTO lv_tbl (val) VALUES (ARRAY[$array_sql]::vector);
    ));

    my $after_insert = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM lv_tbl ORDER BY val <-> '[$lv_query_sql]' LIMIT 5;
    ));
    isnt($after_insert, '', 'LeanVec query after INSERT returns results');

    # Remove the on-disk index while the server is stopped: a running-server
    # delete would be undone by the shutdown drain re-checkpointing the live
    # index, so the restart would load from disk instead of rebuilding.
    $node->stop;
    remove_tree($index_dir);
    my $log_pos_before_second_restart = length($node->log_content());
    $node->start;

    # Demand-driven rebuild: query so the BGW scans the table and re-saves.
    $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM lv_tbl ORDER BY val <-> '[$lv_query_sql]' LIMIT 5;
    ));

    my $rebuild_wait_log = '';
    for (1 .. 20) {
        $rebuild_wait_log =
            substr($node->log_content(), $log_pos_before_second_restart);
        last if $rebuild_wait_log =~ /vamana index \d+ loaded from disk/
             || $rebuild_wait_log =~ /vamana index \d+: scanning table/;
        usleep(500_000);
    }

    my $rebuilt_size = dir_size($index_dir);
    ok(-d $index_dir, 'on-disk index directory exists after BGW rebuild (LeanVec)');
    ok($rebuilt_size > 0, 'rebuilt LeanVec index directory is non-empty');
    ok($rebuilt_size <= $initial_size * 1.5,
        "rebuilt LeanVec index size within 1.5x of original — compression preserved"
    ) or diag("initial_size=$initial_size  rebuilt_size=$rebuilt_size  ratio=",
              ($initial_size > 0 ? sprintf("%.2f", $rebuilt_size / $initial_size) : 'N/A'));

    my $after_second_restart = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM lv_tbl ORDER BY val <-> '[$lv_query_sql]' LIMIT 5;
    ));
    isnt($after_second_restart, '', 'LeanVec query after BGW rebuild returns results');

    my $log_pos_before_third_restart = length($node->log_content());
    $node->restart;

    my $after_third_restart = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM lv_tbl ORDER BY val <-> '[$lv_query_sql]' LIMIT 5;
    ));
    is($after_third_restart, $after_second_restart,
        'LeanVec results after third restart match post-rebuild baseline');

    my $third_restart_log =
      substr($node->log_content(), $log_pos_before_third_restart);

    unlike($third_restart_log, qr/rebuilding vamana index from table data/,
        'no table rebuild on third restart (LeanVec)');
    like($third_restart_log, qr/vamana index \d+ loaded from disk/,
        'LeanVec index loaded from disk on third restart');
    ok(-d $index_dir, 'on-disk index directory still exists after third restart');

    $node->stop;
}

# ===========================================================================
# Metapage-sourced LeanVec config survives ALTER INDEX + reload without
# corruption -- the metapage-frozen leanvec_dims must still win over an
# ALTER INDEX ... SET (leanvec_dims = ...) on reload.
# ===========================================================================
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_leanvec_config_persist');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'vector,svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "log_min_messages = 'notice'");
    $node->start;

    $node->safe_psql("postgres", "CREATE EXTENSION vector;");
    $node->safe_psql("postgres", "CREATE EXTENSION svs;");
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    $node->safe_psql("postgres", qq(
        CREATE TABLE lv_cfg_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO lv_cfg_tbl (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 50) i;
        CREATE INDEX lv_cfg_idx ON lv_cfg_tbl USING vamana (val vector_l2_ops)
            WITH (compression_type = 1, leanvec_dims = 4);
    ));
    my $lv_cfg_baseline = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM lv_cfg_tbl ORDER BY val <-> '[$lv_query_sql]' LIMIT 5;
    ));
    isnt($lv_cfg_baseline, '', 'pre-ALTER LeanVec query returns results');

    $node->safe_psql('postgres', "ALTER INDEX lv_cfg_idx SET (leanvec_dims = 7);");
    $node->restart;
    my $lv_cfg_after_alter = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM lv_cfg_tbl ORDER BY val <-> '[$lv_query_sql]' LIMIT 5;
    ));
    is($lv_cfg_after_alter, $lv_cfg_baseline,
        'ALTER INDEX ... SET (leanvec_dims=...) does not corrupt results on reload '
      . '(metapage value still wins over the altered reloption)');

    $node->stop;
}

# ===========================================================================
# LVQ-compressed persistence — the saved file must reload under a matching spec
#
# Both LVQ families get their own round trip.  (4,8) uses a residual; (8,0) does
# not, and is the only configuration that maps a compression parameter to
# SVS_DATA_TYPE_VOID, so it exercises a distinct specialization on both the save
# and the load side.  A spec mismatch does not fail loudly -- the worker logs
# "failed to load" and silently rebuilds from the table -- so the load-from-disk
# assertions below, not the query results, are what actually pin this down.
# ===========================================================================
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_lvq_persist');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "log_min_messages = 'notice'");
    $node->start;

    $node->safe_psql("postgres", "CREATE EXTENSION vector;");
    $node->safe_psql("postgres", "CREATE EXTENSION svs;");
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    # label => reloptions; each gets its own table so the two indexes cannot
    # share a load path by accident.
    my @lvq_cases = (
        ['residual',    'compression_primary = 4, compression_secondary = 8'],
        ['no_residual', 'compression_primary = 8, compression_secondary = 0'],
    );

    my %baseline;
    my %index_dir;

    for my $case (@lvq_cases) {
        my ($label, $opts) = @$case;

        $node->safe_psql("postgres", qq(
            CREATE TABLE lvq_$label (id serial PRIMARY KEY, val vector($dim));
            INSERT INTO lvq_$label (val)
                SELECT ARRAY[$array_sql]::vector
                FROM generate_series(1, 200) i;
            CREATE INDEX lvq_${label}_idx ON lvq_$label USING vamana (val vector_l2_ops)
                WITH (compression_type = 2, $opts);
        ));

        my $index_oid = $node->safe_psql("postgres",
            "SELECT oid FROM pg_class WHERE relname = 'lvq_${label}_idx';");
        chomp $index_oid;
        $index_dir{$label} = vamana_save_dir($node, 'postgres', $index_oid);

        ok(-d $index_dir{$label},
            "on-disk index directory exists after CREATE INDEX with LVQ ($label)");
        ok(dir_size($index_dir{$label}) > 0,
            "on-disk index directory non-empty with LVQ ($label)");

        $baseline{$label} = $node->safe_psql("postgres", qq(
            SET enable_seqscan = off;
            SELECT id FROM lvq_$label ORDER BY val <-> '[$lv_query_sql]' LIMIT 5;
        ));
        isnt($baseline{$label}, '', "pre-restart LVQ query returns results ($label)");
    }

    my $log_pos_before_restart = length($node->log_content());
    $node->restart;

    for my $case (@lvq_cases) {
        my ($label) = @$case;

        my $after_restart = $node->safe_psql("postgres", qq(
            SET enable_seqscan = off;
            SELECT id FROM lvq_$label ORDER BY val <-> '[$lv_query_sql]' LIMIT 5;
        ));
        is($after_restart, $baseline{$label},
            "LVQ results after restart match baseline ($label)");
    }

    my $new_log = substr($node->log_content(), $log_pos_before_restart);

    unlike($new_log, qr/rebuilding vamana index from table data/,
        'no table rebuild on post-restart LVQ query');
    unlike($new_log, qr/failed to load SVS index/,
        'no load failure on post-restart LVQ query — storage spec matched');

    # One "loaded from disk" line per index, so a single successful load cannot
    # cover for the other family silently rebuilding.
    my @loaded = ($new_log =~ /vamana index \d+ loaded from disk/g);
    is(scalar @loaded, scalar @lvq_cases,
        'both LVQ indexes loaded from disk after restart')
      or diag("loaded-from-disk lines: ", scalar @loaded);

    $node->stop;
}

# ===========================================================================
# LeanVec default leanvec_dims (-1) — rebuild must not crash or assert
# Covers: SVSCreateLeanVecStorage clamping of leanvec_dims=-1 in VamanaRebuildFromTable
# ===========================================================================
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_leanvec_default_dims');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "log_min_messages = 'notice'");
    $node->start;

    $node->safe_psql("postgres", "CREATE EXTENSION vector;");
    $node->safe_psql("postgres", "CREATE EXTENSION svs;");
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    # Create LeanVec index without specifying leanvec_dims — defaults to -1
    $node->safe_psql("postgres", qq(
        CREATE TABLE lv_default_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO lv_default_tbl (val)
            SELECT ARRAY[$array_sql]::vector
            FROM generate_series(1, 200) i;
        CREATE INDEX lv_default_idx ON lv_default_tbl USING vamana (val vector_l2_ops)
            WITH (compression_type = 1, compression_primary = 8, compression_secondary = 8);
    ));

    my $index_oid = $node->safe_psql("postgres",
        "SELECT oid FROM pg_class WHERE relname = 'lv_default_idx';");
    chomp $index_oid;
    my $index_dir = vamana_save_dir($node, 'postgres', $index_oid);

    my $baseline = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM lv_default_tbl ORDER BY val <-> '[$lv_query_sql]' LIMIT 5;
    ));
    isnt($baseline, '', 'LeanVec default-dims: initial query returns results');

    # Force VamanaRebuildFromTable by removing the on-disk index while the
    # server is stopped; a running-server delete would be undone by the
    # shutdown drain re-checkpointing the live index.
    $node->stop;
    remove_tree($index_dir);
    my $log_pos = length($node->log_content());
    $node->start;

    # Demand-driven rebuild: query so the BGW scans the table and re-saves.
    $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM lv_default_tbl ORDER BY val <-> '[$lv_query_sql]' LIMIT 5;
    ));

    # Wait for BGW to complete rebuild
    my $rebuild_log = '';
    for (1 .. 20) {
        $rebuild_log = substr($node->log_content(), $log_pos);
        last if $rebuild_log =~ /vamana index \d+ loaded from disk/
             || $rebuild_log =~ /vamana index \d+: scanning table/;
        usleep(500_000);
    }

    ok(-d $index_dir,
        'LeanVec default-dims: on-disk index recreated after forced rebuild');

    my $after_rebuild = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM lv_default_tbl ORDER BY val <-> '[$lv_query_sql]' LIMIT 5;
    ));
    isnt($after_rebuild, '',
        'LeanVec default-dims: query after rebuild returns results');
    is($after_rebuild, $baseline,
        'LeanVec default-dims: results after rebuild match pre-rebuild baseline');

    like($rebuild_log, qr/rebuilding vamana index from table data/,
        'LeanVec default-dims: rebuild was triggered (not loaded from disk)');

    $node->stop;
}

# ===========================================================================
# halfvec LVQ persistence -- a saved LVQ-compressed halfvec file must reload
# under the same element format and compression spec it was built with.
#
# Under LVQ the quantized distances may reorder the tail of the result, so
# only the zero-distance row (the query vector's own row) is required to
# stay in front, both before and after the restart.
# ===========================================================================
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_halfvec_lvq_persist');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "log_min_messages = 'notice'");
    $node->start;

    $node->safe_psql("postgres", "CREATE EXTENSION vector;");
    $node->safe_psql("postgres", "CREATE EXTENSION svs;");
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    # Neighbours of a row that is in the table, so the query vector is one of
    # the stored ones.
    my $hv_query = sub {
        my ($indexed) = @_;
        my $scans = $indexed
          ? "SET enable_seqscan = off;"
          : "SET enable_indexscan = off; SET enable_seqscan = on;";
        return $node->safe_psql("postgres", qq(
            $scans
            SELECT id FROM hv_lvq
              ORDER BY val <-> (SELECT val FROM hv_lvq WHERE id = 7)
              LIMIT 5;
        ));
    };

    $node->safe_psql("postgres", qq(
        CREATE TABLE hv_lvq (id serial PRIMARY KEY, val halfvec($dim));
        INSERT INTO hv_lvq (val)
            SELECT ARRAY[$array_sql]::halfvec
            FROM generate_series(1, 200) i;
        CREATE INDEX hv_lvq_idx ON hv_lvq USING vamana (val halfvec_l2_ops)
            WITH (compression_type = 2, compression_primary = 4, compression_secondary = 8);
    ));

    my $index_oid = $node->safe_psql("postgres",
        "SELECT oid FROM pg_class WHERE relname = 'hv_lvq_idx';");
    chomp $index_oid;
    my $index_dir = vamana_save_dir($node, 'postgres', $index_oid);

    ok(-d $index_dir,
        'on-disk index directory exists after halfvec CREATE INDEX (lvq)');
    ok(dir_size($index_dir) > 0,
        'on-disk halfvec index directory non-empty (lvq)');

    my $hv_baseline = $hv_query->(1);
    isnt($hv_baseline, '', 'pre-restart halfvec query returns results (lvq)');
    is((split /\n/, $hv_baseline)[0], '7',
        'halfvec query row is its own nearest neighbour (lvq)');

    my $log_pos_before_restart = length($node->log_content());
    $node->restart;

    my $after_restart = $hv_query->(1);
    is($after_restart, $hv_baseline,
        'halfvec results after restart match baseline (lvq)');
    is((split /\n/, $after_restart)[0], '7',
        'reloaded halfvec index keeps the query row in front (lvq)');

    my $hv_log = substr($node->log_content(), $log_pos_before_restart);

    unlike($hv_log, qr/rebuilding vamana index from table data/,
        'no table rebuild on post-restart halfvec query (lvq)');
    unlike($hv_log, qr/vamana index not in memory, rebuilding from table/,
        'no rebuild NOTICE on post-restart halfvec query (lvq)');
    unlike($hv_log, qr/failed to load SVS index/,
        'no load failure on post-restart halfvec query -- element format matched (lvq)');
    like($hv_log, qr/vamana index \d+ loaded from disk/,
        'halfvec LVQ index loaded from disk after restart');

    $node->stop;
}

# ===========================================================================
# Empty-table CREATE INDEX, then INSERT -- a compressed vector index built
# lazily on the first INSERT must reload under the same storage spec CREATE
# INDEX declared, because the load after a restart is driven by what the
# index was declared as, not by what the first INSERT happened to build.
# ===========================================================================
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_empty_first_insert_lvq');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "log_min_messages = 'notice'");
    $node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
    $node->start;

    $node->safe_psql('postgres', 'CREATE EXTENSION vector');
    $node->safe_psql('postgres', 'CREATE EXTENSION svs');
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    # Empty-table CREATE INDEX: nothing is built yet.
    $node->safe_psql('postgres', qq(
        CREATE TABLE ef_lvq_vector (id serial PRIMARY KEY, val vector($dim));
        CREATE INDEX ef_lvq_vector_idx ON ef_lvq_vector USING vamana (val vector_l2_ops)
            WITH (compression_type = 2, compression_primary = 4, compression_secondary = 8);
    ));

    # Warm it so the first INSERT takes the empty-table build path.
    $node->safe_psql('postgres', qq(
        SET enable_seqscan = off;
        SELECT id FROM ef_lvq_vector ORDER BY val <-> '[$query_sql]' LIMIT 1;
    ));

    $node->safe_psql('postgres', qq(
        INSERT INTO ef_lvq_vector (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 200) i;
    ));

    my $ef_baseline = $node->safe_psql('postgres', qq(
        SET enable_seqscan = off;
        SELECT id FROM ef_lvq_vector ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));
    isnt($ef_baseline, '',
        'pre-restart query returns results on lazily built index (lvq_vector)');

    my $ef_log_pos = length($node->log_content());
    $node->restart;

    my $after_restart = $node->safe_psql('postgres', qq(
        SET enable_seqscan = off;
        SELECT id FROM ef_lvq_vector ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));
    is($after_restart, $ef_baseline,
        'results after restart match baseline on lazily built index (lvq_vector)');

    my $ef_log = substr($node->log_content(), $ef_log_pos);

    unlike($ef_log, qr/failed to load SVS index/,
        'no load failure after restart -- first-INSERT build used the declared spec');
    unlike($ef_log, qr/rebuilding vamana index from table data/,
        'no table rebuild after restart of a lazily built index');
    unlike($ef_log, qr/vamana index not in memory, rebuilding from table/,
        'no rebuild NOTICE after restart of a lazily built index');
    like($ef_log, qr/vamana index \d+ loaded from disk/,
        'lazily built LVQ vector index loaded from disk after restart');

    $node->stop;
}

done_testing();
