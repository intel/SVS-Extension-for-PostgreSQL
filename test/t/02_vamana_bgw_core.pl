# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 02_vamana_bgw_core.pl — BGW lifecycle: startup, query correctness,
# restart/crash recovery, multi-database, GUC reload, timeout, and
# search_window_size boundary.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep gettimeofday tv_interval);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

{
    my $node = PostgreSQL::Test::Cluster->new('vamana_bgw');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "log_min_messages = 'notice'");
    $node->start;

    $node->safe_psql("postgres", "CREATE EXTENSION vector;");
    $node->safe_psql("postgres", "CREATE EXTENSION svs;");
    $node->safe_psql("postgres",
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    $node->safe_psql("postgres", qq(
        CREATE TABLE bgw_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO bgw_tbl (val)
            SELECT ARRAY[$array_sql]::vector
            FROM generate_series(1, 200) i;
        CREATE INDEX bgw_idx ON bgw_tbl USING vamana (val vector_l2_ops);
    ));

    my $worker_pid = wait_for_worker($node);
    ok($worker_pid =~ /^\d+$/,
        "vamana background worker process is running (pid=$worker_pid)");

    my $worker_results = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM bgw_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));
    isnt($worker_results, '', 'worker-mode query returns non-empty results');

    my $log_after_worker = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM bgw_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));
    isnt($log_after_worker, '', 'worker-mode query still returns results');
    my $log = $node->log_content();
    unlike($log, qr/vamana index not in memory, rebuilding from table/,
        'no per-backend rebuild when worker is enabled');

    my $log_pos_before_restart = length($node->log_content());
    $node->restart;

    my $after_restart = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM bgw_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));
    is($after_restart, $worker_results,
        'results consistent after server restart (worker mode)');

    my $restart_log = substr($node->log_content(), $log_pos_before_restart);
    unlike($restart_log, qr/rebuilding vamana index from table data/,
        'worker loaded from disk after restart — no table rebuild');
    like($restart_log, qr/vamana index \d+ loaded from disk/,
        'server log confirms disk load on restart');

    # All backends are held in VamanaWorkerWaitUntilAvailable until the cache
    # is warm, so no cold loads should appear during a post-restart burst.
    {
        my $log_pos_before_burst = length($node->log_content());

        my @burst_results = run_synchronized(
            $node, 'postgres', 5,
            sub { "SET enable_seqscan = off;\n" },
            sub { "SELECT id FROM bgw_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;\n" },
        );

        my $burst_log = substr($node->log_content(), $log_pos_before_burst);

        my $all_ok = 1;
        for my $r (@burst_results)
        {
            $all_ok = 0 unless defined $r && $r ne '';
        }
        ok($all_ok, 'all 5 concurrent post-restart queries return results');

        unlike($burst_log, qr/loading vamana index \d+/,
            'no disk load during concurrent query burst — cache was warm at dispatch');
    }

    # SLOTKIND_LOAD: cache warm after CREATE INDEX — first INSERT must not
    # trigger a cold load.  The BGW guarantees the cache is warm before
    # vamanabuild returns, so the first INSERT slot must not emit
    # "loading vamana index %u" before calling SVSAddPoints.
    {
        $node->safe_psql("postgres", qq(
            CREATE TABLE warm_tbl (id serial PRIMARY KEY, val vector($dim));
            INSERT INTO warm_tbl (val)
                SELECT ARRAY[$array_sql]::vector
                FROM generate_series(1, 50) i;
        ));

        my $log_pos_before_create = length($node->log_content());

        $node->safe_psql("postgres",
            "CREATE INDEX warm_idx ON warm_tbl USING vamana (val vector_l2_ops);");

        my $log_pos_after_create = length($node->log_content());

        $node->safe_psql("postgres", qq(
            INSERT INTO warm_tbl (val) VALUES (ARRAY[$array_sql]::vector);
        ));

        my $insert_log = substr($node->log_content(), $log_pos_after_create);
        unlike($insert_log, qr/loading vamana index \d+/,
            'first INSERT after CREATE INDEX does not trigger a cold BGW cache load');

        my $warm_result = $node->safe_psql("postgres", qq(
            SET enable_seqscan = off;
            SELECT id FROM warm_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
        ));
        isnt($warm_result, '',
            'search returns results after first INSERT on freshly built index');
    }

    $node->safe_psql("postgres", qq(
        INSERT INTO bgw_tbl (val) VALUES (ARRAY[$array_sql]::vector);
    ));
    my $after_insert = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM bgw_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));
    isnt($after_insert, '', 'worker-mode query returns results after INSERT');

    my $worker_pid_after_insert = wait_for_worker($node);
    ok($worker_pid_after_insert =~ /^\d+$/,
        'worker still running after INSERT');

    $node->stop('immediate');
    $node->start;

    my $post_crash_pid = wait_for_worker($node, 20);
    ok($post_crash_pid =~ /^\d+$/,
        "vamana background worker running after crash recovery (pid=$post_crash_pid)");

    sleep(2);

    my $after_crash = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM bgw_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));
    isnt($after_crash, '', 'queries work after crash recovery');
    is($after_crash, $after_insert,
        'results after crash recovery match post-insert baseline');

    $node->safe_psql("postgres", "CREATE DATABASE drop_test_db;");
    my ($drop_ret, undef, undef) = $node->psql(
        'postgres', 'DROP DATABASE drop_test_db;', timeout => 15);
    is($drop_ret, 0, 'DROP DATABASE completes while vamana worker is running');

    my ($drop_if_ret, undef, undef) = $node->psql(
        'postgres', 'DROP DATABASE IF EXISTS nonexistent_db;', timeout => 15);
    is($drop_if_ret, 0, 'DROP DATABASE IF EXISTS nonexistent_db completes');

    $node->safe_psql("postgres", "CREATE DATABASE regress_test_db;");
    my ($full_cycle_ret, undef, undef) = $node->psql(
        'postgres', 'DROP DATABASE regress_test_db;', timeout => 15);
    is($full_cycle_ret, 0, 'CREATE then DROP DATABASE completes with worker running');

    $node->stop;
    $node->append_conf('postgresql.conf', "svs.max_batch_size = 1");
    $node->start;

    for my $i (1 .. 3)
    {
        my $result = $node->safe_psql("postgres", qq(
            SET enable_seqscan = off;
            SELECT id FROM bgw_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
        ));
        isnt($result, '', "query $i returns results with max_batch_size=1");
        is($result, $after_insert, "query $i results match baseline with max_batch_size=1");
    }

    # Dynamic enable: inserting an enabled row for testdb drives the launcher
    # (via NOTIFY) to spawn testdb's worker with no restart.  postgres stays
    # enabled from the top of this block, so both workers run concurrently.
    $node->safe_psql("postgres", "CREATE DATABASE testdb;");
    $node->safe_psql("testdb",   "CREATE EXTENSION vector;");
    $node->safe_psql("testdb",   "CREATE EXTENSION svs;");
    $node->safe_psql("testdb", qq(
        CREATE TABLE testdb_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO testdb_tbl (val)
            SELECT ARRAY[$array_sql]::vector
            FROM generate_series(1, 200) i;
    ));

    my $log_pos_before_testdb = length($node->log_content());
    $node->safe_psql("postgres",
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('testdb', true);");

    my $testdb_worker_pid = wait_for_worker_db($node, 'testdb', 20);
    ok($testdb_worker_pid =~ /^\d+$/,
        "launcher spawns a worker for testdb after dynamic enable (pid=$testdb_worker_pid)");

    $node->safe_psql("testdb",
        "CREATE INDEX testdb_idx ON testdb_tbl USING vamana (val vector_l2_ops);");

    sleep(2);

    my $testdb_results = $node->safe_psql("testdb", qq(
        SET enable_seqscan = off;
        SELECT id FROM testdb_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));
    isnt($testdb_results, '', 'testdb worker serves queries after dynamic enable');

    my $testdb_log = substr($node->log_content(), $log_pos_before_testdb);
    like($testdb_log,
        qr/vamana background worker started for database "testdb"/,
        'server log confirms worker started for testdb');

    # A database with no vamana_databases row is unconfigured: after the
    # launcher's initial scan, AssertDatabase hard-fails such a backend rather
    # than spinning out the startup wait.  This is the config half of the
    # config/liveness split.
    $node->safe_psql("postgres", "CREATE DATABASE unconfigured_db;");
    $node->safe_psql("unconfigured_db", "CREATE EXTENSION vector;");
    $node->safe_psql("unconfigured_db", "CREATE EXTENSION svs;");
    # An empty table is deliberate: the config gate is checked before the table
    # scan, so CREATE INDEX must fail regardless of the heap's contents.
    my ($unconf_ret, undef, $unconf_err) = $node->psql("unconfigured_db", qq(
        CREATE TABLE u_tbl (id serial PRIMARY KEY, val vector($dim));
        CREATE INDEX u_idx ON u_tbl USING vamana (val vector_l2_ops);
    ));
    like($unconf_err,
        qr/vamana index is not enabled for this database/,
        'backend in an unconfigured database gets a config hard-fail');

    # A disabled row never gets a shmem slot reserved, so the config gate sees
    # the same missing slot as an absent row and must raise the same error.
    $node->safe_psql("postgres", "CREATE DATABASE disabled_db;");
    $node->safe_psql("disabled_db", "CREATE EXTENSION vector;");
    $node->safe_psql("disabled_db", "CREATE EXTENSION svs;");
    $node->safe_psql("postgres",
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('disabled_db', false);");
    my ($disabled_ret, undef, $disabled_err) = $node->psql("disabled_db", qq(
        CREATE TABLE d_tbl (id serial PRIMARY KEY, val vector($dim));
        CREATE INDEX d_idx ON d_tbl USING vamana (val vector_l2_ops);
    ));
    like($disabled_err,
        qr/vamana index is not enabled for this database/,
        'present-but-disabled database gets the same config hard-fail as absent');

    # The gate fires before the relation, its catalog row, or its on-disk save
    # directory ($PGDATA/vamana_indexes/<dboid>/<relid>) exist, so a failure
    # leaves none.
    $node->safe_psql("disabled_db",
        "CREATE TABLE na_tbl (id serial PRIMARY KEY, val vector($dim));");

    my $vamana_dir = $node->data_dir . "/vamana_indexes";
    my $count_index_dirs = sub {
        return 0 unless -d $vamana_dir;
        opendir(my $dh, $vamana_dir) or die "opendir $vamana_dir: $!";
        my @e = grep { !/^\.\.?$/ } readdir($dh);
        closedir($dh);
        return scalar @e;
    };
    my $dirs_before = $count_index_dirs->();

    my ($na_ret, undef, $na_err) = $node->psql("disabled_db",
        "CREATE INDEX na_idx ON na_tbl USING vamana (val vector_l2_ops);");
    like($na_err,
        qr/vamana index is not enabled for this database/,
        'unconfigured-database CREATE INDEX hard-fails');
    is($node->safe_psql("disabled_db", "SELECT to_regclass('na_idx') IS NULL;"),
        't', 'no relation survives the failed CREATE INDEX');
    is($node->safe_psql("disabled_db",
            "SELECT count(*) FROM pg_class WHERE relname = 'na_idx';"),
        '0', 'pg_class has no row for the attempted index');
    is($count_index_dirs->(), $dirs_before,
        'no on-disk save directory created by the failed build');

    my $postgres_worker_pid = wait_for_worker_db($node, 'postgres', 20);
    ok($postgres_worker_pid =~ /^\d+$/,
        "postgres worker still running alongside testdb worker (pid=$postgres_worker_pid)");

    # With a live worker, CREATE INDEX takes the available fast path and builds
    # immediately, with no startup wait.
    $node->safe_psql("postgres", qq(
        CREATE TABLE running_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO running_tbl (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 200) i;
    ));
    my $t0 = [gettimeofday];
    $node->safe_psql("postgres",
        "CREATE INDEX running_idx ON running_tbl USING vamana (val vector_l2_ops);");
    my $running_elapsed = tv_interval($t0);
    ok($running_elapsed < 5,
        "CREATE INDEX with a running worker proceeds without a startup wait (${running_elapsed}s)");
    is($node->safe_psql("postgres", qq(
            SET enable_seqscan = off;
            SELECT count(*) FROM (
                SELECT id FROM running_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5
            ) q;
        )), '5', 'running-worker index serves queries after the no-wait build');

    sleep(2);

    $node->safe_psql("postgres", "ALTER SYSTEM SET svs.worker_timeout_ms = 100;");
    $node->safe_psql("postgres", "SELECT pg_reload_conf();");

    kill('STOP', $postgres_worker_pid);
    usleep(100_000);

    my ($timeout_ret, undef, $timeout_err) = $node->psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM bgw_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));

    kill('CONT', $postgres_worker_pid);

    like($timeout_err,
        qr/vamana background worker unavailable/,
        'worker timeout raises ERROR');

    $node->safe_psql("postgres", "ALTER SYSTEM RESET svs.worker_timeout_ms;");
    $node->safe_psql("postgres", "SELECT pg_reload_conf();");

    $node->safe_psql("postgres", "ALTER SYSTEM SET svs.worker_timeout_ms = 200;");
    $node->safe_psql("postgres", "SELECT pg_reload_conf();");
    sleep(2);

    my $reloaded_val = $node->safe_psql("postgres",
        "SELECT current_setting('svs.worker_timeout_ms');");
    is($reloaded_val, '200',
        'svs.worker_timeout_ms updated via SIGHUP without restart');

    $node->safe_psql("postgres", "ALTER SYSTEM RESET svs.worker_timeout_ms;");
    $node->safe_psql("postgres", "SELECT pg_reload_conf();");

    $node->safe_psql("postgres", qq(
        CREATE TABLE bgw_tbl2 (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO bgw_tbl2 (val)
            SELECT ARRAY[$array_sql]::vector
            FROM generate_series(1, 100) i;
        CREATE INDEX bgw_idx2 ON bgw_tbl2 USING vamana (val vector_l2_ops);
    ));
    sleep(2);

    for my $tbl ('bgw_tbl', 'bgw_tbl2')
    {
        my $multi_result = $node->safe_psql("postgres", qq(
            SET enable_seqscan = off;
            SELECT id FROM $tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
        ));
        isnt($multi_result, '', "worker serves queries against $tbl with two indexes");
    }

    my $boundary_result = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SET svs.search_window_size = 10000;
        SELECT id FROM bgw_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));
    isnt($boundary_result, '',
        'query with search_window_size at maximum (10000) returns results');

    my $out_of_range_err = '';
    eval {
        $node->safe_psql("postgres", "SET svs.search_window_size = 10001;");
    };
    $out_of_range_err = $@ if $@;
    like($out_of_range_err, qr/outside the valid range|out of range|invalid value/i,
        'GUC rejects search_window_size exceeding maximum (10000)');

    $node->stop;
}

done_testing();
