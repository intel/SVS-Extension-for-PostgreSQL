# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 040_launcher_read_error_recovery.pl — an error reading vamana_databases
# degrades to the launcher's own WARNING-and-retry path instead of crash-
# looping the launcher forever.
#
# ReadDatabaseRows() runs a SELECT against vamana_databases inside the
# launcher's main loop.  A failing SELECT (a lock conflict, a corrupt index, a
# shape mismatch after a manual schema change) makes SPI_execute ereport
# ERROR rather than return a bad status, so without containment the error
# unwinds out of the launcher's for(;;) loop, the launcher exits, and the
# postmaster respawns it into the same failure indefinitely.  While that is
# happening nothing reconciles: workers already running are unmanaged and new
# enablements never take effect.
#
# The trigger used here is a column rename, so only the launcher's positional
# SELECT breaks; the row-level triggers address columns by attnum and keep
# working.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

my $node = PostgreSQL::Test::Cluster->new('launcher_read_error');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 10");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
# Minimum respawn interval, so a crash loop would be visible in a short window.
$node->append_conf('postgresql.conf', "svs.worker_restart_time = 1");
# Two databases are enabled below; the default ceilings are sized for one.
$node->append_conf('postgresql.conf', "svs.max_search_work_mem = '400MB'");
$node->append_conf('postgresql.conf', "svs.max_residency_memory = '400MB'");
# Default log_min_messages ('warning'): for that GUC, LOG outranks ERROR and
# WARNING, so leaving it at 'log' would silently suppress both messages this
# test asserts on.
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres',
    "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

my $worker_pid = wait_for_worker_db($node, 'postgres', 40);
ok($worker_pid =~ /^\d+$/, "worker running (pid=$worker_pid)");

my $launcher_before = $node->safe_psql('postgres',
    "SELECT pid FROM pg_stat_activity WHERE backend_type = 'vamana launcher' LIMIT 1;");
chomp $launcher_before;
ok($launcher_before =~ /^\d+$/, "launcher running (pid=$launcher_before)");

my $log_pos = length($node->log_content());

# ---------------------------------------------------------------------------
# Break the shape the launcher's SELECT depends on.
# ---------------------------------------------------------------------------
$node->safe_psql('postgres',
    "ALTER TABLE vamana_databases RENAME COLUMN restart_generation TO restart_gen;");

# The rename itself does not NOTIFY (DDL does not fire the row trigger); force
# a reconcile pass with a row change, which does.
$node->safe_psql('postgres',
    "UPDATE vamana_databases SET enabled = true WHERE datname = 'postgres';");

# Watch for 20 s. At svs.worker_restart_time = 1 a crash loop shows many
# distinct launcher pids and repeated exits; a graceful degradation shows one
# launcher pid throughout and a WARNING instead.
my %pids;
for (1 .. 40)
{
    usleep(500_000);
    my $p = $node->safe_psql('postgres',
        "SELECT coalesce(string_agg(pid::text, ','), '') FROM pg_stat_activity "
      . "WHERE backend_type = 'vamana launcher';");
    chomp $p;
    $pids{$_} = 1 for grep { /^\d+$/ } split(/,/, $p);
}

my $log = substr($node->log_content(), $log_pos);
my @exits    = ($log =~ /background worker "vamana launcher".*exited with exit code 1/g);
my @errors   = ($log =~ /column "restart_generation" does not exist/g);
my @warnings = ($log =~ /vamana launcher: failed to read vamana_databases/g);

diag("distinct launcher pids seen over 20 s: " . scalar(keys %pids));
diag("launcher exit-code-1 lines: " . scalar(@exits));
diag("'column does not exist' ERRORs: " . scalar(@errors));
diag("'failed to read vamana_databases' WARNINGs: " . scalar(@warnings));

cmp_ok(scalar(@errors), '>=', 1, 'the read genuinely fails (precondition established)');

# ---------------------------------------------------------------------------
# The intended WARNING-and-retry degradation happens, and the launcher
# survives the read error rather than crash-looping.
# ---------------------------------------------------------------------------
cmp_ok(scalar(@warnings), '>=', 1,
    'the WARNING branch written for exactly this case fires: '
  . 'a failing SPI_execute is caught and reported')
  or diag('ReadDatabaseRows() should catch the error via PG_TRY and warn');

is(scalar(@exits), 0,
    'the launcher does not exit on the read error')
  or diag(scalar(@exits) . " launcher exits in 20 s; "
        . scalar(keys %pids) . " distinct launcher pids observed");

is(scalar(keys %pids), 1,
    '(confirming) the launcher pid holds steady rather than churning');

# ---------------------------------------------------------------------------
# Collateral: while the table is genuinely unreadable, a new enablement
# cannot take effect (there is no row data to reconcile against, whether or
# not the launcher survives), but the launcher itself does not crash doing
# so, and enrollment is not left in a broken state -- it just waits, like
# everything else, for the read to start succeeding again.
# ---------------------------------------------------------------------------
{
    $node->safe_psql('postgres', "CREATE DATABASE launcher_read_error_newdb;");
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) "
      . "VALUES ('launcher_read_error_newdb', true);");

    my $pid = wait_for_worker_db($node, 'launcher_read_error_newdb', 6);   # 3 s
    is($pid, '',
        '(confirming) no worker yet -- the read is still broken, so there is no row '
      . 'data to reconcile a new enablement against');

    my $launcher_after = $node->safe_psql('postgres',
        "SELECT pid FROM pg_stat_activity WHERE backend_type = 'vamana launcher' LIMIT 1;");
    chomp $launcher_after;
    is($launcher_after, $launcher_before,
        'the launcher is still the same process -- enrolling during the read error '
      . 'does not itself crash it');
}

# ---------------------------------------------------------------------------
# Recovery: restoring the shape lets the launcher pick back up with no
# intervention.
# ---------------------------------------------------------------------------
{
    $node->safe_psql('postgres',
        "ALTER TABLE vamana_databases RENAME COLUMN restart_gen TO restart_generation;");
    $node->safe_psql('postgres',
        "UPDATE vamana_databases SET enabled = true WHERE datname = 'postgres';");

    my $pid = wait_for_worker_db($node, 'launcher_read_error_newdb', 40);
    ok($pid =~ /^\d+$/,
        "the launcher keeps working once the shape is restored "
      . "(launcher_read_error_newdb worker pid=$pid)");
}

$node->stop;

done_testing();
