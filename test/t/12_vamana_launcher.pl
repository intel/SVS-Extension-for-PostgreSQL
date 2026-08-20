# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 12_vamana_launcher.pl — the launcher and per-database worker entry point.
#
# The launcher is the one statically-registered background worker.  It reads
# the enabled rows from vamana_databases in svs.launcher_database and spawns
# one dynamic per-database worker for each, adding workers as new rows are
# enabled and terminating them as rows are disabled.  These tests exercise the
# launcher and the workers it owns together, against real running processes:
# startup and runtime spawning, per-worker database isolation, per-database
# availability and the config gate, disable-driven graceful termination and
# prompt re-enable, standby behavior, and the launcher's GUC inventory and
# registration.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep gettimeofday tv_interval);
use File::Temp qw(tempdir);

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
# Startup spawns a worker for every enabled row, and only those.
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
# A row enabled at runtime gets a worker with no restart.
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
# A launcher restart must not disturb an already-running worker.
#
# The restarted launcher's ledger starts empty, even though the per-database
# worker it lost track of is still running.  It must recognize that and leave
# the worker alone rather than spawning a second one into its slot.
# ---------------------------------------------------------------------------
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_launcher_restart_transparency');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
    $node->append_conf('postgresql.conf', "svs.worker_restart_time = 1");
    $node->start;

    $node->safe_psql('postgres', "CREATE EXTENSION vector;");
    $node->safe_psql('postgres', "CREATE EXTENSION svs;");
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname) VALUES ('postgres');");

    my $before_pid = wait_for_worker_db($node, 'postgres', 30);
    ok($before_pid =~ /^\d+$/,
        "worker running before launcher restart (pid=$before_pid)");

    my $lp1 = $node->safe_psql('postgres',
        "SELECT pid FROM pg_stat_activity WHERE backend_type = 'vamana launcher' LIMIT 1;");
    chomp $lp1;
    ok($lp1 =~ /^\d+$/, "launcher running (pid=$lp1)");

    kill('TERM', $lp1);

    my $lp2 = '';
    for (1 .. 100)    # up to 10s
    {
        usleep(100_000);
        $lp2 = $node->safe_psql('postgres',
            "SELECT pid FROM pg_stat_activity WHERE backend_type = 'vamana launcher' LIMIT 1;");
        chomp $lp2;
        last if $lp2 =~ /^\d+$/ && $lp2 ne $lp1;
    }
    ok($lp2 =~ /^\d+$/ && $lp2 ne $lp1, "postmaster restarts the launcher (pid=$lp2)");

    # Give the restarted launcher's initial reconcile pass time to run.
    usleep(2_000_000);

    is(worker_count($node, 'postgres'), '1',
        "exactly one worker still serving 'postgres' after launcher restart");
    my $after_pid = wait_for_worker_db($node, 'postgres', 1);
    is($after_pid, $before_pid,
        "the pre-existing worker survives the launcher restart untouched (pid=$before_pid)");

    $node->stop;
}

# ---------------------------------------------------------------------------
# Cross-database enumeration, visibility gate, and per-database availability.
#
# pg_stat_vamana_worker reports one row per reserved database.  A privileged
# caller (superuser / pg_read_all_stats) sees every worker; the launcher having
# passed each dbOid as bgw_main_arg shows up as one 'running' row per database
# with the correct db_oid and a distinct worker_pid.  An unprivileged caller is
# gated C-side to only its own MyDatabaseId row — proof the cross-database scope
# does not leak other tenants' existence.
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

    my $postgres_oid = $node->safe_psql('postgres',
        "SELECT oid FROM pg_database WHERE datname = 'postgres';");
    chomp $postgres_oid;

    # A privileged caller enumerates all three workers, each 'running'
    # with the right db_oid and a distinct pid — the launcher passed each dbOid
    # as bgw_main_arg and each worker bound to its own database.
    my $rows = $node->safe_psql('postgres', qq{
        SELECT db_oid, worker_state FROM pg_stat_vamana_worker ORDER BY db_oid;
    });
    my %state_by_oid = map { split /\|/ } split /\n/, $rows;
    is($state_by_oid{$postgres_oid}, 'running', 'postgres worker running (privileged view)');
    is($state_by_oid{$iso_a_oid},    'running', 'iso_a worker running (privileged view)');
    is($state_by_oid{$iso_b_oid},    'running', 'iso_b worker running (privileged view)');

    my $distinct_pids = $node->safe_psql('postgres',
        "SELECT count(DISTINCT worker_pid) FROM pg_stat_vamana_worker "
      . "WHERE worker_pid IS NOT NULL;");
    chomp $distinct_pids;
    is($distinct_pids, '3', 'three distinct worker pids across databases');

    # An unprivileged caller in iso_a is gated to only its own row;
    # iso_b's existence never leaks.
    $node->safe_psql('iso_a', "CREATE ROLE unpriv LOGIN;");
    my $seen_a = $node->safe_psql('iso_a',
        "SELECT db_oid FROM pg_stat_vamana_worker;", extra_params => [ '-U', 'unpriv' ]);
    chomp $seen_a;
    is($seen_a, $iso_a_oid,
        'unprivileged backend in iso_a sees only its own row (no cross-db leakage)');

    # A backend in iso_a, forced to search, is served by iso_a's own
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
# VamanaWorkerAssertDatabase is a per-database config gate.
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
# Standby behavior is preserved under the launcher.
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
# GUC inventory and entry-point cutover.
#
# The launcher GUCs exist with the documented contexts.  The registered static
# worker is the launcher, and no running code path reads svs.worker_database.
# ---------------------------------------------------------------------------
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_launcher_cutover');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
    $node->start;

    $node->safe_psql('postgres', "CREATE EXTENSION vector;");
    $node->safe_psql('postgres', "CREATE EXTENSION svs;");

    # svs.worker_database no longer exists.
    my $removed = $node->safe_psql('postgres',
        "SELECT count(*) FROM pg_settings WHERE name = 'svs.worker_database';");
    chomp $removed;
    is($removed, '0', 'svs.worker_database GUC no longer exists');

    # The launcher GUCs exist with the documented contexts.
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

    # VamanaInit registered the launcher (not the old single worker).
    # The launcher's bgw_type is visible in pg_stat_activity.
    my $launcher = $node->safe_psql('postgres',
        "SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'vamana launcher';");
    chomp $launcher;
    is($launcher, '1',
        'VamanaInit registered the launcher (one vamana launcher process running)');

    # No running code path reads the removed GUC.  Setting an
    # unknown svs.* placeholder GUC yields a placeholder that SHOW reports;
    # the real proof is that svs.worker_database is absent from pg_settings
    # (the GUC inventory check above) and cannot be read as a defined setting here.
    my ($cur_ret, undef, $cur_err) = $node->psql('postgres',
        "SELECT current_setting('svs.worker_database');");
    isnt($cur_ret, 0,
        'current_setting(svs.worker_database) errors — the GUC is not defined');

    $node->stop;
}

# Disabling a database terminates its live worker through the graceful drain:
# the launcher signals SIGTERM, the worker checkpoints every cached index and
# exits cleanly, and the slot stays reserved so the database is still
# configured while paused.  Re-enabling respawns promptly — a deliberate stop
# clears the backoff rather than inheriting a window it never earned.
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_launcher_pause');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "log_min_messages = debug1");
    $node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
    $node->append_conf('postgresql.conf', "svs.checkpoint_min_ops = 999999");
    $node->append_conf('postgresql.conf', "svs.checkpoint_debounce_window = 999999");
    # A large backoff so an erroneous accrual would visibly delay the re-enable.
    $node->append_conf('postgresql.conf', "svs.worker_restart_backoff = 30000");
    $node->start;

    $node->safe_psql('postgres', "CREATE EXTENSION vector;");
    $node->safe_psql('postgres', "CREATE EXTENSION svs;");
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");
    wait_for_worker($node, 30);

    my @idx = (1, 2, 3);
    for my $n (@idx)
    {
        $node->safe_psql('postgres', qq{
            CREATE TABLE pause_tbl$n (id serial PRIMARY KEY, val vector($dim));
            INSERT INTO pause_tbl$n (val) SELECT ARRAY[$array_sql]::vector
                FROM generate_series(1,100) i;
            CREATE INDEX pause_idx$n ON pause_tbl$n USING vamana (val vector_l2_ops);
        });
        $node->safe_psql('postgres', qq{
            SET enable_seqscan = off;
            SELECT id FROM pause_tbl$n ORDER BY val <-> '[$query_sql]' LIMIT 5;
        });
    }

    my $worker_pid = wait_for_worker_db($node, 'postgres', 30);

    my $log_pos = length($node->log_content());
    $node->safe_psql('postgres',
        "UPDATE vamana_databases SET enabled = false WHERE datname = 'postgres';");

    for (1 .. 100)
    {
        usleep(100_000);
        last if worker_count($node, 'postgres') eq '0';
    }
    is(worker_count($node, 'postgres'), '0',
        'disabling the database terminates its worker');

    $node->wait_for_log(qr/\(PID $worker_pid\) exited with exit code/, $log_pos);
    my $log = substr($node->log_content(), $log_pos);

    like($log, qr/vamana background worker shutting down/,
        'the terminated worker runs the graceful drain, not quickdie');

    my %checkpointed;
    $checkpointed{$1} = 1
        while $log =~ /vamana index (\d+): checkpoint complete/g;
    is(scalar keys %checkpointed, scalar @idx,
        'the drain checkpoints every cached index before exit');

    unlike($log, qr/\(PID $worker_pid\) exited with exit code 1/,
        'the worker exits cleanly on disable');

    my $reserved = $node->safe_psql('postgres',
        "SELECT count(*) FROM pg_stat_vamana_worker "
      . "WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');");
    chomp $reserved;
    is($reserved, '1',
        'the slot stays reserved while paused — the database is still configured');

    # At rest during the pause: each index's logical slot is present but
    # inactive (no worker holds it) with confirmed_flush_lsn populated by the
    # drain's final checkpoint.
    my $dboid = $node->safe_psql('postgres',
        "SELECT oid FROM pg_database WHERE datname = 'postgres';");
    chomp $dboid;
    my @slot_names;
    for my $n (@idx)
    {
        my $relid = $node->safe_psql('postgres',
            "SELECT oid FROM pg_class WHERE relname = 'pause_idx$n';");
        chomp $relid;
        push @slot_names, "vamana_${dboid}_${relid}";
    }
    my $slot_list = join(',', map { "'$_'" } @slot_names);

    my $present = $node->safe_psql('postgres',
        "SELECT count(*) FROM pg_replication_slots WHERE slot_name IN ($slot_list);");
    chomp $present;
    is($present, scalar @idx,
        'every paused index keeps its replication slot');

    my $inactive = $node->safe_psql('postgres',
        "SELECT count(*) FROM pg_replication_slots "
      . "WHERE slot_name IN ($slot_list) AND NOT active;");
    chomp $inactive;
    is($inactive, scalar @idx,
        'every paused slot is inactive — no worker holds it');

    my $flushed = $node->safe_psql('postgres',
        "SELECT count(*) FROM pg_replication_slots "
      . "WHERE slot_name IN ($slot_list) AND confirmed_flush_lsn IS NOT NULL;");
    chomp $flushed;
    is($flushed, scalar @idx,
        'every paused slot has a confirmed_flush_lsn from the drain checkpoint');

    # Re-enable and time the respawn: with no backoff inherited it must beat the
    # configured 30s window by a wide margin.
    my $t0 = [gettimeofday];
    $node->safe_psql('postgres',
        "UPDATE vamana_databases SET enabled = true WHERE datname = 'postgres';");
    my $repid = wait_for_worker_db($node, 'postgres', 60);
    my $elapsed = tv_interval($t0);
    ok($repid =~ /^\d+$/ && $elapsed < 10,
        "re-enabling respawns promptly, no inherited backoff (${elapsed}s)");

    $node->stop;
}

# A paused database has no worker to advance its slot, so the slot's
# confirmed_flush_lsn is frozen while the cluster WAL head keeps moving under
# unrelated activity: the slot's lag grows monotonically.  This is why pause is
# bounded by max_slot_wal_size, not safe to leave open indefinitely.
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_paused_slot_wal');
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
    wait_for_worker($node, 30);

    $node->safe_psql('postgres', qq{
        CREATE TABLE wal_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO wal_tbl (val) SELECT ARRAY[$array_sql]::vector
            FROM generate_series(1,100) i;
        CREATE INDEX wal_idx ON wal_tbl USING vamana (val vector_l2_ops);
    });
    $node->safe_psql('postgres', qq{
        SET enable_seqscan = off;
        SELECT id FROM wal_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    });

    # A separate database drives WAL unrelated to the paused one.
    $node->safe_psql('postgres', "CREATE DATABASE churn_db;");

    my $dboid = $node->safe_psql('postgres',
        "SELECT oid FROM pg_database WHERE datname = 'postgres';");
    chomp $dboid;
    my $relid = $node->safe_psql('postgres',
        "SELECT oid FROM pg_class WHERE relname = 'wal_idx';");
    chomp $relid;
    my $slot = "vamana_${dboid}_${relid}";

    $node->safe_psql('postgres',
        "UPDATE vamana_databases SET enabled = false WHERE datname = 'postgres';");
    for (1 .. 100)
    {
        usleep(100_000);
        last if worker_count($node, 'postgres') eq '0';
    }

    my $frozen_lsn = $node->safe_psql('postgres',
        "SELECT confirmed_flush_lsn FROM pg_replication_slots WHERE slot_name = '$slot';");
    chomp $frozen_lsn;
    my $lag_before = $node->safe_psql('postgres',
        "SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) "
      . "FROM pg_replication_slots WHERE slot_name = '$slot';");
    chomp $lag_before;

    for (1 .. 10)
    {
        $node->safe_psql('churn_db', qq{
            CREATE TABLE IF NOT EXISTS churn (id serial PRIMARY KEY, payload text);
            INSERT INTO churn (payload)
                SELECT repeat('x', 1000) FROM generate_series(1, 2000);
        });
        $node->safe_psql('churn_db', "SELECT pg_switch_wal();");
    }

    my $lsn_after = $node->safe_psql('postgres',
        "SELECT confirmed_flush_lsn FROM pg_replication_slots WHERE slot_name = '$slot';");
    chomp $lsn_after;
    my $lag_after = $node->safe_psql('postgres',
        "SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) "
      . "FROM pg_replication_slots WHERE slot_name = '$slot';");
    chomp $lag_after;

    is($lsn_after, $frozen_lsn,
        'the paused slot confirmed_flush_lsn stays frozen — no worker advances it');
    ok($lag_after > $lag_before,
        "the paused slot's WAL lag grows with unrelated activity "
      . "($lag_before -> $lag_after)");

    $node->stop;
}

# At-rest behavior of a paused database: queries fail loudly and promptly, the
# catalog row and shmem reservation persist, and re-enabling resumes cleanly.
# svs.max_databases is set to 1 so the still-counted paused reservation blocks a
# second enable, proving the slot is held rather than released.
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_paused_at_rest');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
    $node->append_conf('postgresql.conf', "svs.checkpoint_min_ops = 999999");
    $node->append_conf('postgresql.conf', "svs.checkpoint_debounce_window = 999999");
    $node->append_conf('postgresql.conf', "svs.max_databases = 1");
    # A short availability wait: a correct fast-fail lands far below it, so a
    # regression that spun to the timeout would be plainly visible.
    $node->append_conf('postgresql.conf', "svs.worker_startup_timeout_ms = 20000");
    $node->start;

    $node->safe_psql('postgres', "CREATE EXTENSION vector;");
    $node->safe_psql('postgres', "CREATE EXTENSION svs;");
    $node->safe_psql('postgres', "CREATE DATABASE spare_db;");
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");
    wait_for_worker($node, 30);

    $node->safe_psql('postgres', qq{
        CREATE TABLE rest_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO rest_tbl (val) SELECT ARRAY[$array_sql]::vector
            FROM generate_series(1,100) i;
        CREATE INDEX rest_idx ON rest_tbl USING vamana (val vector_l2_ops);
    });
    $node->safe_psql('postgres', qq{
        SET enable_seqscan = off;
        SELECT id FROM rest_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    });
    wait_for_worker_db($node, 'postgres', 30);

    $node->safe_psql('postgres',
        "UPDATE vamana_databases SET enabled = false WHERE datname = 'postgres';");
    for (1 .. 100)
    {
        usleep(100_000);
        last if worker_count($node, 'postgres') eq '0';
    }

    # A query against the paused index short-circuits on the reserved-but-
    # workerless slot and errors at once, rather than hanging to the timeout.
    my $t0 = [gettimeofday];
    my ($ret, $out, $err) = $node->psql('postgres', qq{
        SET enable_seqscan = off;
        SELECT id FROM rest_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    });
    my $wait = tv_interval($t0);
    ok($ret != 0 && $err =~ /vamana background worker unavailable/,
        'a query during pause fails with the worker-unavailable error');
    ok($wait < 10,
        "the paused-database query fails promptly, not a hang (${wait}s)");

    my $row = $node->safe_psql('postgres',
        "SELECT enabled FROM vamana_databases WHERE datname = 'postgres';");
    chomp $row;
    is($row, 'f',
        'the vamana_databases row persists across the pause, still disabled');

    my ($ret2, undef, $err2) = $node->psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('spare_db', true);");
    ok($ret2 != 0 && $err2 =~ /already reached/,
        'the paused slot still counts against svs.max_databases');

    # Re-enable: a worker respawns and the index answers from its on-disk save.
    $node->safe_psql('postgres',
        "UPDATE vamana_databases SET enabled = true WHERE datname = 'postgres';");
    my $repid = wait_for_worker_db($node, 'postgres', 60);
    my $scan = $node->safe_psql('postgres', qq{
        SET enable_seqscan = off;
        SELECT count(*) FROM (
            SELECT id FROM rest_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5
        ) s;
    });
    chomp $scan;
    ok($repid =~ /^\d+$/ && $scan eq '5',
        're-enabling respawns a worker and the index answers from disk');

    $node->stop;
}

# Extension-owned tables are excluded from pg_dump by default unless they
# opt in via pg_extension_config_dump.
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_databases_dump');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->start;

    $node->safe_psql('postgres', "CREATE EXTENSION vector;");
    $node->safe_psql('postgres', "CREATE EXTENSION svs;");
    $node->safe_psql('postgres', qq(
        INSERT INTO vamana_databases (datname, enabled, search_num_threads)
            VALUES ('postgres', true, 4);
    ));

    my $before_rows = $node->safe_psql('postgres',
        "SELECT count(*) FROM vamana_databases WHERE datname = 'postgres';");
    chomp $before_rows;
    is($before_rows, '1', 'vamana_databases row is present before dump');

    my $dumpfile = tempdir(CLEANUP => 1) . "/postgres.dump.sql";
    $node->command_ok(
        [ 'pg_dump', '-d', $node->connstr('postgres'), '-f', $dumpfile ],
        'pg_dump of the enabled database succeeds');

    $node->safe_psql('postgres', "CREATE DATABASE restored_db;");
    $node->safe_psql('restored_db', "CREATE EXTENSION vector;");
    $node->safe_psql('restored_db', "CREATE EXTENSION svs;");
    $node->command_ok(
        [ 'psql', '-X', '-q', '-v', 'ON_ERROR_STOP=1',
          '-d', $node->connstr('restored_db'), '-f', $dumpfile ],
        'restoring the dump into a fresh database succeeds');

    my $after_rows = $node->safe_psql('restored_db',
        "SELECT count(*) FROM vamana_databases WHERE datname = 'postgres';");
    chomp $after_rows;
    is($after_rows, $before_rows,
        'vamana_databases row enabling "postgres" survives the dump/restore round trip');

    $node->safe_psql('postgres', "DROP DATABASE restored_db;");
    $node->stop;
}

done_testing();
