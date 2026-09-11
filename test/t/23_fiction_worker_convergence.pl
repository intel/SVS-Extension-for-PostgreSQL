# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 23_fiction_worker_convergence.pl -- pins the observable behavior a
# per-database worker must show once it holds one parked parallel slot per
# granted search thread (Task A4).  Written ahead of the implementation: its
# two dependencies (a slot-set primitive and grant application) are still in
# review, so every assertion here is built only on what already exists on
# main today -- the grant math in svs_cpu_budget.c / PublishCpuGrants, and
# core PostgreSQL views.
#
# This file is expected to fail. That is the point: it fails on its
# assertions, pinning the target behavior, so the implementation has
# something external to converge against instead of being graded by tests
# shaped after the fact.
#
# Stable observables only (see the design note this was written from):
#   - backend_type = 'vamana search slot'  (SvsSlotKindBgwType; not under review)
#   - pg_stat_vamana_worker.search_threads_desired / _granted / _reserved
#   - pg_stat_vamana_worker.worker_pid / heartbeat_ts
#   - absence of "exited with exit code" / "Segmentation fault" in the log
#   - whether a plain core parallel query gets workers from the shared pool
# Never application_name text or shortfall log wording: both are under
# active review and will change shape without changing meaning.
#
# ---------------------------------------------------------------------------
# OPEN DESIGN QUESTION -- static hold vs. per-dispatch acquisition
#
# Whether a granted search thread's parked slot is held for the grant's
# whole lifetime (static hold) or acquired only while a search is actually
# dispatched is not yet decided. Every assertion in this file that compares
# a "vamana search slot" row count against a *granted* value while no
# search is in flight assumes static hold -- that is, the worker owns a
# slot set and converges the held slot count on the launcher's published
# grant, and it is also the model nearly
# every case below tests, because none of them keep a search actively
# running at the moment they sample. If the policy flips to per-dispatch,
# every such assertion in this file needs rewriting; the grant-math checks
# (search_threads_desired/granted/reserved converge correctly) and the
# crash/pid-stability checks do not, since they say nothing about *when* a
# slot is held. That whole class of assertion is marked with a
# STATIC-HOLD ASSUMPTION comment at each site below rather than gathered
# into one lexical block, because it is not a handful of cases -- it is most
# of the file. See the final task report for the reviewer-facing version of
# this note.
# ---------------------------------------------------------------------------

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep gettimeofday tv_interval);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

# ---------------------------------------------------------------------------
# Local helpers
# ---------------------------------------------------------------------------

sub db_oid
{
    my ($node, $db) = @_;
    my $oid = $node->safe_psql('postgres',
        "SELECT oid FROM pg_database WHERE datname = '$db';");
    chomp $oid;
    return $oid;
}

# STATIC-HOLD ASSUMPTION: a row count here is only comparable to a grant
# when the worker is expected to be holding slots at rest, not mid-search.
#
# A parked "vamana search slot" is registered without
# BGWORKER_BACKEND_DATABASE_CONNECTION (svs_cpu_slots.c), so it never runs
# InitPostgres and pg_stat_activity.datname for it is always NULL, for every
# database, with no exception -- confirmed by hand against a scratch
# cluster. That column cannot attribute a slot to a database. The only
# per-database signal a parked slot publishes at all is its
# application_name, set by SvsFormatSearchSlotAppName as
# "vamana: db=<datname> search slot <i>/<n> (reserved <n>)"; matching on the
# "db=<datname> " prefix is therefore the only available per-database
# filter, not a preference over the datname column.
sub search_slot_count
{
    my ($node, $db) = @_;
    my $c = $node->safe_psql('postgres',
        "SELECT count(*) FROM pg_stat_activity "
      . "WHERE backend_type = 'vamana search slot' "
      . "AND application_name LIKE 'vamana: db=$db %';");
    chomp $c;
    return $c;
}

sub granted_for_db
{
    my ($node, $dboid) = @_;
    my $g = $node->safe_psql('postgres',
        "SELECT search_threads_granted FROM pg_stat_vamana_worker "
      . "WHERE db_oid = $dboid;");
    chomp $g;
    return $g;
}

sub desired_for_db
{
    my ($node, $dboid) = @_;
    my $d = $node->safe_psql('postgres',
        "SELECT search_threads_desired FROM pg_stat_vamana_worker "
      . "WHERE db_oid = $dboid;");
    chomp $d;
    return $d;
}

# Poll the *published* grant, distinct from whether slots are held for it --
# keeping "published" and "held" as separate polls is what makes a failure
# here diagnosable as a launcher problem vs. a worker problem.
sub wait_for_granted
{
    my ($node, $dboid, $want, $attempts) = @_;
    $attempts //= 40;
    my $g = '';
    for (1 .. $attempts)
    {
        usleep(500_000);
        $g = granted_for_db($node, $dboid);
        return $g if defined($g) && $g ne '' && $g == $want;
    }
    return $g;
}

# STATIC-HOLD ASSUMPTION: waiting for held slots to reach $want only makes
# sense if slots are supposed to be held independent of an active search.
sub wait_for_search_slot_count
{
    my ($node, $db, $want, $attempts) = @_;
    $attempts //= 40;
    my $c = '';
    for (1 .. $attempts)
    {
        usleep(500_000);
        $c = search_slot_count($node, $db);
        return $c if $c eq $want;
    }
    return $c;
}

# Case 8: the rollup invariant. sum(granted) across every worker equals the
# total number of held search slots cluster-wide. The single best
# whole-feature guard because it is the one check that a per-database
# implementation cannot pass by accident -- it must hold across every row.
# STATIC-HOLD ASSUMPTION: only meaningful at rest, with no search in flight.
sub rollup_snapshot
{
    my ($node) = @_;
    my $sum = $node->safe_psql('postgres',
        "SELECT coalesce(sum(search_threads_granted), 0) "
      . "FROM pg_stat_vamana_worker;");
    chomp $sum;
    my $slots = $node->safe_psql('postgres',
        "SELECT count(*) FROM pg_stat_activity "
      . "WHERE backend_type = 'vamana search slot';");
    chomp $slots;
    return ($sum, $slots);
}

sub assert_rollup_matches
{
    my ($node, $label) = @_;
    my ($sum, $slots) = rollup_snapshot($node);
    my $breakdown = $node->safe_psql('postgres',
        "SELECT db_oid, worker_pid, search_threads_desired, "
      . "search_threads_granted, search_threads_reserved FROM pg_stat_vamana_worker;");
    diag("pg_stat_vamana_worker at '$label':\n$breakdown");
    is($sum, $slots,
        "rollup invariant ($label): sum(search_threads_granted)=$sum "
      . "matches held 'vamana search slot' rows=$slots");
}

# Case 9: no worker died. Checked from an anchored log offset so an
# unrelated earlier line can never satisfy it.
sub assert_no_crash_since
{
    my ($node, $log_pos, $label) = @_;
    my $log = substr($node->log_content(), $log_pos);
    unlike($log, qr/exited with exit code/,
        "no worker exit-code crash during $label");
    unlike($log, qr/Segmentation fault/,
        "no segfault during $label");
}

sub wait_for_new_worker_pid_db
{
    my ($node, $db, $old, $attempts) = @_;
    $attempts //= 60;
    for (1 .. $attempts)
    {
        usleep(500_000);
        my $pid = $node->safe_psql('postgres',
            "SELECT pid FROM pg_stat_activity "
          . "WHERE backend_type = 'vamana worker' AND datname = '$db' LIMIT 1;");
        chomp $pid;
        return $pid if $pid =~ /^\d+$/ && $pid ne $old;
    }
    return '';
}

# A plain core parallel query, forced regardless of table size or cost
# settings, so the workers-launched count reflects only pool availability,
# not planner cost heuristics.
sub workers_launched
{
    my ($node, $db, $tbl) = @_;
    my $out = $node->safe_psql($db, qq(
        SET parallel_setup_cost = 0;
        SET parallel_tuple_cost = 0;
        SET min_parallel_table_scan_size = 0;
        SET max_parallel_workers_per_gather = 4;
        EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
        SELECT count(*) FROM $tbl;
    ));
    my ($n) = $out =~ /Workers Launched:\s*(\d+)/;
    return defined($n) ? $n : 0;
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

my $node = PostgreSQL::Test::Cluster->new('vamana_convergence');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 10");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "max_worker_processes = 24");
$node->append_conf('postgresql.conf', "max_parallel_workers = 8");
$node->append_conf('postgresql.conf', "log_min_messages = 'notice'");
$node->start;

# Anchor every crash check to this run's log, not offset 0: the log file on
# disk persists across repeated `make prove_installcheck` invocations (it is
# not touched by the tmp_check wipe), so a literal 0 would also match FATAL
# lines left over from an unrelated earlier run.
my $run_log_pos = length($node->log_content());

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres',
    "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

my $pg_worker_pid = wait_for_worker_db($node, 'postgres', 30);
ok($pg_worker_pid =~ /^\d+$/,
    "worker for 'postgres' is running before any convergence case (pid=$pg_worker_pid)");

my $pg_dboid = db_oid($node, 'postgres');

# Baseline: an explicit search_num_threads = 1, with a large pool, so
# desired = granted = 1 once live.
#
# A plain UPDATE is used here, not a wait on the cluster-default alone: the
# reconcile that first spawned this worker (above) ran before the worker set
# its own workerPid, so it published a grant of 0 and nothing wakes the
# launcher on the liveness transition itself (this is the same zero-grant
# gap cases 3 and 5 pin below). Any catalog UPDATE fires a fresh NOTIFY-driven
# reconcile that reads the worker's now-current liveness, which is what
# actually settles the baseline -- confirmed by hand: without this UPDATE,
# the grant sits at 0 far past this wait's bound.
$node->safe_psql('postgres',
    "UPDATE vamana_databases SET search_num_threads = 1 WHERE datname = 'postgres';");
my $baseline_granted = wait_for_granted($node, $pg_dboid, 1, 30);
is($baseline_granted, '1', "baseline published grant settles at 1 thread");

# A table big enough that a forced parallel seq scan is worth planning, used
# only for the core-parallel-query proofs (cases 2 and part of case 7). Not a
# vamana index -- this table exists purely to observe the shared
# max_parallel_workers pool from the outside.
$node->safe_psql('postgres', qq(
    CREATE TABLE core_probe (id int, pad text);
    INSERT INTO core_probe SELECT g, repeat('x', 100) FROM generate_series(1, 50000) g;
    ANALYZE core_probe;
));

# ---------------------------------------------------------------------------
# Case 1: converge up.
#
# The grant math (SvsComputeCpuGrants / PublishCpuGrants) already exists on
# main; only slot-holding does not. So this splits into a real assertion
# (the published grant reaches 4) and a pinning assertion (the held slot
# count matches it), which is expected to fail until A4 lands.
# ---------------------------------------------------------------------------
{
    $node->safe_psql('postgres',
        "UPDATE vamana_databases SET search_num_threads = 4 WHERE datname = 'postgres';");

    my $granted = wait_for_granted($node, $pg_dboid, 4, 30);
    is($granted, '4', "case 1: published grant reaches 4 after raising search_num_threads");

    # STATIC-HOLD ASSUMPTION: no search is in flight; this expects the
    # worker to hold 4 parked search slots simply because it was granted 4.
    my $held = wait_for_search_slot_count($node, 'postgres', 4, 20);
    is($held, '4',
        "case 1: exactly 4 'vamana search slot' rows exist for the database "
      . "(pins the not-yet-implemented slot hold)");
}

# ---------------------------------------------------------------------------
# Case 2: converge down, and prove the released slots really returned to
# the shared pool (not a private counter) by observing a plain core
# parallel query regain workers.
#
# max_parallel_workers is lowered to 4 for this block only, so that if
# search slots really consumed the shared pool, granting 4 to search would
# starve a concurrent core query down to 0 workers, and dropping the grant
# to 2 would free 2 back for it. Today nothing consumes the pool for
# search, so this is a real, meaningful failure (not a vacuous one): the
# "starved-then-recovers" shape never appears.
# ---------------------------------------------------------------------------
{
    $node->safe_psql('postgres', "ALTER SYSTEM SET max_parallel_workers = 4;");
    $node->safe_psql('postgres', "SELECT pg_reload_conf();");
    usleep(500_000);

    # Re-affirm the case-1 grant of 4 under the new, smaller pool (still
    # fits: pool 4, desired 4).
    my $granted_high = wait_for_granted($node, $pg_dboid, 4, 30);
    is($granted_high, '4', "case 2: grant of 4 still fits an equal-sized pool of 4");

    # STATIC-HOLD ASSUMPTION: if 4 slots were genuinely held right now,
    # a core query asking for up to 4 workers should get none.
    my $before = workers_launched($node, 'postgres', 'core_probe');

    $node->safe_psql('postgres',
        "UPDATE vamana_databases SET search_num_threads = 2 WHERE datname = 'postgres';");
    my $granted_low = wait_for_granted($node, $pg_dboid, 2, 30);
    is($granted_low, '2', "case 2: published grant reaches 2 after lowering search_num_threads");

    my $held = wait_for_search_slot_count($node, 'postgres', 2, 20);
    is($held, '2',
        "case 2: exactly 2 'vamana search slot' rows remain "
      . "(pins the not-yet-implemented slot release)");

    my $after = workers_launched($node, 'postgres', 'core_probe');
    ok($before == 0 && $after > $before,
        "case 2: a core parallel query is starved while 4 slots are held "
      . "and regains workers once 2 are released "
      . "(before=$before, after=$after)")
      or diag("today nothing holds slots for search, so the pool is never "
            . "actually starved: before=$before after=$after");

    $node->safe_psql('postgres', "ALTER SYSTEM RESET max_parallel_workers;");
    $node->safe_psql('postgres', "SELECT pg_reload_conf();");
    usleep(500_000);
}

assert_rollup_matches($node, 'after cases 1-2');
assert_no_crash_since($node, $run_log_pos, 'cases 1-2');

my $pid_after_12 = $node->safe_psql('postgres',
    "SELECT pid FROM pg_stat_activity WHERE backend_type = 'vamana worker' "
  . "AND datname = 'postgres';");
chomp $pid_after_12;
is($pid_after_12, $pg_worker_pid,
    "case 9: the worker pid is unchanged by grant-only changes (no crash/restart)");

# ---------------------------------------------------------------------------
# Cases 3 and 5: a freshly enabled database.
#
# Section 3.1: PublishCpuGrants publishes 0 for a not-yet-live database, but
# the accessor is supposed to clamp that up to 1 so a starting worker never
# runs 0 slots while SVS runs a search thread. Section 3.3: the reconcile
# that spawns the worker has already published its grant as 0 (spawn loop
# runs after PublishCpuGrants), and nothing wakes the launcher on the
# workerPid 0-to-nonzero transition, so without a fix this can stay at 0 for
# up to VAMANA_LAUNCHER_NAPTIME_MS (180s). The poll bounds below are well
# under that, so a naptime-only regression fails this test instead of
# hanging it.
# ---------------------------------------------------------------------------
{
    $node->safe_psql('postgres', "CREATE DATABASE fresh_db;");

    # Resolved before the enabling INSERT below, not after: the not-yet-live
    # window this case samples for is a one-shot transient (0 published once,
    # then never again), so any query latency spent between the INSERT and
    # the first sample eats directly into the only chance to observe it.
    my $fresh_oid = db_oid($node, 'fresh_db');

    # Case 3: sample repeatedly while the published grant is still 0 (the
    # not-yet-live window). STATIC-HOLD ASSUMPTION: expects exactly 1 held
    # slot throughout this window, per the accessor's 0-clamped-to-1 rule --
    # not 0, and not the eventual configured grant of 5.
    #
    # Measured by hand against a scratch cluster: with the launcher kicked
    # promptly once the worker publishes its own workerPid, the whole span
    # from the enabling INSERT to the worker's startup log
    # line is single-digit milliseconds. A one-shot transient that short
    # cannot be sampled by spawning a new psql client process per poll --
    # each spawn alone costs more than the entire window. Both the INSERT
    # and every poll below therefore run over background_psql sessions
    # already connected before the INSERT fires, so the only latency left
    # between "grant published as 0" and "this poll observes it" is one
    # protocol round trip, not a process fork/exec/connect/authenticate
    # cycle.
    my $ctl = $node->background_psql('postgres');
    my $poll = $node->background_psql('postgres');

    my $t0 = [gettimeofday];
    $ctl->query_safe(
        "INSERT INTO vamana_databases (datname, enabled, search_num_threads) "
      . "VALUES ('fresh_db', true, 5);");

    my $saw_zero_grant_window = 0;
    my $slots_threads_ever_disagreed = 0;
    for (1 .. 4000)    # tight for ~2s, then the coarser waits below take over
    {
        # Both columns are read from the same $poll session, back to back,
        # in one round trip each over an already-open connection. Reading
        # the held count via a freshly spawned safe_psql process here (as
        # search_slot_count does everywhere else in this file) would add
        # tens of milliseconds of fork/exec/connect latency between the two
        # reads -- long enough, confirmed by hand, for the real system to
        # have already converged past the instant the grant was sampled at,
        # making the two columns describe two different moments in time
        # rather than one.
        my $g = $poll->query_safe(
            "SELECT search_threads_granted FROM pg_stat_vamana_worker "
          . "WHERE db_oid = $fresh_oid;");
        chomp $g;
        next unless $g ne '';
        if ($g == 0)
        {
            $saw_zero_grant_window = 1;

            # A held count of 0 here is not necessarily the accessor's
            # clamp failing: SvsSlotSetResize's own registration call only
            # waits for the postmaster to assign the new parked worker a
            # pid (WaitForBackgroundWorkerStartup), not for that child to
            # run pgstat_beinit()/pgstat_report_appname() and publish
            # itself into pg_stat_activity. Confirmed by hand: that
            # self-registration lag is the same order of magnitude as the
            # zero-grant window itself, so a single sample can legitimately
            # land after the parent's resize call has returned but before
            # the child has published its row. Retry briefly so the child
            # gets a fair chance to appear; stop retrying, without flagging
            # a disagreement, the moment the grant itself moves off 0 --
            # at that point this particular window is over and a 0 held
            # count says nothing about the clamp.
            my $held = '';
            my $window_closed = 0;
            for (1 .. 40)
            {
                $held = $poll->query_safe(
                    "SELECT count(*) FROM pg_stat_activity "
                  . "WHERE backend_type = 'vamana search slot' "
                  . "AND application_name LIKE 'vamana: db=fresh_db %';");
                chomp $held;
                last if $held eq '1';

                my $g2 = $poll->query_safe(
                    "SELECT search_threads_granted FROM pg_stat_vamana_worker "
                  . "WHERE db_oid = $fresh_oid;");
                chomp $g2;
                if ($g2 ne '0')
                {
                    $window_closed = 1;
                    last;
                }
            }

            # Only a real disagreement if the window was still open (grant
            # still reading 0) and 40 retries were not enough for the held
            # count to reach 1 -- never flagged just because the window
            # closed before this particular sample could resolve.
            $slots_threads_ever_disagreed = 1
              unless $held eq '1' || $window_closed;
        }
        else
        {
            last;    # grant has moved off 0; the transient is over
        }
    }
    $ctl->quit;
    $poll->quit;

    ok($saw_zero_grant_window,
        "case 3: observed the not-yet-live window where the published grant is 0");
    ok(!$slots_threads_ever_disagreed,
        "case 3: during the zero-grant window, exactly 1 slot is held "
      . "(clamped up from 0), never 0 and never the eventual grant of 5");

    # Now wait, bounded well under the 180s naptime, for convergence to the
    # configured grant of 5.
    my $granted = wait_for_granted($node, $fresh_oid, 5, 40);    # ~20s
    is($granted, '5', "case 3: grant eventually converges to the configured 5 threads");

    my $held_final = wait_for_search_slot_count($node, 'fresh_db', 5, 20);
    is($held_final, '5',
        "case 3: held slot count converges to 5, matching the final grant");

    # Case 5: prompt convergence is a hard requirement -- "takes effect
    # within about 1 second" per the documented contract -- not just
    # "eventually, within naptime." Bound the assertion in seconds, far
    # below the 180s naptime, so a regression to naptime-only fails loudly
    # here instead of the suite hanging for three minutes.
    my $elapsed = tv_interval($t0);
    ok($granted eq '5' && $elapsed < 30,
        "case 5: grant convergence after enabling a database happens in "
      . "seconds, not the 180s naptime (elapsed=${elapsed}s)")
      or diag("180s naptime is the specific failure mode being guarded "
            . "against here; 30s is a generous bound still far below it");
}

assert_rollup_matches($node, 'after cases 3 and 5');
assert_no_crash_since($node, $run_log_pos, 'cases 3 and 5');

# ---------------------------------------------------------------------------
# Case 4: restart into an unchanged grant.
#
# THIS IS THE SINGLE MOST IMPORTANT CASE IN THIS FILE. desired/reserved are
# written unconditionally on every reconcile, but grantedSearchThreads is
# written -- and the worker's latch kicked -- only when the value *changes*.
# VamanaWorkerResetEntryState explicitly does not run on a plain worker
# restart. So a worker that restarts while the grant is already settled at
# its current value is never kicked about it: a kick-only convergence
# implementation passes every other case in this file and fails only this
# one, by leaving the restarted worker holding zero slots forever. Do not
# simplify this case away; it is the regression test for exactly that trap.
# Convergence must be driven by polling every heartbeat, with the kick only
# making it prompt.
#
# Confirmed by hand against a scratch cluster: on main today the published
# grant does not merely stay "unchanged and un-acted-on" across a restart --
# it drops to 0 (the old worker's exit is noticed by a reconcile that
# correctly sees "not live" and publishes 0) and then stays at 0
# indefinitely, because nothing re-notifies the launcher once the new
# worker becomes live (the same zero-grant gap cases 3 and 5 pin, triggered
# here by a restart instead of an initial enable). So the "post_granted"
# assertion below fails today for that reason, not because the grant was
# literally frozen at its old value. Both symptoms share the same root
# cause and the same fix (SvsKickLauncher on the worker publishing its own
# workerPid), so the assertion is left as specified -- once fixed, the
# grant should settle back to its pre-restart value quickly, which is what
# "unchanged" means here: the same steady-state value, not a value that
# never moved in between.
# ---------------------------------------------------------------------------
{
    my $pre_granted = granted_for_db($node, $pg_dboid);
    my $pre_held = search_slot_count($node, 'postgres');

    $node->safe_psql('postgres', "SELECT svs_restart_worker('postgres');");
    my $new_pid = wait_for_new_worker_pid_db($node, 'postgres', $pg_worker_pid, 60);
    ok($new_pid =~ /^\d+$/ && $new_pid ne $pg_worker_pid,
        "case 4: worker restarted with a new pid (pid=$new_pid)");

    my $post_granted = wait_for_granted($node, $pg_dboid, $pre_granted, 30);
    is($post_granted, $pre_granted,
        "case 4: the published grant value is unchanged across the restart "
      . "($pre_granted before and after)");

    # STATIC-HOLD ASSUMPTION: the restarted worker should re-acquire the
    # same held slot count as before, purely by polling its heartbeat --
    # not by waiting for a kick that a kick-only implementation would never
    # send, since the grant value above never changed.
    my $post_held = wait_for_search_slot_count($node, 'postgres', $pre_held, 30);
    is($post_held, $pre_held,
        "case 4: the restarted worker converges to the same held slot count "
      . "($pre_held) without the grant value ever changing -- the "
      . "kick-only-trap regression test");

    $pg_worker_pid = $new_pid;
}

assert_rollup_matches($node, 'after case 4');
assert_no_crash_since($node, $run_log_pos, 'case 4');

# ---------------------------------------------------------------------------
# Case 6: release on exit, then re-converge on return.
#
# Case 4 just left the published grant at 0 (see the note above), so a
# no-op UPDATE forces a fresh reconcile to re-settle it at a known nonzero
# value first -- otherwise "re-converges to its pre-disable value" would
# compare 0 to 0 and prove nothing.
# ---------------------------------------------------------------------------
{
    $node->safe_psql('postgres',
        "UPDATE vamana_databases SET search_num_threads = 2 WHERE datname = 'postgres';");
    my $pre_disable_granted = wait_for_granted($node, $pg_dboid, 2, 30);
    is($pre_disable_granted, '2',
        "case 6 setup: grant re-settles at 2 before the disable/enable cycle");

    $node->safe_psql('postgres',
        "UPDATE vamana_databases SET enabled = false WHERE datname = 'postgres';");

    for (1 .. 60)    # up to 30s for the graceful drain to finish
    {
        usleep(500_000);
        my $alive = $node->safe_psql('postgres',
            "SELECT count(*) FROM pg_stat_activity "
          . "WHERE backend_type = 'vamana worker' AND datname = 'postgres';");
        chomp $alive;
        last if $alive eq '0';
    }
    my $alive = $node->safe_psql('postgres',
        "SELECT count(*) FROM pg_stat_activity "
      . "WHERE backend_type = 'vamana worker' AND datname = 'postgres';");
    chomp $alive;
    is($alive, '0', "case 6: worker for 'postgres' has stopped after disable");

    # STATIC-HOLD ASSUMPTION, but a vacuous one today: nothing has ever held
    # a slot for 'postgres' in this run, so this is expected to already be
    # 0 regardless of whether release-on-exit is implemented.
    my $held_after_stop = search_slot_count($node, 'postgres');
    is($held_after_stop, '0',
        "case 6: no 'vamana search slot' rows remain after the worker stops "
      . "(vacuous today: none were ever held)");

    $node->safe_psql('postgres',
        "UPDATE vamana_databases SET enabled = true WHERE datname = 'postgres';");
    my $reborn_pid = wait_for_worker_db($node, 'postgres', 30);
    ok($reborn_pid =~ /^\d+$/, "case 6: worker for 'postgres' comes back (pid=$reborn_pid)");
    $pg_worker_pid = $reborn_pid;

    my $reconverged = wait_for_granted($node, $pg_dboid, $pre_disable_granted, 30);
    is($reconverged, $pre_disable_granted,
        "case 6: grant re-converges to its pre-disable value "
      . "($pre_disable_granted) after re-enabling");

    my $held_reconverged =
        wait_for_search_slot_count($node, 'postgres', $pre_disable_granted, 20);
    is($held_reconverged, $pre_disable_granted,
        "case 6: held slot count re-converges to $pre_disable_granted on return");
}

assert_rollup_matches($node, 'after case 6');
assert_no_crash_since($node, $run_log_pos, 'case 6');

# ---------------------------------------------------------------------------
# Case 7: reduced pool. Constrain max_parallel_workers below what 'postgres'
# desires, so granted < desired, and pin that the held count tracks
# granted, not desired. No log-text assertion (section 2 item 2): the
# shortfall is observed purely through the numeric gap in the view.
#
# svs.max_search_threads_per_db must be raised explicitly here. It defaults
# to 0, which means "follow max_parallel_workers" (see
# ComputePerDatabaseCeiling in svs_cpu_budget.c) -- so with the default left
# alone, lowering max_parallel_workers alone clamps *desired* itself down to
# the same small number and no gap ever appears in the view. Confirmed by
# hand against a scratch cluster: without this second GUC, desired reads 1,
# not 5, and the "shortfall" assertion below would be checking two equal
# numbers instead of a real gap.
# ---------------------------------------------------------------------------
{
    $node->safe_psql('postgres', "ALTER SYSTEM SET max_parallel_workers = 1;");
    $node->safe_psql('postgres', "ALTER SYSTEM SET svs.max_search_threads_per_db = 10;");
    $node->safe_psql('postgres', "SELECT pg_reload_conf();");
    usleep(500_000);

    $node->safe_psql('postgres',
        "UPDATE vamana_databases SET search_num_threads = 5 WHERE datname = 'postgres';");

    my $desired = '';
    my $granted = '';
    for (1 .. 30)
    {
        usleep(500_000);
        $desired = desired_for_db($node, $pg_dboid);
        $granted = granted_for_db($node, $pg_dboid);
        last if defined($desired) && $desired eq '5'
             && defined($granted) && $granted ne '' && $granted < $desired;
    }
    is($desired, '5', "case 7: desired reflects the full ask (5) despite the small pool");
    ok(defined($granted) && $granted ne '' && $granted < $desired,
        "case 7: the view shows a real shortfall, granted ($granted) < desired ($desired)");

    # STATIC-HOLD ASSUMPTION: held slots should track the clamped grant,
    # never the raw ask.
    my $held = search_slot_count($node, 'postgres');
    is($held, $granted,
        "case 7: held slot count ($held) matches granted ($granted), never desired ($desired)");
    isnt($held, $desired,
        "case 7: held slot count must not drift up to the unmet desired value");

    $node->safe_psql('postgres', "ALTER SYSTEM RESET max_parallel_workers;");
    $node->safe_psql('postgres', "ALTER SYSTEM RESET svs.max_search_threads_per_db;");
    $node->safe_psql('postgres', "SELECT pg_reload_conf();");
    # Restore a grant the rest of the suite (and teardown) can settle on.
    $node->safe_psql('postgres',
        "UPDATE vamana_databases SET search_num_threads = 1 WHERE datname = 'postgres';");
    wait_for_granted($node, $pg_dboid, 1, 30);
    usleep(500_000);
}

assert_rollup_matches($node, 'after case 7');
assert_no_crash_since($node, $run_log_pos, 'case 7 (reduced pool)');

$node->stop;

done_testing();
