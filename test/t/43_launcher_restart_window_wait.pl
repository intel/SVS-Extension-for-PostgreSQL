# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 043_launcher_restart_window_wait.pl — a backend that reaches
# VamanaWorkerWaitUntilAvailable() during a deliberate worker stop (restart,
# pause, respawn) waits out svs.worker_startup_timeout_ms for the replacement
# worker, instead of hard-erroring on the spot with a false errdetail.
#
# A worker that stops cleanly (VamanaWorkerDrainAndStop) clears workerPid but
# used to leave heartbeat_ts at its last, fresh value; VamanaWorkerWaitUntil-
# Available's guard tested "heartbeat_ts != 0", not staleness, so every
# backend hitting it during that window hard-errored immediately and blamed a
# heartbeat that was in fact a fraction of a second old.
#
# Part A holds the window open deterministically by SIGSTOPping the launcher,
# so the worker is confirmed gone and the replacement is confirmed not yet
# spawned for the whole measurement.  Part B repeats the same scenario through
# the documented operator action, svs_restart_worker(), with the launcher
# running normally; it is only asserted if it proves reliable across a few
# rounds; otherwise this file reports the observed flake rate instead of
# shipping a flaky assertion.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep time);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

# Long enough that "did it wait?" is unambiguous: a bounded wait would take
# ~20 s, an immediate hard error takes well under a second.
my $STARTUP_TIMEOUT_MS = 20000;

my $node = PostgreSQL::Test::Cluster->new('launcher_restart_window');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 10");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->append_conf('postgresql.conf', "svs.worker_restart_time = 1");
$node->append_conf('postgresql.conf',
    "svs.worker_startup_timeout_ms = $STARTUP_TIMEOUT_MS");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres',
    "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

my $worker_pid = wait_for_worker_db($node, 'postgres', 40);
ok($worker_pid =~ /^\d+$/, "worker running (pid=$worker_pid)");

$node->safe_psql('postgres', qq{
    CREATE TABLE r43_tbl (id serial PRIMARY KEY, val vector($dim));
    INSERT INTO r43_tbl (val)
        SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 200) i;
    CREATE INDEX r43_idx ON r43_tbl USING vamana (val vector_l2_ops);
});

my $launcher_pid = $node->safe_psql('postgres',
    "SELECT pid FROM pg_stat_activity WHERE backend_type = 'vamana launcher' LIMIT 1;");
chomp $launcher_pid;
ok($launcher_pid =~ /^\d+$/, "launcher running (pid=$launcher_pid)");

# ===========================================================================
# Part A — deterministic. Freeze the launcher, stop the worker cleanly, and
# observe what a backend gets while the window is held open.
#
# SIGSTOP on the launcher, not SIGKILL: it must be unable to react (no
# respawn) while staying resumable, so the window is a held state rather than
# a race.
#
# SIGTERM on the worker is exactly what the launcher itself sends for a
# restart (TerminateBackgroundWorker in ExecuteRestartAction), so the worker
# takes the same clean VamanaWorkerDrainAndStop path.
# ===========================================================================
{
    kill('STOP', $launcher_pid) or die "kill STOP $launcher_pid: $!";

    kill('TERM', $worker_pid) or die "kill TERM $worker_pid: $!";

    my $gone = 0;
    for (1 .. 100)
    {
        usleep(100_000);
        if (!kill(0, $worker_pid)) { $gone = 1; last; }
    }
    ok($gone, 'worker exited after SIGTERM (clean drain-and-stop)');

    my $log = $node->log_content();
    like($log, qr/vamana background worker shutting down/,
        'worker took the clean drain path, not a crash');

    my $hb_age_ms = $node->safe_psql('postgres',
        "SELECT (extract(epoch from (now() - heartbeat_ts)) * 1000)::bigint "
      . "FROM pg_stat_vamana_worker "
      . "WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = current_database());");
    chomp $hb_age_ms;

    my $pid_now = $node->safe_psql('postgres',
        "SELECT coalesce(worker_pid::text, 'NULL') FROM pg_stat_vamana_worker "
      . "WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = current_database());");
    chomp $pid_now;
    is($pid_now, 'NULL', 'slot reports no live worker (workerPid cleared by the drain)');

    diag("heartbeat age at the moment of the probing INSERT: ${hb_age_ms} ms "
       . "(NULL/empty means the drain cleared it -- heartbeat_ts is 0)");

    my $t0 = time();
    my ($rc, $out, $err) = $node->psql('postgres',
        "INSERT INTO r43_tbl (val) SELECT ARRAY[$array_sql]::vector;");
    my $elapsed_ms = int((time() - $t0) * 1000);

    diag("INSERT rc=$rc after ${elapsed_ms} ms; stderr:\n$err") if $rc != 0;

    # The backend waits out the bounded startup timeout for the replacement
    # worker instead of hard-erroring on the spot.
    cmp_ok($elapsed_ms, '>=', $STARTUP_TIMEOUT_MS / 2,
        "the backend waits (elapsed ${elapsed_ms} ms) rather than hard-erroring "
      . "in place of the bounded svs.worker_startup_timeout_ms (${STARTUP_TIMEOUT_MS} ms)");

    # The launcher is still frozen, so nothing can spawn a replacement within
    # the timeout; the wait must still end in the documented "unavailable
    # after N ms" error, not the stale-heartbeat one this fix removes.
    isnt($rc, 0, 'the INSERT still fails once the bounded wait itself times out');
    unlike($err, qr/last heartbeat is older than/,
        'the failure is the timeout error, not the false stale-heartbeat one');
    like($err, qr/unavailable after \d+ ms/,
        'the failure names the bounded wait actually taken');

    # Confirm the window really was transient: resume the launcher and the
    # same INSERT succeeds once the replacement worker is up.
    kill('CONT', $launcher_pid) or die "kill CONT $launcher_pid: $!";

    my $new_pid = wait_for_worker_db($node, 'postgres', 60);
    ok($new_pid =~ /^\d+$/ && $new_pid ne $worker_pid,
        "launcher respawned the worker once resumed (pid=$new_pid)");

    my ($rc2, undef, $err2) = $node->psql('postgres',
        "INSERT INTO r43_tbl (val) SELECT ARRAY[$array_sql]::vector;");
    is($rc2, 0, 'the identical INSERT succeeds once the replacement worker is up')
      or diag($err2);

    $worker_pid = $new_pid;
}

# ===========================================================================
# Part B — the same scenario through the documented operator action,
# svs_restart_worker(), with the launcher running normally.  Included only if
# it proves reliable; otherwise report the flake rate.
# ===========================================================================
{
    my $reproduced_bad_error = 0;
    my $any_insert_failed    = 0;
    my $attempts              = 0;
    my $sample_error          = '';

    for my $round (1 .. 12)
    {
        my $before = $node->safe_psql('postgres',
            "SELECT pid FROM pg_stat_activity "
          . "WHERE backend_type = 'vamana worker' AND datname = 'postgres' LIMIT 1;");
        chomp $before;
        next unless $before =~ /^\d+$/;

        $node->safe_psql('postgres', "SELECT svs_restart_worker('postgres');");

        for (1 .. 200)
        {
            $attempts++;
            my ($rc, undef, $err) = $node->psql('postgres',
                "INSERT INTO r43_tbl (val) SELECT ARRAY[$array_sql]::vector;");
            if ($rc != 0)
            {
                $any_insert_failed++;
                if ($err =~ /last heartbeat is older than/)
                {
                    $reproduced_bad_error++;
                    $sample_error ||= $err;
                }
                last;
            }
            my $now = $node->safe_psql('postgres',
                "SELECT pid FROM pg_stat_activity "
              . "WHERE backend_type = 'vamana worker' AND datname = 'postgres' LIMIT 1;");
            chomp $now;
            last if $now =~ /^\d+$/ && $now ne $before;
            usleep(5_000);
        }

        wait_for_worker_db($node, 'postgres', 60);
    }

    diag("svs_restart_worker rounds: $reproduced_bad_error/12 hit the false "
       . "stale-heartbeat error, $any_insert_failed/12 saw any INSERT failure "
       . "($attempts INSERT attempts total)");
    diag("sample error:\n$sample_error") if $sample_error;

    is($reproduced_bad_error, 0,
        'svs_restart_worker() never rejects a concurrent INSERT with the false '
      . 'stale-heartbeat error');
}

$node->stop;

done_testing();
