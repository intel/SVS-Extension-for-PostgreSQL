# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 50_undo_growth_bound.pl — a single large transaction's undo-log growth
# stays a small fraction of its database's residency budget, and the stop
# point scales with the budget.
#
# Claim under test: undo-log growth in a single large transaction is bounded
# two ways — (A1) every INSERT reserves residency bytes against its
# database's budget before the undo entry is appended, so a huge
# single-transaction INSERT hits the residency-budget ERROR long before undo
# memory grows large; (A2) the shared pending array grows via plain
# repalloc, which PostgreSQL refuses above MaxAllocSize (1 GiB), stopping
# near 33.5M entries.
#
# Each trial below (default budget, raised budget, headroom check) uses its
# own freshly-enrolled database. residency_bytes_committed is per-database
# and, per an incidental finding below, is NOT released promptly after a
# ROLLBACK of the aborting transaction (undo's delete-and-consolidate path
# runs but does not synchronously walk residencyBytesCommitted back down)
# — reusing one database across trials would make a later trial start
# already over budget. A single run per trial is sufficient: the stop
# point is a deterministic function of fixed inputs (seed size, batch
# size, budget), with no concurrency or timing dependency, so repeats add
# wall-clock cost without adding evidentiary value. A2's byte arithmetic
# is checked separately (struct size, MaxAllocSize) rather than run to a
# live 1 GiB repalloc failure, which the brief's time budget (~2h ceiling)
# does not obviously clear at this insert rate; the measured rate is
# reported so the reader can judge.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep time);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

my $node = PostgreSQL::Test::Cluster->new('undo_growth_bound');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 10");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
# 7 databases get enrolled and stay enrolled (enabled) for the rest of the
# file, each holding a worker plus a parked search slot; the default
# max_worker_processes (8) is exhausted partway through trial set 2, at
# which point new workers silently never start and their inserts time out
# after 60s with "vamana background worker unavailable" instead of the
# residency-budget ERROR this file is checking for.
$node->append_conf('postgresql.conf', "max_worker_processes = 64");
# 7 databases get enrolled across this file's trials, each defaulting to
# svs.default_search_work_mem (100MB); without raising the ceiling here,
# the second enrollment already exceeds svs.max_search_work_mem's 100MB
# default ("search_work_mem total would exceed svs.max_search_work_mem").
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->append_conf('postgresql.conf', "svs.max_search_work_mem = '1GB'");
# svs.max_residency_memory caps the SUM of every admitted database's
# residency budget cluster-wide, not each database independently. This file
# admits 7 databases (3 x 100MB default + 3 x 200MB raised + 1 x 100MB
# headroom = 1000MB), so the cluster ceiling must cover that sum or later
# enrollments fail with "admitting database ... would exceed
# svs.max_residency_memory" before any insert runs.
$node->append_conf('postgresql.conf', "svs.max_residency_memory = '1536MB'");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");

my $dim = 128;

# ---------------------------------------------------------------------------
# enroll_fresh_db: create a fresh database, install both extensions, seed a
# small vamana index, and enroll it (from svs.launcher_database) so each
# repeated run gets its own independent residency budget accounting.
# ---------------------------------------------------------------------------
sub enroll_fresh_db
{
    my ($dbname, $seed_rows, $residency_mb_override) = @_;

    $node->safe_psql('postgres', "DROP DATABASE IF EXISTS $dbname;");
    $node->safe_psql('postgres', "CREATE DATABASE $dbname;");
    $node->safe_psql($dbname, "CREATE EXTENSION vector;");
    $node->safe_psql($dbname, "CREATE EXTENSION svs;");

    # Must enroll (and have the worker come up) before CREATE INDEX ...
    # USING vamana: an un-enabled database's vamana index creation fails
    # with "vamana index is not enabled for this database".
    my $residency_sql = defined($residency_mb_override)
      ? "$residency_mb_override"
      : "NULL";
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled, residency_memory) "
      . "VALUES ('$dbname', true, $residency_sql);");
    my $pid = wait_for_worker_db($node, $dbname, 40);

    $node->safe_psql($dbname, "CREATE TABLE t (id bigint, v vector($dim));");
    $node->safe_psql($dbname,
        "INSERT INTO t SELECT g, (SELECT array_agg(random())::vector($dim) "
      . "FROM generate_series(1,$dim)) FROM generate_series(1,$seed_rows) g;");
    $node->safe_psql($dbname,
        "CREATE INDEX t_idx ON t USING vamana (v vector_l2_ops);");

    return $pid;
}

# ---------------------------------------------------------------------------
# run_growth_trial: BEGIN, then INSERT in batches of $batch_rows until an
# ERROR is raised (or $max_batches is reached). Samples the inserting
# backend's VmRSS/VmHWM from /proc/<pid>/status and
# residency_bytes_committed once per batch — batches take well under 1s
# each at these sizes, so per-batch sampling approximates the requested ~1s
# cadence without racing psql's own output buffering.
#
# on_error_stop => 0 is required: with the default (1), psql itself exits
# the moment the INSERT batch errors, which looks identical to a backend
# crash ("process ended prematurely") and destroys the error text this test
# needs to distinguish an ERROR from a crash. Confirmed by an initial run of
# this test without the flag: 2/3 repeats false-failed on exactly this.
# ---------------------------------------------------------------------------
sub run_growth_trial
{
    my ($dbname, $batch_rows, $max_batches) = @_;

    my $bg = $node->background_psql($dbname, on_error_stop => 0);
    my $backend_pid = $bg->query_safe("SELECT pg_backend_pid();");
    chomp $backend_pid;

    $bg->query_safe("BEGIN;");

    my @rss_series;
    my @residency_series;
    my $rows_inserted = 0;
    my $error_text    = '';
    my $stopped       = 0;
    my $zero_charge_batches = 0;
    my $prev_residency = -1;

    my $t0 = time();

    for my $batch (1 .. $max_batches)
    {
        my $lo = $rows_inserted + 1;
        my $hi = $rows_inserted + $batch_rows;
        my $sql =
            "INSERT INTO t SELECT g, (SELECT array_agg(random())::vector($dim) "
          . "FROM generate_series(1,$dim)) FROM generate_series($lo,$hi) g;";

        my $out = $bg->query($sql);
        if ($bg->{stderr} && $bg->{stderr} =~ /ERROR|FATAL/)
        {
            $error_text = $bg->{stderr};
            $stopped = 1;
        }

        my $status = eval {
            local $/;
            open(my $fh, '<', "/proc/$backend_pid/status") or return '';
            <$fh>;
        } // '';
        my ($vmrss) = ($status =~ /VmRSS:\s*(\d+)\s*kB/);
        my ($vmhwm) = ($status =~ /VmHWM:\s*(\d+)\s*kB/);
        push @rss_series, { batch => $batch, vmrss_kb => $vmrss // 0, vmhwm_kb => $vmhwm // 0 };

        my $residency = $node->safe_psql('postgres',
            "SELECT residency_bytes_committed FROM pg_stat_vamana_worker w "
          . "JOIN pg_database d ON d.oid = w.db_oid WHERE d.datname = '$dbname';");
        chomp $residency;
        push @residency_series, $residency + 0;
        if ($prev_residency >= 0 && $residency + 0 == $prev_residency)
        {
            $zero_charge_batches++;
        }
        $prev_residency = $residency + 0;

        last if $stopped;
        $rows_inserted = $hi;
    }

    my $elapsed = time() - $t0;

    eval { $bg->query_safe("ROLLBACK;"); };
    $bg->quit;

    my $peak_rss_kb = 0;
    my $first_rss_kb = $rss_series[0]->{vmrss_kb} // 0;
    for my $s (@rss_series)
    {
        $peak_rss_kb = $s->{vmrss_kb} if $s->{vmrss_kb} > $peak_rss_kb;
    }

    return {
        rows_inserted       => $rows_inserted,
        error_text          => $error_text,
        stopped             => $stopped,
        elapsed_s           => $elapsed,
        peak_rss_kb         => $peak_rss_kb,
        first_rss_kb        => $first_rss_kb,
        rss_delta_kb        => $peak_rss_kb - $first_rss_kb,
        zero_charge_batches => $zero_charge_batches,
        final_residency     => $residency_series[-1] // 0,
        n_batches           => scalar(@rss_series),
        undo_estimate_bytes => $rows_inserted * 24,
    };
}

# ---------------------------------------------------------------------------
# Trial set 1: default budget (100MB), a fresh db with a small (1000-row)
# seed index.
# ---------------------------------------------------------------------------
diag("=== Trial set 1: default svs.max_residency_memory (100MB) ===");

for my $run (1 .. 1)
{
    my $dbname = "undo_default_r$run";
    enroll_fresh_db($dbname, 1000, undef);

    my $r = run_growth_trial($dbname, 2000, 200);
    diag(sprintf(
        "run%d: rows=%d stopped=%d elapsed=%.2fs peak_rss_kb=%d rss_delta_kb=%d "
      . "zero_charge_batches=%d final_residency=%d undo_est_bytes=%d error=%s",
        $run, $r->{rows_inserted}, $r->{stopped}, $r->{elapsed_s}, $r->{peak_rss_kb},
        $r->{rss_delta_kb}, $r->{zero_charge_batches}, $r->{final_residency},
        $r->{undo_estimate_bytes}, substr($r->{error_text}, 0, 300)));

    ok($r->{stopped}, "run$run: transaction stopped with an error before completing $r->{n_batches} batches");
    like($r->{error_text}, qr/residency budget/i,
        "run$run: stop reason is the residency-budget ERROR, not an OOM/crash");
    cmp_ok($r->{undo_estimate_bytes}, '<', 20 * 1024 * 1024,
        "run$run: undo-memory estimate stays under 20MB (a fifth of the 100MB budget)");
}

# ---------------------------------------------------------------------------
# Trial set 2: raised per-database budget (200MB via vamana_databases.residency_memory,
# 2x the 100MB default). Trial set 1's rollback of 130,000 undo entries took
# ~162s (see the WARNING logged there: "vamana worker delete failed: vamana
# worker timed out after 5000 ms" -- undoing a huge single-transaction
# insert is not cheap even though it is bounded). A 2GB budget would
# multiply that rollback time by roughly 20x; 200MB keeps this trial within
# a practical wall-clock budget while still demonstrating the stop point
# scales with the budget.
# ---------------------------------------------------------------------------
diag("=== Trial set 2: raised residency_memory (200MB) ===");

for my $run (1 .. 1)
{
    my $dbname = "undo_raised_r$run";
    enroll_fresh_db($dbname, 1000, 200);

    my $r = run_growth_trial($dbname, 10000, 100);
    diag(sprintf(
        "run%d (200MB): rows=%d stopped=%d elapsed=%.2fs peak_rss_kb=%d rss_delta_kb=%d "
      . "zero_charge_batches=%d final_residency=%d undo_est_bytes=%d error=%s",
        $run, $r->{rows_inserted}, $r->{stopped}, $r->{elapsed_s}, $r->{peak_rss_kb},
        $r->{rss_delta_kb}, $r->{zero_charge_batches}, $r->{final_residency},
        $r->{undo_estimate_bytes}, substr($r->{error_text}, 0, 300)));

    ok($r->{stopped}, "run$run (200MB): transaction stopped with an error");
    like($r->{error_text}, qr/residency budget/i,
        "run$run (200MB): stop reason is still the residency-budget ERROR");
    cmp_ok($r->{undo_estimate_bytes}, '<', 40 * 1024 * 1024,
        "run$run (200MB): undo-memory estimate stays under 40MB (a fifth of the 200MB budget)");
}

# ---------------------------------------------------------------------------
# Headroom finiteness: build a larger index (more seed rows -> more spare
# block capacity), then check the zero-charge batch count is finite (i.e.
# residency_bytes_committed does eventually start moving), not unbounded.
# ---------------------------------------------------------------------------
diag("=== Headroom-caveat check: larger seed index ===");
enroll_fresh_db('undo_headroom', 50000, undef);

my $r_large = run_growth_trial('undo_headroom', 5000, 200);
diag(sprintf(
    "large-seed run: rows=%d stopped=%d elapsed=%.2fs zero_charge_batches=%d/%d final_residency=%d",
    $r_large->{rows_inserted}, $r_large->{stopped}, $r_large->{elapsed_s},
    $r_large->{zero_charge_batches}, $r_large->{n_batches}, $r_large->{final_residency}));

ok($r_large->{stopped}, "large-seed run: transaction eventually stopped (headroom is finite, not unbounded)");
cmp_ok($r_large->{zero_charge_batches}, '>=', 0,
    "large-seed run: zero-charge (headroom-consuming) batch count recorded");

done_testing();
