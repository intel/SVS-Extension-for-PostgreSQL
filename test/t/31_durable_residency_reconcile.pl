# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 31_durable_residency_reconcile.pl — svs_index_residency rows orphaned by
# DROP INDEX and REINDEX INDEX CONCURRENTLY are swept away at the worker's
# next startup, the durable floor falls back to what is genuinely resident,
# and a still-live index's row is left untouched.

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

# ---------------------------------------------------------------------------
# Build three indexes: one to be DROPped, one to be REINDEXed CONCURRENTLY,
# and one left alone throughout as the regression guard -- a live index's
# durable row must survive the sweep.
# ---------------------------------------------------------------------------
$node->safe_psql('postgres', qq(
    CREATE TABLE dropped_tbl (id serial PRIMARY KEY, val vector($dim));
    INSERT INTO dropped_tbl (val)
        SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 500);
    CREATE INDEX dropped_idx ON dropped_tbl USING vamana (val vector_l2_ops);

    CREATE TABLE reindexed_tbl (id serial PRIMARY KEY, val vector($dim));
    INSERT INTO reindexed_tbl (val)
        SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 500);
    CREATE INDEX reindexed_idx ON reindexed_tbl USING vamana (val vector_l2_ops);

    CREATE TABLE live_tbl (id serial PRIMARY KEY, val vector($dim));
    INSERT INTO live_tbl (val)
        SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 500);
    CREATE INDEX live_idx ON live_tbl USING vamana (val vector_l2_ops);
));
wait_for_worker($node);

my $dropped_relid   = relid_of('dropped_idx');
my $reindexed_relid = relid_of('reindexed_idx');
my $live_relid       = relid_of('live_idx');

for my $pair (['dropped_idx', $dropped_relid], ['reindexed_idx', $reindexed_relid],
    ['live_idx', $live_relid])
{
    my ($name, $relid) = @$pair;
    ok(residency_row_exists($relid),
        "$name has a durable residency row before any DDL (relid=$relid)");
}

my $floor_before_ddl = durable_floor_for_postgres();
cmp_ok($floor_before_ddl, '>', 0,
    'the durable floor is positive with all three indexes resident');

# ---------------------------------------------------------------------------
# Orphan one row via DROP INDEX, and another via REINDEX INDEX CONCURRENTLY
# (which drops the old relid once the new one takes its place). Both leave a
# permanent row behind without a worker restart -- this is the leak itself,
# not yet the fix.
# ---------------------------------------------------------------------------
$node->safe_psql('postgres', "DROP INDEX dropped_idx;");
$node->safe_psql('postgres', "REINDEX INDEX CONCURRENTLY reindexed_idx;");
my $reindexed_relid_new = relid_of('reindexed_idx');
isnt($reindexed_relid_new, $reindexed_relid,
    'REINDEX CONCURRENTLY gives reindexed_idx a new relid');

# Give any asynchronous eviction/cleanup a moment to happen, then confirm the
# orphan rows are still there: this is what makes the bug a leak rather than
# a transient staleness.
usleep(2_000_000);
ok(residency_row_exists($dropped_relid),
    "dropped_idx's old relid leaves an orphaned durable row after DROP INDEX");
ok(residency_row_exists($reindexed_relid),
    "reindexed_idx's pre-REINDEX relid leaves an orphaned durable row");
ok(residency_row_exists($reindexed_relid_new),
    "reindexed_idx's new relid has its own durable row after REINDEX CONCURRENTLY");
ok(residency_row_exists($live_relid),
    "live_idx's durable row is untouched by unrelated DDL");

# ---------------------------------------------------------------------------
# Restart the worker: this is the only point the fix runs. Confirm the
# restart actually happened (a new pid) before trusting anything that
# follows -- a restart that silently didn't happen would make a broken sweep
# look like a working one.
# ---------------------------------------------------------------------------
$node->safe_psql('postgres', "SELECT svs_restart_worker('postgres');");
my $pid2 = '';
for (1 .. 60)
{
    usleep(500_000);
    my $pid = $node->safe_psql('postgres',
        "SELECT pid FROM pg_stat_activity "
      . "WHERE backend_type = 'vamana worker' AND datname = 'postgres';");
    chomp $pid;
    if ($pid =~ /^\d+$/ && $pid ne $pid1)
    {
        $pid2 = $pid;
        last;
    }
}
ok($pid2 =~ /^\d+$/ && $pid2 ne $pid1,
    "svs_restart_worker actually replaced the worker (pid $pid1 -> $pid2)");

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
# After the restart, the orphan rows must be gone, the live rows must
# remain, and the durable floor must fall back to exactly what the two
# surviving indexes actually have resident.
# ---------------------------------------------------------------------------
my $swept = '';
for (1 .. 60)
{
    $swept = !residency_row_exists($dropped_relid)
        && !residency_row_exists($reindexed_relid);
    last if $swept;
    usleep(500_000);
}
ok($swept, 'both orphaned rows are gone after the worker restart');

ok(residency_row_exists($reindexed_relid_new),
    "reindexed_idx's current row survives the restart");
ok(residency_row_exists($live_relid),
    "live_idx's row survives the restart untouched, which is the regression this test guards against");

my $floor_after_restart = durable_floor_for_postgres();
my $expected_floor = $node->safe_psql('postgres', qq(
    SELECT COALESCE(SUM(resident_bytes), 0) FROM svs_index_residency
    WHERE index_relid IN ($reindexed_relid_new, $live_relid);
));
chomp $expected_floor;
is($floor_after_restart, $expected_floor,
    'the durable floor after restart equals exactly the two surviving indexes\' committed bytes');
cmp_ok($floor_after_restart, '<', $floor_before_ddl,
    'the durable floor drops once the orphaned rows are swept, from '
  . "$floor_before_ddl to $floor_after_restart");

$node->safe_psql('postgres', "DROP TABLE reindexed_tbl;");
$node->safe_psql('postgres', "DROP TABLE live_tbl;");

$node->stop;

done_testing();
