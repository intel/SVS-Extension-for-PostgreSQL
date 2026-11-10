# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 77_vamana_load_tidmapping_leak.pl — checks that the worker's TopMemoryContext
# does not keep growing across repeated CREATE INDEX / DROP INDEX cycles.
# Cycle 1 is excluded from the comparison since it seeds one-time cache
# bookkeeping that grows regardless of the leak.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

my $ROWS = 2000;

# Issues pg_log_backend_memory_contexts() for $pid, then polls the log from
# $offset for that backend's TopMemoryContext line and returns its "total"
# figure. Returns undef on timeout.
sub get_top_memory_context_total
{
    my ($node, $pid, $offset, $timeout_s) = @_;
    $timeout_s //= 10;
    $node->safe_psql('postgres', "SELECT pg_log_backend_memory_contexts($pid);");
    for (1 .. $timeout_s * 2)
    {
        my $log = PostgreSQL::Test::Utils::slurp_file($node->logfile, $offset);
        if ($log =~ /\[$pid\].*TopMemoryContext: (\d+) total/)
        {
            return $1;
        }
        usleep(500_000);
    }
    return undef;
}

{
    my $node = PostgreSQL::Test::Cluster->new('vamana_load_tidmapping_leak');
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

    my $worker_pid = wait_for_worker($node, 30);
    ok($worker_pid =~ /^\d+$/, "worker running (pid=$worker_pid)");

    my $log_offset = -s $node->logfile;

    my @totals;
    for my $cycle (1 .. 4)
    {
        $node->safe_psql('postgres', qq{
            DROP TABLE IF EXISTS leak_tbl;
            CREATE TABLE leak_tbl (id serial PRIMARY KEY, val vector($dim));
            INSERT INTO leak_tbl (val)
                SELECT ARRAY[$array_sql]::vector FROM generate_series(1, $ROWS);
            CREATE INDEX ON leak_tbl USING vamana (val vector_l2_ops);
            DROP INDEX leak_tbl_val_idx;
        });

        my $total = get_top_memory_context_total($node, $worker_pid, $log_offset, 10);
        ok(defined $total, "cycle $cycle: got the worker's TopMemoryContext total");
        diag("cycle $cycle: TopMemoryContext total = " . (defined $total ? $total : 'undef'));
        push @totals, $total;
        $log_offset = -s $node->logfile;
    }

    # Exact equality would be flaky: the worker may evict the dropped
    # index's cache entry some time after DROP INDEX returns rather than
    # synchronously, so one sample can land while that entry (and its TID
    # map) is still live and another cannot, differing by about one
    # entry's TID-map size even with the fix in place. The per-cycle leak
    # itself is $ROWS * 6 bytes, so bound growth well under that instead
    # of requiring it to be exactly zero.
    my $leak_per_cycle = $ROWS * 6;
    my $growth = $totals[3] - $totals[1];
    cmp_ok($growth, '<', $leak_per_cycle,
        "TopMemoryContext growth across repeated CREATE INDEX/DROP INDEX cycles stays well "
      . "under one cycle's leak size ($growth bytes vs $leak_per_cycle; cycle 2: $totals[1], "
      . "cycle 4: $totals[3])");

    $node->stop;
}

done_testing();
