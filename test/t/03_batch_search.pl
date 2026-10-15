# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 03_batch_search.pl — native SVS batch search path in the BGW.
#
# When N backends submit search requests concurrently, VamanaWorkerRunBatch
# detects n > 1 with uniform k/dimensions, packs all query vectors into a
# single contiguous buffer, and calls svs_index_search once.  Heterogeneous
# search_window_size falls back to a sequential per-query loop.
#
# "Submitted together" does not mean "collected in one worker pass": the
# worker can scan PENDING slots between two backends' publishes, which turns
# a would-be batch into N one-at-a-time dispatches. On builds with injection
# points, run_parked_batch pins the worker at
# vamana-worker-before-collect-requests before the barrier releases, so all
# N publishes land before the worker's next scan, making the batch log
# assertions below deterministic. Builds without injection points fall back
# to the undeterministic run_synchronized and skip the log assertion.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

sub make_search_sql
{
    my ($q) = @_;
    return qq(
        SET enable_seqscan = off;
        SELECT id FROM batch_tbl ORDER BY val <-> '[$q]' LIMIT 5;
    );
}

my $have_injection_points = (($ENV{enable_injection_points} // 'no') eq 'yes');

{
    my $node = PostgreSQL::Test::Cluster->new('vamana_batch');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "log_min_messages = 'debug1'");
    # Headroom for the worker to stay parked at the injection point on slow
    # cassert runners without a backend's claim going stale.
    $node->append_conf('postgresql.conf', "svs.worker_timeout_ms = 30000");
    $node->start;

    $node->safe_psql("postgres", "CREATE EXTENSION vector;");
    $node->safe_psql("postgres", "CREATE EXTENSION svs;");
    $node->safe_psql("postgres", "CREATE EXTENSION injection_points;")
      if $have_injection_points;
    $node->safe_psql("postgres",
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");
    wait_for_worker($node);

    $node->safe_psql("postgres", qq(
        CREATE TABLE batch_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO batch_tbl (val)
            SELECT ARRAY[$array_sql]::vector
            FROM generate_series(1, 300) i;
        CREATE INDEX batch_idx ON batch_tbl USING vamana (val vector_l2_ops);
    ));

    sleep(2);

    my @baselines;
    for my $i (0 .. $N - 1)
    {
        my $q = $query_vecs[$i];
        my $r = $node->safe_psql("postgres", qq(
            SET enable_seqscan = off;
            SELECT id FROM batch_tbl ORDER BY val <-> '[$q]' LIMIT 5;
        ));
        isnt($r, '', "baseline $i is non-empty");
        push @baselines, $r;
    }

    my @concurrent_results = run_concurrent(
        $node, "postgres", $N,
        sub { make_search_sql($query_vecs[ $_[0] ]) }
    );

    for my $i (0 .. $N - 1)
    {
        isnt($concurrent_results[$i], '',
            "concurrent client $i returns non-empty results");
        is($concurrent_results[$i], $baselines[$i],
            "concurrent client $i results match single-client baseline");
    }

    my $all_same = 1;
    for my $i (1 .. $N - 1)
    {
        $all_same = 0 if $concurrent_results[$i] ne $concurrent_results[0];
    }
    ok(!$all_same,
        "concurrent clients with distinct query vectors return distinct result sets");

    my $log_pos_before_batch = length($node->log_content());

    my $pre_sql  = sub { "SET enable_seqscan = off;\n" };
    my $search_sql = sub {
        my $q = $query_vecs[ $_[0] ];
        "SELECT id FROM batch_tbl ORDER BY val <-> '[$q]' LIMIT 5;\n";
    };

    my @synced_results;
    if ($have_injection_points)
    {
        my ($results_ref, $pending_seen) = run_parked_batch(
            $node, "postgres", $N, $pre_sql, $search_sql, 'batch_idx');
        @synced_results = @$results_ref;
        is($pending_seen, $N,
            "all $N searches were pending together before the worker's collect pass");
    }
    else
    {
        @synced_results = run_synchronized(
            $node, "postgres", $N, $pre_sql, $search_sql);
    }

    for my $i (0 .. $N - 1)
    {
        is($synced_results[$i], $baselines[$i],
            "synchronized client $i results match baseline");
    }

    my $batch_log = substr($node->log_content(), $log_pos_before_batch);
    SKIP: {
        skip 'batching cannot be forced without injection points', 1
          if !$have_injection_points;
        like($batch_log,
            qr/vamana worker: dispatching $N search \+ 0 write/,
            "worker log confirms all $N searches dispatched in one pass");
        like($batch_log,
            qr/vamana worker: native batch search for $N queries/,
            "worker log confirms native batch path for synchronized concurrent queries");
    }

    $node->stop;
    $node->append_conf('postgresql.conf', "svs.max_batch_size = 2");
    $node->start;
    sleep(2);

    my @capped_results = run_concurrent(
        $node, "postgres", 4,
        sub { make_search_sql($query_vecs[ $_[0] ]) },
        $SYNC_SLEEP
    );

    for my $i (0 .. 3)
    {
        isnt($capped_results[$i], '', "client $i returns results with max_batch_size=2");
        is($capped_results[$i], $baselines[$i],
            "client $i results match baseline with max_batch_size=2");
    }

    $node->stop;
    $node->append_conf('postgresql.conf', "svs.max_batch_size = 0");
    $node->start;
    sleep(2);

    my $sws_low  = 10;
    my $sws_high = 50;
    my $q0       = $query_vecs[0];
    my $q1       = $query_vecs[1];

    my $base_low = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SET svs.search_window_size = $sws_low;
        SELECT id FROM batch_tbl ORDER BY val <-> '[$q0]' LIMIT 5;
    ));
    my $base_high = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SET svs.search_window_size = $sws_high;
        SELECT id FROM batch_tbl ORDER BY val <-> '[$q1]' LIMIT 5;
    ));

    isnt($base_low,  '', "heterogeneous-k baseline (sws=$sws_low) is non-empty");
    isnt($base_high, '', "heterogeneous-k baseline (sws=$sws_high) is non-empty");

    my $hetero_pre = sub {
        my $i   = shift;
        my $sws = ($i == 0) ? $sws_low : $sws_high;
        return qq(SET enable_seqscan = off;\n)
          . qq(SET svs.search_window_size = $sws;\n);
    };
    my $hetero_search = sub {
        my $i = shift;
        my $q = ($i == 0) ? $q0 : $q1;
        return qq(SELECT id FROM batch_tbl ORDER BY val <-> '[$q]' LIMIT 5;\n);
    };

    my $hetero_log_pos = length($node->log_content());
    my @hetero_results;
    if ($have_injection_points)
    {
        my ($results_ref, $pending_seen) = run_parked_batch(
            $node, "postgres", 2, $hetero_pre, $hetero_search, 'batch_idx');
        @hetero_results = @$results_ref;
        is($pending_seen, 2,
            "both heterogeneous-k searches were pending together before the worker's collect pass");
    }
    else
    {
        @hetero_results = run_synchronized(
            $node, "postgres", 2, $hetero_pre, $hetero_search);
    }

    is($hetero_results[0], $base_low,
        "heterogeneous-k client 0 (sws=$sws_low) results match baseline");
    is($hetero_results[1], $base_high,
        "heterogeneous-k client 1 (sws=$sws_high) results match baseline");

    my $hetero_log = substr($node->log_content(), $hetero_log_pos);
    SKIP: {
        skip 'batching cannot be forced without injection points', 1
          if !$have_injection_points;
        like($hetero_log,
            qr/vamana worker: sequential search for 2 queries \(heterogeneous k\/dims\)/,
            "worker log confirms sequential fallback for heterogeneous search_window_size");
    }

    $node->stop;
}

# ===========================================================================
# Search-slot fault injection — VamanaWorkerRunBatch's PG_CATCH must release
# its rwlock and reset CurrentMemoryContext correctly on a search failure.
# ===========================================================================
SKIP: {
    skip 'server not built with --enable-injection-points', 6
        if (($ENV{enable_injection_points} // 'no') ne 'yes');

    my $node = PostgreSQL::Test::Cluster->new('vamana_search_fault');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "log_min_messages = 'debug1'");
    $node->start;

    $node->safe_psql('postgres', "CREATE EXTENSION vector;");
    $node->safe_psql('postgres', "CREATE EXTENSION svs;");
    $node->safe_psql('postgres', "CREATE EXTENSION injection_points;");
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    my $worker_pid = wait_for_worker($node);
    ok($worker_pid =~ /^\d+$/, 'worker is running before the search-fault loop');

    $node->safe_psql('postgres', qq(
        CREATE TABLE search_fault_tbl (id serial PRIMARY KEY, c1 vector($dim));
        INSERT INTO search_fault_tbl (c1)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 2000) i;
        CREATE INDEX search_fault_idx ON search_fault_tbl USING vamana (c1 vector_l2_ops);
    ));

    my $query_vec = "[" . join(',', (0) x $dim) . "]";

    my $baseline = $node->safe_psql('postgres',
        "SELECT count(*) FROM (SELECT id FROM search_fault_tbl "
      . "ORDER BY c1 <-> '$query_vec'::vector LIMIT 5) s;");
    chomp $baseline;
    is($baseline, '5', 'baseline search succeeds before fault injection');

    $node->safe_psql('postgres',
        "SELECT injection_points_attach('vamana-worker-search-error', 'error');");

    my $crashed_after_iteration;
    my $crash_log = '';

    for my $iter (1 .. 3)
    {
        my $log_pos = length($node->log_content());

        eval {
            $node->safe_psql('postgres',
                "SELECT id FROM search_fault_tbl "
              . "ORDER BY c1 <-> '$query_vec'::vector LIMIT 5;");
        };

        my $log = substr($node->log_content(), $log_pos);
        if ($log =~ /terminated by signal|Segmentation fault/)
        {
            $crashed_after_iteration = $iter;
            $crash_log = $log;
            last;
        }

        my $live_pid = $node->safe_psql('postgres',
            "SELECT pid FROM pg_stat_activity WHERE backend_type = 'vamana worker';");
        chomp $live_pid;
        is($live_pid, $worker_pid,
            "iteration $iter: worker survives the injected search failure without restarting");
    }

    ok(!defined $crashed_after_iteration,
        'repeated injected search failures do not crash the worker')
      or diag("crashed after $crashed_after_iteration failed search(es); server log:\n$crash_log");

    $node->safe_psql('postgres',
        "SELECT injection_points_detach('vamana-worker-search-error');")
      if !defined $crashed_after_iteration;

    $node->stop;
}

done_testing();
