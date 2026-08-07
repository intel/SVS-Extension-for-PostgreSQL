# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 07_vamana_replication_slots.pl — replication slot lifecycle for Vamana indexes.
#
# Verifies four observable guarantees:
#
#   1. A slot named "vamana_<dboid>_<indexoid>" appears in pg_replication_slots
#      after CREATE INDEX and the BGW loads the index.
#   2. The slot is inactive (not acquired) immediately after the BGW opens it.
#   3. The slot is dropped when the index is dropped (DROP INDEX).
#   4. confirmed_flush_lsn advances after an INSERT triggers a checkpoint.
#
# Also covers crash-recovery replay scenarios, including worker DELETE
# reverse-map consistency under TID reuse.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

{
    my $node = PostgreSQL::Test::Cluster->new('vamana_repl_slots');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
    $node->append_conf('postgresql.conf', "svs.checkpoint_min_ops = 1");
    $node->append_conf('postgresql.conf', "svs.checkpoint_debounce_window = 1");
    $node->start;

    $node->safe_psql('postgres', "CREATE EXTENSION vector;");
    $node->safe_psql('postgres', "CREATE EXTENSION svs;");
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    # The launcher spawns the worker asynchronously in response to the row
    # above, so wait for it before CREATE INDEX: the slot is created when a live
    # worker loads the index, and building it against no worker would leave the
    # slot uncreated.
    wait_for_worker($node, 30);

    $node->safe_psql('postgres', qq{
        CREATE TABLE rs_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO rs_tbl (val)
            SELECT ARRAY[$array_sql]::vector
            FROM generate_series(1, 50);
        CREATE INDEX rs_idx ON rs_tbl USING vamana (val vector_l2_ops);
    });

    my $dboid = $node->safe_psql('postgres',
        "SELECT oid FROM pg_database WHERE datname = 'postgres';");
    chomp $dboid;

    my $indexoid = $node->safe_psql('postgres',
        "SELECT oid FROM pg_class WHERE relname = 'rs_idx';");
    chomp $indexoid;

    my $slot_name = "vamana_${dboid}_${indexoid}";

    # ---------------------------------------------------------------- Test 1 --
    # Slot exists after CREATE INDEX and BGW load.  Poll rather than sleep a
    # fixed interval: the worker creates the slot when it processes the LOAD
    # request, and its timing is not tied to CREATE INDEX returning.
    my $slot_exists = 0;
    for (1 .. 20)
    {
        usleep(500_000);
        $slot_exists = $node->safe_psql('postgres', qq{
            SELECT count(*) FROM pg_replication_slots
            WHERE slot_name = '$slot_name' AND plugin = 'svs';
        });
        chomp $slot_exists;
        last if $slot_exists == 1;
    }

    ok($slot_exists == 1,
        "replication slot '$slot_name' exists after CREATE INDEX");

    my $slot_active = $node->safe_psql('postgres', qq{
        SELECT active FROM pg_replication_slots WHERE slot_name = '$slot_name';
    });
    chomp $slot_active;

    ok($slot_active eq 'f',
        "slot is inactive (not acquired) after BGW opens handle");

    # ---------------------------------------------------------------- Test 4 --
    # After INSERT + checkpoint, confirmed_flush_lsn must advance past '0/0'.

    $node->safe_psql('postgres', qq{
        INSERT INTO rs_tbl (val) VALUES (ARRAY[$array_sql]::vector);
    });

    # Wait up to 10 s for the BGW heartbeat to fire ShouldCheckpoint and
    # advance the slot.  checkpoint_min_ops=1 and checkpoint_debounce_window=1
    # guarantee a checkpoint fires after one write and one quiet second.
    my $lsn_advanced = 0;
    for (1 .. 20)
    {
        usleep(500_000);
        my $lsn = $node->safe_psql('postgres', qq{
            SELECT confirmed_flush_lsn FROM pg_replication_slots
            WHERE slot_name = '$slot_name';
        });
        chomp $lsn;
        if ($lsn ne '0/0' && $lsn ne '')
        {
            $lsn_advanced = 1;
            last;
        }
    }
    ok($lsn_advanced,
        "confirmed_flush_lsn advanced after INSERT + checkpoint (slot=$slot_name)");

    # ---------------------------------------------------------------- Test 2 --
    # Slot persists across restart.

    $node->restart;

    wait_for_worker($node, 30);

    my $slot_after_restart = $node->safe_psql('postgres', qq{
        SELECT count(*) FROM pg_replication_slots
        WHERE slot_name = '$slot_name' AND plugin = 'svs';
    });
    chomp $slot_after_restart;

    ok($slot_after_restart == 1,
        "replication slot persists across server restart");

    # ---------------------------------------------------------------- Test 3 --
    # Slot is dropped on DROP INDEX.

    $node->safe_psql('postgres', "DROP INDEX rs_idx;");

    # Give BGW time to process the relcache invalidation and drop the slot.
    sleep(2);

    my $slot_after_drop = $node->safe_psql('postgres', qq{
        SELECT count(*) FROM pg_replication_slots
        WHERE slot_name = '$slot_name';
    });
    chomp $slot_after_drop;

    ok($slot_after_drop == 0,
        "replication slot dropped after DROP INDEX");

    $node->stop;
}

# ===========================================================================
# ShouldCheckpoint debounce unit tests
#
# Each test case isolates one decision branch of ShouldCheckpoint by
# manipulating exactly one GUC dimension and observing whether
# confirmed_flush_lsn advances (or does not).  Polling loops are used
# throughout — no fixed sleeps — so these are not timing-sensitive.
#
# A fresh table+index is created per case so opsSinceCheckpoint starts at
# zero and there is no carry-over between cases.
# ===========================================================================

# Returns the current confirmed_flush_lsn for the named slot.
sub current_lsn
{
    my ($node, $slot_name) = @_;
    my $lsn = $node->safe_psql('postgres', qq{
        SELECT confirmed_flush_lsn FROM pg_replication_slots
        WHERE slot_name = '$slot_name';
    });
    chomp $lsn;
    return $lsn;
}

# Polls until confirmed_flush_lsn differs from $baseline, or timeout expires.
# Returns 1 if it advanced, 0 if not.
sub wait_for_lsn_advance
{
    my ($node, $slot_name, $baseline, $timeout_s) = @_;
    $timeout_s //= 10;
    for (1 .. $timeout_s * 2)
    {
        usleep(500_000);
        my $lsn = current_lsn($node, $slot_name);
        return 1 if $lsn ne $baseline && $lsn ne '';
    }
    return 0;
}

{
    my $node = PostgreSQL::Test::Cluster->new('vamana_debounce');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 20");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
    $node->start;

    $node->safe_psql('postgres', "CREATE EXTENSION vector;");
    $node->safe_psql('postgres', "CREATE EXTENSION svs;");
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    my $dboid = $node->safe_psql('postgres',
        "SELECT oid FROM pg_database WHERE datname = 'postgres';");
    chomp $dboid;

    # Helper: create a fresh table+index, wait for BGW to load it, and
    # return (table_name, slot_name, baseline_lsn).
    #
    # The 5 seed rows set opsSinceCheckpoint=5 inside the BGW.  VamanaCacheIndex
    # initialises lastCheckpointTime=GetCurrentTimestamp(), so the max_interval
    # clock starts at load time and the BGW will not fire a spurious immediate
    # checkpoint — baseline_lsn is a stable starting point for each case's guard
    # assertions.
    my $case_num = 0;
    my $make_index = sub {
        $case_num++;
        my $tbl = "deb_tbl_$case_num";
        my $idx = "deb_idx_$case_num";
        $node->safe_psql('postgres', qq{
            CREATE TABLE $tbl (id serial PRIMARY KEY, val vector($dim));
            INSERT INTO $tbl (val)
                SELECT ARRAY[$array_sql]::vector
                FROM generate_series(1, 5);
            CREATE INDEX $idx ON $tbl USING vamana (val vector_l2_ops);
        });
        my $ioid = $node->safe_psql('postgres',
            "SELECT oid FROM pg_class WHERE relname = '$idx';");
        chomp $ioid;
        my $sname = "vamana_${dboid}_${ioid}";
        # Wait for the slot to appear (BGW has processed the LOAD request).
        for (1 .. 20)
        {
            usleep(500_000);
            my $cnt = $node->safe_psql('postgres', qq{
                SELECT count(*) FROM pg_replication_slots
                WHERE slot_name = '$sname';
            });
            chomp $cnt;
            last if $cnt == 1;
        }
        my $baseline = current_lsn($node, $sname);
        return ($tbl, $sname, $baseline);
    };

    wait_for_worker($node, 30);

    # ---------------------------------------------------------------- Case 1 --
    # Ops gate: below min_ops suppresses checkpoint; reaching min_ops fires it.

    $node->safe_psql('postgres',
        "ALTER SYSTEM SET svs.checkpoint_min_ops = 5;");
    $node->safe_psql('postgres',
        "ALTER SYSTEM SET svs.checkpoint_debounce_window = 1;");
    $node->safe_psql('postgres', "SELECT pg_reload_conf();");
    sleep(1);

    my ($tbl1, $slot1, $baseline1) = $make_index->();

    # Insert 4 rows (below min_ops=5) and wait past debounce_window.
    for (1 .. 4)
    {
        $node->safe_psql('postgres', qq{
            INSERT INTO $tbl1 (val) VALUES (ARRAY[$array_sql]::vector);
        });
    }
    my $no_advance1 = !wait_for_lsn_advance($node, $slot1, $baseline1, 4);
    ok($no_advance1,
        "ops gate: no checkpoint while opsSinceCheckpoint (4) < min_ops (5)");

    # Insert one more row to reach min_ops=5; checkpoint must now fire.
    $node->safe_psql('postgres', qq{
        INSERT INTO $tbl1 (val) VALUES (ARRAY[$array_sql]::vector);
    });
    ok(wait_for_lsn_advance($node, $slot1, $baseline1, 10),
        "ops gate: checkpoint fires when opsSinceCheckpoint reaches min_ops (5)");

    # ---------------------------------------------------------------- Case 2 --
    # Quiet guard: suppresses while writes are recent, fires after quiet period.

    $node->safe_psql('postgres',
        "ALTER SYSTEM SET svs.checkpoint_min_ops = 1;");
    $node->safe_psql('postgres',
        "ALTER SYSTEM SET svs.checkpoint_debounce_window = 4;");
    $node->safe_psql('postgres', "SELECT pg_reload_conf();");
    sleep(1);

    my ($tbl2, $slot2, $baseline2) = $make_index->();

    $node->safe_psql('postgres', qq{
        INSERT INTO $tbl2 (val) VALUES (ARRAY[$array_sql]::vector);
    });

    # Poll for 2 s — lastWriteTime was just set, quiet_sec < debounce_window=4.
    my $no_advance2 = !wait_for_lsn_advance($node, $slot2, $baseline2, 2);
    ok($no_advance2,
        "quiet guard: no checkpoint immediately after INSERT (not yet quiet for 4 s)");

    # After ~5 s total quiet the debounce window expires; checkpoint must fire.
    ok(wait_for_lsn_advance($node, $slot2, $baseline2, 10),
        "quiet guard: checkpoint fires after writes stop for debounce_window (4 s)");

    # ---------------------------------------------------------------- Case 3 --
    # max_interval backstop: fires even when debounce_window is very long.

    $node->safe_psql('postgres',
        "ALTER SYSTEM SET svs.checkpoint_min_ops = 1;");
    $node->safe_psql('postgres',
        "ALTER SYSTEM SET svs.checkpoint_debounce_window = 60;");
    $node->safe_psql('postgres',
        "ALTER SYSTEM SET svs.checkpoint_max_interval = 3;");
    $node->safe_psql('postgres', "SELECT pg_reload_conf();");
    sleep(1);

    my ($tbl3, $slot3, $baseline3) = $make_index->();

    $node->safe_psql('postgres', qq{
        INSERT INTO $tbl3 (val) VALUES (ARRAY[$array_sql]::vector);
    });

    # debounce_window=60 would suppress forever, but max_interval=3 overrides it.
    ok(wait_for_lsn_advance($node, $slot3, $baseline3, 10),
        "max_interval backstop: checkpoint fires within max_interval (3 s) despite debounce_window=60");

    # Reset max_interval to default so it does not interfere with case 4.
    $node->safe_psql('postgres',
        "ALTER SYSTEM SET svs.checkpoint_max_interval = 3600;");
    $node->safe_psql('postgres', "SELECT pg_reload_conf();");
    sleep(1);

    # ---------------------------------------------------------------- Case 4 --
    # Simple ops mode: checkpoint_operations > 0 activates simple OR-logic.

    $node->safe_psql('postgres',
        "ALTER SYSTEM SET svs.checkpoint_operations = 3;");
    $node->safe_psql('postgres', "SELECT pg_reload_conf();");
    sleep(1);

    my ($tbl4, $slot4, $baseline4) = $make_index->();

    # Insert 2 rows (ops = 2 < 3) — must not trigger simple ops mode.
    for (1 .. 2)
    {
        $node->safe_psql('postgres', qq{
            INSERT INTO $tbl4 (val) VALUES (ARRAY[$array_sql]::vector);
        });
    }
    my $no_advance4 = !wait_for_lsn_advance($node, $slot4, $baseline4, 4);
    ok($no_advance4,
        "simple ops mode: no checkpoint at 2 ops when checkpoint_operations = 3");

    # Insert one more row to reach ops = 3.
    $node->safe_psql('postgres', qq{
        INSERT INTO $tbl4 (val) VALUES (ARRAY[$array_sql]::vector);
    });
    ok(wait_for_lsn_advance($node, $slot4, $baseline4, 10),
        "simple ops mode: checkpoint fires when ops reaches checkpoint_operations (3)");

    $node->stop;
}

# ===========================================================================
# Crash recovery: replay applies INSERTs to graph
#
# checkpoint_min_ops is set high so inserted rows are never flushed to the
# on-disk graph before the crash.  After an immediate stop the BGW replays
# the committed changes from the slot and the rows become searchable.
# ===========================================================================

{
    my $node = PostgreSQL::Test::Cluster->new('vamana_crash_replay_insert');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
    $node->append_conf('postgresql.conf', "svs.checkpoint_min_ops = 999999");
    $node->start;

    $node->safe_psql('postgres', "CREATE EXTENSION vector;");
    $node->safe_psql('postgres', "CREATE EXTENSION svs;");
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    $node->safe_psql('postgres', qq{
        CREATE TABLE replay_tbl (id serial, val vector($dim));
        CREATE INDEX replay_idx ON replay_tbl USING vamana (val vector_l2_ops);
    });

    wait_for_worker($node, 30);

    for (1 .. 20)
    {
        usleep(500_000);
        my $cnt = $node->safe_psql('postgres', q{
            SELECT count(*) FROM pg_replication_slots WHERE plugin = 'svs';
        });
        chomp $cnt;
        last if $cnt >= 1;
    }

    for my $i (1 .. 5)
    {
        $node->safe_psql('postgres', qq{
            INSERT INTO replay_tbl (val) VALUES (ARRAY[$array_sql]::vector);
        });
    }

    wait_for_worker($node, 30);

    $node->stop('immediate');
    $node->start;
    wait_for_worker($node, 30);

    my $count = 0;
    for (1 .. 20)
    {
        usleep(500_000);
        $count = $node->safe_psql('postgres', qq{
            SELECT count(*) FROM (
                SELECT * FROM replay_tbl
                ORDER BY val <-> ARRAY[$array_sql]::vector
                LIMIT 10
            ) sub;
        });
        chomp $count;
        last if $count == 5;
    }

    ok($count == 5,
        "crash recovery: 5 rows recovered via slot replay after immediate stop");

    $node->stop;
}

# ===========================================================================
# Idempotent replay: checkpointed rows not double-inserted
# ===========================================================================

{
    my $node = PostgreSQL::Test::Cluster->new('vamana_crash_replay_idempotent');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
    $node->append_conf('postgresql.conf', "svs.checkpoint_min_ops = 1");
    $node->append_conf('postgresql.conf', "svs.checkpoint_debounce_window = 1");
    $node->start;

    $node->safe_psql('postgres', "CREATE EXTENSION vector;");
    $node->safe_psql('postgres', "CREATE EXTENSION svs;");
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    $node->safe_psql('postgres', qq{
        CREATE TABLE idem_tbl (id serial, val vector($dim));
        CREATE INDEX idem_idx ON idem_tbl USING vamana (val vector_l2_ops);
    });

    wait_for_worker($node, 30);

    for (1 .. 20)
    {
        usleep(500_000);
        my $cnt = $node->safe_psql('postgres', q{
            SELECT count(*) FROM pg_replication_slots WHERE plugin = 'svs';
        });
        chomp $cnt;
        last if $cnt >= 1;
    }

    my $dboid = $node->safe_psql('postgres',
        "SELECT oid FROM pg_database WHERE datname = 'postgres';");
    chomp $dboid;
    my $ioid = $node->safe_psql('postgres',
        "SELECT oid FROM pg_class WHERE relname = 'idem_idx';");
    chomp $ioid;
    my $slot_name = "vamana_${dboid}_${ioid}";

    my $initial_flush_lsn = $node->safe_psql('postgres', qq{
        SELECT confirmed_flush_lsn FROM pg_replication_slots
        WHERE slot_name = '$slot_name';
    });
    chomp $initial_flush_lsn;

    # INSERT 3 rows — will be checkpointed (min_ops=1, debounce=1).
    for my $i (1 .. 3)
    {
        $node->safe_psql('postgres', qq{
            INSERT INTO idem_tbl (val) VALUES (ARRAY[$array_sql]::vector);
        });
    }

    # Wait for checkpoint to advance confirmed_flush_lsn.
    my $advanced = 0;
    for (1 .. 20)
    {
        usleep(500_000);
        my $lsn = $node->safe_psql('postgres', qq{
            SELECT confirmed_flush_lsn FROM pg_replication_slots
            WHERE slot_name = '$slot_name';
        });
        chomp $lsn;
        if ($lsn ne '' && $lsn ne $initial_flush_lsn)
        {
            $advanced = 1;
            last;
        }
    }
    die "checkpoint did not fire for idempotency test" unless $advanced;

    # Suppress further checkpoints.
    $node->safe_psql('postgres',
        "ALTER SYSTEM SET svs.checkpoint_min_ops = 999999;");
    $node->safe_psql('postgres', "SELECT pg_reload_conf();");
    sleep(1);

    # INSERT 2 more rows (not checkpointed).
    for my $i (1 .. 2)
    {
        $node->safe_psql('postgres', qq{
            INSERT INTO idem_tbl (val) VALUES (ARRAY[$array_sql]::vector);
        });
    }

    wait_for_worker($node, 30);

    $node->stop('immediate');
    $node->start;
    wait_for_worker($node, 30);

    my $count = 0;
    for (1 .. 20)
    {
        usleep(500_000);
        $count = $node->safe_psql('postgres', qq{
            SELECT count(*) FROM (
                SELECT * FROM idem_tbl
                ORDER BY val <-> ARRAY[$array_sql]::vector
                LIMIT 10
            ) sub;
        });
        chomp $count;
        last if $count == 5;
    }

    ok($count == 5,
        "idempotent replay: rows present in checkpoint are not double-inserted");

    $node->stop;
}

# ===========================================================================
# Crash recovery: DELETE replay
# ===========================================================================

{
    my $node = PostgreSQL::Test::Cluster->new('vamana_crash_replay_delete');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
    $node->append_conf('postgresql.conf', "svs.checkpoint_min_ops = 999999");
    $node->start;

    $node->safe_psql('postgres', "CREATE EXTENSION vector;");
    $node->safe_psql('postgres', "CREATE EXTENSION svs;");
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    $node->safe_psql('postgres', qq{
        CREATE TABLE del_tbl (id serial, val vector($dim));
        CREATE INDEX del_idx ON del_tbl USING vamana (val vector_l2_ops);
    });

    wait_for_worker($node, 30);

    for (1 .. 20)
    {
        usleep(500_000);
        my $cnt = $node->safe_psql('postgres', q{
            SELECT count(*) FROM pg_replication_slots WHERE plugin = 'svs';
        });
        chomp $cnt;
        last if $cnt >= 1;
    }

    for my $i (1 .. 5)
    {
        $node->safe_psql('postgres', qq{
            INSERT INTO del_tbl (val) VALUES (ARRAY[$array_sql]::vector);
        });
    }

    wait_for_worker($node, 30);

    $node->safe_psql('postgres', "DELETE FROM del_tbl WHERE id <= 2;");

    wait_for_worker($node, 30);

    $node->stop('immediate');
    $node->start;
    wait_for_worker($node, 30);

    my $count = 0;
    for (1 .. 20)
    {
        usleep(500_000);
        $count = $node->safe_psql('postgres', qq{
            SELECT count(*) FROM (
                SELECT * FROM del_tbl
                ORDER BY val <-> ARRAY[$array_sql]::vector
                LIMIT 10
            ) sub;
        });
        chomp $count;
        last if $count == 3;
    }

    ok($count == 3,
        "crash recovery: deletes replayed correctly after immediate stop");

    $node->stop;
}

# ===========================================================================
# Crash recovery: worker DELETE clears the reverse TID map
#
# The BGW worker DELETE path must forget both directions of the TID map, or a
# checkpoint persists a stale TID -> externalId entry.  After a physical TID is
# reused by a new row and the node crashes, replay rebuilds the reverse map
# from the stale tidmap.bin; its idempotency check (vamana_replication.c) then
# mistakes the reused TID for one already in the graph and silently skips the
# re-insert, leaving the index one row short.
#
# Sequence: insert -> delete+vacuum (worker DELETE) -> checkpoint (persists
# tidmap.bin) -> reuse the freed TID with a new insert -> crash -> replay.
# ===========================================================================

{
    my $node = PostgreSQL::Test::Cluster->new('vamana_replay_reuse_tid');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
    # Start with checkpoints enabled so the stale tidmap.bin gets persisted;
    # suppressed later so the reuse insert stays WAL-only for replay.
    $node->append_conf('postgresql.conf', "svs.checkpoint_min_ops = 1");
    $node->append_conf('postgresql.conf', "svs.checkpoint_debounce_window = 1");
    # Keep the heap page from being extended so the freed line pointer is
    # reused by the next insert on the same page.
    $node->append_conf('postgresql.conf', "autovacuum = off");
    $node->start;

    $node->safe_psql('postgres', "CREATE EXTENSION vector;");
    $node->safe_psql('postgres', "CREATE EXTENSION svs;");
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    $node->safe_psql('postgres', qq{
        CREATE TABLE reuse_tbl (id serial, val vector($dim));
        CREATE INDEX reuse_idx ON reuse_tbl USING vamana (val vector_l2_ops);
    });

    wait_for_worker($node, 30);

    for (1 .. 20)
    {
        usleep(500_000);
        my $cnt = $node->safe_psql('postgres', q{
            SELECT count(*) FROM pg_replication_slots WHERE plugin = 'svs';
        });
        chomp $cnt;
        last if $cnt >= 1;
    }

    my $dboid = $node->safe_psql('postgres',
        "SELECT oid FROM pg_database WHERE datname = 'postgres';");
    chomp $dboid;
    my $ioid = $node->safe_psql('postgres',
        "SELECT oid FROM pg_class WHERE relname = 'reuse_idx';");
    chomp $ioid;
    my $slot_name = "vamana_${dboid}_${ioid}";

    for my $i (1 .. 5)
    {
        $node->safe_psql('postgres', qq{
            INSERT INTO reuse_tbl (val) VALUES (ARRAY[$array_sql]::vector);
        });
    }
    wait_for_worker($node, 30);

    # Record the physical TID we intend to free and later reuse.
    my $target_ctid = $node->safe_psql('postgres',
        "SELECT ctid FROM reuse_tbl WHERE id = 3;");
    chomp $target_ctid;

    my $read_flush_lsn = sub {
        my $lsn = $node->safe_psql('postgres', qq{
            SELECT confirmed_flush_lsn FROM pg_replication_slots
            WHERE slot_name = '$slot_name';
        });
        chomp $lsn;
        return $lsn;
    };

    my $wait_for_flush_past = sub {
        my ($prev) = @_;
        for (1 .. 20)
        {
            usleep(500_000);
            my $lsn = $read_flush_lsn->();
            return 1 if $lsn ne '' && $lsn ne $prev;
        }
        return 0;
    };

    # A checkpoint must persist tidmap.bin BEFORE the delete: vamanabulkdelete
    # loads the on-disk map and skips entirely if the file is absent, so the
    # worker DELETE path (under test) would never run otherwise.
    my $flush_before_insert_ckpt = $read_flush_lsn->();
    ok($wait_for_flush_past->($flush_before_insert_ckpt),
        "checkpoint persisted after initial inserts");

    my $flush_before_del = $read_flush_lsn->();

    # DELETE + VACUUM: the worker DELETE path runs here, and the reverse map
    # entry for target_ctid is cleared.  VACUUM also frees the heap line
    # pointer for reuse.
    $node->safe_psql('postgres', "DELETE FROM reuse_tbl WHERE id = 3;");
    $node->safe_psql('postgres', "VACUUM reuse_tbl;");
    wait_for_worker($node, 30);

    # A second checkpoint persists the post-delete tidMapping to tidmap.bin.
    # This assertion guards against a NULL svsIndex during checkpoint
    # eviction.
    ok($wait_for_flush_past->($flush_before_del),
        "checkpoint persisted after delete");

    # Suppress further checkpoints: the reuse insert must stay WAL-only so it
    # is applied by replay, not restored from a checkpoint.
    $node->safe_psql('postgres',
        "ALTER SYSTEM SET svs.checkpoint_min_ops = 999999;");
    $node->safe_psql('postgres', "SELECT pg_reload_conf();");
    sleep(1);

    # Reuse the freed TID with a new row.
    $node->safe_psql('postgres', qq{
        INSERT INTO reuse_tbl (val) VALUES (ARRAY[$array_sql]::vector);
    });
    wait_for_worker($node, 30);

    my $reused_ctid = $node->safe_psql('postgres',
        "SELECT ctid FROM reuse_tbl WHERE id = 6;");
    chomp $reused_ctid;

    # Reuse is deterministic here: a single heap page (five small rows) with
    # autovacuum off means VACUUM frees the line pointer and the next insert
    # reoccupies it.  Assert it so a broken precondition fails loudly instead
    # of silently skipping the scenario under test.
    is($reused_ctid, $target_ctid,
        "insert reused the freed heap TID (precondition for reverse-map test)");

    $node->stop('immediate');
    $node->start;
    wait_for_worker($node, 30);

    # Five live rows are expected: ids 1,2,4,5 plus the reused-TID id 6.
    # Replay must resolve id 6's TID to the live externalId, not the stale
    # dead one.
    my $count = 0;
    for (1 .. 20)
    {
        usleep(500_000);
        $count = $node->safe_psql('postgres', qq{
            SELECT count(*) FROM (
                SELECT * FROM reuse_tbl
                ORDER BY val <-> ARRAY[$array_sql]::vector
                LIMIT 10
            ) sub;
        });
        chomp $count;
        last if $count == 5;
    }

    ok($count == 5,
        "crash recovery: reused-TID row replayed after worker DELETE "
        . "cleared the reverse map");

    $node->stop;
}

# ===========================================================================
# Data survives repeated crashes
#
# An index built on an empty table takes on rows only through the write path,
# leaving them un-checkpointed.  After each immediate stop the index recovers
# on demand, so every row stays searchable across two successive crashes.
# ===========================================================================

{
    my $node = PostgreSQL::Test::Cluster->new('vamana_replay_doublecrash_checkpoint');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
    $node->append_conf('postgresql.conf', "svs.checkpoint_min_ops = 999999");
    $node->start;

    $node->safe_psql('postgres', "CREATE EXTENSION vector;");
    $node->safe_psql('postgres', "CREATE EXTENSION svs;");
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    $node->safe_psql('postgres', qq{
        CREATE TABLE dbl_tbl (id serial, val vector($dim));
        CREATE INDEX dbl_idx ON dbl_tbl USING vamana (val vector_l2_ops);
    });

    wait_for_worker($node, 30);

    for (1 .. 20)
    {
        usleep(500_000);
        my $cnt = $node->safe_psql('postgres', q{
            SELECT count(*) FROM pg_replication_slots WHERE plugin = 'svs';
        });
        chomp $cnt;
        last if $cnt >= 1;
    }

    # INSERT 5 rows — applied via IPC write slots.
    for my $i (1 .. 5)
    {
        $node->safe_psql('postgres', qq{
            INSERT INTO dbl_tbl (val) VALUES (ARRAY[$array_sql]::vector);
        });
    }
    wait_for_worker($node, 30);

    # Returns the row count an index scan yields after the node is up.
    my $recovered_count = sub {
        my $count = 0;
        for (1 .. 20)
        {
            usleep(500_000);
            $count = $node->safe_psql('postgres', qq{
                SET enable_seqscan = off;
                SELECT count(*) FROM (
                    SELECT id FROM dbl_tbl
                    ORDER BY val <-> ARRAY[$array_sql]::vector
                    LIMIT 10
                ) sub;
            });
            chomp $count;
            last if $count == 5;
        }
        return $count;
    };

    # First crash: no checkpoint has fired (min_ops=999999), on-disk graph is empty.
    $node->stop('immediate');
    $node->start;
    wait_for_worker($node, 30);
    is($recovered_count->(), 5,
        "all rows searchable after first crash recovery");

    # Second crash: the un-checkpointed rows must survive again.
    $node->stop('immediate');
    $node->start;
    wait_for_worker($node, 30);
    is($recovered_count->(), 5,
        "all rows searchable after second crash recovery");

    $node->stop;
}

# ===========================================================================
# Metapage counter drift after crash-before-checkpoint
#
# The metapage bumps numVectors per insert, but the on-disk graph and
# tidmap.bin are only rewritten at checkpoint.  A crash between the last
# checkpoint and the next leaves the metapage ahead of disk.  On reload the
# count must be reconciled from the persisted TID map, or the inflated value
# loosens the search result-count clamp (svs_wrapper.c) that suppresses
# duplicate TIDs — observable as total-returned exceeding distinct-returned.
#
# checkpoint_min_ops is set high so post-build inserts never checkpoint: the
# metapage advances per insert while tidmap.bin/graph stay at the build
# snapshot.  Replay reapplies the un-checkpointed inserts after restart.
# ===========================================================================

{
    my $node = PostgreSQL::Test::Cluster->new('vamana_counter_drift');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
    $node->append_conf('postgresql.conf', "svs.checkpoint_min_ops = 999999");
    $node->start;

    $node->safe_psql('postgres', "CREATE EXTENSION vector;");
    $node->safe_psql('postgres', "CREATE EXTENSION svs;");
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    # Wait for the launcher-spawned worker before building the index so the
    # replication slot is created and retains the post-build un-checkpointed
    # inserts that replay must reapply after the crash.
    wait_for_worker($node, 30);

    $node->safe_psql('postgres', qq{
        CREATE TABLE drift_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO drift_tbl (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 50);
        CREATE INDEX drift_idx ON drift_tbl USING vamana (val vector_l2_ops);
    });
    wait_for_worker($node, 30);

    # Returns (total, distinct) ids the index scan yields for a large LIMIT.
    # An inflated numVectors leaves the clamp too loose, letting duplicate TIDs
    # through, so total != distinct is the observable symptom of drift.
    my $index_counts = sub {
        my $counts = $node->safe_psql('postgres', qq{
            SET enable_seqscan = off;
            SELECT count(*), count(DISTINCT id) FROM (
                SELECT id FROM drift_tbl ORDER BY val <-> '[$query_sql]' LIMIT 100000
            ) s;
        });
        chomp $counts;
        return split(/\|/, $counts);
    };

    my ($total, $distinct) = $index_counts->();
    is($total, 50, 'baseline: 50 rows after build');

    # Post-build inserts: metapage bumps, no checkpoint persists the graph.
    $node->safe_psql('postgres', qq{
        INSERT INTO drift_tbl (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 25);
    });
    wait_for_worker($node, 30);
    ($total, $distinct) = $index_counts->();
    is($distinct, 75, 'all 75 rows searchable pre-crash');

    $node->stop('immediate');
    $node->start;
    wait_for_worker($node, 30);

    # Replay reapplies the 25 un-checkpointed inserts; the reconciled count
    # keeps the clamp tight, so every row is returned exactly once.
    ($total, $distinct) = $index_counts->();
    is($distinct, 75, 'all 75 rows searchable after crash recovery + replay');
    is($total, $distinct,
        'no duplicate TIDs after reload (numVectors reconciled from TID map)');
    is($node->safe_psql('postgres', 'SELECT count(*) FROM drift_tbl;'), 75,
        'heap agrees at 75 rows');

    $node->stop;
}

done_testing();
