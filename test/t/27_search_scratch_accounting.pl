# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 27_search_scratch_accounting.pl — the search-scratch axis: a catalog-time
# sum check on search_work_mem rejects an enrollment that would push the
# cluster-wide sum over svs.max_search_work_mem, serialized against a
# concurrent enrollment doing the same; a batch of queries whose combined
# memoized cost would exceed a database's search-scratch budget is refused at
# dispatch, before the CPU-governance thread grant is ever applied; the live
# in-flight total resets to zero on worker restart; and lowering
# search_work_mem while a batch is in flight disturbs nothing already
# admitted, applying only to the next one.

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

my $node = PostgreSQL::Test::Cluster->new('search_scratch_accounting');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'vector,svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 20");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "log_min_messages = 'debug1'");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->append_conf('postgresql.conf', "svs.max_residency_memory = '400MB'");
$node->append_conf('postgresql.conf', "svs.max_search_work_mem = '400MB'");
$node->append_conf('postgresql.conf', "svs.search_window_size = 10000");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres', "CREATE EXTENSION injection_points;");
$node->safe_psql('postgres',
    "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");
wait_for_worker($node);

# ---------------------------------------------------------------------------
# Case 0: the catalog-time sum check serializes concurrent enrollments, the
# same way residency admission serializes a decrease, but here for a plain
# sum across every row. 240MB each fits alone under the 400MB ceiling;
# both together (480MB) do not, so exactly one of the two must commit.
# ---------------------------------------------------------------------------
{
    $node->safe_psql('postgres', "CREATE DATABASE ssg_race_a;");
    $node->safe_psql('postgres', "CREATE DATABASE ssg_race_b;");

    my $first = $node->background_psql('postgres', on_error_stop => 0);
    $first->query_until(qr//, qq(
        BEGIN;
        INSERT INTO vamana_databases (datname, enabled, search_work_mem)
            VALUES ('ssg_race_a', true, 240);
    ));

    my $second = $node->background_psql('postgres', on_error_stop => 0);
    my $second_pid = $second->query('SELECT pg_backend_pid();');
    chomp $second_pid;
    $second->query_until(qr//, qq(
        INSERT INTO vamana_databases (datname, enabled, search_work_mem)
            VALUES ('ssg_race_b', true, 240);
    ));

    my $blocked = '';
    for (1 .. 100)
    {
        usleep(100_000);
        $blocked = $node->safe_psql('postgres',
            "SELECT wait_event FROM pg_stat_activity WHERE pid = $second_pid "
          . "AND wait_event_type = 'Lock';");
        last if $blocked ne '';
    }
    isnt($blocked, '', 'the second enrollment blocks on the serializing lock while the first is uncommitted');

    $first->query_safe("COMMIT;");
    $first->quit;

    my $unblocked = '';
    for (1 .. 100)
    {
        usleep(100_000);
        $unblocked = $node->safe_psql('postgres',
            "SELECT wait_event FROM pg_stat_activity WHERE pid = $second_pid "
          . "AND wait_event_type = 'Lock';");
        last if $unblocked eq '';
    }
    is($unblocked, '', 'the second enrollment unblocks once the first commits');
    $second->quit;

    is($node->safe_psql('postgres',
            "SELECT count(*) FROM vamana_databases WHERE datname = 'ssg_race_a';"),
        '1', 'the first enrollment committed');
    is($node->safe_psql('postgres',
            "SELECT count(*) FROM vamana_databases WHERE datname = 'ssg_race_b';"),
        '0', 'the second enrollment was rejected once it saw the first already committed');

    $node->safe_psql('postgres', "DELETE FROM vamana_databases WHERE datname = 'ssg_race_a';");
    $node->safe_psql('postgres', "DROP DATABASE ssg_race_a;");
    $node->safe_psql('postgres', "DROP DATABASE ssg_race_b;");
}

$node->safe_psql('postgres', qq(
    CREATE TABLE ssg_tbl (id serial PRIMARY KEY, val vector($dim));
    INSERT INTO ssg_tbl (val)
        SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 300) i;
    CREATE INDEX ssg_idx ON ssg_tbl USING vamana (val vector_l2_ops);
));
my $relid = $node->safe_psql('postgres', "SELECT 'ssg_idx'::regclass::oid;");

# search_work_mem is whole-MB granularity, but one query's real cost is only
# a few hundred KB even at the maximum search_window_size, so even the
# smallest allowed ceiling (1 MB) admits up to about 8 of them together.
# Real scheduling jitter can split $BATCH_N synchronized queries into
# several separate worker-side batches rather than one; $BATCH_N must be
# large enough that no plausible split leaves every resulting batch at or
# under that ~8-query admit threshold.
my $BATCH_N = 60;
my @batch_query_vecs =
    map { join(",", map { sprintf("%.6f", rand()) } 1 .. $dim) } 1 .. $BATCH_N;

my $probe_search_sql = qq(
    SET enable_seqscan = off;
    SELECT id FROM ssg_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
);
my ($probe_session, $probe_client_pid, $probe_worker_pid) =
    park_search_scratch_reservation($node, 'postgres', $probe_search_sql);
isnt($probe_worker_pid, '', 'a search parks once its search-scratch cost is admitted');

my $cost_bytes = search_scratch_cost_for_relid($node, 'postgres', $relid);
ok($cost_bytes =~ /^\d+$/ && $cost_bytes > 0,
    "the paused search's memoized cost is a positive byte count ($cost_bytes)");
is(search_scratch_in_flight_bytes($node, 'postgres'), $cost_bytes,
    'the in-flight total while paused equals exactly this one admitted cost');

release_search_scratch_reservation($node, 'postgres', $probe_session);

my $cost_mb = int(($cost_bytes + 1024 * 1024 - 1) / (1024 * 1024));
$cost_mb = 1 if $cost_mb < 1;

is(wait_for_search_scratch_in_flight($node, 'postgres', '0'), '0',
    'the in-flight total returns to zero once the paused search completes');

# ---------------------------------------------------------------------------
# Case 1: a batch whose combined cost exceeds the database's search-scratch
# budget is refused at dispatch, before the CPU-governance thread grant is
# ever applied to the handle. $BATCH_N synchronized clients against the same
# index can land in more than one worker-side batch (real scheduling jitter
# splits them), so only "at least one refused" is a claim the gate actually
# guarantees; the ceiling is pinned at the floor (a single query's own
# rounded-up cost) so every plausible split still has at least one batch
# too big to admit.
# ---------------------------------------------------------------------------
{
    $node->safe_psql('postgres',
        "UPDATE vamana_databases SET search_work_mem = $cost_mb WHERE datname = 'postgres';");

    my $log_pos = length($node->log_content());
    my @results = run_synchronized(
        $node, 'postgres', $BATCH_N,
        sub { return "SET enable_seqscan = off;\n"; },
        sub {
            my ($i) = @_;
            return "SELECT id FROM ssg_tbl ORDER BY val <-> '[$batch_query_vecs[$i]]' LIMIT 5;\n";
        });

    my $any_refused = 0;
    for my $r (@results)
    {
        $any_refused = 1 if $r eq '';
    }
    ok($any_refused,
        "at least one of $BATCH_N synchronized queries against one index is refused "
      . "once their combined cost exceeds the search-scratch budget");

    my $log = substr($node->log_content(), $log_pos);
    like($log, qr/exceeds this database's search-scratch budget/,
        'the refusal names the search-scratch budget');

    is(wait_for_search_scratch_in_flight($node, 'postgres', '0'), '0',
        'nothing is left in flight after the refused queries error');
}

# ---------------------------------------------------------------------------
# Case 2: raising the budget to comfortably cover the whole $BATCH_N-way
# batch, however it gets grouped, lets all of it through -- proving Case 1's
# refusal was the gate, not some unrelated breakage. search_num_threads is
# changed first so the CPU-governance apply log line is guaranteed to fire
# on this dispatch: that line only logs when the grant changes (22_search_
# grant_applied.pl case 6), so it is not itself proof of admission on its
# own, only that admission reached the code that applies the grant.
# ---------------------------------------------------------------------------
{
    $node->safe_psql('postgres',
        "UPDATE vamana_databases SET search_work_mem = " . ($cost_mb * ($BATCH_N + 1)) .
        ", search_num_threads = 2 WHERE datname = 'postgres';");

    my $log_pos = length($node->log_content());
    my @results = run_synchronized(
        $node, 'postgres', $BATCH_N,
        sub { return "SET enable_seqscan = off;\n"; },
        sub {
            my ($i) = @_;
            return "SELECT id FROM ssg_tbl ORDER BY val <-> '[$batch_query_vecs[$i]]' LIMIT 5;\n";
        });

    my $all_succeeded = 1;
    for my $r (@results)
    {
        $all_succeeded = 0 if $r eq '';
    }
    ok($all_succeeded,
        "the same $BATCH_N-way batch succeeds once the budget comfortably covers its combined cost");

    my $log = substr($node->log_content(), $log_pos);
    like($log, qr/vamana worker: dispatching batch on index $relid with 2 search threads/,
        'the thread grant is applied once the scratch gate admits the batch');

    is(wait_for_search_scratch_in_flight($node, 'postgres', '0'), '0',
        'nothing is left in flight once the admitted batch completes');
}

# ---------------------------------------------------------------------------
# Case 3: the live in-flight total resets to zero on worker restart, with no
# re-derivation needed -- unlike residency, nothing here is durable.  The
# worker is killed while genuinely holding a reservation (parked via the
# same mechanism as the probe above, before this batch's own release
# is reached), so this is the one path that can leak the counter forever
# without the worker-startup reset.
# ---------------------------------------------------------------------------
{
    my ($victim, $victim_pid, $pid1) = park_search_scratch_reservation($node, 'postgres', qq(
        SET enable_seqscan = off;
        SELECT id FROM ssg_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));
    isnt($pid1, '', 'the worker parks holding a reservation, before this batch\'s own release');
    is(search_scratch_in_flight_bytes($node, 'postgres'), $cost_bytes,
        'the in-flight total reflects the reservation the worker is about to lose');

    kill('TERM', $pid1);

    my $pid2 = '';
    for (1 .. 100)
    {
        usleep(100_000);
        $pid2 = $node->safe_psql('postgres',
            "SELECT pid FROM pg_stat_activity "
          . "WHERE backend_type = 'vamana worker' LIMIT 1;");
        chomp $pid2;
        last if $pid2 =~ /^\d+$/ && $pid2 ne $pid1;
    }
    ok($pid2 =~ /^\d+$/ && $pid2 ne $pid1,
        "worker respawns after being killed while holding a reservation (pid=$pid2)");

    is(wait_for_search_scratch_in_flight($node, 'postgres', '0'), '0',
        'the in-flight total reads zero after respawn, not the leaked reservation from the killed worker');

    # The victim's slot was reset straight to EMPTY by the new worker's
    # startup, never to DONE or ERROR, so nothing wakes VamanaWorkerSubmitSearch;
    # it would otherwise only give up once vamana_worker_timeout_ms elapses.
    $node->safe_psql('postgres', "SELECT pg_cancel_backend($victim_pid);");
    $victim->quit;
    $node->safe_psql('postgres',
        "SELECT injection_points_detach('vamana-search-scratch-reserved');");
}

# ---------------------------------------------------------------------------
# Case 4: lowering search_work_mem while a batch is in flight disturbs
# nothing already admitted -- no decrease-validation trigger exists for this
# axis -- and the lower ceiling is simply what the next batch is checked
# against.
# ---------------------------------------------------------------------------
{
    $node->safe_psql('postgres',
        "UPDATE vamana_databases SET search_work_mem = " . ($cost_mb * 3) .
        " WHERE datname = 'postgres';");

    my ($parked_req, $parked_req_pid, $worker_pid) =
        park_search_scratch_reservation($node, 'postgres', qq(
            SET enable_seqscan = off;
            SELECT id FROM ssg_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
        ));
    isnt($worker_pid, '', 'a fresh search parks with its cost already admitted');
    is(search_scratch_in_flight_bytes($node, 'postgres'), $cost_bytes,
        'the in-flight total reflects the paused batch');

    my ($ret, $stdout, $stderr) = $node->psql('postgres',
        "UPDATE vamana_databases SET search_work_mem = $cost_mb WHERE datname = 'postgres';");
    is($ret, 0,
        'lowering search_work_mem while a batch is in flight succeeds with no decrease check');

    is(search_scratch_in_flight_bytes($node, 'postgres'), $cost_bytes,
        'the paused batch\'s admitted cost is untouched by the lower ceiling');

    # Released via a kill/respawn (Case 3's mechanism, already proven clean)
    # rather than injection_points_wakeup: waking a batch parked here while a
    # concurrent catalog change is pending its own NOTIFY-driven launcher
    # reconcile does not reliably resume, an interaction with the
    # injection point's own condition variable, not anything this test needs
    # to prove.
    kill('TERM', $worker_pid);
    $node->safe_psql('postgres', "SELECT pg_cancel_backend($parked_req_pid);");
    $parked_req->quit;
    $node->safe_psql('postgres',
        "SELECT injection_points_detach('vamana-search-scratch-reserved');");

    my $new_worker_pid = '';
    for (1 .. 100)
    {
        usleep(100_000);
        $new_worker_pid = $node->safe_psql('postgres',
            "SELECT pid FROM pg_stat_activity "
          . "WHERE backend_type = 'vamana worker' LIMIT 1;");
        chomp $new_worker_pid;
        last if $new_worker_pid =~ /^\d+$/ && $new_worker_pid ne $worker_pid;
    }
    ok($new_worker_pid =~ /^\d+$/ && $new_worker_pid ne $worker_pid,
        "worker respawns after releasing the paused batch (pid=$new_worker_pid)");

    is(wait_for_search_scratch_in_flight($node, 'postgres', '0'), '0',
        'the paused batch left nothing in flight once released');

    # A single query fits the new, lower ceiling; $BATCH_N concurrent ones
    # against the same index push their combined cost over it.
    my @results = run_synchronized(
        $node, 'postgres', $BATCH_N,
        sub { return "SET enable_seqscan = off;\n"; },
        sub {
            my ($i) = @_;
            return "SELECT id FROM ssg_tbl ORDER BY val <-> '[$batch_query_vecs[$i]]' LIMIT 5;\n";
        });

    my $any_refused = 0;
    for my $r (@results)
    {
        $any_refused = 1 if $r eq '';
    }
    ok($any_refused,
        'a new batch is checked against the lower ceiling, not the one in effect when it was reserved');
}

# ---------------------------------------------------------------------------
# Case 5: the memoized per-query cost is computed once and read from cache
# on every unchanged repeat, then the two non-hot-path recompute triggers
# (see the design's three-trigger list; the hot-path trigger, at index load,
# is already exercised implicitly by every case above).
#
# Trigger 2, ALTER INDEX: the OAT_POST_ALTER hook rechecks the memoized cost
# against the index's current reloptions and invalidates it on a real
# change. This hook runs inside the same command as the catalog update, one
# CommandCounterIncrement before that update's self-invalidation would
# otherwise be visible -- calling it explicitly is what makes the hook's own
# index_open see the just-altered options instead of a stale copy.
#
# Trigger 3, SIGHUP: unlike the hook above, VamanaWorkerRefreshSearchScratchCosts
# runs entirely inside the worker's own fresh transaction, so it was never
# exposed to the same staleness.
# ---------------------------------------------------------------------------
{
    my $log_pos = length($node->log_content());
    $node->safe_psql('postgres', qq(
        SET enable_seqscan = off;
        SELECT id FROM ssg_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));
    my $repeat_log = substr($node->log_content(), $log_pos);
    unlike($repeat_log, qr/vamana worker: computed search-scratch cost/,
        'a repeat query against an unchanged index reads the memoized cost, not a recompute');

    $log_pos = length($node->log_content());
    $node->safe_psql('postgres', "ALTER INDEX ssg_idx SET (use_search_history = false);");
    $node->safe_psql('postgres', qq(
        SET enable_seqscan = off;
        SELECT id FROM ssg_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));

    my $log = substr($node->log_content(), $log_pos);
    like($log, qr/vamana worker: computed search-scratch cost/,
        'ALTER INDEX ... SET (use_search_history=...) invalidates the memoized '
      . 'search-scratch cost, so the next search recomputes it');

    $log_pos = length($node->log_content());
    $node->safe_psql('postgres', "ALTER SYSTEM SET svs.search_window_size = 5000;");
    $node->safe_psql('postgres', "SELECT pg_reload_conf();");

    my $recomputed = '';
    for (1 .. 100)
    {
        usleep(100_000);
        $recomputed = substr($node->log_content(), $log_pos);
        last if $recomputed =~ /vamana worker: computed search-scratch cost/;
    }
    like($recomputed, qr/vamana worker: computed search-scratch cost/,
        'a SIGHUP that changes svs.search_window_size invalidates every cached '
      . "index's memoized search-scratch cost");

    $node->safe_psql('postgres', "ALTER SYSTEM RESET svs.search_window_size;");
    $node->safe_psql('postgres', "SELECT pg_reload_conf();");
}

$node->stop;

done_testing();
