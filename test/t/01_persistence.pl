# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 01_persistence.pl — on-disk persistence, save/load round-trips,
# search thread configuration, and LeanVec-compressed persistence.

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
# Index persistence — survive restart, rebuild on INSERT, second restart
# ===========================================================================
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_persist');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "log_min_messages = 'notice'");
    # The 100k-row rebuild later in this block can take longer than the
    # default 5000ms on a loaded machine; the backend's wait must outlast it.
    $node->append_conf('postgresql.conf', "svs.worker_timeout_ms = 30000");
    $node->start;

    $node->safe_psql("postgres", "CREATE EXTENSION vector;");
    $node->safe_psql("postgres", "CREATE EXTENSION svs;");
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    $node->safe_psql("postgres", qq(
        CREATE TABLE vp_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO vp_tbl (val)
            SELECT ARRAY[$array_sql]::vector
            FROM generate_series(1, 200) i;
        CREATE INDEX vp_idx ON vp_tbl USING vamana (val vector_l2_ops);
    ));

    my $index_oid = $node->safe_psql("postgres",
        "SELECT oid FROM pg_class WHERE relname = 'vp_idx';");
    chomp $index_oid;

    my $parent_dir = $node->data_dir . "/vamana_indexes";
    my $index_dir  = vamana_save_dir($node, 'postgres', $index_oid);
    ok(-d $index_dir, "on-disk index directory exists after CREATE INDEX");

    my @initial_files = glob("$index_dir/*");
    ok(scalar @initial_files > 0, 'on-disk index directory is non-empty');

    # VamanaSaveTidMapAtomically (src/vamanaio.c) publishes tidmap.bin by
    # renaming tidmap.bin.tmp onto it, and unlinks the temp file on every error
    # path.  Either way nothing named *.tmp should survive a completed save.
    is(scalar(grep { /\.tmp$/ } @initial_files), 0,
        'no temp files left behind after CREATE INDEX');

    # Index vectors are user data and must not be readable by other OS accounts.
    # VamanaEnsureSaveDir (src/vamanaio.c) creates both directories with
    # MakePGDirectory, which applies pg_dir_create_mode (0700, or 0750 when the
    # cluster was initialized with group access). These assertions guard that
    # choice: a naked mkdir() with an explicit mode, or one subject to the
    # ambient umask, would leave the vectors group- or world-readable.
    for my $dir ($parent_dir, $index_dir)
    {
        my $mode = (stat($dir))[2] & 07777;
        ok($mode == 0700 || $mode == 0750,
            sprintf('%s mode is %04o (expect 0700, or 0750 with group access)',
                    $dir, $mode));
    }

    my $baseline = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM vp_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));
    isnt($baseline, '', 'pre-restart query returns results');

    my $log_pos_before_restart = length($node->log_content());
    $node->restart;

    my $after_restart = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM vp_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));
    is($after_restart, $baseline, 'query results after restart match pre-restart baseline');

    my $new_log = substr($node->log_content(), $log_pos_before_restart);

    unlike($new_log, qr/rebuilding vamana index from table data/,
        'no table rebuild on post-restart query');
    unlike($new_log, qr/vamana index not in memory, rebuilding from table/,
        'no rebuild NOTICE on post-restart query');
    like($new_log, qr/vamana index \d+ loaded from disk/,
        'server log confirms index loaded from disk');
    like($new_log, qr/vamana index \d+: loading TID map for \d+ vectors/,
        'TID map load start logged');
    like($new_log, qr/vamana index \d+: TID map loaded/,
        'TID map load completion logged');

    $node->safe_psql("postgres", qq(
        INSERT INTO vp_tbl (val) VALUES (ARRAY[$array_sql]::vector);
    ));

    my $after_insert = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM vp_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));
    isnt($after_insert, '', 'query after INSERT returns results');

    ok(-d $index_dir, 'on-disk index directory still exists after INSERT+rebuild');
    my @rebuilt_files = glob("$index_dir/*");
    ok(scalar @rebuilt_files > 0, 'on-disk index directory non-empty after rebuild');

    my $log_pos_before_second_restart = length($node->log_content());
    $node->restart;

    my $after_second_restart = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM vp_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));
    is($after_second_restart, $after_insert,
        'results after second restart match post-INSERT baseline');

    my $second_restart_log =
      substr($node->log_content(), $log_pos_before_second_restart);

    unlike($second_restart_log, qr/rebuilding vamana index from table data/,
        'no table rebuild on second restart');
    unlike($second_restart_log, qr/vamana index not in memory, rebuilding from table/,
        'no rebuild NOTICE on second restart');
    like($second_restart_log, qr/vamana index \d+ loaded from disk/,
        'index loaded from disk on second restart');
    ok(-d $index_dir, 'on-disk index directory still exists after second restart');

    # VamanaRebuildFromTable emits a progress LOG every 100k rows.
    $node->safe_psql("postgres", qq(
        CREATE TABLE vp_progress_tbl (id serial PRIMARY KEY, val vector(1));
        INSERT INTO vp_progress_tbl (val)
            SELECT ARRAY[random()]::vector
            FROM generate_series(1, 100001) i;
        CREATE INDEX vp_progress_idx ON vp_progress_tbl
            USING vamana (val vector_l2_ops);
    ));

    my $progress_index_oid = $node->safe_psql("postgres",
        "SELECT oid FROM pg_class WHERE relname = 'vp_progress_idx';");
    chomp $progress_index_oid;
    my $progress_index_dir =
        vamana_save_dir($node, 'postgres', $progress_index_oid);

    $node->stop;
    remove_tree($progress_index_dir);
    my $log_pos_before_rebuild = length($node->log_content());
    $node->start;

    # Demand-driven load: the rebuild fires only when a backend queries the
    # index.  Issue the query, then read the progress LOG it produced.
    $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM vp_progress_tbl ORDER BY val <-> '[0]' LIMIT 1;
    ));

    my $rebuild_log = '';
    for (1 .. 30) {
        $rebuild_log = substr($node->log_content(), $log_pos_before_rebuild);
        last if $rebuild_log =~
            /vamana index \d+: scanning table, 100000 vectors collected/;
        usleep(500_000);
    }

    like($rebuild_log,
        qr/vamana index \d+: scanning table, 100000 vectors collected/,
        'progress LOG emitted at 100k-vector interval during rebuild');

    $node->safe_psql("postgres", "DROP TABLE vp_progress_tbl;");

    # VamanaObjectAccessHook fires on OAT_DROP and calls VamanaDeleteSaveDir.
    # Verify the on-disk directory is removed on DROP INDEX and on DROP TABLE cascade.
    $node->safe_psql("postgres", "DROP INDEX vp_idx;");
    ok(!-d $index_dir,
        "on-disk directory removed after DROP INDEX ($index_dir)");

    my $index_oid2 = do {
        $node->safe_psql("postgres",
            "CREATE INDEX vp_idx2 ON vp_tbl USING vamana (val vector_l2_ops);");
        my $oid = $node->safe_psql("postgres",
            "SELECT oid FROM pg_class WHERE relname = 'vp_idx2';");
        chomp $oid;
        $oid;
    };
    my $index_dir2 = vamana_save_dir($node, 'postgres', $index_oid2);
    ok(-d $index_dir2,
        "on-disk directory exists for fresh index before DROP TABLE ($index_dir2)");

    $node->safe_psql("postgres", "DROP TABLE vp_tbl;");
    ok(!-d $index_dir2,
        "on-disk directory removed after DROP TABLE cascade ($index_dir2)");

    $node->stop;
}

# ===========================================================================
# BGW save path — deferred save after INSERT, save failure + recovery
# ===========================================================================
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_deferred_save');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "svs.checkpoint_min_ops = 1");
    $node->append_conf('postgresql.conf', "svs.checkpoint_debounce_window = 1");
    $node->append_conf('postgresql.conf', "log_min_messages = 'debug1'");
    $node->start;

    my $pgdata = $node->data_dir;

    $node->safe_psql("postgres", "CREATE EXTENSION vector;");
    $node->safe_psql("postgres", "CREATE EXTENSION svs;");
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    # Deferred save after INSERT
    {
        $node->safe_psql("postgres", qq(
            CREATE TABLE ds_tbl (id serial PRIMARY KEY, val vector($dim));
            INSERT INTO ds_tbl (val)
                SELECT ARRAY[$array_sql]::vector
                FROM generate_series(1, 200) i;
            CREATE INDEX ds_idx ON ds_tbl USING vamana (val vector_l2_ops);
        ));

        my $index_oid = $node->safe_psql("postgres",
            "SELECT oid FROM pg_class WHERE relname = 'ds_idx';");
        chomp $index_oid;
        my $index_dir = vamana_save_dir($node, 'postgres', $index_oid);
        my $log_pos   = length($node->log_content());

        $node->safe_psql("postgres", qq(
            INSERT INTO ds_tbl (val) VALUES (ARRAY[$array_sql]::vector);
        ));

        ok(-d $index_dir, 'on-disk index directory present after INSERT');

        my $result = $node->safe_psql("postgres", qq(
            SET enable_seqscan = off;
            SELECT id FROM ds_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
        ));
        isnt($result, '', 'SELECT after INSERT returns results');

        ok(-d $index_dir, 'on-disk index directory present after deferred save');

        my @saved_files = glob("$index_dir/*");
        ok(scalar @saved_files > 0, 'on-disk index directory non-empty after save');
        is(scalar(grep { /\.tmp$/ } @saved_files), 0,
            'no temp files left behind after deferred save');

        my $chkpt_logged = 0;
        for (1 .. 20) {
            usleep(500_000);
            my $log_a = substr($node->log_content(), $log_pos);
            if ($log_a =~ /vamana index \d+: checkpoint complete, slot advanced to/) {
                $chkpt_logged = 1;
                last;
            }
        }
        ok($chkpt_logged, 'BGW checkpoint logged after INSERT');

        $node->safe_psql("postgres", "DROP TABLE ds_tbl;");
    }

    # Save failure and recovery when save directory is unwritable
    {
        $node->safe_psql("postgres", qq(
            CREATE TABLE vc_tbl (id serial PRIMARY KEY, val vector($dim));
            INSERT INTO vc_tbl (val)
                SELECT ARRAY[$array_sql]::vector
                FROM generate_series(1, 200) i;
            CREATE INDEX vc_idx ON vc_tbl USING vamana (val vector_l2_ops);
        ));

        my $index_oid = $node->safe_psql("postgres",
            "SELECT oid FROM pg_class WHERE relname = 'vc_idx';");
        chomp $index_oid;
        my $index_dir   = vamana_save_dir($node, 'postgres', $index_oid);
        my $save_parent = "$pgdata/vamana_indexes";

        my $bg = $node->background_psql("postgres");
        $bg->query_safe("SET client_min_messages = error;");

        chmod(0000, $save_parent) or die "chmod 0000 $save_parent: $!";
        my $log_pos_c = length($node->log_content());

        $bg->query_safe(qq(
            INSERT INTO vc_tbl (val) VALUES (ARRAY[$array_sql]::vector);
        ));

        chmod(0755, $save_parent) or die "chmod 0755 $save_parent: $!";

        $bg->query_safe(qq(
            INSERT INTO vc_tbl (val) VALUES (ARRAY[$array_sql]::vector);
        ));
        $bg->quit;

        ok(-d $index_dir, 'on-disk index directory exists after save recovery');

        $node->safe_psql("postgres", "DROP TABLE vc_tbl;");
    }

    $node->stop;
}

# ===========================================================================
# CREATE INDEX fails hard when the save directory is unwritable
# ===========================================================================
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_build_save_fail');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "log_min_messages = 'debug1'");
    $node->start;

    my $pgdata = $node->data_dir;

    $node->safe_psql("postgres", "CREATE EXTENSION vector;");
    $node->safe_psql("postgres", "CREATE EXTENSION svs;");
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    $node->safe_psql("postgres", qq(
        CREATE TABLE bi_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO bi_tbl (val)
            SELECT ARRAY[$array_sql]::vector
            FROM generate_series(1, 200) i;
    ));

    # Trigger lazy creation of vamana_indexes/ then lock it down.
    my $save_parent = "$pgdata/vamana_indexes";
    mkdir $save_parent unless -d $save_parent;
    chmod(0000, $save_parent) or die "chmod 0000 $save_parent: $!";

    my ($stdout, $stderr);
    my $ret = $node->psql("postgres",
        "CREATE INDEX bi_idx ON bi_tbl USING vamana (val vector_l2_ops);",
        stdout => \$stdout,
        stderr => \$stderr);

    chmod(0755, $save_parent) or die "chmod 0755 $save_parent: $!";

    isnt($ret, 0, 'CREATE INDEX exits non-zero when save dir is unwritable');
    like($stderr, qr/ERROR/,
        'CREATE INDEX reports ERROR when serialization fails');

    my $index_exists = $node->safe_psql("postgres",
        "SELECT count(*) FROM pg_class WHERE relname = 'bi_idx';");
    chomp $index_exists;
    is($index_exists, '0', 'index does not exist in catalog after failed CREATE INDEX');

    my @leftover = glob("$save_parent/*");
    is(scalar @leftover, 0,
        'no partial save directory left on disk after CREATE INDEX failure');

    # Confirm CREATE INDEX succeeds cleanly once disk is writable again.
    $node->safe_psql("postgres",
        "CREATE INDEX bi_idx ON bi_tbl USING vamana (val vector_l2_ops);");
    my $index_oid = $node->safe_psql("postgres",
        "SELECT oid FROM pg_class WHERE relname = 'bi_idx';");
    chomp $index_oid;
    ok(-d vamana_save_dir($node, 'postgres', $index_oid),
        'CREATE INDEX succeeds and on-disk directory exists after disk is writable');

    $node->safe_psql("postgres", "DROP TABLE bi_tbl;");
    $node->stop;
}

# ===========================================================================
# BGW after-rebuild save failure: index stays queryable, retry succeeds
# ===========================================================================
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_rebuild_save_fail');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "svs.checkpoint_min_ops = 1");
    $node->append_conf('postgresql.conf', "svs.checkpoint_debounce_window = 1");
    $node->append_conf('postgresql.conf', "log_min_messages = 'debug1'");
    $node->start;

    my $pgdata = $node->data_dir;

    $node->safe_psql("postgres", "CREATE EXTENSION vector;");
    $node->safe_psql("postgres", "CREATE EXTENSION svs;");
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    $node->safe_psql("postgres", qq(
        CREATE TABLE rb_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO rb_tbl (val)
            SELECT ARRAY[$array_sql]::vector
            FROM generate_series(1, 200) i;
        CREATE INDEX rb_idx ON rb_tbl USING vamana (val vector_l2_ops);
    ));

    my $index_oid = $node->safe_psql("postgres",
        "SELECT oid FROM pg_class WHERE relname = 'rb_idx';");
    chomp $index_oid;
    my $save_parent = "$pgdata/vamana_indexes";
    my $index_dir   = vamana_save_dir($node, 'postgres', $index_oid);

    # Remove the on-disk copy to force VamanaRebuildFromTable on next BGW load.
    remove_tree($index_dir) if -d $index_dir;

    # Lock the parent so the post-rebuild save fails.
    chmod(0000, $save_parent) or die "chmod 0000 $save_parent: $!";

    my $log_pos = length($node->log_content());

    # Restart to evict the cache; the rebuild fires on the first query.
    $node->restart;
    wait_for_worker($node);

    # Query while the save dir is still locked so the post-rebuild save fails.
    # An ORDER BY ... LIMIT is required: a distance predicate is not an
    # indexable qual, so it would seqscan and never reach the worker.
    $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM rb_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));

    my $save_failed = 0;
    for (1 .. 20) {
        if (substr($node->log_content(), $log_pos) =~
            /save after rebuild failed, will retry; index durability degraded/)
        {
            $save_failed = 1;
            last;
        }
        usleep(500_000);
    }

    chmod(0755, $save_parent) or die "chmod 0755 $save_parent: $!";

    my $log_after_restart = substr($node->log_content(), $log_pos);

    like($log_after_restart,
        qr/vamana index \d+: save after rebuild failed, will retry; index durability degraded/,
        'BGW logs when post-rebuild save fails');

    # The index must still be queryable from the in-memory cache.
    my $result = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT count(*) FROM rb_tbl WHERE val <-> '[$query_sql]' < 100;
    ));
    isnt($result, '', 'index still queryable after failed post-rebuild save');

    # Trigger a write so the checkpoint fires and re-creates the on-disk index.
    $node->safe_psql("postgres", qq(
        INSERT INTO rb_tbl (val) VALUES (ARRAY[$array_sql]::vector);
    ));

    my $dir_recreated = 0;
    for (1 .. 20) {
        usleep(500_000);
        if (-d $index_dir) { $dir_recreated = 1; last; }
    }
    ok($dir_recreated, 'on-disk index directory re-created after checkpoint');

    $node->safe_psql("postgres", "DROP TABLE rb_tbl;");
    $node->stop;
}

# ===========================================================================
# Search threads — SVSLoadIndex uses SVSDefaultSearchThreads(), not build threads
# ===========================================================================
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_search_threads');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "max_parallel_maintenance_workers = 2");
    $node->append_conf('postgresql.conf', "log_min_messages = 'debug1'");
    $node->start;

    $node->safe_psql("postgres", "CREATE EXTENSION vector;");
    $node->safe_psql("postgres", "CREATE EXTENSION svs;");
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    $node->safe_psql("postgres", qq(
        CREATE TABLE st_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO st_tbl (val)
            SELECT ARRAY[$array_sql]::vector
            FROM generate_series(1, 200) i;
        CREATE INDEX st_idx ON st_tbl USING vamana (val vector_l2_ops);
    ));

    my $log_pos_before_restart = length($node->log_content());
    $node->restart;

    my $after_restart = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM st_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));
    isnt($after_restart, '',
        'search returns results with max_parallel_maintenance_workers=2');

    my $new_log = substr($node->log_content(), $log_pos_before_restart);

    like($new_log,
        qr/loading SVS index with \d+ search threads \(svs\.search_num_threads=\d+, max_parallel_maintenance_workers=2\)/,
        'DEBUG1 log confirms SVSLoadIndex used SVSDefaultSearchThreads()');

    my $nproc_raw = `nproc 2>/dev/null`;
    chomp $nproc_raw;
    my $nproc = ($nproc_raw =~ /^(\d+)$/) ? int($1) : 0;
    my $expected_search_threads = $nproc > 1 ? $nproc - 1 : 1;

    if ($nproc >= 4)
    {
        like($new_log,
            qr/loading SVS index with $expected_search_threads search threads/,
            "search threads ($expected_search_threads = nproc-1) exceed max_parallel_maintenance_workers (2)");
    }
    else
    {
        pass("skipped: nproc=$nproc, nproc-1 may equal max_parallel_maintenance_workers");
    }

    $node->safe_psql("postgres",
        "ALTER SYSTEM SET svs.search_num_threads = 3;");
    my $log_pos_before_test4 = length($node->log_content());
    $node->restart;

    # Demand-driven load: query so SVSLoadIndex runs and logs its thread count.
    $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM st_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));

    my $log_test4 = '';
    for (1 .. 20) {
        $log_test4 = substr($node->log_content(), $log_pos_before_test4);
        last if $log_test4 =~
            /loading SVS index with 3 search threads \(svs\.search_num_threads=3/;
        usleep(500_000);
    }

    like($log_test4,
        qr/loading SVS index with 3 search threads \(svs\.search_num_threads=3/,
        'svs.search_num_threads=3 overrides auto default');

    $node->safe_psql("postgres",
        "ALTER SYSTEM RESET svs.search_num_threads;");

    $node->stop;
}

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
    unlike($new_log, qr/vamana index not in memory, rebuilding from table/,
        'no rebuild NOTICE on post-restart LeanVec query');
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
    unlike($third_restart_log, qr/vamana index not in memory, rebuilding from table/,
        'no rebuild NOTICE on LeanVec third restart');
    like($third_restart_log, qr/vamana index \d+ loaded from disk/,
        'LeanVec index loaded from disk on third restart');
    ok(-d $index_dir, 'on-disk index directory still exists after third restart');

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
# tidmap.bin header validation — a file whose header fails validation must be
# rejected and the index rebuilt from the heap, never silently zero-filled.
# Covers: VamanaLoadTidMap magic/version/capacity check
# ===========================================================================
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_tidmap_header');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
    $node->append_conf('postgresql.conf', "svs.checkpoint_min_ops = 1");
    $node->append_conf('postgresql.conf', "svs.checkpoint_debounce_window = 1");
    $node->append_conf('postgresql.conf', "log_min_messages = 'notice'");
    $node->start;

    $node->safe_psql('postgres', "CREATE EXTENSION vector;");
    $node->safe_psql('postgres', "CREATE EXTENSION svs;");
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    $node->safe_psql('postgres', qq{
        CREATE TABLE hdr_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO hdr_tbl (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 50);
        CREATE INDEX hdr_idx ON hdr_tbl USING vamana (val vector_l2_ops);
    });
    wait_for_worker($node, 30);

    my $ioid = $node->safe_psql('postgres',
        "SELECT oid FROM pg_class WHERE relname = 'hdr_idx';");
    chomp $ioid;
    my $tidmap = vamana_save_dir($node, 'postgres', $ioid) . "/tidmap.bin";

    # One more insert forces a checkpoint (min_ops=1) that persists tidmap.bin.
    $node->safe_psql('postgres',
        "INSERT INTO hdr_tbl (val) VALUES (ARRAY[$array_sql]::vector);");
    for (1 .. 20)
    {
        last if -f $tidmap;
        usleep(500_000);
    }
    $node->stop;
    ok(-f $tidmap, 'tidmap.bin written before corruption');

    # tidmap.bin holds heap TIDs and inherits its mode from the temp file the
    # rename published, so this is the observable test of that mode.
    # VamanaSaveTidMapAtomically (src/vamanaio.c) creates the temp file with
    # pg_file_create_mode and fchmod()s it to exactly that, so the result does
    # not depend on the postmaster's umask.  Expect 0600, or 0640 when the
    # cluster was initialized with group access.  No execute bit either way.
    my $tidmap_mode = (stat($tidmap))[2] & 07777;
    ok($tidmap_mode == 0600 || $tidmap_mode == 0640,
        sprintf('tidmap.bin mode is %04o (expect 0600, or 0640 with group access)',
                $tidmap_mode));

    ok(!-e "$tidmap.tmp", 'no tidmap.bin.tmp left behind after save');

    # Clobber the 4-byte magic in the header.
    open(my $fh, '+<:raw', $tidmap) or die "open $tidmap: $!";
    print $fh "\xDE\xAD\xBE\xEF";
    close($fh);

    my $log_pos = length($node->log_content());
    $node->start;
    wait_for_worker($node, 30);

    # Demand-driven load: the corrupt-TID-map rejection and heap rebuild fire
    # only when a backend queries the index.
    my $count = $node->safe_psql('postgres', qq{
        SET enable_seqscan = off;
        SELECT count(*) FROM (
            SELECT id FROM hdr_tbl ORDER BY val <-> '[$query_sql]' LIMIT 100000
        ) s;
    });
    chomp $count;

    my $log = substr($node->log_content(), $log_pos);
    like($log, qr/vamana index $ioid: TID map is malformed or larger than expected/,
        'corrupt tidmap.bin header rejected on load');
    like($log, qr/rebuilding vamana index from table data/,
        'index rebuilt from heap after rejection');

    is($count, 51, 'all 51 rows searchable after rebuild');

    $node->stop;
}

# ===========================================================================
# Save directories are namespaced by database — pg_class OIDs are unique per
# database, not per cluster, so CREATE DATABASE ... TEMPLATE can duplicate a
# relid across databases. A drop in one database must not touch another
# database's save directory at the same relid.
# ===========================================================================
{
    my $LAUNCHER_DB = 'postgres';
    my $SRC_DB      = 'src_db';

    my $node = PostgreSQL::Test::Cluster->new('vamana_savedir_ns');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "svs.launcher_database = '$LAUNCHER_DB'");
    $node->append_conf('postgresql.conf', "svs.max_databases = 4");
    $node->start;

    $node->safe_psql($LAUNCHER_DB, "CREATE EXTENSION vector;");
    $node->safe_psql($LAUNCHER_DB, "CREATE EXTENSION svs;");
    $node->safe_psql($LAUNCHER_DB, "CREATE DATABASE $SRC_DB;");
    $node->safe_psql($SRC_DB, "CREATE EXTENSION vector;");
    $node->safe_psql($SRC_DB, "CREATE EXTENSION svs;");

    $node->safe_psql($LAUNCHER_DB,
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('$SRC_DB', true);");
    wait_for_worker_db($node, $SRC_DB, 30);

    $node->safe_psql($SRC_DB, qq(
        CREATE TABLE src_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO src_tbl (val)
            SELECT ARRAY[$array_sql]::vector
            FROM generate_series(1, 200) i;
        CREATE INDEX src_idx ON src_tbl USING vamana (val vector_l2_ops);
    ));

    # Force the on-disk save so a directory actually exists to collide over.
    $node->safe_psql($SRC_DB, qq(
        SET enable_seqscan = off;
        SELECT id FROM src_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));

    my $relid = $node->safe_psql($SRC_DB,
        "SELECT oid FROM pg_class WHERE relname = 'src_idx';");
    chomp $relid;

    my $save_dir = vamana_save_dir($node, $SRC_DB, $relid);
    ok(-d $save_dir, "$SRC_DB: src_idx save directory exists before the clone");

    # CREATE DATABASE ... TEMPLATE requires the source to have no other active
    # connections, including the vamana worker's own backend. Disable src_db
    # and wait for its worker to drain and exit before cloning. The launcher's
    # own persistent connection is to $LAUNCHER_DB, not $SRC_DB, so it does
    # not block this.
    $node->safe_psql($LAUNCHER_DB,
        "UPDATE vamana_databases SET enabled = false WHERE datname = '$SRC_DB';");
    for (1 .. 100) {
        usleep(100_000);
        my $count = $node->safe_psql('postgres',
            "SELECT count(*) FROM pg_stat_activity "
          . "WHERE backend_type = 'vamana worker' AND datname = '$SRC_DB';");
        chomp $count;
        last if $count eq '0';
    }

    # Clone: pg_class OIDs are preserved by TEMPLATE, so clone_db's src_idx has
    # the identical relid as src_db's src_idx.
    $node->safe_psql($LAUNCHER_DB, "CREATE DATABASE clone_db TEMPLATE $SRC_DB;");

    my $clone_relid = $node->safe_psql('clone_db',
        "SELECT oid FROM pg_class WHERE relname = 'src_idx';");
    chomp $clone_relid;
    is($clone_relid, $relid,
        'clone_db src_idx has the same relid as src_db src_idx (collision set up)');

    # Re-enable src_db so its index is live again.
    $node->safe_psql($LAUNCHER_DB,
        "UPDATE vamana_databases SET enabled = true WHERE datname = '$SRC_DB';");
    wait_for_worker_db($node, $SRC_DB, 30);

    # Drop the index in the unrelated clone. clone_db was never enabled in
    # vamana_databases, so this exercises the object-access hook with no
    # worker slot for clone_db at all.
    $node->safe_psql('clone_db', "DROP INDEX src_idx;");

    ok(-d $save_dir,
        "dropping the clone's same-relid index does not delete ${SRC_DB}'s save directory");

    my $result = $node->safe_psql($SRC_DB, qq(
        SET enable_seqscan = off;
        SELECT id FROM src_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));
    isnt($result, '',
        "$SRC_DB index still queryable after the unrelated clone_db DROP INDEX");

    $node->stop;
}

# ===========================================================================
# Crash-orphan cleanup — a tidmap.bin.tmp left behind by a crash between the
# write and the rename must be removed, without disturbing the load.
# Covers: the orphan sweep at the top of VamanaLoadTidMap
# ===========================================================================
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_tidmap_orphan');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "svs.checkpoint_min_ops = 1");
    $node->append_conf('postgresql.conf', "svs.checkpoint_debounce_window = 1");

    # debug1 so the sweep's own message is visible: it distinguishes the sweep
    # from the save path, which also clears leftovers before it creates its
    # temp file.
    $node->append_conf('postgresql.conf', "log_min_messages = 'debug1'");
    $node->start;

    $node->safe_psql('postgres', "CREATE EXTENSION vector;");
    $node->safe_psql('postgres', "CREATE EXTENSION svs;");
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    $node->safe_psql('postgres', qq{
        CREATE TABLE orph_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO orph_tbl (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 50);
        CREATE INDEX orph_idx ON orph_tbl USING vamana (val vector_l2_ops);
    });
    wait_for_worker($node, 30);

    my $ioid = $node->safe_psql('postgres',
        "SELECT oid FROM pg_class WHERE relname = 'orph_idx';");
    chomp $ioid;
    my $tidmap = vamana_save_dir($node, 'postgres', $ioid) . "/tidmap.bin";
    my $orphan = "$tidmap.tmp";

    # One more insert forces a checkpoint (min_ops=1) that persists tidmap.bin.
    $node->safe_psql('postgres',
        "INSERT INTO orph_tbl (val) VALUES (ARRAY[$array_sql]::vector);");
    for (1 .. 20)
    {
        last if -f $tidmap;
        usleep(500_000);
    }
    ok(-f $tidmap, 'tidmap.bin written before orphan is planted');

    my $baseline = $node->safe_psql('postgres', qq{
        SET enable_seqscan = off;
        SELECT id FROM orph_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    });
    isnt($baseline, '', 'pre-orphan query returns results');

    $node->stop;

    # Plant the orphan a crash mid-save would leave.  Mode 0666 is deliberately
    # wider than anything the extension would create: it is the mode a leftover
    # temp file could carry into tidmap.bin, and it also shows the sweep does
    # not care what mode it finds.
    open(my $ofh, '>', $orphan) or die "open $orphan: $!";
    print $ofh "junk that is not a valid TID map";
    close($ofh);
    chmod(0666, $orphan) == 1 or die "chmod 0666 $orphan: $!";

    # Backdate it so it predates the next postmaster start.  The sweep skips
    # temp files newer than that, on the assumption they belong to a live writer.
    my $backdated = time() - 3600;
    utime($backdated, $backdated, $orphan) == 1 or die "utime $orphan: $!";

    my $log_pos = length($node->log_content());
    $node->start;

    # The load happens on the first query against the index.
    my $after = $node->safe_psql('postgres', qq{
        SET enable_seqscan = off;
        SELECT id FROM orph_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    });

    ok(!-e $orphan, 'orphaned tidmap.bin.tmp removed on load');

    my $log = substr($node->log_content(), $log_pos);
    like($log, qr/removed orphaned TID map temp file/,
        'orphan removal logged by the load-path sweep');

    ok(-f $tidmap, 'tidmap.bin untouched by orphan cleanup');
    is($after, $baseline, 'query results unchanged by orphan cleanup');
    unlike($log, qr/TID map is malformed/,
        'orphan did not interfere with loading the real TID map');

    $node->stop;
}

# ===========================================================================
# Rebuild input validation — a non-finite value that reached the heap must be
# rejected when the worker rebuilds the index from table data.
# Covers: the "rebuild" guard in VamanaRebuildFromTable (src/vamanabuild.c)
#
# This is the only coverage for that guard.  It cannot be reached from
# test/sql/: BuildCallback rejects any CREATE INDEX over a non-finite value,
# and vamanainsert rejects any such value added to an already-indexed table,
# so no SQL route leaves NaN in the heap beside a valid index.  Two things are
# needed to construct that state:
#
#   - A raw datum.  pgvector's vector_in rejects NaN before the extension is
#     reached, so the value arrives through a bytea -> vector cast declared
#     WITHOUT FUNCTION, which reinterprets the bytes with no validation.
#
#   - A write that skips the index.  Clearing pg_index.indisready stops
#     PostgreSQL maintaining the index on DML, so the INSERT never calls
#     vamanainsert and the value lands in the heap only.  It is restored
#     immediately afterwards, leaving a valid index over a heap the other two
#     guards would never have permitted.
#
# The guard's own message cannot be asserted on: VamanaWorkerGetOrLoadIndex
# runs the rebuild under VamanaRunInSubXact and frees the ErrorData, discarding
# the text.  The observable consequence is checked instead, and the recovery
# step at the end is what attributes the failure to the planted value rather
# than to the forced-rebuild procedure itself.
#
# log_min_messages must stay below WARNING: in that GUC LOG outranks WARNING,
# so the default would suppress the warning matched below.
# ===========================================================================
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_rebuild_nan');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "log_min_messages = 'notice'");
    $node->start;

    $node->safe_psql('postgres', "CREATE EXTENSION vector;");
    $node->safe_psql('postgres', "CREATE EXTENSION svs;");
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");
    wait_for_worker($node, 30);

    # The payload used below encodes three dimensions, so this block uses
    # vector(3) rather than the shared $dim.
    $node->safe_psql('postgres',
        "CREATE CAST (bytea AS vector) WITHOUT FUNCTION;");
    $node->safe_psql('postgres', qq{
        CREATE TABLE rbnan_tbl (id serial PRIMARY KEY, val vector(3));
        INSERT INTO rbnan_tbl (val) VALUES ('[1,1,1]'), ('[2,2,2]');
        CREATE INDEX rbnan_idx ON rbnan_tbl USING vamana (val vector_l2_ops);
    });

    my $ioid = $node->safe_psql('postgres',
        "SELECT oid FROM pg_class WHERE relname = 'rbnan_idx';");
    chomp $ioid;
    my $save_dir = vamana_save_dir($node, 'postgres', $ioid);

    my $query = "SET enable_seqscan = off; "
              . "SELECT id FROM rbnan_tbl ORDER BY val <-> '[1,1,1]' LIMIT 2;";

    # 16-byte bytea payload read as a vector body: int16 dim=3, int16 unused=0,
    # then three little-endian float4s of which the first is 0x7FC00000, a
    # quiet NaN.  q{} keeps Perl from interpreting the \x.
    my $nan_datum = q{'\x030000000000c07f0000803f0000803f'::bytea::vector};

    # Inserting the value directly is not possible: vamanainsert rejects it
    # while the index exists, and BuildCallback rejects it on any subsequent
    # CREATE INDEX, so neither ordering leaves it in the heap.  Both of those
    # refusals are already covered by the bytea-cast cases in
    # test/sql/vector.sql, which is why the detour below is needed here.
    #
    # Take the index out of the write path for one statement.  Each safe_psql
    # is its own session, so the INSERT connects after the catalog change and
    # reads the updated indisready.
    $node->safe_psql('postgres',
        "UPDATE pg_index SET indisready = false "
      . "WHERE indexrelid = 'rbnan_idx'::regclass;");
    $node->safe_psql('postgres',
        "INSERT INTO rbnan_tbl (val) VALUES ($nan_datum);");
    $node->safe_psql('postgres',
        "UPDATE pg_index SET indisready = true "
      . "WHERE indexrelid = 'rbnan_idx'::regclass;");

    is($node->safe_psql('postgres',
            "SELECT count(*) FROM rbnan_tbl WHERE val::text LIKE '%NaN%';"),
        '1', 'non-finite value reached the heap');
    is($node->safe_psql('postgres',
            "SELECT indisvalid FROM pg_index "
          . "WHERE indexrelid = 'rbnan_idx'::regclass;"),
        't', 'index is still valid after the detour');

    # Drop the on-disk copy so the next request has to rebuild from the heap.
    # It must go while the cluster is down: a running worker checkpoints the
    # index on shutdown and would write a fresh copy straight back.
    $node->stop;
    remove_tree($save_dir) if -d $save_dir;
    ok(!-d $save_dir, 'save directory removed while cluster is down');

    my $log_pos = length($node->log_content());
    $node->start;
    wait_for_worker($node, 30);

    my ($out, $err) = ('', '');
    my $rc = $node->psql('postgres', $query,
        stdout => \$out, stderr => \$err);
    isnt($rc, 0, 'query fails while the heap holds a non-finite value');
    like($err, qr/not loaded/,
        'backend reports the index could not be loaded');

    my $log = substr($node->log_content(), $log_pos);
    like($log, qr/rebuilding vamana index from table data/,
        'rebuild from table data was attempted');
    like($log, qr/failed to load index/,
        'worker reports the rebuild failed');

    # Recovery: the same index rebuilds cleanly once the row is gone.
    $node->safe_psql('postgres',
        "DELETE FROM rbnan_tbl WHERE val::text LIKE '%NaN%';");

    $node->stop;
    remove_tree($save_dir) if -d $save_dir;
    $node->start;
    wait_for_worker($node, 30);

    # The save directory was removed again, so answering this query requires a
    # second rebuild from the heap: succeeding here means the guard passed the
    # same data once the offending row was gone.
    isnt($node->safe_psql('postgres', $query), '',
        'rebuild succeeds once the non-finite value is removed');

    $node->stop;
}

done_testing();
