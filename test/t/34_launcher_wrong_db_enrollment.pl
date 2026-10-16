# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 34_launcher_wrong_db_enrollment.pl -- enrolling a database from its OWN
# copy of vamana_databases (rather than the launcher's, named by
# svs.launcher_database) must now be rejected immediately, instead of
# silently reserving a shared-memory slot the launcher will never service.
#
# Code under test: src/vamana_databases.c
#                   (vamana_databases_queue_reservation's new guard),
#                   src/vamanalauncher.c (ReadDatabaseRows),
#                   src/vamanaworker.c   (VamanaWorkerAssertDatabase)
#
# CREATE EXTENSION svs installs a vamana_databases table, its NOTIFY
# trigger, and its C reservation trigger into EVERY database where it is
# installed, but only ONE copy is authoritative: the launcher reads the
# table in svs.launcher_database. Before this fix, an INSERT into any other
# database's copy still reserved a real shmem slot (because the row-level
# trigger ran wherever the INSERT ran), permanently stranding that database:
# a slot exists so VamanaWorkerAssertDatabase believes it's configured, but
# no worker is ever spawned because the launcher never sees the row.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

# Short, so the test is quick; the fix's behavior does not depend on it.
my $STARTUP_TIMEOUT_MS = 3000;

my $node = PostgreSQL::Test::Cluster->new('wrong_db_enrollment');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 10");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->append_conf('postgresql.conf',
    "svs.worker_startup_timeout_ms = $STARTUP_TIMEOUT_MS");
$node->start;

# The launcher's home database, set up correctly.
$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");

# The application database.
$node->safe_psql('postgres', "CREATE DATABASE appdb;");
$node->safe_psql('appdb', "CREATE EXTENSION vector;");
$node->safe_psql('appdb', "CREATE EXTENSION svs;");

my $appdb_oid = $node->safe_psql('postgres',
    "SELECT oid FROM pg_database WHERE datname = 'appdb';");
chomp $appdb_oid;

# ---------------------------------------------------------------------------
# Enrolling from appdb's own copy of the table is rejected
# immediately, instead of silently reserving a stray slot.
# ---------------------------------------------------------------------------
{
    my ($ins_rc, undef, $ins_err) = $node->psql('appdb',
        "INSERT INTO vamana_databases (datname, enabled) VALUES (current_database(), true);");
    isnt($ins_rc, 0, 'the INSERT into appdb\'s own vamana_databases is rejected')
      or diag('the INSERT unexpectedly succeeded');
    like($ins_err, qr/cannot enroll "appdb" into vamana_databases from this database/,
        'the rejection names the database and the enrollment problem');
    like($ins_err, qr/svs\.launcher_database/,
        'the rejection mentions svs.launcher_database');
    like($ins_err, qr/Run this INSERT\/UPDATE while connected to "postgres" instead/,
        'the rejection gives the actionable hint: run it from the launcher database');

    my $in_appdb = $node->safe_psql('appdb',
        "SELECT count(*) FROM vamana_databases WHERE datname = 'appdb';");
    chomp $in_appdb;
    is($in_appdb, '0', 'no row was left behind in appdb\'s own copy');

    my $slot = $node->safe_psql('postgres',
        "SELECT count(*) FROM pg_stat_vamana_worker WHERE db_oid = $appdb_oid;");
    chomp $slot;
    is($slot, '0', 'no stray shmem slot was reserved for appdb');

    my $pid = wait_for_worker_db($node, 'appdb', 8);
    is($pid, '', 'no worker is spawned for appdb (nothing was ever enrolled)');
}

# ---------------------------------------------------------------------------
# The identical enrollment succeeds when run from the launcher database.
# ---------------------------------------------------------------------------
{
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('appdb', true);");

    my $in_launcher = $node->safe_psql('postgres',
        "SELECT count(*) FROM vamana_databases WHERE datname = 'appdb';");
    chomp $in_launcher;
    is($in_launcher, '1', 'the row lands in the launcher\'s own copy of the table');

    my $pid = wait_for_worker_db($node, 'appdb', 40);
    ok($pid =~ /^\d+$/, "a worker is spawned for appdb (pid=$pid)");

    $node->safe_psql('appdb', qq{
        CREATE TABLE t34 (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO t34 (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 50) i;
    });
    my ($rc, undef, $err) = $node->psql('appdb',
        "CREATE INDEX i34 ON t34 USING vamana (val vector_l2_ops);");
    is($rc, 0, 'CREATE INDEX succeeds in appdb once it is correctly enrolled')
      or diag($err);
}

# ---------------------------------------------------------------------------
# Once a database is correctly enrolled (above), a second, local-only write
# from that same database's own connection -- not the launcher's -- succeeds,
# because a slot is already reserved for it: this is the pattern
# svs_restart_worker() uses from the launcher side, and the pattern
# maintenance_num_threads overrides use from the enrolled database's own
# side (see SvsDatabasesGetMyMaintenanceNumThreads, test 19). It must not be
# confused with a first enrollment attempt from the wrong database, which
# the earlier block in this file still rejects.
# ---------------------------------------------------------------------------
{
    # appdb's own local copy of the table has no row yet: the enrolling
    # INSERT above landed in the launcher's ('postgres') copy, which is a
    # separate relation instance from appdb's own. This INSERT is the
    # local-only write SvsDatabasesGetMyMaintenanceNumThreads() later reads
    # back, same pattern test 19 uses.
    my ($rc, undef, $err) = $node->psql('appdb',
        "INSERT INTO vamana_databases (datname, enabled, maintenance_num_threads) "
      . "VALUES ('appdb', true, 2);");
    is($rc, 0, 'a local-only write from an already-enrolled database\'s own connection succeeds')
      or diag($err);

    my $value = $node->safe_psql('appdb',
        "SELECT maintenance_num_threads FROM vamana_databases WHERE datname = 'appdb';");
    chomp $value;
    is($value, '2', 'the local write actually took effect in appdb\'s own copy');
}

# ---------------------------------------------------------------------------
# Defense-in-depth: svs_restart_worker() run from the wrong database is
# rejected the same way, covering a row that predates this fix (the only way
# such a row can still exist, since a fresh INSERT from the wrong database
# can no longer create one).
# ---------------------------------------------------------------------------
{
    $node->safe_psql('postgres', "CREATE DATABASE staledb;");
    $node->safe_psql('staledb', "CREATE EXTENSION vector;");
    $node->safe_psql('staledb', "CREATE EXTENSION svs;");

    # Simulate a row that predates this fix: bypass the new guard once, by
    # disabling the trigger that enforces it, to get a row into staledb's own
    # copy the way a pre-fix INSERT would have.
    $node->safe_psql('staledb', qq{
        ALTER TABLE vamana_databases DISABLE TRIGGER vamana_databases_queue_reservation;
        INSERT INTO vamana_databases (datname, enabled) VALUES ('staledb', true);
        ALTER TABLE vamana_databases ENABLE TRIGGER vamana_databases_queue_reservation;
    });

    my ($rc, undef, $err) = $node->psql('staledb',
        "SELECT svs_restart_worker('staledb');");
    isnt($rc, 0, 'svs_restart_worker() from the wrong database is rejected too')
      or diag('svs_restart_worker() unexpectedly succeeded');
    like($err, qr/cannot enroll "staledb" into vamana_databases from this database/,
        'the rejection is the same enrollment-guard error, not a different message');
}

$node->stop;

done_testing();
