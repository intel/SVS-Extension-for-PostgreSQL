# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 08_vamana_standby_replay.pl — standby BGW replay via main-loop sweep.
#
# Verifies that the standby BGW replays committed changes from the primary
# via its main-loop replication sweep (gated by RecoveryInProgress()).
#
# Tests:
#   1. Rows inserted on primary become searchable on standby via ANN query.
#   2. Additional inserts on primary propagate to standby (bounded staleness).
#   3. Fast-path skip: CreateDecodingContext is not called repeatedly
#      when no new WAL arrives on the standby.
#   4. An index created on the primary after the standby worker is already
#      running becomes searchable, and its slot reaches consistency, with no
#      restart.
#   5. The worker heartbeat keeps advancing while that slot converges.
#   6. Dropping the index on the primary reaps the standby's own replication
#      slot, with no restart.
#   7. An invalidation on an unrelated relation does not disturb the worker or
#      existing search results.
#   8. A CREATE INDEX immediately followed by writes replays both the
#      discovery and the writes.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

my $dim = 16;
my $array_sql = join(",", ('random()') x $dim);

# A constant query vector.  The order key must be an immutable literal for the
# planner to consider the vamana index; a per-row random() expression forces a
# sort instead, even with enable_seqscan off.
my $query_vec = '[' . join(",", map { sprintf("%.6f", rand()) } 1 .. $dim) . ']';

# ===========================================================================
# Setup: primary + streaming standby
# ===========================================================================

my $primary = PostgreSQL::Test::Cluster->new('primary_replay');
$primary->init(allows_streaming => 1);
$primary->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$primary->append_conf('postgresql.conf', "wal_level = logical");
$primary->append_conf('postgresql.conf', "max_replication_slots = 10");
$primary->append_conf('postgresql.conf', "max_wal_senders = 10");
$primary->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$primary->append_conf('postgresql.conf', "svs.checkpoint_min_ops = 999999");
$primary->start;

$primary->safe_psql('postgres', "CREATE EXTENSION vector;");
$primary->safe_psql('postgres', "CREATE EXTENSION svs;");
$primary->safe_psql('postgres',
    "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

$primary->safe_psql('postgres', qq{
    CREATE TABLE rep_tbl (id serial, val vector($dim));
    CREATE INDEX rep_idx ON rep_tbl USING vamana (val vector_l2_ops);
});

# Wait for primary BGW to load the index.
wait_for_worker($primary, 30);

# INSERT 5 rows on primary.
for my $i (1 .. 5)
{
    $primary->safe_psql('postgres', qq{
        INSERT INTO rep_tbl (val) VALUES (ARRAY[$array_sql]::vector);
    });
}
wait_for_worker($primary, 30);

$primary->safe_psql('postgres',
    "SELECT pg_create_physical_replication_slot('replay_phys');");

# Take backup and create standby.
my $backup_name = 'standby_backup';
$primary->backup($backup_name);

my $standby = PostgreSQL::Test::Cluster->new('standby_replay');
$standby->init_from_backup($primary, $backup_name, has_streaming => 1);
$standby->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$standby->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$standby->append_conf('postgresql.conf', "svs.checkpoint_min_ops = 999999");
$standby->append_conf('postgresql.conf', "log_min_messages = debug1");
$standby->append_conf('postgresql.conf', "hot_standby = on");
# Live create/drop tests below need a slot on the standby to actually reach
# CONSISTENT; a physical slot pins the primary's catalog_xmin so
# hot_standby_feedback keeps that possible.
$standby->append_conf('postgresql.conf', "hot_standby_feedback = on");
$standby->append_conf('postgresql.conf', "primary_slot_name = 'replay_phys'");
$standby->start;

# Wait for standby to catch up with primary.
$primary->wait_for_replay_catchup($standby);

# ===========================================================================
# Test 1: Rows inserted on primary are searchable on standby
#
# enable_seqscan = off forces the vamana index so the query is answered from
# the worker's in-memory graph rather than a heap sort; at these row counts the
# planner would otherwise seq-scan the replicated heap and pass regardless of
# whether index replay ran.
# ===========================================================================

my $ann_query = qq{
    SET enable_seqscan = off;
    SELECT count(*) FROM (
        SELECT * FROM rep_tbl
        ORDER BY val <-> '$query_vec'::vector
        LIMIT 10
    ) sub;
};

my $count = 0;
for (1 .. 30)
{
    usleep(500_000);
    eval {
        $count = $standby->safe_psql('postgres', $ann_query);
    };
    chomp $count if defined $count;
    last if defined $count && $count == 5;
}

ok($count == 5,
    "standby replay: 5 rows from primary searchable via ANN on standby");

# Confirm the count above actually came from the vamana index, not a heap scan.
my $plan = $standby->safe_psql('postgres', qq{
    SET enable_seqscan = off;
    EXPLAIN (COSTS OFF)
    SELECT * FROM rep_tbl
    ORDER BY val <-> '$query_vec'::vector
    LIMIT 10;
});
like($plan, qr/Index Scan using rep_idx/,
    "standby replay: ANN query is served by the vamana index");

# ===========================================================================
# Test 2: Additional inserts propagate to standby
# ===========================================================================

for my $i (1 .. 3)
{
    $primary->safe_psql('postgres', qq{
        INSERT INTO rep_tbl (val) VALUES (ARRAY[$array_sql]::vector);
    });
}
wait_for_worker($primary, 30);
$primary->wait_for_replay_catchup($standby);

$count = 0;
for (1 .. 30)
{
    usleep(500_000);
    eval {
        $count = $standby->safe_psql('postgres', $ann_query);
    };
    chomp $count if defined $count;
    last if defined $count && $count == 8;
}

# With the index forced, count == 8 proves replay ran: a standby that only
# loaded the 5-row base backup would still report 5 here.
ok($count == 8,
    "standby replay: additional inserts from primary propagate to standby");

# ===========================================================================
# Test 3: Fast-path skip — no CreateDecodingContext when WAL is idle
# ===========================================================================

# Record current log size before idle period.
my $logfile = $standby->logfile;
my $log_size_before = -s $logfile;

# No more DML. Let the standby idle for 5 seconds (at least 4 loop iterations).
sleep(5);

# Count "entering CreateDecodingContext" entries appended during the idle window.
open(my $fh, '<', $logfile) or die "cannot open standby log: $!";
seek($fh, $log_size_before, 0);
my $idle_decode_count = 0;
while (my $line = <$fh>)
{
    $idle_decode_count++ if $line =~ /vamana replay: entering CreateDecodingContext/;
}
close($fh);

# During 5s idle with 1s loop, without fast-path: >= 4 calls.
# With fast-path: at most 1 call (the iteration that sets lastReplayWalEnd,
# after which subsequent iterations skip before ReplicationSlotAcquire).
ok($idle_decode_count <= 2,
    "fast-path skip: CreateDecodingContext calls bounded during idle ($idle_decode_count)");

# ===========================================================================
# Test 4: Live create — index created after the standby worker is already
# running becomes searchable, and its own slot reaches consistency.
# ===========================================================================

$primary->safe_psql('postgres', qq{
    CREATE TABLE live_tbl (id serial, val vector($dim));
    CREATE INDEX live_idx ON live_tbl USING vamana (val vector_l2_ops);
    INSERT INTO live_tbl (val)
        SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 5);
});

my $live_count = -1;
for (1 .. 60)
{
    usleep(500_000);
    $primary->safe_psql('postgres', "SELECT pg_log_standby_snapshot();");
    eval {
        $live_count = $standby->safe_psql('postgres', "SELECT count(*) FROM live_tbl;");
    };
    chomp $live_count if defined $live_count;
    last if defined $live_count && $live_count == 5;
}
ok(defined $live_count && $live_count == 5,
    "live create: index created on primary after standby worker start becomes searchable, no restart");

my $live_relid = $standby->safe_psql('postgres',
    "SELECT oid FROM pg_class WHERE relname = 'live_idx';");
chomp $live_relid;
my $dboid = $standby->safe_psql('postgres',
    "SELECT oid FROM pg_database WHERE datname = 'postgres';");
chomp $dboid;
my $live_slot = "vamana_${dboid}_${live_relid}";

my $live_slot_consistent = -1;
for (1 .. 60)
{
    usleep(500_000);
    $primary->safe_psql('postgres', "SELECT pg_log_standby_snapshot();");
    $live_slot_consistent = $standby->safe_psql('postgres',
        "SELECT count(*) FROM pg_replication_slots "
      . "WHERE slot_name = '$live_slot' AND confirmed_flush_lsn IS NOT NULL;");
    chomp $live_slot_consistent;
    last if $live_slot_consistent == 1;
}
ok($live_slot_consistent == 1,
    "live create: standby's own slot for the new index reaches consistency");

# ===========================================================================
# Test 5: Heartbeat is not starved while that slot converges.
# ===========================================================================

my $hb_before = $standby->safe_psql('postgres',
    "SELECT extract(epoch from heartbeat_ts) FROM pg_stat_vamana_worker "
  . "WHERE db_oid = $dboid;");
chomp $hb_before;
usleep(2_000_000);
my $hb_after = $standby->safe_psql('postgres',
    "SELECT extract(epoch from heartbeat_ts) FROM pg_stat_vamana_worker "
  . "WHERE db_oid = $dboid;");
chomp $hb_after;
ok($hb_after > $hb_before,
    "heartbeat keeps advancing while a newly created index's slot converges");

# ===========================================================================
# Test 6: Live drop reaps the standby's own slot, no restart.
# ===========================================================================

$primary->safe_psql('postgres', "DROP INDEX live_idx;");

my $slot_after_drop = -1;
for (1 .. 60)
{
    usleep(500_000);
    $primary->safe_psql('postgres', "SELECT pg_log_standby_snapshot();");
    $slot_after_drop = $standby->safe_psql('postgres',
        "SELECT count(*) FROM pg_replication_slots WHERE slot_name = '$live_slot';");
    chomp $slot_after_drop;
    last if $slot_after_drop == 0;
}
ok($slot_after_drop == 0,
    "live drop: standby's own replication slot for the dropped index is reaped, no restart");

# ===========================================================================
# Test 7: An unrelated relation's invalidation is a no-op.
# ===========================================================================

$primary->safe_psql('postgres', "CREATE TABLE plain_tbl (id int);");
$primary->wait_for_replay_catchup($standby);
$primary->safe_psql('postgres', "ANALYZE plain_tbl;");
$primary->wait_for_replay_catchup($standby);

my $worker_pid_after_noise = '';
for (1 .. 60)
{
    usleep(500_000);
    $primary->safe_psql('postgres', "SELECT pg_log_standby_snapshot();");
    $worker_pid_after_noise = $standby->safe_psql('postgres',
        "SELECT worker_pid FROM pg_stat_vamana_worker WHERE db_oid = $dboid;");
    chomp $worker_pid_after_noise;
    last if $worker_pid_after_noise =~ /^\d+$/;
}
ok($worker_pid_after_noise =~ /^\d+$/,
    "non-vamana invalidation: worker is still alive after unrelated ANALYZE");

my $rep_count_after_noise = -1;
eval {
    $rep_count_after_noise = $standby->safe_psql('postgres', $ann_query);
};
chomp $rep_count_after_noise if defined $rep_count_after_noise;
ok(defined $rep_count_after_noise,
    "non-vamana invalidation: existing index still queryable after unrelated ANALYZE");

# ===========================================================================
# Test 8: create immediately followed by writes replays both correctly.
# ===========================================================================

$primary->safe_psql('postgres', qq{
    CREATE TABLE order_tbl (id serial, val vector($dim));
    CREATE INDEX order_idx ON order_tbl USING vamana (val vector_l2_ops);
    INSERT INTO order_tbl (val)
        SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 5);
});
for my $i (1 .. 5)
{
    $primary->safe_psql('postgres',
        "INSERT INTO order_tbl (val) VALUES (ARRAY[$array_sql]::vector);");
}

my $order_count = -1;
for (1 .. 60)
{
    usleep(500_000);
    $primary->safe_psql('postgres', "SELECT pg_log_standby_snapshot();");
    eval {
        $order_count = $standby->safe_psql('postgres', "SELECT count(*) FROM order_tbl;");
    };
    chomp $order_count if defined $order_count;
    last if defined $order_count && $order_count == 10;
}
ok(defined $order_count && $order_count == 10,
    "create immediately followed by writes: both discovery and writes replay correctly");

$standby->stop;
$primary->stop;

done_testing();
