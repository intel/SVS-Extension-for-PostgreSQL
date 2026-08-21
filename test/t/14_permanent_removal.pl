# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# the BEFORE DELETE guard across databases.
#
# The guard on vamana_databases reads the target database's live-index count
# from shared memory, so it works from the launcher database without any
# cross-database query.  Regression runs in a single database where the
# launcher and target coincide; only a real two-database cluster proves the
# shmem read reaches across databases, which is what this file exercises:
#
#   1. DELETE from the launcher database is rejected while a vamana index still
#      exists in the target database (the count is read from the target's slot).
#   2. After svs_teardown_database() runs in the target, the same DELETE from
#      the launcher database succeeds.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

my $LAUNCHER_DB = 'postgres';
my $TARGET_DB   = 'target_db';

my $node = PostgreSQL::Test::Cluster->new('vamana_permanent_removal');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 10");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "svs.launcher_database = '$LAUNCHER_DB'");
$node->start;

$node->safe_psql($LAUNCHER_DB, "CREATE EXTENSION vector;");
$node->safe_psql($LAUNCHER_DB, "CREATE EXTENSION svs;");
$node->safe_psql($LAUNCHER_DB, "CREATE DATABASE $TARGET_DB;");
$node->safe_psql($TARGET_DB, "CREATE EXTENSION vector;");
$node->safe_psql($TARGET_DB, "CREATE EXTENSION svs;");

# Enable the target and wait for its worker, so its shmem slot is reserved and
# the index count the guard reads is live.
$node->safe_psql($LAUNCHER_DB,
    "INSERT INTO vamana_databases (datname, enabled) VALUES ('$TARGET_DB', true);");
wait_for_worker_db($node, $TARGET_DB, 30);

$node->safe_psql($TARGET_DB, qq{
    CREATE TABLE t (id serial PRIMARY KEY, val vector($dim));
    INSERT INTO t (val)
        SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 20);
    CREATE INDEX t_idx ON t USING vamana (val vector_l2_ops);
});

# Test 1: the launcher-database DELETE is rejected by the target's shmem count.
my ($del_ret, undef, $del_err) = $node->psql($LAUNCHER_DB,
    "DELETE FROM vamana_databases WHERE datname = '$TARGET_DB';");
isnt($del_ret, 0,
    'DELETE from the launcher database is rejected while the target has an index');
like($del_err,
    qr/cannot remove "$TARGET_DB" from vamana_databases: \d+ vamana index\(es\) still exist/,
    'rejection reads the index count from the target database\'s shmem slot');

my $still_there = $node->safe_psql($LAUNCHER_DB,
    "SELECT count(*) FROM vamana_databases WHERE datname = '$TARGET_DB';");
chomp $still_there;
is($still_there, '1', 'the rejected DELETE left the row in place');

# Test 2: after teardown in the target, the launcher-database DELETE succeeds.
$node->safe_psql($TARGET_DB, "SELECT svs_teardown_database();");

my $target_oid = $node->safe_psql($LAUNCHER_DB,
    "SELECT oid FROM pg_database WHERE datname = '$TARGET_DB';");
chomp $target_oid;

my ($ok_ret, undef, $ok_err) = $node->psql($LAUNCHER_DB,
    "DELETE FROM vamana_databases WHERE datname = '$TARGET_DB';");
is($ok_ret, 0,
    'DELETE from the launcher database succeeds once the target is torn down');

my $gone = $node->safe_psql($LAUNCHER_DB,
    "SELECT count(*) FROM vamana_databases WHERE datname = '$TARGET_DB';");
chomp $gone;
is($gone, '0', 'the row is removed after teardown');

# The DELETE removing the catalog row is not the same as the launcher
# releasing the shmem slot it held; the latter only happens once the launcher
# observes the stopped worker on a later reconcile pass.
ok(wait_for_slot_release($node, $LAUNCHER_DB, $target_oid, 30),
    'the shmem slot is released, not just the catalog row');

$node->stop;

done_testing();
