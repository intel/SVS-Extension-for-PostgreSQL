# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 11_vamana_shmem_layout.pl — M2 shmem control-block array.
#
# Covers the M2 structural and concurrency tests that have an observable
# surface in the single-worker interim:
#   1. Sizing: the shmem segments scale with svs.max_databases.
#   3. No reallocation: segment offsets are stable for the postmaster's life.
#   4. indexCount: maintained per database, correct under concurrency.
#
# M2 tests 2 (arbitrary-position lookup) and 5 (no torn read during a
# reservation) are deferred to M3, which is the first module to populate
# entries beyond slots[0]; see m03_precommit_slot_reservation.md.

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
    my ($name, $max_databases) = @_;
    my $node = PostgreSQL::Test::Cluster->new($name);
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "svs.worker_database = 'postgres'");
    $node->append_conf('postgresql.conf', "svs.max_databases = $max_databases");
    $node->start;
    $node->safe_psql('postgres', "CREATE EXTENSION vector;");
    $node->safe_psql('postgres', "CREATE EXTENSION svs;");
    return $node;
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

done_testing();
