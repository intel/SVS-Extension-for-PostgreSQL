# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 51_worker_crash_scope.pl — a per-database vamana worker's crash scope
# depends on how it died: a graceful exit stays contained to its own
# database, but a signal-killed shared-memory-attached process takes the
# whole cluster down for crash recovery.
#
# Claim under test: a per-database vamana worker that exits via ERROR/FATAL
# (exit code 1) affects only its own database (contained). A worker killed
# by a signal (SIGSEGV, SIGABRT, SIGKILL) makes the postmaster treat it as a
# crash of a shared-memory-attached process and restart every backend in the
# cluster.
#
# This test uses two enrolled databases (dba, dbb). It kills dba's worker
# four ways (pg_terminate_backend/SIGTERM as the contained case, then
# SIGSEGV/SIGABRT/SIGKILL as signal cases) and observes what happens to a
# long-lived dbb session, the postmaster log, and the time to serve a dbb
# query again. It also SIGKILLs a parked search-slot process and the
# launcher, recording the outcome for each rather than assuming it matches
# the worker cases.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep time);
use POSIX qw(SIGTERM SIGSEGV SIGABRT SIGKILL);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

my $node = PostgreSQL::Test::Cluster->new('worker_crash_scope');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 10");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->append_conf('postgresql.conf', "svs.worker_restart_time = 1");
# PostgreSQL::Test::Cluster.pm forces restart_after_crash = off for every TAP
# node (so a crashing test does not loop forever). That means, unpatched,
# this file's own signal cases would never observe recovery: the postmaster
# shuts down for good after "terminating any other active server processes"
# instead of reinitializing. Override it back to the production default so
# the cluster-wide-crash cases can actually be measured end to end.
$node->append_conf('postgresql.conf', "restart_after_crash = on");
# Two databases, each defaulting to svs.default_search_work_mem (100MB),
# exceed the 100MB svs.max_search_work_mem default before either gets a
# search slot ("search_work_mem total would exceed svs.max_search_work_mem").
$node->append_conf('postgresql.conf', "svs.max_search_work_mem = '512MB'");
# Same shape of ceiling for residency: svs.max_residency_memory caps the SUM
# across all admitted databases (default 100MB), and two databases at the
# 100MB-each default would exceed it before either is admitted.
$node->append_conf('postgresql.conf', "svs.max_residency_memory = '512MB'");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres', "CREATE DATABASE dba;");
$node->safe_psql('postgres', "CREATE DATABASE dbb;");

for my $db (qw(dba dbb))
{
    $node->safe_psql($db, "CREATE EXTENSION vector;");
    $node->safe_psql($db, "CREATE EXTENSION svs;");
}

# Enrollment must run against svs.launcher_database ('postgres') per prior
# findings, not against dba/dbb themselves. It must also happen before
# CREATE INDEX ... USING vamana: an un-enabled database's vamana index
# creation fails with "vamana index is not enabled for this database".
$node->safe_psql('postgres',
    "INSERT INTO vamana_databases (datname, enabled, search_num_threads) "
  . "VALUES ('dba', true, 1), ('dbb', true, 1);");

my $dba_pid = wait_for_worker_db($node, 'dba', 40);
my $dbb_pid = wait_for_worker_db($node, 'dbb', 40);
ok($dba_pid =~ /^\d+$/, "dba worker running (pid=$dba_pid)");
ok($dbb_pid =~ /^\d+$/, "dbb worker running (pid=$dbb_pid)");

for my $db (qw(dba dbb))
{
    $node->safe_psql($db,
        "CREATE TABLE t (id bigint, v vector(16));");
    $node->safe_psql($db,
        "INSERT INTO t SELECT g, (SELECT array_agg(random())::vector(16) "
      . "FROM generate_series(1,16)) FROM generate_series(1,200) g;");
    $node->safe_psql($db,
        "CREATE INDEX t_idx ON t USING vamana (v vector_l2_ops);");
}

my %results;    # case => { affected => 'contained'|'cluster'|..., notes => ... }

sub get_worker_pid
{
    my ($db) = @_;
    my $pid = $node->safe_psql('postgres',
        "SELECT worker_pid FROM pg_stat_vamana_worker w "
      . "JOIN pg_database d ON d.oid = w.db_oid WHERE d.datname = '$db';");
    chomp $pid;
    return $pid;
}

sub get_launcher_pid
{
    my $pid = $node->safe_psql('postgres',
        "SELECT pid FROM pg_stat_activity WHERE backend_type = 'vamana launcher' LIMIT 1;");
    chomp $pid;
    return $pid;
}

sub get_search_slot_pid
{
    my ($db) = @_;
    my $pid = $node->safe_psql('postgres',
        "SELECT pid FROM pg_stat_activity WHERE backend_type = 'vamana search slot' "
      . "AND application_name LIKE '%db=$db%' LIMIT 1;");
    chomp $pid;
    return $pid;
}

# ---------------------------------------------------------------------------
# Case 1 (contained, x3): pg_terminate_backend on dba's worker.
# ---------------------------------------------------------------------------
diag("=== Case 1: pg_terminate_backend on dba worker (contained, expected) ===");
for my $run (1 .. 3)
{
    my $dbb_session = $node->background_psql('dbb');
    my $dbb_client_pid = $dbb_session->query_safe("SELECT pg_backend_pid();");
    chomp $dbb_client_pid;
    ok($dbb_session->query_safe("SELECT 1;") =~ /1/, "run$run: dbb session alive before kill");

    my $worker_pid = get_worker_pid('dba');
    my $log_pos = length($node->log_content());

    $node->safe_psql('postgres', "SELECT pg_terminate_backend($worker_pid);");

    # pg_terminate_backend sends SIGTERM, which the worker's own handler
    # catches for a graceful shutdown ("vamana background worker shutting
    # down"), not a crash-style "exited with exit code 1" -- confirmed by an
    # initial run of this test against the actual log wording.
    $node->wait_for_log(qr/vamana background worker shutting down/, $log_pos);

    my $dbb_after_pid = $dbb_session->query_safe("SELECT pg_backend_pid();");
    chomp $dbb_after_pid;
    is($dbb_after_pid, $dbb_client_pid, "run$run: dbb session survives with the same backend pid");

    my $log = substr($node->log_content(), $log_pos);
    my $saw_cluster_wide = ($log =~ /terminating any other active server processes/) ? 1 : 0;
    is($saw_cluster_wide, 0, "run$run: no cluster-wide restart message on contained termination");

    my $new_worker_pid = wait_for_worker_db($node, 'dba', 40);
    ok($new_worker_pid =~ /^\d+$/ && $new_worker_pid != $worker_pid,
        "run$run: launcher respawned dba's worker with a new pid ($worker_pid -> $new_worker_pid)");

    $results{"contained_run$run"} = {
        affected => 'single-db',
        cluster_wide_msg => $saw_cluster_wide,
        dbb_survived => ($dbb_after_pid == $dbb_client_pid) ? 1 : 0,
        respawned => ($new_worker_pid =~ /^\d+$/) ? 1 : 0,
    };

    $dbb_session->quit;
}

# ---------------------------------------------------------------------------
# Case 2: signal crashes. Each causes (per claim) a full cluster restart, so
# "fresh cluster state" for the next case is a natural side effect; we just
# have to wait for the restart and re-establish sessions/pids afterward.
# ---------------------------------------------------------------------------
my %sig_map = (SEGV => SIGSEGV, ABRT => SIGABRT, KILL => SIGKILL);

for my $sig_name (qw(SEGV ABRT KILL))
{
    diag("=== Case 2 (${sig_name}): signal on dba worker (expected cluster-wide) ===");

    my $dbb_session = $node->background_psql('dbb');
    my $dbb_client_pid = $dbb_session->query_safe("SELECT pg_backend_pid();");
    chomp $dbb_client_pid;

    my $worker_pid = get_worker_pid('dba');
    my $log_pos = length($node->log_content());
    my $t0 = time();

    kill $sig_map{$sig_name}, $worker_pid;

    my $saw_signal_msg = 0;
    my $saw_cluster_wide = 0;
    my $saw_reinit = 0;
    eval {
        $node->wait_for_log(qr/was terminated by signal/, $log_pos);
        $saw_signal_msg = 1;
    };
    eval {
        $node->wait_for_log(qr/terminating any other active server processes/, $log_pos);
        $saw_cluster_wide = 1;
    };
    eval {
        $node->wait_for_log(qr/all server processes terminated; reinitializing/, $log_pos);
        $saw_reinit = 1;
    };

    # The dbb session's backend process is killed along with everything
    # else; confirm the old connection is now dead.
    my $dbb_dead = 0;
    eval {
        my $r = $dbb_session->query_safe("SELECT 1;");
        $dbb_dead = 1 unless defined $r && $r =~ /1/;
    };
    $dbb_dead = 1 if $@;
    $dbb_session->quit;

    # Wait for the cluster to come back and a dbb query to succeed again.
    my $recovered = 0;
    my $recover_elapsed;
    for (1 .. 300)
    {
        usleep(200_000);
        my $ok = eval { $node->safe_psql('dbb', "SELECT count(*) FROM t;") };
        if (defined $ok && $ok =~ /^\d+$/)
        {
            $recovered = 1;
            $recover_elapsed = time() - $t0;
            last;
        }
    }

    diag(sprintf(
        "%s: signal_msg=%d cluster_wide_msg=%d reinit_msg=%d dbb_dead=%d recovered=%d recover_elapsed=%.2fs",
        $sig_name, $saw_signal_msg, $saw_cluster_wide, $saw_reinit, $dbb_dead,
        $recovered, $recover_elapsed // -1));

    ok($saw_signal_msg, "$sig_name: postmaster logged a signal-terminated worker");
    ok($recovered, "$sig_name: cluster recovered and served a dbb query again");

    $results{"signal_$sig_name"} = {
        affected          => $saw_cluster_wide ? 'cluster-wide' : 'single-db',
        cluster_wide_msg  => $saw_cluster_wide,
        reinit_msg        => $saw_reinit,
        dbb_dead          => $dbb_dead,
        recover_elapsed_s => $recover_elapsed // -1,
    };

    # Re-establish which workers/launcher are up before the next iteration.
    # Guarded: if recovery didn't complete above, safe_psql inside this
    # helper would otherwise die on connection refused and abort the whole
    # script instead of letting later cases run and report their own result.
    eval { wait_for_worker_db($node, 'dba', 40) };
    eval { wait_for_worker_db($node, 'dbb', 40) };
}

# ---------------------------------------------------------------------------
# Case 3: SIGKILL a parked search-slot process for dba.
# ---------------------------------------------------------------------------
diag("=== Case 3: SIGKILL a parked search-slot process (dba) ===");
{
    my $slot_pid = get_search_slot_pid('dba');
    ok($slot_pid =~ /^\d+$/, "found a parked search-slot pid for dba ($slot_pid)");

    if ($slot_pid =~ /^\d+$/)
    {
        my $dbb_session = $node->background_psql('dbb');
        my $dbb_client_pid = $dbb_session->query_safe("SELECT pg_backend_pid();");
        chomp $dbb_client_pid;

        my $log_pos = length($node->log_content());
        my $t0 = time();
        kill SIGKILL, $slot_pid;

        my $saw_cluster_wide = 0;
        eval {
            $node->wait_for_log(qr/terminating any other active server processes/, $log_pos);
            $saw_cluster_wide = 1;
        };

        my $dbb_dead = 0;
        eval {
            my $r = $dbb_session->query_safe("SELECT 1;");
            $dbb_dead = 1 unless defined $r && $r =~ /1/;
        };
        $dbb_dead = 1 if $@;
        $dbb_session->quit;

        my $recovered = 0;
        for (1 .. 300)
        {
            usleep(200_000);
            my $ok = eval { $node->safe_psql('dbb', "SELECT count(*) FROM t;") };
            if (defined $ok && $ok =~ /^\d+$/) { $recovered = 1; last; }
        }

        diag(sprintf("search-slot SIGKILL: cluster_wide_msg=%d dbb_dead=%d recovered=%d",
            $saw_cluster_wide, $dbb_dead, $recovered));
        ok($recovered, "search-slot SIGKILL: cluster recovered afterward");

        $results{search_slot_sigkill} = {
            affected         => $saw_cluster_wide ? 'cluster-wide' : 'single-db',
            cluster_wide_msg => $saw_cluster_wide,
            dbb_dead         => $dbb_dead,
        };

        eval { wait_for_worker_db($node, 'dba', 40) };
        eval { wait_for_worker_db($node, 'dbb', 40) };
    }
    else
    {
        $results{search_slot_sigkill} = { affected => 'not-found' };
    }
}

# ---------------------------------------------------------------------------
# Case 4: SIGKILL the launcher process.
# ---------------------------------------------------------------------------
diag("=== Case 4: SIGKILL the launcher process ===");
{
    my $launcher_pid = get_launcher_pid();
    ok($launcher_pid =~ /^\d+$/, "found launcher pid ($launcher_pid)");

    my $dbb_session = $node->background_psql('dbb');
    my $log_pos = length($node->log_content());

    kill SIGKILL, $launcher_pid;

    my $saw_cluster_wide = 0;
    eval {
        $node->wait_for_log(qr/terminating any other active server processes/, $log_pos);
        $saw_cluster_wide = 1;
    };

    my $dbb_dead = 0;
    eval {
        my $r = $dbb_session->query_safe("SELECT 1;");
        $dbb_dead = 1 unless defined $r && $r =~ /1/;
    };
    $dbb_dead = 1 if $@;
    $dbb_session->quit;

    my $recovered = 0;
    for (1 .. 300)
    {
        usleep(200_000);
        my $ok = eval { $node->safe_psql('dbb', "SELECT count(*) FROM t;") };
        if (defined $ok && $ok =~ /^\d+$/) { $recovered = 1; last; }
    }

    diag(sprintf("launcher SIGKILL: cluster_wide_msg=%d dbb_dead=%d recovered=%d",
        $saw_cluster_wide, $dbb_dead, $recovered));
    ok($recovered, "launcher SIGKILL: cluster recovered afterward");

    $results{launcher_sigkill} = {
        affected         => $saw_cluster_wide ? 'cluster-wide' : 'single-db',
        cluster_wide_msg => $saw_cluster_wide,
        dbb_dead         => $dbb_dead,
    };
}

diag("=== Summary table (case => affected) ===");
for my $k (sort keys %results)
{
    diag(sprintf("%-24s affected=%s", $k, $results{$k}->{affected}));
}

done_testing();
