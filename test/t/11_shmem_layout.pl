# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# shmem control-block array.
#
# Covers the structural and concurrency guarantees that have an observable
# surface in the single-worker interim:
#   Sizing: the shmem segments scale with svs.max_databases.
#   No reallocation: segment offsets are stable for the postmaster's life.
#   indexCount: maintained per database, correct under concurrency.
#
# Arbitrary-position lookup and no-torn-read during a reservation need several
# databases at arbitrary array positions and the cross-database stat scope to
# observe them; covered elsewhere.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

# Read one shmem segment's (size, off) from pg_shmem_allocations.
sub shmem_alloc
{
    my ($node, $name) = @_;
    my $row = $node->safe_psql('postgres',
        "SELECT coalesce(size, -1), coalesce(off, -1) "
      . "FROM pg_shmem_allocations WHERE name = '$name';");
    chomp $row;
    return split(/\|/, $row);
}

sub start_node
{
    my ($name, $max_databases, $log_min_messages) = @_;
    my $node = PostgreSQL::Test::Cluster->new($name);
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
    $node->append_conf('postgresql.conf', "svs.max_databases = $max_databases");
    $node->append_conf('postgresql.conf', "log_min_messages = '$log_min_messages'")
        if defined $log_min_messages;
    $node->start;
    $node->safe_psql('postgres', "CREATE EXTENSION vector;");
    $node->safe_psql('postgres', "CREATE EXTENSION svs;");
    return $node;
}

# Enable the launcher_database itself so its worker reserves a slot and comes
# up.  Kept out of start_node: the precommit-reservation blocks below manage
# vamana_databases from an empty table and would break on a pre-inserted row.
sub enable_postgres
{
    my ($node) = @_;
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");
}

# ---------------------------------------------------------------------------
# Test 1: sizing scales with svs.max_databases.
#
# The VamanaWorkerSlots segment is N * MaxBackends * stride, so doubling then
# doubling again N must scale it exactly, with no dependence on MaxBackends.
# The header segment is base + N * sizeof(slot); two data points let us solve
# for sizeof(slot) and confirm the base is non-negative and consistent.
# ---------------------------------------------------------------------------
{
    my $node4  = start_node('vamana_shmem_n4', 4);
    my $node16 = start_node('vamana_shmem_n16', 16);

    my ($hdr4_size, $hdr4_off)   = shmem_alloc($node4,  'VamanaWorkerShmemHeader');
    my ($slot4_size)             = shmem_alloc($node4,  'VamanaWorkerSlots');
    my ($hdr16_size)             = shmem_alloc($node16, 'VamanaWorkerShmemHeader');
    my ($slot16_size)            = shmem_alloc($node16, 'VamanaWorkerSlots');

    ok($hdr4_size > 0 && $slot4_size > 0,
        "shmem segments present (header=$hdr4_size slots=$slot4_size at N=4)");

    # pg_shmem_allocations rounds each allocation up to a cache line, so compare
    # the ratio with a small tolerance rather than demanding exact equality.
    my $slot_ratio = $slot16_size / $slot4_size;
    ok(abs($slot_ratio - 4.0) < 0.01,
        "VamanaWorkerSlots scales 4x from N=4 to N=16 (ratio=$slot_ratio)");

    # header(N) = base + N * sizeof(slot); solve across the two runs.
    my $slot_struct = ($hdr16_size - $hdr4_size) / (16 - 4);
    my $base        = $hdr4_size - 4 * $slot_struct;
    ok($slot_struct > 0 && $base >= 0,
        "header grows linearly in N (sizeof(slot)~=$slot_struct base~=$base)");

    $node4->stop;
    $node16->stop;
}

# ---------------------------------------------------------------------------
# Test 3: the array is never reallocated.  Segment offsets must be identical
# before and after CREATE/DROP INDEX churn within one postmaster lifetime.
# ---------------------------------------------------------------------------
{
    my $node = start_node('vamana_shmem_norealloc', 8);
    enable_postgres($node);

    my (undef, $hdr_off_before)  = shmem_alloc($node, 'VamanaWorkerShmemHeader');
    my (undef, $slot_off_before) = shmem_alloc($node, 'VamanaWorkerSlots');

    $node->safe_psql('postgres', qq{
        CREATE TABLE nr_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO nr_tbl (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 50);
    });
    for my $i (1 .. 5)
    {
        $node->safe_psql('postgres',
            "CREATE INDEX nr_idx_$i ON nr_tbl USING vamana (val vector_l2_ops);");
        $node->safe_psql('postgres', "DROP INDEX nr_idx_$i;");
    }

    my (undef, $hdr_off_after)  = shmem_alloc($node, 'VamanaWorkerShmemHeader');
    my (undef, $slot_off_after) = shmem_alloc($node, 'VamanaWorkerSlots');

    is($hdr_off_after, $hdr_off_before,
        "VamanaWorkerShmemHeader offset stable across DDL churn ($hdr_off_before)");
    is($slot_off_after, $slot_off_before,
        "VamanaWorkerSlots offset stable across DDL churn ($slot_off_before)");

    $node->stop;
}

# ---------------------------------------------------------------------------
# Test 4 + indexCount unit checks: the per-database counter tracks live
# vamana indexes, is not moved by non-vamana indexes, and suffers no lost
# updates under concurrent CREATE/DROP.
# ---------------------------------------------------------------------------
{
    my $node = start_node('vamana_shmem_indexcount', 8);
    enable_postgres($node);

    my $worker_pid = wait_for_worker($node, 30);
    ok($worker_pid =~ /^\d+$/, "worker running (pid=$worker_pid)");

    my $count = sub {
        my $c = $node->safe_psql('postgres',
            "SELECT DISTINCT index_count FROM pg_stat_vamana_worker;");
        chomp $c;
        return $c;
    };

    $node->safe_psql('postgres', qq{
        CREATE TABLE ic_tbl (id serial PRIMARY KEY, val vector($dim), tag int);
        INSERT INTO ic_tbl (val, tag)
            SELECT ARRAY[$array_sql]::vector, 1 FROM generate_series(1, 50);
    });

    is($count->(), '0', "index_count starts at 0");

    $node->safe_psql('postgres',
        "CREATE INDEX ic_idx ON ic_tbl USING vamana (val vector_l2_ops);");
    is($count->(), '1', "index_count is 1 after CREATE INDEX");

    # A non-vamana index must not move the counter.
    $node->safe_psql('postgres', "CREATE INDEX ic_btree ON ic_tbl (tag);");
    is($count->(), '1', "index_count unchanged by a btree index");

    $node->safe_psql('postgres', "DROP INDEX ic_btree;");
    is($count->(), '1', "index_count unchanged by dropping a btree index");

    $node->safe_psql('postgres', "DROP INDEX ic_idx;");
    is($count->(), '0', "index_count is 0 after DROP INDEX");

    # Concurrency: N sessions each create a vamana index on their own table
    # (no array-wide lock is held for the counter), so the net increment must
    # be exactly N with no lost updates.
    my $create_sql = sub {
        my $i = shift;
        return qq{
            CREATE TABLE cc_tbl_$i (id serial PRIMARY KEY, val vector($dim));
            INSERT INTO cc_tbl_$i (val)
                SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 30);
            CREATE INDEX cc_idx_$i ON cc_tbl_$i USING vamana (val vector_l2_ops);
        };
    };
    run_concurrent($node, 'postgres', $N, $create_sql);
    is($count->(), "$N",
        "index_count is $N after $N concurrent CREATE INDEX (no lost increments)");

    my $drop_sql = sub {
        my $i = shift;
        return "DROP INDEX cc_idx_$i;";
    };
    run_concurrent($node, 'postgres', $N, $drop_sql);
    is($count->(), '0',
        "index_count is 0 after $N concurrent DROP INDEX (no lost decrements)");

    $node->stop;
}

{
    my $node = start_node('vamana_precommit_registration', 8, 'debug1');

    $node->safe_psql('postgres', qq{
        CREATE DATABASE vamana_precommit_registration_dba;
        CREATE DATABASE vamana_precommit_registration_dbb;
    });

    my $log_pos_before = length($node->log_content());

    $node->safe_psql('postgres', qq{
        INSERT INTO vamana_databases (datname)
            VALUES ('vamana_precommit_registration_dba'), ('vamana_precommit_registration_dbb');
        UPDATE vamana_databases SET enabled = false
            WHERE datname = 'vamana_precommit_registration_dba';
        UPDATE vamana_databases SET enabled = true
            WHERE datname = 'vamana_precommit_registration_dba';
        INSERT INTO vamana_databases (datname) VALUES ('postgres');
    });

    my $new_log = substr($node->log_content(), $log_pos_before);
    my $registrations =
      () = $new_log =~ /vamana_databases: registered reservation xact callback/g;

    is($registrations, 1,
        "RegisterXactCallback() fires exactly once across 4 row-trigger firings in one backend");

    $node->stop;
}

{
    my $node = start_node('vamana_precommit_capacity', 2);

    $node->safe_psql('postgres', "CREATE DATABASE vamana_precommit_capacity_dba;");

    $node->safe_psql('postgres', qq{
        INSERT INTO vamana_databases (datname) VALUES ('postgres');
        INSERT INTO vamana_databases (datname) VALUES ('vamana_precommit_capacity_dba');
    });

    my ($stdout, $stderr) = ('', '');
    $node->psql('postgres',
        "INSERT INTO vamana_databases (datname) VALUES ('template1');",
        stdout => \$stdout, stderr => \$stderr);

    like($stderr, qr/svs\.max_databases \(2\) already reached/,
        "capacity-exhausted INSERT raises the documented error");

    is($node->safe_psql('postgres',
            "SELECT count(*) FROM vamana_databases WHERE datname = 'template1';"),
        '0',
        "the rejected row was not committed");

    $node->stop;
}

{
    my $node = start_node('vamana_precommit_savepoint', 1);

    $node->safe_psql('postgres', "CREATE DATABASE vamana_precommit_savepoint_dba;");

    # A row queued inside a subtransaction that is later rolled back must not
    # be reserved at COMMIT. With max_databases = 1, if the rolled-back
    # entry were wrongly reserved it would consume the one slot, and the
    # second INSERT below would fail with a capacity error instead of
    # succeeding.
    $node->safe_psql('postgres', qq{
        BEGIN;
        SAVEPOINT s;
        INSERT INTO vamana_databases (datname) VALUES ('vamana_precommit_savepoint_dba');
        ROLLBACK TO SAVEPOINT s;
        INSERT INTO vamana_databases (datname) VALUES ('postgres');
        COMMIT;
    });

    is($node->safe_psql('postgres', "SELECT count(*) FROM vamana_databases;"), '1',
        "only the post-rollback row is present");
    is($node->safe_psql('postgres',
            "SELECT datname FROM vamana_databases;"),
        'postgres',
        "the row queued before the savepoint rollback was not reserved or persisted");

    $node->stop;
}

{
    # max_databases = 4 against an empty vamana_databases table: all 4 slots
    # are free.  The transaction below queues 3 reservations and aborts; if any
    # slot leaked, the follow-up INSERT of 3 more rows would exceed capacity.
    my $node = start_node('vamana_precommit_abort_rollback', 4);

    $node->safe_psql('postgres', qq{
        CREATE DATABASE vamana_precommit_abort_rollback_dba;
        CREATE DATABASE vamana_precommit_abort_rollback_dbb;
        CREATE DATABASE vamana_precommit_abort_rollback_dbc;
    });

    # A transaction queuing 3 reservations that later aborts (for a reason
    # unrelated to those INSERTs) must release all 3 slots, not just one.
    # If any slot were left reserved after the abort, the second
    # transaction below — reserving 3 more databases into the same 3 free
    # slots — would fail with a capacity error instead of succeeding.
    my ($stdout, $stderr) = ('', '');
    $node->psql('postgres', qq{
        BEGIN;
        INSERT INTO vamana_databases (datname) VALUES
            ('vamana_precommit_abort_rollback_dba'),
            ('vamana_precommit_abort_rollback_dbb'),
            ('vamana_precommit_abort_rollback_dbc');
        SELECT 1/0;
        COMMIT;
    }, stdout => \$stdout, stderr => \$stderr);

    like($stderr, qr/division by zero/,
        "the forced error aborted the multi-row INSERT's transaction");

    is($node->safe_psql('postgres', "SELECT count(*) FROM vamana_databases;"), '0',
        "none of the 3 rows were committed");

    $node->safe_psql('postgres', qq{
        INSERT INTO vamana_databases (datname) VALUES ('template1'), ('postgres'), ('template0');
    });

    is($node->safe_psql('postgres', "SELECT count(*) FROM vamana_databases;"), '3',
        "all 3 slots from the aborted transaction were released, leaving full capacity available");

    $node->stop;
}

{
    # ReserveSlotsForEnabledEntries is idempotent, so re-queuing 'postgres'
    # (what svs_restart_worker does) returns its existing, live slot rather
    # than creating one. An abort must release only slots this transaction
    # actually created, not ones it merely found.
    my $node = start_node('vamana_precommit_abort_preserves_live', 1);
    enable_postgres($node);

    $node->poll_query_until('postgres', qq{
        SELECT worker_state = 'running' FROM pg_stat_vamana_worker
         WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');
    }) or die "postgres's worker never reached 'running'";

    $node->safe_psql('postgres', "CREATE DATABASE vamana_precommit_abort_preserves_live_dbb;");

    my ($stdout, $stderr) = ('', '');
    $node->psql('postgres', qq{
        BEGIN;
        UPDATE vamana_databases SET restart_generation = restart_generation + 1
            WHERE datname = 'postgres';
        INSERT INTO vamana_databases (datname)
            VALUES ('vamana_precommit_abort_preserves_live_dbb');
        COMMIT;
    }, stdout => \$stdout, stderr => \$stderr);

    like($stderr, qr/svs\.max_databases \(1\) already reached/,
        "the second database's capacity failure aborted the transaction");

    is($node->safe_psql('postgres', qq{
            SELECT count(*) FROM pg_stat_vamana_worker
             WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');
        }),
        '1',
        "postgres's pre-existing, live slot survives the sibling transaction's abort");

    $node->stop;
}

# ---------------------------------------------------------------------------
# index_relid on an empty slot is masked at read time, so a database that
# recycles a freed worker entry never observes a leftover index OID from the
# previous tenant.
# ---------------------------------------------------------------------------
{
    my $node = start_node('vamana_slot_relid_leak', 1);

    $node->safe_psql('postgres', "CREATE DATABASE leak_tenant_a;");
    $node->safe_psql('postgres', "CREATE DATABASE leak_tenant_b;");
    $node->safe_psql('leak_tenant_a', "CREATE EXTENSION vector;");
    $node->safe_psql('leak_tenant_a', "CREATE EXTENSION svs;");
    $node->safe_psql('leak_tenant_b', "CREATE EXTENSION vector;");
    $node->safe_psql('leak_tenant_b', "CREATE EXTENSION svs;");

    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('leak_tenant_a', true);");
    wait_for_worker_db($node, 'leak_tenant_a', 30);

    $node->safe_psql('leak_tenant_a', qq{
        CREATE TABLE t (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO t (val) SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 20);
        CREATE INDEX t_idx ON t USING vamana (val vector_l2_ops);
    });
    $node->safe_psql('leak_tenant_a', qq{
        SET enable_seqscan = off;
        SELECT id FROM t ORDER BY val <-> '[$query_sql]' LIMIT 1;
    });
    my $idx_a_oid = $node->safe_psql('leak_tenant_a', "SELECT 't_idx'::regclass::oid;");
    chomp $idx_a_oid;

    my $a_oid = $node->safe_psql('postgres',
        "SELECT oid FROM pg_database WHERE datname = 'leak_tenant_a';");
    chomp $a_oid;

    $node->safe_psql('leak_tenant_a', "SELECT svs_teardown_database();");
    $node->safe_psql('postgres',
        "DELETE FROM vamana_databases WHERE datname = 'leak_tenant_a';");
    ok(wait_for_slot_release($node, 'postgres', $a_oid, 30),
        'leak_tenant_a releases its worker entry');

    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('leak_tenant_b', true);");
    wait_for_worker_db($node, 'leak_tenant_b', 30);

    my $b_oid = $node->safe_psql('postgres',
        "SELECT oid FROM pg_database WHERE datname = 'leak_tenant_b';");
    chomp $b_oid;

    my $leaked = $node->safe_psql('postgres',
        "SELECT count(*) FROM pg_stat_vamana_worker_slot "
      . "WHERE db_oid = $b_oid AND slot_status = 'empty' AND index_relid = $idx_a_oid;");
    chomp $leaked;
    is($leaked, '0',
        'no empty slot in the recycled entry carries a leftover index_relid from the previous database');

    $node->stop;
}

done_testing();
