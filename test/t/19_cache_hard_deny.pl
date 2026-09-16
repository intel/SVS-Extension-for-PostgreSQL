# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 19_cache_hard_deny.pl — the index cache is byte-bounded, not slot-bounded:
# loading more than eight small, well-under-budget indexes succeeds with no
# artificial deny, from both the warmup path and the plain search path, and
# with no eviction of any already-resident index.  A real refusal still
# happens once a database's own residency budget is actually exhausted, and
# that refusal names the residency ceiling, not a slot count.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

# ---------------------------------------------------------------------------
# Cluster setup
# ---------------------------------------------------------------------------

my $node = PostgreSQL::Test::Cluster->new('cache_hard_deny');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'vector,svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 20");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "log_min_messages = 'log'");
$node->append_conf('postgresql.conf', "svs.max_residency_memory = '150MB'");
$node->append_conf('postgresql.conf', "svs.max_search_work_mem = '400MB'");
$node->start;

$node->safe_psql("postgres", "CREATE EXTENSION vector;");
$node->safe_psql("postgres", "CREATE EXTENSION svs;");
$node->safe_psql("postgres",
    "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");
my $wpid = wait_for_worker($node);
like($wpid, qr/^\d+$/, 'vamana worker started');

# ---------------------------------------------------------------------------
# 11 small, well-under-budget indexes: one more than the old 8-slot cap.
# ---------------------------------------------------------------------------

my $N_TABLES = 11;

for my $i (1 .. $N_TABLES)
{
    $node->safe_psql("postgres", qq(
        CREATE TABLE t$i (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO t$i (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 100) s;
        CREATE INDEX idx$i ON t$i USING vamana (val vector_l2_ops);
    ));
}
wait_for_worker($node);

my @baseline;
for my $i (1 .. $N_TABLES)
{
    my $res = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM t$i ORDER BY val <-> '[$query_sql]' LIMIT 3;
    ));
    push @baseline, $res;
}

# ---------------------------------------------------------------------------
# Case 1: every one of the 11 loads via svs_warmup_index, no deny.
# ---------------------------------------------------------------------------

for my $i (1 .. $N_TABLES)
{
    my ($ret, $stdout, $stderr) = $node->psql("postgres",
        "SELECT svs_warmup_index('idx$i');");
    is($ret, 0, "idx$i warms successfully (index $i of $N_TABLES)");
}

# ---------------------------------------------------------------------------
# Case 2: no eviction — every index still returns its baseline result.
# ---------------------------------------------------------------------------

for my $i (1 .. $N_TABLES)
{
    my $res = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM t$i ORDER BY val <-> '[$query_sql]' LIMIT 3;
    ));
    is($res, $baseline[$i - 1],
        "idx$i query results unchanged after warming all $N_TABLES indexes");
}

# ---------------------------------------------------------------------------
# Case 3: the plain search path also loads a 12th, never-warmed index with
# no deny.  This exercises VamanaWorkerEnsureIndexCurrent directly, not
# svs_warmup_index / VamanaWorkerProcessWarmupSlot.
# ---------------------------------------------------------------------------

$node->safe_psql("postgres", qq(
    CREATE TABLE t12 (id serial PRIMARY KEY, val vector($dim));
    INSERT INTO t12 (val)
        SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 100) s;
    CREATE INDEX idx12 ON t12 USING vamana (val vector_l2_ops);
));
wait_for_worker($node);

{
    my ($ret, $stdout, $stderr) = $node->psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM t12 ORDER BY val <-> '[$query_sql]' LIMIT 3;
    ));
    is($ret, 0, 'a cold 12th index loads via the search path with no deny');
}

# ---------------------------------------------------------------------------
# Case 4: a real refusal still happens once a database's own residency
# budget is exhausted, and it names the ceiling, not a slot count.
# ---------------------------------------------------------------------------

$node->safe_psql("postgres", "CREATE DATABASE tinydb;");
$node->safe_psql("tinydb", "CREATE EXTENSION vector;");
$node->safe_psql("tinydb", "CREATE EXTENSION svs;");
$node->safe_psql("postgres",
    "INSERT INTO vamana_databases (datname, enabled, residency_memory) "
  . "VALUES ('tinydb', true, 1);");
wait_for_worker_db($node, 'tinydb', 30);

$node->safe_psql("tinydb", qq(
    CREATE TABLE big_tbl (id serial PRIMARY KEY, val vector($dim));
    INSERT INTO big_tbl (val)
        SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 5000) s;
));

{
    my ($ret, $stdout, $stderr) = $node->psql("tinydb",
        "CREATE INDEX big_idx ON big_tbl USING vamana (val vector_l2_ops);");
    is($ret, 0, 'CREATE INDEX itself succeeds; the worker load is asynchronous');
    like($stderr, qr/residency budget/,
        "the worker's load warning names the residency ceiling, not a slot count");
    unlike($stderr, qr/cache slots/,
        'the load warning is not the old slot-count message');

    my ($qret, $qstdout, $qstderr) = $node->psql("tinydb", qq(
        SET enable_seqscan = off;
        SELECT id FROM big_tbl ORDER BY val <-> '[$query_sql]' LIMIT 3;
    ));
    isnt($qret, 0,
        'querying the index the worker could not load fails');
    like($qstderr, qr/not loaded/,
        'the query error is "not loaded", not a slot-count denial');
}

# ---------------------------------------------------------------------------
# The worker for postgres is unaffected by tinydb's refusal.
# ---------------------------------------------------------------------------

{
    my $hb0 = $node->safe_psql("postgres",
        "SELECT heartbeat_ts FROM pg_stat_vamana_worker "
      . "WHERE worker_pid = $wpid;");
    my $hb_advanced = '';
    for my $i (1 .. 40)
    {
        usleep(250_000);
        my $hb = $node->safe_psql("postgres",
            "SELECT heartbeat_ts FROM pg_stat_vamana_worker "
          . "WHERE worker_pid = $wpid;");
        if ($hb ne '' && $hb0 ne '' && $hb gt $hb0)
        {
            $hb_advanced = 1;
            last;
        }
    }
    ok($hb_advanced, 'postgres worker heartbeat advances after tinydb\'s refusal');

    my $res = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM t1 ORDER BY val <-> '[$query_sql]' LIMIT 3;
    ));
    is($res, $baseline[0],
        'idx1 still returns its baseline result after tinydb\'s refusal');
}

$node->stop;

done_testing();
