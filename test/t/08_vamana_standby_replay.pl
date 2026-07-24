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
$primary->append_conf('postgresql.conf', "svs.worker_database = 'postgres'");
$primary->append_conf('postgresql.conf', "svs.checkpoint_min_ops = 999999");
$primary->start;

$primary->safe_psql('postgres', "CREATE EXTENSION vector;");
$primary->safe_psql('postgres', "CREATE EXTENSION svs;");

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

# Take backup and create standby.
my $backup_name = 'standby_backup';
$primary->backup($backup_name);

my $standby = PostgreSQL::Test::Cluster->new('standby_replay');
$standby->init_from_backup($primary, $backup_name, has_streaming => 1);
$standby->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$standby->append_conf('postgresql.conf', "svs.worker_database = 'postgres'");
$standby->append_conf('postgresql.conf', "svs.checkpoint_min_ops = 999999");
$standby->append_conf('postgresql.conf', "log_min_messages = debug1");
$standby->append_conf('postgresql.conf', "hot_standby = on");
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

$standby->stop;
$primary->stop;

done_testing();
