# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 31_durable_residency_reconcile.pl — svs_index_residency rows orphaned by a
# DROP INDEX that commits while the worker is down are swept away once the
# worker comes back up, the durable floor falls back to what is genuinely
# resident, and a still-live index's row is left untouched.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

my $node = PostgreSQL::Test::Cluster->new('durable_residency_reconcile');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'vector,svs'");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 10");
$node->append_conf('postgresql.conf', "max_wal_senders = 4");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");

# One database at the 100MB default consumes the whole cluster ceiling by
# design (a second enrolled database would otherwise be refused), and this
# test's three indexes together exceed that default; raise both GUCs before
# enrolling.
$node->safe_psql('postgres', "ALTER SYSTEM SET svs.max_residency_memory = '16000MB';");
$node->safe_psql('postgres', "ALTER SYSTEM SET svs.default_residency_memory = '16000MB';");
$node->restart;

$node->safe_psql('postgres',
    "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");
my $pid1 = wait_for_worker($node);
ok($pid1 =~ /^\d+$/, "worker running for postgres (pid=$pid1)");
is($node->safe_psql('postgres',
        "SELECT worker_state FROM pg_stat_vamana_worker "
      . "WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');"),
    'running', 'worker_state is running before the test begins');

sub relid_of
{
    my ($ident) = @_;
    my $relid = $node->safe_psql('postgres', "SELECT '$ident'::regclass::oid;");
    chomp $relid;
    return $relid;
}

sub residency_row_exists
{
    my ($relid) = @_;
    my $count = $node->safe_psql('postgres',
        "SELECT count(*) FROM svs_index_residency WHERE index_relid = $relid;");
    chomp $count;
    return $count eq '1';
}

sub durable_floor_for_postgres
{
    # Filter against pg_class so a still-orphaned row from this very bug
    # cannot be mistaken for the genuinely resident total this assertion is
    # trying to measure.
    my $sum = $node->safe_psql('postgres', qq(
        SELECT COALESCE(SUM(r.resident_bytes), 0)
        FROM svs_index_residency r
        JOIN pg_class c ON c.oid = r.index_relid
        WHERE r.db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');
    ));
    chomp $sum;
    return $sum;
}

# A DROP INDEX or REINDEX CONCURRENTLY committing while the worker is up
# retires its residency row promptly, through the same worker-side reload
# path a plain cache invalidation uses. Only a database with no live worker
# to receive that signal leaves a row this sweep still needs to catch.
sub kill_worker_and_wait
{
    my $worker_pid = $node->safe_psql('postgres',
        "SELECT pid FROM pg_stat_activity WHERE backend_type = 'vamana worker';");
    chomp $worker_pid;
    $node->safe_psql('postgres',
        "UPDATE vamana_databases SET enabled = false WHERE datname = 'postgres';");

    my $log_pos = length($node->log_content());
    kill('TERM', $worker_pid);
    $node->wait_for_log(qr/vamana background worker shutting down/, $log_pos);
    for (1 .. 100)
    {
        usleep(100_000);
        my $alive = $node->safe_psql('postgres',
            "SELECT count(*) FROM pg_stat_activity "
          . "WHERE backend_type = 'vamana worker';");
        chomp $alive;
        last if $alive eq '0';
    }
}

# ---------------------------------------------------------------------------
# Build two indexes: one to be DROPped, and one left alone throughout as the
# regression guard -- a live index's durable row must survive the sweep.
#
# REINDEX INDEX CONCURRENTLY needs a build-thread grant from the launcher,
# which is unavailable while the database is disabled, so it cannot be used
# to reproduce the worker-down orphan case below; plain DROP INDEX can.
# ---------------------------------------------------------------------------
$node->safe_psql('postgres', qq(
    CREATE TABLE dropped_tbl (id serial PRIMARY KEY, val vector($dim));
    INSERT INTO dropped_tbl (val)
        SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 500);
    CREATE INDEX dropped_idx ON dropped_tbl USING vamana (val vector_l2_ops);

    CREATE TABLE live_tbl (id serial PRIMARY KEY, val vector($dim));
    INSERT INTO live_tbl (val)
        SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 500);
    CREATE INDEX live_idx ON live_tbl USING vamana (val vector_l2_ops);
));
wait_for_worker($node);

my $dropped_relid = relid_of('dropped_idx');
my $live_relid     = relid_of('live_idx');

for my $pair (['dropped_idx', $dropped_relid], ['live_idx', $live_relid])
{
    my ($name, $relid) = @$pair;
    ok(residency_row_exists($relid),
        "$name has a durable residency row before any DDL (relid=$relid)");
}

my $floor_before_ddl = durable_floor_for_postgres();
cmp_ok($floor_before_ddl, '>', 0,
    'the durable floor is positive with both indexes resident');

# ---------------------------------------------------------------------------
# Take the worker down, then orphan dropped_idx's row via DROP INDEX. With no
# live worker to signal, the commit's retire request is never delivered --
# this is the leak itself, not yet the fix.
# ---------------------------------------------------------------------------
kill_worker_and_wait();

$node->safe_psql('postgres', "DROP INDEX dropped_idx;");

ok(residency_row_exists($dropped_relid),
    "dropped_idx's relid leaves an orphaned durable row after DROP INDEX with no worker running");

# ---------------------------------------------------------------------------
# Bring the worker back: this is the only point the fix runs.
# ---------------------------------------------------------------------------
$node->safe_psql('postgres',
    "UPDATE vamana_databases SET enabled = true WHERE datname = 'postgres';");
my $pid2 = wait_for_worker($node);
ok($pid2 =~ /^\d+$/ && $pid2 ne $pid1,
    "the worker came back up for postgres (pid $pid1 -> $pid2)");

for (1 .. 60)
{
    my $state = $node->safe_psql('postgres',
        "SELECT worker_state FROM pg_stat_vamana_worker "
      . "WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');");
    chomp $state;
    last if $state eq 'running';
    usleep(500_000);
}
is($node->safe_psql('postgres',
        "SELECT worker_state FROM pg_stat_vamana_worker "
      . "WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');"),
    'running', 'the restarted worker settles into running');

# ---------------------------------------------------------------------------
# After the restart, the orphan row must be gone, the live row must remain,
# and the durable floor must fall back to exactly what the surviving index
# actually has resident.
# ---------------------------------------------------------------------------
my $swept = '';
for (1 .. 60)
{
    $swept = !residency_row_exists($dropped_relid);
    last if $swept;
    usleep(500_000);
}
ok($swept, "the orphaned row is gone after the worker restart");

ok(residency_row_exists($live_relid),
    "live_idx's row survives the restart untouched, which is the regression this test guards against");

my $floor_after_restart = durable_floor_for_postgres();
my $expected_floor = $node->safe_psql('postgres', qq(
    SELECT COALESCE(SUM(resident_bytes), 0) FROM svs_index_residency
    WHERE index_relid = $live_relid;
));
chomp $expected_floor;
is($floor_after_restart, $expected_floor,
    "the durable floor after restart equals exactly live_idx's committed bytes");
cmp_ok($floor_after_restart, '<', $floor_before_ddl,
    'the durable floor drops once the orphaned row is swept, from '
  . "$floor_before_ddl to $floor_after_restart");

$node->safe_psql('postgres', "DROP TABLE live_tbl;");

$node->stop;

done_testing();
