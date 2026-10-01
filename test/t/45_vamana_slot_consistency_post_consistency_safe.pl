# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL
#
# 45_vamana_slot_consistency_post_consistency_safe.pl -- pre-check: once a
# vamana index's replication slot has reached its initial CONSISTENT point
# (confirmed_flush_lsn populated), does a transaction started AFTERWARDS make
# it unsafe again? This test confirms it does not: checking once, at load
# time, whether the slot was ever consistent is enough; the check does
# not need to re-derive the *current* state on every load.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

my $node = PostgreSQL::Test::Cluster->new('r9_post_consistency');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 10");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->append_conf('postgresql.conf', "fsync = on");
$node->append_conf('postgresql.conf', "svs.worker_timeout_ms = 30000");
# Default checkpoint GUCs -- deliberately not overridden.
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres',
    "INSERT INTO vamana_databases (datname) VALUES ('postgres');");
wait_for_worker_db($node, 'postgres', 40);

$node->safe_psql('postgres', qq{
    CREATE TABLE pc_tbl (id serial PRIMARY KEY, val vector($dim));
    INSERT INTO pc_tbl (val)
        SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 50);
    CREATE INDEX pc_idx ON pc_tbl USING vamana (val vector_l2_ops);
});
wait_for_worker_db($node, 'postgres', 30);

sub slot_confirmed_flush
{
    my $v = $node->safe_psql('postgres', qq{
        SELECT confirmed_flush_lsn FROM pg_replication_slots
        WHERE slot_name LIKE 'vamana_%';
    });
    chomp $v;
    return $v;
}

# Step 1: wait for the slot to reach consistency BEFORE opening any blocker.
my $reached = 0;
for (1 .. 200)    # up to 20s
{
    if (slot_confirmed_flush() ne '')
    {
        $reached = 1;
        last;
    }
    usleep(100_000);
}
ok($reached, 'slot reaches consistency with no blocker present (sanity)');

# Step 2: only now open a long-running, uncommitted, unrelated transaction.
my $blocker = $node->background_psql('postgres');
$blocker->query_safe('BEGIN;');
$blocker->query_safe("CREATE TABLE unrelated_lock_holder_2 (x int);");
$blocker->query_safe("INSERT INTO unrelated_lock_holder_2 VALUES (1);");
# Left open (no COMMIT).

# Step 3: insert while the blocker is open, confirm the slot STAYS consistent
# (does not revert to NULL) despite the concurrent open transaction.
$node->safe_psql('postgres', qq{
    INSERT INTO pc_tbl (val)
        SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 5);
});
sleep(3);
my $cf_during_blocker = slot_confirmed_flush();
isnt($cf_during_blocker, '',
    'confirmed_flush_lsn stays populated (does not revert to NULL) with a '
    . 'blocker open AFTER the slot already reached consistency');

# Step 4: crash and restart with the blocker still open, confirm full recall.
$node->stop('immediate');
$node->start;
wait_for_worker_db($node, 'postgres', 30);

my $search_sql = qq{
    SET enable_seqscan = off;
    SELECT count(*), count(DISTINCT id) FROM (
        SELECT id FROM pc_tbl ORDER BY val <-> '[$query_sql]'
        LIMIT 100000
    ) s;
};
my ($total, $distinct) = ('', '');
for (1 .. 120)
{
    my $c = $node->safe_psql('postgres', $search_sql);
    chomp $c;
    ($total, $distinct) = split(/\|/, $c);
    last if $distinct eq '55' && $total eq '55';
    usleep(500_000);
}
is($total, $distinct, 'no duplicate TIDs after the crash');
is($distinct, 55,
    'a transaction started AFTER the slot reached consistency does NOT make '
    . 'a later crash unsafe -- full recall expected');

$node->stop;
done_testing();
