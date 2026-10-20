# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 57_wal_level_crash_loop.pl -- with wal_level < logical, the launcher
# detects the misconfiguration once at its own startup and FATALs with a
# message naming wal_level explicitly, instead of letting every enabled
# database's per-database worker FATAL independently, forever.
#
# wal_level is PGC_POSTMASTER: it cannot change while the server runs, so it
# is knowable once, at launcher startup (VamanaLauncherMain), for every
# database at once. The launcher never spawns a per-database worker
# (VamanaWorkerMain) unless that check already passed, so no worker-side
# wal_level FATAL can occur anymore.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

my $node = PostgreSQL::Test::Cluster->new('f10_wal_level');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
# Deliberately NOT logical. 'replica' is the PostgreSQL default, so this is
# the state of every server where the operator has not yet read the
# requirement.
$node->append_conf('postgresql.conf', "wal_level = replica");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
# Short restart interval so several launcher respawn-and-FATAL cycles land
# inside the observation window.
$node->append_conf('postgresql.conf', "svs.worker_restart_time = 1");
$node->append_conf('postgresql.conf', "log_min_messages = 'log'");
$node->start;

my $wal_level = $node->safe_psql('postgres', "SHOW wal_level;");
chomp $wal_level;
is($wal_level, 'replica', "server is running with wal_level = $wal_level");

my $log_pos = length($node->log_content());

# ---------------------------------------------------------------------------
# FIX (F10) -- the launcher never stays up with wal_level < logical; it
# FATALs at its own startup instead of connecting and reconciling workers.
# ---------------------------------------------------------------------------
my $launcher = $node->safe_psql('postgres',
    "SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'vamana launcher';");
chomp $launcher;
is($launcher, '0',
    'FIX: the launcher does not stay running with wal_level < logical -- it '
  . 'FATALs at its own startup instead of registering per-database workers '
  . 'that could only FATAL themselves later');

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");

# Observe several launcher restart cycles (restart_time = 1 s above).
usleep(6_000_000);

my $log = substr($node->log_content(), $log_pos);
my @launcher_fatals = ($log =~ /vamana launcher requires wal_level = logical/g);
my @worker_fatals = ($log =~ /vamana background worker requires wal_level/g);

diag("launcher wal_level FATALs in 6 s: " . scalar(@launcher_fatals));
diag("per-database worker wal_level FATALs in 6 s: " . scalar(@worker_fatals));

cmp_ok(scalar(@launcher_fatals), '>=', 1,
    'the launcher does refuse to run, with a message naming wal_level');

is(scalar(@worker_fatals), 0,
    'FIX: no per-database worker ever FATALs on wal_level -- the launcher '
  . 'never spawns one past its own startup check');

# ---------------------------------------------------------------------------
# FIX -- the launcher's own FATAL explicitly names wal_level, unlike the
# pre-fix launcher log lines which never attributed the per-database crash
# loop to anything.
# ---------------------------------------------------------------------------
{
    my @launcher_lines = grep { /vamana launcher/ } split(/\n/, $log);
    my @naming_wal = grep { /wal_level/ } @launcher_lines;

    diag("launcher log lines mentioning wal_level: " . scalar(@naming_wal));
    diag("launcher log lines total: " . scalar(@launcher_lines));

    cmp_ok(scalar(@naming_wal), '>=', 1,
        'the launcher log attributes the refusal to wal_level, so an '
      . 'operator reading the log sees a named cause, not an unexplained '
      . 'crash loop');
}

# ---------------------------------------------------------------------------
# No worker ever got far enough to register a slot: no row for this
# database should exist in pg_stat_vamana_worker.
# ---------------------------------------------------------------------------
{
    my $slot_count = $node->safe_psql('postgres',
        "SELECT count(*) FROM pg_stat_vamana_worker "
      . "WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = current_database());");
    chomp $slot_count;
    is($slot_count, '0',
        'no worker slot was ever reserved for this database -- the launcher '
      . 'never got past its own wal_level check to spawn one');
}

$node->stop;

done_testing();
