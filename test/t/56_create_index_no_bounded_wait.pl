# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 56_create_index_no_bounded_wait.pl -- CREATE INDEX takes the bounded wait
# the documented three-state gate (docs/dev/BGW_LAUNCHER.md Sec. 11) promises
# for the "slot reserved, workerPid == 0" state, instead of committing with a
# misleading WARNING.
#
# The three documented states for CREATE INDEX:
#   1. No slot                        -> hard error, no build attempted
#   2. Slot present, workerPid == 0   -> bounded wait, then proceed or error
#   3. Slot present, workerPid set    -> available, proceed normally
#
# vamanabuild() now calls VamanaWorkerWaitUntilAvailable() before deciding
# whether to submit a warm-up load, the same bounded wait vamanascan.c,
# vamanainsert.c, and vamana_warmup.c already took. A worker that never
# comes back within svs.worker_startup_timeout_ms now surfaces through that
# call's own ERROR instead of a silent WARNING-and-commit.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(time);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

if (($ENV{enable_injection_points} // 'no') ne 'yes')
{
    plan skip_all => 'server not built with --enable-injection-points';
}

my $STARTUP_TIMEOUT_MS = 8000;

my $node = PostgreSQL::Test::Cluster->new('f5_no_bounded_wait');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 10");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->append_conf('postgresql.conf',
    "svs.worker_startup_timeout_ms = $STARTUP_TIMEOUT_MS");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres', "CREATE EXTENSION injection_points;");

$node->safe_psql('postgres', qq{
    CREATE TABLE f5_tbl (id serial PRIMARY KEY, val vector($dim));
    INSERT INTO f5_tbl (val)
        SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 200) i;
});

# ---------------------------------------------------------------------------
# Pause the worker at the very start of VamanaWorkerMain, before it claims
# its shared-memory slot. The launcher is left fully live: it will still
# reserve the slot (workerPid == 0) and keep servicing build-thread grants.
# ---------------------------------------------------------------------------
$node->safe_psql('postgres',
    "SELECT injection_points_attach('vamana-worker-startup-crash', 'wait');");

$node->safe_psql('postgres',
    "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

$node->wait_for_event('vamana worker', 'vamana-worker-startup-crash');

my $slot_state = $node->safe_psql('postgres',
    "SELECT coalesce(worker_pid::text, 'NULL') || '/' || worker_state "
  . "FROM pg_stat_vamana_worker "
  . "WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = current_database());");
chomp $slot_state;
diag("slot state (worker_pid/worker_state): $slot_state");
like($slot_state, qr{^NULL/},
    'documented state 2 reached: slot present, worker process ID zero, '
  . 'launcher still live');

# ---------------------------------------------------------------------------
# FIX (F5) -- CREATE INDEX takes the bounded wait and times out through the
# same already-correct error path DML uses, instead of committing silently.
# ---------------------------------------------------------------------------
{
    my $t0 = time();
    my ($rc, undef, $err) = $node->psql('postgres',
        "CREATE INDEX f5_idx ON f5_tbl USING vamana (val vector_l2_ops);");
    my $elapsed_ms = int((time() - $t0) * 1000);

    diag("CREATE INDEX rc=$rc after ${elapsed_ms} ms; stderr:\n$err");

    cmp_ok($elapsed_ms, '>=', $STARTUP_TIMEOUT_MS / 2,
        'CREATE INDEX takes the bounded wait BGW_LAUNCHER.md Sec. 11 state 2 '
      . "specifies (svs.worker_startup_timeout_ms is ${STARTUP_TIMEOUT_MS} ms)");

    isnt($rc, 0,
        'CREATE INDEX fails with an actionable error rather than committing '
      . 'with no live worker ever having existed for the index');

    unlike($err, qr/will be adopted by the worker on startup/,
        'the error path does not use the stale "adopted by the worker on '
      . 'startup" wording -- loading remains demand-driven (src/vamanacache.c)');

    my $committed = $node->safe_psql('postgres',
        "SELECT count(*) FROM pg_class WHERE relname = 'f5_idx';");
    chomp $committed;
    is($committed, '0',
        'the index is not committed into pg_class when no worker ever became '
      . 'available');
}

$node->safe_psql('postgres',
    "SELECT injection_points_detach('vamana-worker-startup-crash');");
$node->safe_psql('postgres',
    "SELECT injection_points_wakeup('vamana-worker-startup-crash');");

my $worker_pid = wait_for_worker_db($node, 'postgres', 40);
ok($worker_pid =~ /^\d+$/,
    "worker eventually comes up once released (pid=$worker_pid)");

# The earlier CREATE INDEX attempt errored out (no worker ever became
# available), so f5_tbl has no vamana index yet. Build one now, with the
# worker live, so the INSERT contrast below actually exercises
# vamanainsert()'s own wait rather than skipping index maintenance entirely.
$node->safe_psql('postgres',
    "CREATE INDEX f5_idx ON f5_tbl USING vamana (val vector_l2_ops);");

# ---------------------------------------------------------------------------
# Contrast: once a worker is live, the DML paths DO take the bounded wait
# against a genuinely absent worker; re-pause at the same point and show
# INSERT refuses rather than committing silently, matching CREATE INDEX's
# behavior above now that both paths wait the same way.
# ---------------------------------------------------------------------------
{
    # Attach before killing: the launcher can respawn the replacement worker
    # fast enough that it clears the (unattached) injection point before a
    # later attach call would take effect, which would let the replacement
    # claim its slot and defeat this contrast case.
    $node->safe_psql('postgres',
        "SELECT injection_points_attach('vamana-worker-startup-crash', 'wait');");
    kill('TERM', $worker_pid) or die "kill TERM $worker_pid: $!";

    my $launcher_pid = $node->safe_psql('postgres',
        "SELECT pid FROM pg_stat_activity WHERE backend_type = 'vamana launcher' LIMIT 1;");
    chomp $launcher_pid;
    # Nudge the launcher's reconcile loop so it notices the dead worker and
    # respawns promptly rather than waiting out its own poll interval.
    kill('HUP', $launcher_pid);

    $node->wait_for_event('vamana worker', 'vamana-worker-startup-crash');

    my $t0 = time();
    my ($rc, undef, $err) = $node->psql('postgres',
        "INSERT INTO f5_tbl (val) SELECT ARRAY[$array_sql]::vector;");
    my $elapsed_ms = int((time() - $t0) * 1000);

    isnt($rc, 0, 'INSERT refuses to proceed without a worker');
    diag("INSERT rc=$rc after ${elapsed_ms} ms (vamanainsert.c does call "
       . "VamanaWorkerWaitUntilAvailable); stderr:\n$err");

    $node->safe_psql('postgres',
        "SELECT injection_points_detach('vamana-worker-startup-crash');");
    $node->safe_psql('postgres',
        "SELECT injection_points_wakeup('vamana-worker-startup-crash');");
}

$node->stop;

done_testing();
