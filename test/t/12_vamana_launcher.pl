# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 12_vamana_launcher.pl — the launcher and per-database worker entry point.
#
# The launcher is the one statically-registered background worker.  It reads
# the enabled rows from vamana_databases in svs.launcher_database and spawns
# one dynamic per-database worker for each, adding workers as new rows are
# enabled.  These tests exercise the launcher and the workers it owns together,
# against real running processes.
#
# Coverage (test numbers follow m04_launcher_core.md):
#   1.  Startup spawns workers for all enabled rows (and only those).
#   2.  A row enabled at runtime gets a worker with no restart (NOTIFY path).
#   9.  Per-worker isolation: each worker is bound to its own database.
#   10. Per-database availability: a backend sees only its own worker's slot.
#   11. VamanaWorkerAssertDatabase is a per-database config gate.
#   12. Standby behavior: the launcher starts on a hot standby and its
#       worker's hot_standby_feedback requirement still holds.
#   17. GUC inventory: svs.worker_database is gone; the launcher GUCs exist.
#   18. VamanaInit registers the launcher (its worker is "vamana launcher").
#   19. No dangling svs.worker_database reference reaches a running server.
#
# Tests 3 (stop-on-disable) and 4 (DELETE-rejection) are owned by the pause
# (M8) and permanent-removal (M10) modules: the launcher's reconcile loop in
# this phase only spawns missing workers, and there is no BEFORE DELETE
# trigger yet.  They are covered when those modules land, not here.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

# Count running vamana workers, optionally filtered by database name.
sub worker_count
{
    my ($node, $db) = @_;
    my $filter = defined $db ? "AND datname = '$db'" : "";
    my $c = $node->safe_psql('postgres',
        "SELECT count(*) FROM pg_stat_activity "
      . "WHERE backend_type = 'vamana worker' $filter;");
    chomp $c;
    return $c;
}

# Poll until the number of running vamana workers reaches $want (up to
# $attempts x 0.5s).  Returns the final observed count.
sub wait_for_worker_count
{
    my ($node, $want, $attempts) = @_;
    $attempts //= 30;
    my $count = 0;
    for (1 .. $attempts)
    {
        usleep(500_000);
        $count = worker_count($node);
        last if $count >= $want;
    }
    return $count;
}

# ---------------------------------------------------------------------------
# Test 1: startup spawns a worker for every enabled row, and only those.
#
# Seed vamana_databases with a mix of enabled/disabled rows, then restart so
# the launcher's initial scan is the sole source of truth.  Only the enabled
# databases must have a running worker after startup.
# ---------------------------------------------------------------------------
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_launcher_startup');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
    $node->start;

    $node->safe_psql('postgres', "CREATE EXTENSION vector;");
    $node->safe_psql('postgres', "CREATE EXTENSION svs;");

    $node->safe_psql('postgres', "CREATE DATABASE enabled_a;");
    $node->safe_psql('postgres', "CREATE DATABASE enabled_b;");
    $node->safe_psql('postgres', "CREATE DATABASE disabled_c;");

    # Seed a mix of rows before the launcher's scan is authoritative.
    $node->safe_psql('postgres', qq{
        INSERT INTO vamana_databases (datname, enabled) VALUES
            ('postgres',   true),
            ('enabled_a',  true),
            ('enabled_b',  true),
            ('disabled_c', false);
    });

    # Restart so the launcher materializes purely from the seeded table.
    $node->restart;

    my $enabled_count = wait_for_worker_count($node, 3, 40);
    is($enabled_count, '3',
        'launcher spawns a worker for each of the 3 enabled databases');

    is(worker_count($node, 'disabled_c'), '0',
        'no worker for the disabled database');
    is(worker_count($node, 'enabled_a'), '1', 'worker present for enabled_a');
    is(worker_count($node, 'enabled_b'), '1', 'worker present for enabled_b');

    $node->stop;
}

# ---------------------------------------------------------------------------
# Test 2: a row enabled at runtime gets a worker with no restart.
#
# The INSERT fires NOTIFY vamana_databases_changed; the launcher's reconcile
# pass diffs the table against its ledger and spawns the missing worker
# without any server restart.
# ---------------------------------------------------------------------------
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_launcher_runtime');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
    $node->start;

    $node->safe_psql('postgres', "CREATE EXTENSION vector;");
    $node->safe_psql('postgres', "CREATE EXTENSION svs;");
    $node->safe_psql('postgres', "CREATE DATABASE runtime_db;");

    is(worker_count($node, 'runtime_db'), '0',
        'no worker before the database is enabled');

    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('runtime_db', true);");

    my $pid = wait_for_worker_db($node, 'runtime_db', 30);
    ok($pid =~ /^\d+$/,
        "launcher spawns a worker for a runtime-enabled database (pid=$pid)");

    $node->stop;
}

# ---------------------------------------------------------------------------
# Tests 9 + 10: per-worker isolation and per-database availability.
#
# pg_stat_vamana_worker is per-connected-database: the SRF looks up the slot
# for MyDatabaseId, so each backend sees only its own worker.  With workers for
# three databases running, a backend in iso_a must see a slot whose db_oid is
# iso_a's OID (never iso_b's), and vice versa — direct proof that the launcher
# passed each dbOid as bgw_main_arg and each worker bound to its own database.
# ---------------------------------------------------------------------------
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_launcher_isolation');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
    $node->start;

    $node->safe_psql('postgres', "CREATE EXTENSION vector;");
    $node->safe_psql('postgres', "CREATE EXTENSION svs;");
    $node->safe_psql('postgres', "CREATE DATABASE iso_a;");
    $node->safe_psql('postgres', "CREATE DATABASE iso_b;");
    $node->safe_psql('iso_a', "CREATE EXTENSION vector;");
    $node->safe_psql('iso_a', "CREATE EXTENSION svs;");
    $node->safe_psql('iso_b', "CREATE EXTENSION vector;");
    $node->safe_psql('iso_b', "CREATE EXTENSION svs;");

    $node->safe_psql('postgres', qq{
        INSERT INTO vamana_databases (datname, enabled) VALUES
            ('postgres', true), ('iso_a', true), ('iso_b', true);
    });

    wait_for_worker_count($node, 3, 40);

    my $iso_a_oid = $node->safe_psql('postgres',
        "SELECT oid FROM pg_database WHERE datname = 'iso_a';");
    chomp $iso_a_oid;
    my $iso_b_oid = $node->safe_psql('postgres',
        "SELECT oid FROM pg_database WHERE datname = 'iso_b';");
    chomp $iso_b_oid;

    # Test 9: each backend's view reports exactly its own worker, bound to its
    # own database OID.  The launcher passed dbOid as bgw_main_arg; the worker
    # recorded MyDatabaseId in its slot, which the SRF resolves per backend.
    my $seen_a = $node->safe_psql('iso_a',
        "SELECT DISTINCT db_oid FROM pg_stat_vamana_worker;");
    chomp $seen_a;
    is($seen_a, $iso_a_oid,
        'a backend in iso_a sees only iso_a\'s worker (main_arg honored)');

    my $seen_b = $node->safe_psql('iso_b',
        "SELECT DISTINCT db_oid FROM pg_stat_vamana_worker;");
    chomp $seen_b;
    is($seen_b, $iso_b_oid,
        'a backend in iso_b sees only iso_b\'s worker (no cross-db leakage)');

    # Test 10: a backend in iso_a, forced to search, is served by iso_a's own
    # worker.  A successful worker-mode search proves the backend resolved its
    # own database's slot end to end.
    $node->safe_psql('iso_a', qq{
        CREATE TABLE t (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO t (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 50);
        CREATE INDEX ON t USING vamana (val vector_l2_ops);
    });

    my $res = $node->safe_psql('iso_a', qq{
        SET enable_seqscan = off;
        SELECT id FROM t ORDER BY val <-> '[$query_sql]' LIMIT 5;
    });
    isnt($res, '',
        'backend in iso_a is served by iso_a\'s own worker (search succeeds)');

    $node->stop;
}

# ---------------------------------------------------------------------------
# Test 11: VamanaWorkerAssertDatabase is a per-database config gate.
#
# After the launcher's initial scan, a backend in an unconfigured database
# hard-fails on CREATE INDEX — the gate is keyed on MyDatabaseId's slot, not a
# single global dbOid.  A configured database in the same cluster succeeds,
# proving the check discriminates per database rather than globally.
# ---------------------------------------------------------------------------
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_launcher_assert');
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
    wait_for_worker_db($node, 'postgres', 30);

    # Configured database: the build is accepted.
    $node->safe_psql('postgres', qq{
        CREATE TABLE ok_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO ok_tbl (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 20);
    });
    my ($ok_ret, undef, $ok_err) = $node->psql('postgres',
        "CREATE INDEX ok_idx ON ok_tbl USING vamana (val vector_l2_ops);");
    is($ok_ret, 0, 'CREATE INDEX succeeds in the configured (postgres) database');

    # Unconfigured database: the same statement hard-fails on the config gate.
    # The empty table is deliberate — the gate is checked before the table
    # scan, so the failure cannot depend on the heap having rows.
    $node->safe_psql('postgres', "CREATE DATABASE assert_unconf;");
    $node->safe_psql('assert_unconf', "CREATE EXTENSION vector;");
    $node->safe_psql('assert_unconf', "CREATE EXTENSION svs;");
    my ($bad_ret, undef, $bad_err) = $node->psql('assert_unconf', qq{
        CREATE TABLE u_tbl (id serial PRIMARY KEY, val vector($dim));
        CREATE INDEX u_idx ON u_tbl USING vamana (val vector_l2_ops);
    });
    like($bad_err, qr/vamana index is not enabled for this database/,
        'CREATE INDEX hard-fails in an unconfigured database (per-database gate)');

    $node->stop;
}

# ---------------------------------------------------------------------------
# Test 12: standby behavior is preserved under the launcher.
#
# The launcher registers with BgWorkerStart_ConsistentState, so it must start
# on a hot standby before recovery finishes.  A worker whose slot loads on the
# standby needs hot_standby_feedback; with it off, the worker logs the
# documented requirement.  Both are launcher-owned behaviors that must survive
# the per-db entry-point cutover.
# ---------------------------------------------------------------------------
{
    my $primary = PostgreSQL::Test::Cluster->new('vamana_launcher_primary');
    $primary->init(allows_streaming => 1);
    $primary->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $primary->append_conf('postgresql.conf', "wal_level = logical");
    $primary->append_conf('postgresql.conf', "max_replication_slots = 10");
    $primary->append_conf('postgresql.conf', "max_wal_senders = 10");
    $primary->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
    $primary->start;

    $primary->safe_psql('postgres', "CREATE EXTENSION vector;");
    $primary->safe_psql('postgres', "CREATE EXTENSION svs;");
    $primary->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");
    $primary->safe_psql('postgres', qq{
        CREATE TABLE s_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO s_tbl (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 50);
        CREATE INDEX s_idx ON s_tbl USING vamana (val vector_l2_ops);
    });
    wait_for_worker_db($primary, 'postgres', 30);

    my $backup = 'launcher_standby_backup';
    $primary->backup($backup);

    my $standby = PostgreSQL::Test::Cluster->new('vamana_launcher_standby');
    $standby->init_from_backup($primary, $backup, has_streaming => 1);
    $standby->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $standby->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
    $standby->append_conf('postgresql.conf', "hot_standby = on");
    # Deliberately leave hot_standby_feedback off to elicit the worker warning.
    $standby->append_conf('postgresql.conf', "hot_standby_feedback = off");
    $standby->append_conf('postgresql.conf', "log_min_messages = debug1");
    $standby->start;

    $primary->wait_for_replay_catchup($standby);

    # The launcher must come up on the standby (ConsistentState, before
    # RecoveryFinished) and spawn the postgres worker there.
    my $standby_pid = wait_for_worker_db($standby, 'postgres', 40);
    ok($standby_pid =~ /^\d+$/,
        "launcher starts on the hot standby and spawns a worker (pid=$standby_pid)");

    # With hot_standby_feedback off, the standby worker logs the documented
    # requirement as it tries to create its replay slot.
    my $logfile = $standby->logfile;
    my $log = '';
    for (1 .. 30)
    {
        usleep(500_000);
        open(my $fh, '<', $logfile) or next;
        $log = do { local $/; <$fh> };
        close($fh);
        last if $log =~ /hot_standby_feedback/;
    }
    like($log,
        qr/vamana replay on standby requires hot_standby_feedback = on/,
        'standby worker logs the hot_standby_feedback requirement');

    $standby->stop;
    $primary->stop;
}

# ---------------------------------------------------------------------------
# Tests 17 + 18 + 19: GUC inventory and entry-point cutover.
#
# The old single-worker GUC is gone; the launcher GUCs exist with the
# documented contexts.  The registered static worker is the launcher, and no
# running code path still reads svs.worker_database.
# ---------------------------------------------------------------------------
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_launcher_cutover');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
    $node->start;

    $node->safe_psql('postgres', "CREATE EXTENSION vector;");
    $node->safe_psql('postgres', "CREATE EXTENSION svs;");

    # Test 17: svs.worker_database no longer exists.
    my $removed = $node->safe_psql('postgres',
        "SELECT count(*) FROM pg_settings WHERE name = 'svs.worker_database';");
    chomp $removed;
    is($removed, '0', 'svs.worker_database GUC no longer exists');

    # Test 17: the launcher GUCs exist with the documented contexts.
    my %expected_ctx = (
        'svs.launcher_database'       => 'postmaster',
        'svs.max_databases'           => 'postmaster',
        'svs.worker_restart_backoff'  => 'sighup',
        'svs.worker_timeout_ms'       => 'sighup',
        'svs.worker_startup_timeout_ms' => 'sighup',
    );
    for my $guc (sort keys %expected_ctx)
    {
        my $ctx = $node->safe_psql('postgres',
            "SELECT context FROM pg_settings WHERE name = '$guc';");
        chomp $ctx;
        is($ctx, $expected_ctx{$guc},
            "$guc exists with context '$expected_ctx{$guc}'");
    }

    # Test 18: VamanaInit registered the launcher (not the old single worker).
    # The launcher's bgw_type is visible in pg_stat_activity.
    my $launcher = $node->safe_psql('postgres',
        "SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'vamana launcher';");
    chomp $launcher;
    is($launcher, '1',
        'VamanaInit registered the launcher (one vamana launcher process running)');

    # Test 19: no running code path reads the removed GUC.  Setting an
    # unknown svs.* placeholder GUC yields a placeholder that SHOW reports;
    # the real proof is that svs.worker_database is absent from pg_settings
    # (test 17) and cannot be read as a defined setting here.
    my ($cur_ret, undef, $cur_err) = $node->psql('postgres',
        "SELECT current_setting('svs.worker_database');");
    isnt($cur_ret, 0,
        'current_setting(svs.worker_database) errors — the GUC is not defined');

    $node->stop;
}

done_testing();
