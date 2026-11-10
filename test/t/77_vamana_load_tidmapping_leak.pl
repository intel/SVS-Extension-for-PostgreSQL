# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 77_vamana_load_tidmapping_leak.pl — VamanaWorkerProcessLoadSlot's staging
# TID-map buffer must be freed once VamanaCacheIndex has copied it into the
# cache entry's own buffer, not leaked into TopMemoryContext.
#
# VamanaCacheIndex copies the caller's tidMapping into a separately
# allocated buffer of its own rather than taking ownership of it, so the
# local staging copy must be pfree'd on the LOAD slot's success path (the
# warm-up that follows CREATE INDEX). Without that free, every successful
# load leaks tidMappingCapacity * sizeof(ItemPointerData) bytes into the
# worker's TopMemoryContext, with nothing to bound it short of a worker
# restart.
#
# Driving several CREATE INDEX / DROP INDEX cycles on fresh tables and
# reading the worker's exact TopMemoryContext byte count via
# pg_log_backend_memory_contexts() after each one gives a clean signal: on
# unfixed code this grows by a consistent, predictable amount every cycle;
# fixed, it stays flat once the cache bookkeeping itself stabilizes.

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

    # First cycle also seeds per-relid cache bookkeeping that grows once
    # regardless of the leak, so it is excluded from the no-growth
    # comparison below; only cycles 2 onward, once that one-time bookkeeping
    # has already happened, are compared against each other.
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

    is($totals[3], $totals[1],
        "no growth in TopMemoryContext across repeated CREATE INDEX/DROP INDEX cycles "
      . "(cycle 2: $totals[1] bytes, cycle 4: $totals[3] bytes)");

    $node->stop;
}

done_testing();
