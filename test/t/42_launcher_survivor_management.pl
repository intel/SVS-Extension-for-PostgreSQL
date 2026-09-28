# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 042_launcher_survivor_management.pl — a worker inherited across a launcher
# restart (the launcher's own ledger is rebuilt empty, but the worker itself
# survives) can still be paused and restarted.
#
# VamanaLauncherReconcileWorkers() correctly avoids double-spawning into an
# already-live worker's slot on launcher restart, but used to never adopt the
# survivor into WorkerLedger either.  Every management path (pause, restart
# convergence) walked only the ledger, so an inherited worker was permanently
# unmanageable until the next full postmaster restart: disabling its database
# did not stop it, and svs_restart_worker() reported success while bouncing
# nothing.
#
# The fix drives this one case from the shared control block instead of the
# ledger: a durable stopRequested flag and servicedRestartGeneration marker,
# checked by the worker's own loop alongside worker_got_sigterm, since a
# restarted launcher holds no BackgroundWorkerHandle for a worker it did not
# itself register and so cannot TerminateBackgroundWorker it.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

sub launcher_pid
{
    my ($node) = @_;
    my $pid = $node->safe_psql('postgres',
        "SELECT pid FROM pg_stat_activity WHERE backend_type = 'vamana launcher' LIMIT 1;");
    chomp $pid;
    return $pid;
}

sub worker_pid
{
    my ($node) = @_;
    my $pid = $node->safe_psql('postgres',
        "SELECT pid FROM pg_stat_activity "
      . "WHERE backend_type = 'vamana worker' AND datname = 'postgres' LIMIT 1;");
    chomp $pid;
    return $pid;
}

my $node = PostgreSQL::Test::Cluster->new('launcher_survivor');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 10");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
# Keep the postmaster's launcher respawn snappy so the test is not slow.
$node->append_conf('postgresql.conf', "svs.worker_restart_time = 1");
$node->append_conf('postgresql.conf', "log_min_messages = 'log'");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres',
    "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

my $w1 = wait_for_worker_db($node, 'postgres', 40);
ok($w1 =~ /^\d+$/, "worker running before the launcher restart (pid=$w1)");

my $l1 = launcher_pid($node);
ok($l1 =~ /^\d+$/, "launcher running (pid=$l1)");

# ---------------------------------------------------------------------------
# Bounce the launcher and let the postmaster bring a fresh one back.  SIGTERM,
# not SIGKILL: the launcher's handler is core's die(), so it exits FATAL with
# status 1, which the postmaster treats as a restartable bgworker exit.
# SIGKILL would leave the shmem child slot undetached, escalating to
# HandleChildCrash and restarting the entire cluster -- taking the worker with
# it and destroying the condition under test.
# ---------------------------------------------------------------------------
kill('TERM', $l1) or die "kill TERM $l1: $!";

my $l2 = '';
for (1 .. 120)
{
    usleep(500_000);
    $l2 = launcher_pid($node);
    last if $l2 =~ /^\d+$/ && $l2 ne $l1;
}
ok($l2 =~ /^\d+$/ && $l2 ne $l1,
    "postmaster restarted the launcher (pid $l1 -> $l2)");

# By design (matches test/t/12_launcher.pl): a restarted launcher never
# double-spawns into an already-live worker's slot.
is(worker_pid($node), $w1,
    "(confirming) the pre-existing worker survived the launcher restart (pid=$w1)");

my $nworkers = $node->safe_psql('postgres',
    "SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'vamana worker';");
chomp $nworkers;
is($nworkers, '1', '(confirming) the restarted launcher did not spawn a duplicate worker');

# ===========================================================================
# Pausing the inherited worker must stop it.
# ===========================================================================
{
    my $log_pos = length($node->log_content());

    $node->safe_psql('postgres',
        "UPDATE vamana_databases SET enabled = false WHERE datname = 'postgres';");

    my $stopped = 0;
    for (1 .. 60)          # 30 s: far beyond the NOTIFY-driven reconcile latency
    {
        usleep(500_000);
        if (!kill(0, $w1)) { $stopped = 1; last; }
    }

    my $log = substr($node->log_content(), $log_pos);

    ok($stopped,
        'setting enabled = false stops the inherited worker')
      or diag("worker $w1 still alive 30 s after the pause; log since the UPDATE:\n$log");

    like($log, qr/vamana background worker shutting down/,
        '(confirming) the worker took the normal drain-and-stop path');

    my $enabled = $node->safe_psql('postgres',
        "SELECT enabled FROM vamana_databases WHERE datname = 'postgres';");
    chomp $enabled;
    is($enabled, 'f', '(confirming) the catalog still says the database is paused');
}

# ===========================================================================
# svs_restart_worker() on the inherited (now respawned, still unledgered no
# more -- see note below) database must bounce it.
#
# Re-enabling after the pause above causes an ordinary spawn: the survivor's
# original slot has no live worker anymore, so the normal spawn-diff loop
# registers a fresh worker and, with it, a fresh ledger entry. To keep this
# file testing the *unledgered* restart path specifically -- not the ordinary
# ledger-tracked one already covered elsewhere -- bounce the launcher a
# second time before restarting, so the newly-spawned worker becomes an
# unledgered survivor of its own.
# ===========================================================================
{
    $node->safe_psql('postgres',
        "UPDATE vamana_databases SET enabled = true WHERE datname = 'postgres';");

    my $w2 = wait_for_worker_db($node, 'postgres', 40);
    ok($w2 =~ /^\d+$/ && $w2 ne $w1, "re-enabling spawned a fresh worker (pid=$w2)");

    my $l3 = launcher_pid($node);
    kill('TERM', $l3) or die "kill TERM $l3: $!";

    my $l4 = '';
    for (1 .. 120)
    {
        usleep(500_000);
        $l4 = launcher_pid($node);
        last if $l4 =~ /^\d+$/ && $l4 ne $l3;
    }
    ok($l4 =~ /^\d+$/ && $l4 ne $l3,
        "postmaster restarted the launcher a second time (pid $l3 -> $l4)");
    is(worker_pid($node), $w2,
        "(confirming) the worker survived this second launcher restart too (pid=$w2)");

    my $gen_before = $node->safe_psql('postgres',
        "SELECT restart_generation FROM vamana_databases WHERE datname = 'postgres';");
    chomp $gen_before;

    my ($rc, undef, $err) = $node->psql('postgres',
        "SELECT svs_restart_worker('postgres');");
    is($rc, 0, 'svs_restart_worker() returns success') or diag($err);

    my $gen_after = $node->safe_psql('postgres',
        "SELECT restart_generation FROM vamana_databases WHERE datname = 'postgres';");
    chomp $gen_after;
    isnt($gen_after, $gen_before,
        "restart_generation was bumped ($gen_before -> $gen_after)");

    my $bounced = 0;
    for (1 .. 40)          # 20 s
    {
        usleep(500_000);
        my $now = worker_pid($node);
        if ($now =~ /^\d+$/ && $now ne $w2) { $bounced = 1; last; }
    }

    ok($bounced,
        'svs_restart_worker() bounces the inherited worker')
      or diag("worker pid unchanged ($w2) 20 s after svs_restart_worker; "
            . "restart_generation is now $gen_after with nothing converging to it");
}

$node->stop;

done_testing();
