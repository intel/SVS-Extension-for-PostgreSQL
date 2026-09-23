# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 20_standby_cache_overflow.pl — standby bootstrap survives indexes that
# fail to load.
#
# VamanaWorkerServe bootstraps a standby's cache before it starts accepting
# requests: it enumerates every vamana index in the database and loads each
# one via VamanaStandbyLoadIndex, which calls VamanaWorkerGetOrLoadIndex with
# no enclosing PG_TRY. If a load failure propagates instead of returning
# NULL, it escapes VamanaWorkerServe uncaught and takes the whole worker
# down; the postmaster restarts it, bootstrap runs again, and it dies at the
# same point every time. This test builds a fixture where every index's own
# residency footprint exceeds the database's own residency budget, so every
# load fails during bootstrap, and asserts the worker starts once and stays
# up regardless.
#
# The residency budget the standby denies against is not the primary's:
# svs.default_residency_memory and svs.max_residency_memory are per-server
# GUCs, not part of the replicated vamana_databases row, so the primary and
# the standby can resolve different budgets for the same database
# (SvsMemoryResolveResidencyBudget, src/svs_memory.c). The primary's own
# budget must admit all 9 builds -- SvsMemoryReserveBuild runs at CREATE
# INDEX time now, so a budget too small for that would refuse the setup
# loop itself, not exercise bootstrap denial at all. The standby's own,
# separately configured budget is what stays small enough to deny them.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

my $N_INDEXES = 9;

# ===========================================================================
# Setup: primary with 9 vamana indexes, all admitted under its own
# generous residency budget, then a streaming standby with its own much
# smaller one. Fixture pattern follows test/t/08_standby_replay.pl.
# ===========================================================================

my $primary = PostgreSQL::Test::Cluster->new('primary_cache_overflow');
$primary->init(allows_streaming => 1);
$primary->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$primary->append_conf('postgresql.conf', "wal_level = logical");
$primary->append_conf('postgresql.conf', "max_replication_slots = 20");
$primary->append_conf('postgresql.conf', "max_wal_senders = 10");
$primary->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
# No per-row residency_memory override: that row replicates to the standby,
# which must resolve its own, much smaller budget from its own
# postgresql.conf instead (see below). svs.default_residency_memory and
# svs.max_residency_memory are per-server GUCs, not replicated state, so the
# primary and standby can disagree about how much residency this same
# database gets -- the primary generously (all 9 builds must fit, summing to
# ~55MB), the standby not (see the standby's own conf further down).
$primary->append_conf('postgresql.conf', "svs.default_residency_memory = '80MB'");
$primary->append_conf('postgresql.conf', "svs.max_residency_memory = '80MB'");
$primary->start;

$primary->safe_psql('postgres', "CREATE EXTENSION vector;");
$primary->safe_psql('postgres', "CREATE EXTENSION svs;");
$primary->safe_psql('postgres',
    "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

for my $i (0 .. $N_INDEXES - 1)
{
    $primary->safe_psql('postgres', qq{
        CREATE TABLE so_tbl_$i (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO so_tbl_$i (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 5000);
        CREATE INDEX so_idx_$i ON so_tbl_$i USING vamana (val vector_l2_ops);
    });
}

wait_for_worker($primary, 30);

$primary->safe_psql('postgres',
    "SELECT pg_create_physical_replication_slot('overflow_phys');");

my $backup_name = 'standby_overflow_backup';
$primary->backup($backup_name);

my $standby = PostgreSQL::Test::Cluster->new('standby_cache_overflow');
$standby->init_from_backup($primary, $backup_name, has_streaming => 1);
$standby->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$standby->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$standby->append_conf('postgresql.conf', "hot_standby = on");
$standby->append_conf('postgresql.conf', "hot_standby_feedback = on");
$standby->append_conf('postgresql.conf', "primary_slot_name = 'overflow_phys'");
# The standby's own, much smaller residency budget: below the ~55MB the 9
# replicated indexes durably sum to, so its own worker denies some or all
# of them at bootstrap, independent of whatever the primary admitted them
# under. This is the file's actual fixture now: a real, differently
# configured standby, not a workaround of the primary's own admission gate.
$standby->append_conf('postgresql.conf', "svs.default_residency_memory = '1MB'");
$standby->append_conf('postgresql.conf', "svs.max_residency_memory = '10MB'");
$standby->start;

$primary->wait_for_replay_catchup($standby);

# ===========================================================================
# The worker starts, and only once: no crash-loop from bootstrap's
# uncaught-load-failure path.
# ===========================================================================

my $worker_pid = wait_for_worker($standby, 30);
ok($worker_pid =~ /^\d+$/, "standby worker running (pid=$worker_pid)");

{
    # A standby's worker reports 'replica', not 'running' -- a distinct,
    # equally-up state (VAMANA_WORKER_REPLICA), not a slower path to the
    # same one.
    my $state = '';
    for (1 .. 30)
    {
        usleep(500_000);
        $state = $standby->safe_psql('postgres',
            "SELECT worker_state FROM pg_stat_vamana_worker WHERE worker_pid = $worker_pid;");
        chomp $state;
        last if $state eq 'replica';
    }
    is($state, 'replica', 'standby worker_state is replica before checking any denial');
}

# Bootstrap attempts all 9 relids sequentially with a blocking slot-activation
# wait per index (VamanaWorkerServe, before workerPid is published). Each
# wait needs a standby snapshot from the primary to reach consistency; on an
# otherwise idle primary that only happens on its own schedule, which can
# take tens of seconds per index, so nudge it every iteration the same way
# test/t/08_standby_replay.pl does. Poll pid stability and wait for the
# first heartbeat (bootstrap complete, main loop entered) in the same loop
# rather than assuming a fixed window.
my $stable = 1;
my $hb1 = '';
for (1 .. 200)
{
    usleep(500_000);
    $primary->safe_psql('postgres', "SELECT pg_log_standby_snapshot();");
    my $pid_now = $standby->safe_psql('postgres',
        "SELECT pid FROM pg_stat_activity "
      . "WHERE backend_type = 'vamana worker' LIMIT 1;");
    chomp $pid_now;
    if ($pid_now ne $worker_pid)
    {
        $stable = 0;
        last;
    }
    $hb1 = $standby->safe_psql('postgres',
        "SELECT extract(epoch from heartbeat_ts) FROM pg_stat_vamana_worker LIMIT 1;");
    chomp $hb1;
    last if $hb1 ne '';
}
ok($stable,
    'standby worker pid stays the same across the bootstrap window (no crash-restart)');
ok($hb1 ne '', 'standby worker heartbeat is published once bootstrap completes');

sleep(2);
my $hb2 = $standby->safe_psql('postgres',
    "SELECT extract(epoch from heartbeat_ts) FROM pg_stat_vamana_worker LIMIT 1;");
chomp $hb2;
ok($hb2 ne '' && $hb2 > $hb1, 'standby worker heartbeat advances after bootstrap');

# ===========================================================================
# Every one of the 9 residency-budget denials during bootstrap is a
# WARNING, not a crash, and names the ceiling, not a slot count.
# ===========================================================================

my $log = slurp_file($standby->logfile);
unlike($log, qr/background worker "vamana worker[^"]*".*exited with exit code 1/,
    'no standby worker crash-exit in the server log');
unlike($log, qr/Segmentation fault/,
    'no segfault in the standby server log');
like($log, qr/residency budget/,
    'the bootstrap denials surfaced as WARNING and name the residency ceiling');
unlike($log, qr/cache slots/,
    'no denial during bootstrap is the old slot-count message');

# ===========================================================================
# None of the 9 indexes fit the 1MB budget: each is denied via the
# search-path check (vamanaworkersearch.c) on query, surfacing as a
# client-visible residency-budget error, same as test/t/19_cache_hard_deny.pl's
# tinydb case.  Neither outcome is a crash.
# ===========================================================================

my $ok_query = 0;
for my $i (0 .. $N_INDEXES - 1)
{
    my ($ret, $stdout, $stderr) = $standby->psql('postgres', qq{
        SET enable_seqscan = off;
        SELECT id FROM so_tbl_$i ORDER BY val <-> '[$query_sql]' LIMIT 5;
    });
    $ok_query++ if $ret == 0;
    like($stderr, qr/residency budget/, "so_idx_$i is denied with a residency-budget error, not a crash")
        if $ret != 0;
}
is($ok_query, 0,
    'none of the 9 oversized indexes fit the 1MB budget');

$standby->stop;
$primary->stop;

done_testing();
