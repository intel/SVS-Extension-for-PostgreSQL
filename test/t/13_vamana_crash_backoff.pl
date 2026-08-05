# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 13_vamana_crash_backoff.pl — the launcher's per-database crash-backoff policy.
#
# The launcher owns respawn of its per-database workers (they register
# BGW_NEVER_RESTART with bgw_notify_pid set to the launcher).  A worker that
# dies cleanly is respawned near-instantly off the launcher's latch; a worker
# that crash-loops is respawned on an escalating, capped delay; a worker that
# stays up past the dwell threshold has its failure count forgiven.  The failure
# count lives in shared memory, so it survives a restart of the launcher itself.
#
# Coverage (spec numbers follow m04_launcher_core.md):
#   5. Near-instant respawn: a clean worker death is respawned far faster than
#      the fallback naptime, proving the respawn is latch-driven, not polled.
#   7. Escalating capped backoff: repeated startup crashes are respawned on a
#      growing delay, not a fixed interval.
#   8. The launcher's own restart is postmaster-owned (svs.worker_restart_time),
#      independent of the per-worker svs.worker_restart_backoff.
#   Dwell reset: a worker that survives past VAMANA_BACKOFF_DWELL_RESET_MS clears
#      its failure count, so a later crash restarts the backoff from the base.
#   Durability: the failure count is shared-memory state and survives a launcher
#      restart, so backoff does not reset to the base when the launcher respawns.
#
# The crash loop is driven by the in-tree injection-point framework, the same
# mechanism 09 uses; without it there is no deterministic startup-crash trigger.

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

# The base backoff, in ms.  Kept at the default so the escalation (2x, 4x, 8x
# the base) is coarse enough to distinguish from scheduling jitter, while the
# whole crash loop still fits in a few seconds.
my $BACKOFF_MS = 1000;

# ---------------------------------------------------------------------------
# Launcher PID from pg_stat_activity, or '' if none is running yet.
# ---------------------------------------------------------------------------
sub launcher_pid
{
    my ($node) = @_;
    my $pid = $node->safe_psql('postgres',
        "SELECT pid FROM pg_stat_activity WHERE backend_type = 'vamana launcher' LIMIT 1;");
    chomp $pid;
    return $pid;
}

# ---------------------------------------------------------------------------
# Fractional epoch seconds of every startup-crash log line emitted so far.
# The injection 'error' action logs a fixed message stamped with the
# log_line_prefix timestamp (%m: 'YYYY-MM-DD HH:MM:SS.mmm TZ'); we turn each
# into seconds-of-day for gap arithmetic.  Returned in log (chronological)
# order.
# ---------------------------------------------------------------------------
sub crash_timestamps
{
    my ($node) = @_;
    my $log = $node->log_content();
    my @times;
    while ($log =~ /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})\.(\d{3})\b[^\n]*error triggered for injection point vamana-worker-startup-crash/mg)
    {
        push @times, $4 * 3600 + $5 * 60 + $6 + $7 / 1000.0;
    }
    return @times;
}

# ---------------------------------------------------------------------------
# Consecutive gaps between crash timestamps, correcting a single midnight
# rollover so the arithmetic never yields a spurious negative gap.
# ---------------------------------------------------------------------------
sub crash_gaps
{
    my @t = @_;
    my @gaps;
    for my $i (1 .. $#t)
    {
        my $g = $t[$i] - $t[$i - 1];
        $g += 86400 if $g < 0;
        push @gaps, $g;
    }
    return @gaps;
}

# Poll until at least $want crash log lines are present, or $deadline_s elapses.
sub wait_for_crashes
{
    my ($node, $want, $deadline_s) = @_;
    my $steps = int($deadline_s * 10);
    my @t;
    for (1 .. $steps)
    {
        @t = crash_timestamps($node);
        return @t if @t >= $want;
        usleep(100_000);
    }
    return @t;
}

sub start_node
{
    my ($name) = @_;
    my $node = PostgreSQL::Test::Cluster->new($name);
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
    $node->append_conf('postgresql.conf', "svs.worker_restart_backoff = $BACKOFF_MS");
    $node->start;

    $node->safe_psql('postgres', "CREATE EXTENSION vector;");
    $node->safe_psql('postgres', "CREATE EXTENSION svs;");
    $node->safe_psql('postgres', "CREATE EXTENSION injection_points;");
    return $node;
}

# ---------------------------------------------------------------------------
# Spec 5: a clean worker death is respawned near-instantly.
#
# SIGTERM (not SIGKILL) is deliberate: a BGWORKER_SHMEM_ACCESS worker killed
# uncleanly exits with a status the postmaster treats as a crash, triggering
# whole-cluster crash recovery that would mask the launcher's targeted respawn.
# A clean SIGTERM exit is reaped normally and the launcher alone respawns it,
# off its latch (bgw_notify_pid), far sooner than the ~180s fallback naptime.
# ---------------------------------------------------------------------------
{
    my $node = start_node('vamana_backoff_respawn');
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    my $pid1 = wait_for_worker_db($node, 'postgres', 40);
    ok($pid1 =~ /^\d+$/, "worker running before clean death (pid=$pid1)");

    kill('TERM', $pid1);

    # Poll far faster than the fallback naptime; a respawn observed within a
    # couple of seconds can only be latch-driven.
    my $pid2 = '';
    for (1 .. 100)    # up to 10s
    {
        usleep(100_000);
        $pid2 = $node->safe_psql('postgres',
            "SELECT pid FROM pg_stat_activity "
          . "WHERE backend_type = 'vamana worker' AND datname = 'postgres' LIMIT 1;");
        chomp $pid2;
        last if $pid2 =~ /^\d+$/ && $pid2 ne $pid1;
    }
    ok($pid2 =~ /^\d+$/ && $pid2 ne $pid1,
        "launcher respawns the worker near-instantly after a clean death (pid=$pid2)");

    $node->stop;
}

# ---------------------------------------------------------------------------
# Spec 7 + dwell reset: escalating capped backoff, then forgiveness.
#
# Attaching the startup-crash injection makes every spawn FATAL, so the worker
# crash-loops.  The gaps between successive crashes must grow (base is doubled
# per consecutive failure), not stay fixed — and the loop must stay bounded, not
# flood.  Detaching then lets a spawn succeed; once that worker has been up past
# the dwell threshold its failure count is forgiven, so re-attaching the
# injection restarts the backoff from the base rather than the escalated delay.
# ---------------------------------------------------------------------------
{
    my $node = start_node('vamana_backoff_escalate');

    $node->safe_psql('postgres',
        "SELECT injection_points_attach('vamana-worker-startup-crash', 'error');");

    # Enable a database with the injection already armed: its worker can never
    # reach readiness, so it loops through the escalating backoff.
    $node->safe_psql('postgres', "CREATE DATABASE loop_db;");
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('loop_db', true);");

    # Four crashes exercise gaps of ~2x, ~4x, ~8x the base.
    my @t = wait_for_crashes($node, 4, 25);
    ok(@t >= 4, sprintf('worker crash-loops under the injection (%d crashes seen)', scalar @t));

    my @gaps = crash_gaps(@t);
    ok(@gaps >= 3 && $gaps[-1] > $gaps[0] * 1.5,
        sprintf('respawn delay escalates, not fixed (gaps: %s)',
                join(', ', map { sprintf('%.2f', $_) } @gaps)));

    # Bounded, not a flood: escalation caps the crash count in a fixed window.
    my $n_before = scalar @t;
    sleep(3);
    my $n_after = scalar crash_timestamps($node);
    ok($n_after - $n_before <= 2,
        "escalated backoff throttles the crash loop (" . ($n_after - $n_before) . " crashes in 3s)");

    # Detach: the next spawn succeeds and the worker reaches readiness.
    $node->safe_psql('postgres',
        "SELECT injection_points_detach('vamana-worker-startup-crash');");
    my $recovered_pid = wait_for_worker_db($node, 'loop_db', 40);
    ok($recovered_pid =~ /^\d+$/,
        "worker recovers once the injection is detached (pid=$recovered_pid)");

    # Let the worker live past the dwell threshold (10s) so its death counts as a
    # recovery and clears the escalated failure count.
    sleep(12);

    # Re-arm and force a fresh crash loop; the first gap must be back at the base
    # (~2x base after one failure), proving the count reset rather than resuming
    # the escalated delay.
    my $mark = scalar crash_timestamps($node);
    $node->safe_psql('postgres',
        "SELECT injection_points_attach('vamana-worker-startup-crash', 'error');");
    kill('TERM', $recovered_pid);

    my @t2 = wait_for_crashes($node, $mark + 3, 25);
    my @fresh = @t2[$mark .. $#t2];
    my @gaps2 = crash_gaps(@fresh);
    ok(@gaps2 >= 2 && $gaps2[0] < $gaps[-1],
        sprintf('dwell reset: backoff restarts from the base after a healthy run (first fresh gap %.2f < prior max %.2f)',
                $gaps2[0], $gaps[-1]));

    $node->stop;
}

# ---------------------------------------------------------------------------
# Spec 8 + durability: the launcher's own restart is postmaster-owned, and the
# per-database failure count survives it.
#
# Killing the launcher cleanly (its SIGTERM handler exits normally) lets the
# postmaster restart it on svs.worker_restart_time, wholly independent of
# svs.worker_restart_backoff.  Because the failure count lives in shared memory,
# the restarted launcher does not respawn a crash-looping worker in a fresh
# rapid burst — it resumes the escalated delay it left off at.
# ---------------------------------------------------------------------------
{
    my $node = start_node('vamana_backoff_launcher_restart');
    # A short launcher restart keeps the test quick and shows it is governed by
    # worker_restart_time, not the (longer, escalating) worker backoff.
    $node->append_conf('postgresql.conf', "svs.worker_restart_time = 1");
    $node->restart;

    $node->safe_psql('postgres',
        "SELECT injection_points_attach('vamana-worker-startup-crash', 'error');");
    $node->safe_psql('postgres', "CREATE DATABASE dur_db;");
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('dur_db', true);");

    # Build up several failures so the backoff is well past the base.
    my @t = wait_for_crashes($node, 3, 25);
    ok(@t >= 3, sprintf('crash loop established before launcher kill (%d crashes)', scalar @t));

    my $lp1 = launcher_pid($node);
    ok($lp1 =~ /^\d+$/, "launcher running (pid=$lp1)");

    kill('TERM', $lp1);

    my $lp2 = '';
    for (1 .. 100)    # up to 10s
    {
        usleep(100_000);
        $lp2 = launcher_pid($node);
        last if $lp2 =~ /^\d+$/ && $lp2 ne $lp1;
    }
    ok($lp2 =~ /^\d+$/ && $lp2 ne $lp1,
        "postmaster restarts the launcher independently of worker backoff (pid=$lp2)");

    # Durability: the restarted launcher inherits the shared-memory failure count,
    # so it does not flood-respawn the still-broken worker.  A base-reset launcher
    # would fire the base gap immediately; the escalated gap keeps the count low.
    my $n_before = scalar crash_timestamps($node);
    sleep(3);
    my $n_after = scalar crash_timestamps($node);
    ok($n_after - $n_before <= 2,
        "backoff state survives the launcher restart (" . ($n_after - $n_before) . " crashes in 3s post-restart)");

    $node->safe_psql('postgres',
        "SELECT injection_points_detach('vamana-worker-startup-crash');");
    $node->stop;
}

done_testing();
