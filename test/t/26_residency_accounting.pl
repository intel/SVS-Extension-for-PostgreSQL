# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 26_residency_accounting.pl — the residency-bytes-committed counter stays
# correct under the insert growth gate (refusal before the write lock,
# DELETE ungated, reanchor on a fitting insert), under a crash before a
# pending insert reaches the worker (backend-side or reaper cleanup), and
# across a DROP INDEX that commits while the worker is down (reconciled at
# the worker's next restart).

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

if (($ENV{enable_injection_points} // 'no') ne 'yes')
{
    plan skip_all => 'server not built with --enable-injection-points';
}

my $node = PostgreSQL::Test::Cluster->new('residency_accounting');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'vector,svs'");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 20");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "log_min_messages = 'debug1'");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres', "CREATE EXTENSION injection_points;");
$node->safe_psql('postgres',
    "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");
wait_for_worker($node);

sub committed_bytes
{
    my $bytes = $node->safe_psql('postgres',
        "SELECT residency_bytes_committed FROM pg_stat_vamana_worker "
      . "WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');");
    chomp $bytes;
    return $bytes;
}

# Disables postgres first so the launcher does not race a respawn, SIGTERMs
# its worker, and waits for the process to actually exit.
sub kill_worker_and_wait
{
    my $worker_pid = $node->safe_psql('postgres',
        "SELECT pid FROM pg_stat_activity WHERE backend_type = 'vamana worker';");
    chomp $worker_pid;
    $node->safe_psql('postgres',
        "UPDATE vamana_databases SET enabled = false WHERE datname = 'postgres';");

    my $log_pos = length($node->log_content());
    kill('TERM', $worker_pid);
    $node->wait_for_log(qr/vamana background worker shutting down/, $log_pos);
    for (1 .. 100)
    {
        usleep(100_000);
        my $alive = $node->safe_psql('postgres',
            "SELECT count(*) FROM pg_stat_activity "
          . "WHERE backend_type = 'vamana worker';");
        chomp $alive;
        last if $alive eq '0';
    }
}

$node->safe_psql('postgres', qq(
    CREATE TABLE growth_tbl (id serial PRIMARY KEY, val vector($dim));
    INSERT INTO growth_tbl (val)
        SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 50);
    CREATE INDEX growth_idx ON growth_tbl USING vamana (val vector_l2_ops);
));
wait_for_worker($node);
$node->safe_psql('postgres', qq(
    SET enable_seqscan = off;
    SELECT id FROM growth_tbl ORDER BY val <-> '[$query_sql]' LIMIT 1;
));

my $committed_after_build = committed_bytes();

# residency_memory is in megabytes, the same unit as every other residency
# GUC; rounding up to the nearest whole megabyte is the tightest budget that
# still satisfies the decrease-guard (it must not sit below what this
# database already has committed).
my $pinned_budget_mb = int(($committed_after_build + 1024 * 1024 - 1) / (1024 * 1024));
$node->safe_psql('postgres',
    "UPDATE vamana_databases SET residency_memory = $pinned_budget_mb "
  . "WHERE datname = 'postgres';");

# ---------------------------------------------------------------------------
# Case 1: with the budget pinned at the tightest whole-megabyte value that
# still fits, keep inserting single rows until the next one would cross it.
# That insert is refused before the write lock is taken, and the committed
# total is left exactly where it was.
# ---------------------------------------------------------------------------
my $committed_before_refusal;
{
    my $refused = '';
    for (1 .. 10_000)
    {
        $committed_before_refusal = committed_bytes();
        my ($ret, $stdout, $stderr) = $node->psql('postgres',
            "INSERT INTO growth_tbl (val) VALUES ('[$query_sql]');");
        if ($ret != 0)
        {
            like($stderr, qr/residency budget/,
                'the refusal names the residency budget');
            $refused = 1;
            last;
        }
    }
    ok($refused, 'an insert eventually exceeds the pinned budget and is refused');

    is(committed_bytes(), $committed_before_refusal,
        'the committed total is unchanged by the refused insert');
}

# ---------------------------------------------------------------------------
# Case 2: DELETE is never gated, even while the database sits pinned at a
# budget insert already cannot grow past.
# ---------------------------------------------------------------------------
{
    my ($ret, $stdout, $stderr) = $node->psql('postgres',
        "DELETE FROM growth_tbl WHERE id = 1;");
    is($ret, 0, 'a delete succeeds even though the database is pinned at its budget');
}

# ---------------------------------------------------------------------------
# Case 3: lift the pinned budget; a fitting insert now reanchors the
# committed total to the exact freshly measured size.
# ---------------------------------------------------------------------------
{
    $node->safe_psql('postgres',
        "UPDATE vamana_databases SET residency_memory = NULL WHERE datname = 'postgres';");

    my $committed_before_insert = committed_bytes();
    $node->safe_psql('postgres',
        "INSERT INTO growth_tbl (val) VALUES ('[$query_sql]');");

    isnt(committed_bytes(), $committed_before_insert,
        'a fitting insert moves the committed total off its pre-insert value');
}

my $baseline = committed_bytes();

# ---------------------------------------------------------------------------
# Case 4: the worker dies while a backend's insert is parked just before it
# publishes to the worker -- after SvsMemoryReserveInsert already ran, but
# before the worker can ever see, let alone apply, the request. The
# backend itself stays alive, observes the worker is gone, and its own
# error cleanup (SvsMemoryAbortInsert) must release the reservation: no
# reap is available to do it, since the backend never died.
# ---------------------------------------------------------------------------
{
    $node->safe_psql('postgres',
        "SELECT injection_points_attach('vamana-enqueue-before-publish', 'wait');");

    my $parked = $node->background_psql('postgres', on_error_stop => 0);
    $parked->query_until(qr/insert_started/, qq(
        \\echo insert_started
        INSERT INTO growth_tbl (val) VALUES ('[$query_sql]');
    ));
    $node->wait_for_event('client backend', 'vamana-enqueue-before-publish');

    kill_worker_and_wait();

    $node->safe_psql('postgres',
        "SELECT injection_points_wakeup('vamana-enqueue-before-publish');");

    my $parked_out = $parked->query('SELECT 1');
    like($parked_out, qr/1/,
        "the parked insert's own session stays usable after the worker dies under it");
    $parked->quit;

    $node->safe_psql('postgres',
        "SELECT injection_points_detach('vamana-enqueue-before-publish');");

    $node->safe_psql('postgres',
        "UPDATE vamana_databases SET enabled = true WHERE datname = 'postgres';");
    wait_for_worker($node);

    is(committed_bytes(), $baseline,
        'a reservation whose worker died before publish leaves no trace once the worker recovers');
}

# ---------------------------------------------------------------------------
# Case 5: the reserving backend itself dies (an ordinary SIGTERM, not a
# whole-cluster crash) while parked before publish. Nothing runs that
# backend's own error cleanup, so only the launcher/worker's dead-owner
# reaper (SvsMemoryReapDeadReservations) can reclaim the reservation.
# ---------------------------------------------------------------------------
{
    $node->safe_psql('postgres',
        "SELECT injection_points_attach('vamana-enqueue-before-publish', 'wait');");

    my $victim = $node->background_psql('postgres', on_error_stop => 0);
    my $victim_pid_out = $victim->query('SELECT pg_backend_pid()');
    my ($victim_pid) = $victim_pid_out =~ /(\d+)/;

    $victim->query_until(qr/insert_started/, qq(
        \\echo insert_started
        INSERT INTO growth_tbl (val) VALUES ('[$query_sql]');
    ));
    $node->wait_for_event('client backend', 'vamana-enqueue-before-publish');

    kill('TERM', $victim_pid);

    # The reaper runs on every launcher wake, but the launcher only wakes on
    # its own naptime (up to VAMANA_LAUNCHER_NAPTIME_MS) unless prodded
    # sooner. A no-op UPDATE on vamana_databases fires its AFTER-statement
    # NOTIFY trigger, which wakes the launcher immediately; repeating it
    # alongside the poll also covers the victim's own OS-level exit not
    # having landed yet on the first attempt.
    my $reaped = '';
    for (1 .. 100)
    {
        $node->safe_psql('postgres',
            "UPDATE vamana_databases SET enabled = enabled WHERE datname = 'postgres';");
        usleep(100_000);
        my $bytes = committed_bytes();
        if ($bytes eq $baseline)
        {
            $reaped = 1;
            last;
        }
    }
    ok($reaped,
        "a dead backend's pending insert reservation is reclaimed by the reaper");

    $node->safe_psql('postgres',
        "SELECT injection_points_detach('vamana-enqueue-before-publish');");
}

# ---------------------------------------------------------------------------
# Case 6: growth_idx is dropped while its worker is down. Nothing evicts a
# stale reservation for an index the worker never saw dropped -- only the
# worker's own startup reconcile against the live catalog can.
# ---------------------------------------------------------------------------
{
    my $committed_before_drop = committed_bytes();
    cmp_ok($committed_before_drop, '>', 0,
        'growth_idx is still resident and committed before its worker goes down');

    kill_worker_and_wait();

    $node->safe_psql('postgres', "DROP INDEX growth_idx;");

    $node->safe_psql('postgres',
        "UPDATE vamana_databases SET enabled = true WHERE datname = 'postgres';");
    wait_for_worker($node);

    my $committed_after_restart;
    for (1 .. 30)
    {
        $committed_after_restart = committed_bytes();
        last if $committed_after_restart eq '0';
        usleep(500_000);
    }
    is($committed_after_restart, '0',
        "the dropped index's stale reservation does not survive the worker's restart");
}

# ---------------------------------------------------------------------------
# Case 7: dropping an index while its worker is up releases its committed
# bytes immediately -- no restart-time reconcile needed, unlike Case 6.
# ---------------------------------------------------------------------------
{
    $node->safe_psql('postgres', qq(
        CREATE TABLE dropup_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO dropup_tbl (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 50);
        CREATE INDEX dropup_idx ON dropup_tbl USING vamana (val vector_l2_ops);
    ));
    wait_for_worker($node);

    cmp_ok(committed_bytes(), '>', 0,
        'dropup_idx is resident and committed before it is dropped');

    $node->safe_psql('postgres', "DROP INDEX dropup_idx;");

    is(committed_bytes(), '0',
        'dropping an index while its worker is up releases its bytes with no restart');

    $node->safe_psql('postgres', "DROP TABLE dropup_tbl;");
}

# ---------------------------------------------------------------------------
# Case 8: lowering residency_memory below a durable resident_bytes floor is
# refused while the worker is down. SvsIndexResidencyDurableFloor queries
# svs_index_residency for real here, unlike the unit test's direct call
# with a hand-supplied floor.
# ---------------------------------------------------------------------------
{
    $node->safe_psql('postgres', qq(
        CREATE TABLE floor_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO floor_tbl (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 5000);
        CREATE INDEX floor_idx ON floor_tbl USING vamana (val vector_l2_ops);
    ));
    wait_for_worker($node);

    my $durable_floor_bytes = $node->safe_psql('postgres',
        "SELECT resident_bytes FROM svs_index_residency "
      . "WHERE index_relid = 'floor_idx'::regclass;");
    chomp $durable_floor_bytes;
    cmp_ok($durable_floor_bytes, '>', 1024 * 1024,
        'floor_idx has a durable resident-bytes row above 1MB before its worker goes down');

    kill_worker_and_wait();

    my $budget_before_decrease = $node->safe_psql('postgres',
        "SELECT residency_memory_limit FROM pg_stat_vamana_worker "
      . "WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');");
    chomp $budget_before_decrease;

    $node->safe_psql('postgres',
        "UPDATE vamana_databases SET residency_memory = 1 WHERE datname = 'postgres';");

    my $budget_after_decrease = $node->safe_psql('postgres',
        "SELECT residency_memory_limit FROM pg_stat_vamana_worker "
      . "WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');");
    chomp $budget_after_decrease;
    is($budget_after_decrease, $budget_before_decrease,
        'a decrease below the durable resident-bytes floor is rejected while the worker is down');

    $node->safe_psql('postgres',
        "UPDATE vamana_databases SET enabled = true, residency_memory = NULL "
      . "WHERE datname = 'postgres';");
    wait_for_worker($node);
    $node->safe_psql('postgres', "DROP INDEX floor_idx;");
    $node->safe_psql('postgres', "DROP TABLE floor_tbl;");
}

# ---------------------------------------------------------------------------
# Case: an insert needing no real SVS block growth is admitted, using the
# real, SVS-linked capacity calibration -- not the fake shmem harness
# svs_memory_test uses for the gate logic itself. A fresh index's degree-64
# graph component has room for exactly 64 - N rows before its first real
# block growth, independent of dims (16-dim data, 260-byte adjacency
# entries dominate here).
# ---------------------------------------------------------------------------
{
    $node->safe_psql('postgres', qq(
        CREATE TABLE calib_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO calib_tbl (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 70);
    ));

    my $log_pos = length($node->log_content());
    $node->safe_psql('postgres',
        "CREATE INDEX calib_idx ON calib_tbl USING vamana (val vector_l2_ops);");
    wait_for_worker($node);

    my $log_slice = substr($node->log_content(), $log_pos);
    like($log_slice, qr/capacity headroom for 70 vectors is 58 \(data \d+, graph 58\)/,
        'real calibration computes the analytically expected headroom for a fresh 70-row index');

    my $committed_before_compact = committed_bytes();

    # Delete past vamana_compact_threshold_pct (10% default) and VACUUM to
    # force a real COMPACT; it must recalibrate for the post-compact count.
    # 70 rows span two graph blocks (block size 64); dropping to 60 fits back
    # in one, so compact frees a block and the committed total must shrink.
    $log_pos = length($node->log_content());
    $node->safe_psql('postgres', "DELETE FROM calib_tbl WHERE id <= 10;");
    $node->safe_psql('postgres', "VACUUM calib_tbl;");
    wait_for_worker($node);

    $log_slice = substr($node->log_content(), $log_pos);
    like($log_slice, qr/capacity headroom for 60 vectors is \d+ \(data \d+, graph \d+\)/,
        'compact triggers real recalibration for the post-compact row count');
    cmp_ok(committed_bytes(), '<', $committed_before_compact,
        'compact reconciles the committed residency total, not just the headroom');

    $node->safe_psql('postgres', "DROP INDEX calib_idx;");
    $node->safe_psql('postgres', "DROP TABLE calib_tbl;");
}

# ---------------------------------------------------------------------------
# Case 9: the global ceiling sums resolved per-database budgets, not just
# one database's own. A second database that alone would fit still gets
# rejected once its resolved budget, added to every other admitted
# database's, would cross svs.max_residency_memory. Also races a real build
# on postgres (build axis) against an override update on the second
# database (residency axis) to prove the two axes' header roll-ups don't
# block or corrupt each other.
# ---------------------------------------------------------------------------
{
    $node->safe_psql('postgres', "ALTER SYSTEM SET svs.max_residency_memory = '150MB';");
    $node->safe_psql('postgres', "ALTER SYSTEM SET svs.max_search_work_mem = '1500MB';");
    $node->safe_psql('postgres', "ALTER SYSTEM SET svs.default_search_work_mem = '10MB';");
    $node->reload;

    $node->safe_psql('postgres', "CREATE DATABASE ceiling_b;");

    # postgres already holds the default 100MB against the new 150MB
    # ceiling; another 100MB for ceiling_b would sum to 200MB, over it.
    my ($ret, $stdout, $stderr) = $node->psql('postgres', qq(
        INSERT INTO vamana_databases (datname, enabled, residency_memory)
            VALUES ('ceiling_b', true, 100);
    ));
    isnt($ret, 0, 'a second database is rejected once its budget would push the sum over the ceiling');
    like($stderr, qr/svs\.max_residency_memory/,
        'the rejection names svs.max_residency_memory')
      or diag("stderr: $stderr");

    my $row_count = $node->safe_psql('postgres',
        "SELECT count(*) FROM vamana_databases WHERE datname = 'ceiling_b';");
    chomp $row_count;
    is($row_count, '0', 'the rejected enrollment leaves no row behind');

    # 40MB fits: 100 (postgres) + 40 = 140 <= 150.
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled, residency_memory) VALUES ('ceiling_b', true, 40);");
    my $pid_b = wait_for_worker_db($node, 'ceiling_b');
    ok($pid_b =~ /^\d+$/, 'the second database is admitted once it fits under the ceiling');

    $node->safe_psql('postgres', qq(
        CREATE TABLE ceiling_tbl (id serial PRIMARY KEY, c1 vector($dim));
        INSERT INTO ceiling_tbl (c1)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 2000) i;
    ));

    my $build = $node->background_psql('postgres', on_error_stop => 0);
    $build->query_until(qr/ceiling_build_started/, qq(
        \\echo ceiling_build_started
        CREATE INDEX ceiling_idx ON ceiling_tbl USING vamana (c1 vector_l2_ops);
    ));

    my ($ret2, $stdout2, $stderr2) = $node->psql('postgres',
        "UPDATE vamana_databases SET residency_memory = 45 WHERE datname = 'ceiling_b';");
    is($ret2, 0, 'the second database\'s override update completes while the first is mid-build')
      or diag("stderr: $stderr2");

    $build->query('SELECT 1');
    my $build_stderr = $build->{stderr};
    $build->quit;
    unlike($build_stderr, qr/ERROR/, 'the concurrent build reports no error')
      or diag("stderr: $build_stderr");

    my $index_count = $node->safe_psql('postgres',
        "SELECT count(*) FROM pg_indexes WHERE indexname = 'ceiling_idx';");
    chomp $index_count;
    is($index_count, '1', 'the build completed despite the concurrent override update on the other database');

    is($node->safe_psql('postgres',
            "SELECT residency_memory FROM vamana_databases WHERE datname = 'ceiling_b';"),
        '45', 'the override took effect despite the concurrent build on the other database');

    cmp_ok(committed_bytes(), '>', 0,
        'postgres\'s own committed total reflects its build, unaffected by the other database\'s update');

    $node->safe_psql('postgres', "UPDATE vamana_databases SET enabled = false WHERE datname = 'ceiling_b';");
    $node->safe_psql('postgres', "ALTER SYSTEM RESET svs.max_residency_memory;");
    $node->safe_psql('postgres', "ALTER SYSTEM RESET svs.max_search_work_mem;");
    $node->safe_psql('postgres', "ALTER SYSTEM RESET svs.default_search_work_mem;");
    $node->reload;
}

# ---------------------------------------------------------------------------
# Case 10: svs.default_residency_memory shrinks below the durable total of
# two already-resident indexes, then the node restarts. Only one index's
# residency is re-seeded; the other must be logged, not silently dropped.
# ---------------------------------------------------------------------------
{
    $node->safe_psql('postgres', "DROP TABLE ceiling_tbl;");

    $node->safe_psql('postgres', qq(
        CREATE TABLE shrink_a_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO shrink_a_tbl (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 20000);
        CREATE INDEX shrink_a_idx ON shrink_a_tbl USING vamana (val vector_l2_ops);
    ));
    wait_for_worker($node);

    $node->safe_psql('postgres', qq(
        CREATE TABLE shrink_b_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO shrink_b_tbl (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 20000);
        CREATE INDEX shrink_b_idx ON shrink_b_tbl USING vamana (val vector_l2_ops);
    ));
    wait_for_worker($node);

    my $relid_a = $node->safe_psql('postgres', "SELECT 'shrink_a_idx'::regclass::oid;");
    my $relid_b = $node->safe_psql('postgres', "SELECT 'shrink_b_idx'::regclass::oid;");
    chomp($relid_a, $relid_b);

    my $size_a = $node->safe_psql('postgres',
        "SELECT resident_bytes FROM svs_index_residency WHERE index_relid = $relid_a;");
    my $size_b = $node->safe_psql('postgres',
        "SELECT resident_bytes FROM svs_index_residency WHERE index_relid = $relid_b;");
    chomp($size_a, $size_b);

    my $budget_mb = int(($size_a + 1024 * 1024 - 1) / (1024 * 1024));
    my $budget_bytes = $budget_mb * 1024 * 1024;
    cmp_ok($size_a + $size_b, '>', $budget_bytes,
        'both indexes together exceed the budget this test is about to shrink to');

    $node->safe_psql('postgres',
        "ALTER SYSTEM SET svs.default_residency_memory = '${budget_mb}MB';");

    my $log_pos = length($node->log_content());
    $node->restart;

    my $state = '';
    for (1 .. 60)
    {
        $state = $node->safe_psql('postgres',
            "SELECT worker_state FROM pg_stat_vamana_worker "
          . "WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');");
        chomp $state;
        last if $state eq 'running';
        usleep(500_000);
    }
    is($state, 'running', 'the worker settles into running after the restart');

    my $committed = committed_bytes();
    my $dropped_relid = $committed eq $size_a ? $relid_b
                       : $committed eq $size_b ? $relid_a
                       : undef;
    ok(defined $dropped_relid,
        "committed total ($committed) matches exactly one index's durable size "
      . "(size_a=$size_a, size_b=$size_b)");

    my $log_since_restart = substr($node->log_content(), $log_pos);
    like($log_since_restart,
        qr/WARNING.*residency budget.*\b$dropped_relid\b|WARNING.*\b$dropped_relid\b.*residency budget/s,
        "the seed that lost to the budget is logged, naming index $dropped_relid")
      or diag("log since restart:\n$log_since_restart");

    $node->safe_psql('postgres', "ALTER SYSTEM RESET svs.default_residency_memory;");
    $node->reload;
    $node->safe_psql('postgres', "DROP TABLE shrink_a_tbl, shrink_b_tbl;");
}

$node->stop;

done_testing();
