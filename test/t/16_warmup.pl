# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# explicit warm-up: svs_warmup_index() and
# svs_warmup_database() force indexes resident in the worker cache on demand.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

my $node = PostgreSQL::Test::Cluster->new('vamana_warmup');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 10");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "log_min_messages = 'log'");
$node->start;

$node->safe_psql("postgres", "CREATE EXTENSION vector;");
$node->safe_psql("postgres", "CREATE EXTENSION svs;");
$node->safe_psql("postgres",
    "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

$node->safe_psql("postgres", qq(
    CREATE TABLE warm_tbl (id serial PRIMARY KEY, val vector($dim));
    INSERT INTO warm_tbl (val)
        SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 200) i;
    CREATE INDEX warm_idx ON warm_tbl USING vamana (val vector_l2_ops);
));
wait_for_worker($node);

# A restart leaves the primary worker cache cold: it loads on demand, with no
# eager preload.  Warm-up is the only thing that should trigger a load here.
$node->restart;
wait_for_worker($node);

my $relid = $node->safe_psql("postgres", "SELECT 'warm_idx'::regclass::oid;");

# svs_warmup_index() populates the worker cache: the load happens during the
# call, not on a later query.
{
    my $log_pos = length($node->log_content());
    $node->safe_psql("postgres", "SELECT svs_warmup_index('warm_idx');");
    my $warmup_log = substr($node->log_content(), $log_pos);
    like($warmup_log, qr/loading vamana index $relid/,
        'svs_warmup_index loads the index into the worker cache');

    $log_pos = length($node->log_content());
    my $res = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM warm_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));
    isnt($res, '', 'query returns results after warm-up');
    my $query_log = substr($node->log_content(), $log_pos);
    unlike($query_log, qr/loading vamana index $relid/,
        'query after warm-up hits the resident cache — no cold load');
}

# Warming an already-resident index is a no-op via the in-worker fast path.
{
    my $log_pos = length($node->log_content());
    $node->safe_psql("postgres", "SELECT svs_warmup_index('warm_idx');");
    my $warmup_log = substr($node->log_content(), $log_pos);
    unlike($warmup_log, qr/loading vamana index $relid/,
        'repeated svs_warmup_index on a resident index does not reload');
}

# svs_warmup_database() warms every vamana index in the database and returns
# the count.
{
    $node->safe_psql("postgres", qq(
        CREATE TABLE warm_tbl2 (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO warm_tbl2 (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 100) i;
        CREATE INDEX warm_idx2 ON warm_tbl2 USING vamana (val vector_l2_ops);
    ));

    my $count = $node->safe_psql("postgres", "SELECT svs_warmup_database();");
    is($count, '2', 'svs_warmup_database warms both indexes and returns the count');
}

# A named non-vamana target fails loudly.
{
    my ($ret, $stdout, $stderr) = $node->psql("postgres",
        "SELECT svs_warmup_index('warm_tbl');");
    isnt($ret, 0, 'svs_warmup_index on a non-vamana relation errors');
    like($stderr, qr/is not a vamana index/,
        'error names the wrong-object-type cause');
}

# An empty enumeration succeeds as a no-op.
{
    $node->safe_psql("postgres", "CREATE DATABASE emptydb;");
    $node->safe_psql("postgres",
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('emptydb', true);");
    wait_for_worker_db($node, 'emptydb');
    $node->safe_psql("emptydb", "CREATE EXTENSION vector; CREATE EXTENSION svs;");

    my $count = $node->safe_psql("emptydb", "SELECT svs_warmup_database();");
    is($count, '0', 'svs_warmup_database on a database with no indexes returns 0');
}

# Warm-up with no available worker fails, rather than silently no-opping.
{
    $node->safe_psql("postgres", "CREATE DATABASE noworkerdb;");
    $node->safe_psql("postgres",
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('noworkerdb', true);");
    my $wpid = wait_for_worker_db($node, 'noworkerdb');
    $node->safe_psql("noworkerdb", qq(
        CREATE EXTENSION vector; CREATE EXTENSION svs;
        CREATE TABLE t (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO t (val) SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 50) i;
        CREATE INDEX t_idx ON t USING vamana (val vector_l2_ops);
    ));

    # Disabling tears the worker down; warm-up then has no worker to reach.
    $node->safe_psql("postgres",
        "UPDATE vamana_databases SET enabled = false WHERE datname = 'noworkerdb';");
    for my $i (1 .. 40)
    {
        last unless $node->safe_psql("postgres",
            "SELECT count(*) FROM pg_stat_activity "
          . "WHERE backend_type = 'vamana worker' AND datname = 'noworkerdb';") > 0;
        usleep(250_000);
    }

    my ($ret, $stdout, $stderr) = $node->psql("noworkerdb",
        "SELECT svs_warmup_index('t_idx');");
    isnt($ret, 0, 'svs_warmup_index with no available worker errors');
}

# Non-invocation guard: warm-up is reachable only by explicit SQL call, never
# by an automatic path (launcher init, worker startup, idle reconcile).  On a
# primary the cache is demand-driven with no startup preload, so a fresh
# restart with zero query traffic must leave every index cold until the first
# query loads it.  Observing the worker run several idle heartbeat cycles
# without a cold-load marker proves no background path warmed it.
{
    my $guard_relid =
        $node->safe_psql("postgres", "SELECT 'warm_idx'::regclass::oid;");

    $node->restart;
    my $wpid = wait_for_worker($node);
    like($wpid, qr/^\d+$/, 'worker running after restart for non-invocation guard');

    my $log_pos = length($node->log_content());

    # Let the worker turn several idle loop iterations: a background invocation
    # would have to happen on one of them.  The heartbeat advances once per
    # loop, so waiting for it to move proves cycles elapsed.
    my $hb0 = $node->safe_psql("postgres",
        "SELECT heartbeat_ts FROM pg_stat_vamana_worker WHERE worker_pid = $wpid;");
    for my $i (1 .. 40)
    {
        usleep(250_000);
        my $hb = $node->safe_psql("postgres",
            "SELECT heartbeat_ts FROM pg_stat_vamana_worker WHERE worker_pid = $wpid;");
        last if $hb ne '' && $hb0 ne '' && $hb gt $hb0;
    }

    my $idle_log = substr($node->log_content(), $log_pos);
    unlike($idle_log, qr/loading vamana index $guard_relid/,
        'no automatic path loads the index after restart — warm-up is not auto-invoked');

    # The first query must now demand-load it, confirming it was genuinely cold
    # through all the idle cycles above rather than never observed.
    $log_pos = length($node->log_content());
    $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM warm_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));
    my $query_log = substr($node->log_content(), $log_pos);
    like($query_log, qr/loading vamana index $guard_relid/,
        'first query demand-loads the index, proving it was cold');
}

$node->stop;

# A write-kind request (including warm-up) is rejected at intake on a role
# that cannot execute writes, so it never gets stuck at PROCESSING when write
# dispatch is skipped on a standby.
{
    my $primary = PostgreSQL::Test::Cluster->new('vamana_standby_warmup_primary');
    $primary->init(allows_streaming => 1);
    $primary->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $primary->append_conf('postgresql.conf', "wal_level = logical");
    $primary->append_conf('postgresql.conf', "max_replication_slots = 10");
    $primary->append_conf('postgresql.conf', "max_wal_senders = 10");
    $primary->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
    $primary->start;

    $primary->safe_psql('postgres', "CREATE EXTENSION vector;");
    $primary->safe_psql('postgres', "CREATE EXTENSION svs;");
    $primary->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    $primary->safe_psql('postgres', qq{
        CREATE TABLE standby_warm_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO standby_warm_tbl (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 20);
        CREATE INDEX standby_warm_idx ON standby_warm_tbl USING vamana (val vector_l2_ops);
    });
    wait_for_worker($primary, 30);

    $primary->safe_psql('postgres', "CREATE ROLE unpriv LOGIN;");
    $primary->safe_psql('postgres', "GRANT SELECT ON standby_warm_tbl TO unpriv;");

    my $backup = 'standby_warmup_backup';
    $primary->backup($backup);

    my $standby = PostgreSQL::Test::Cluster->new('vamana_standby_warmup_standby');
    $standby->init_from_backup($primary, $backup, has_streaming => 1);
    $standby->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $standby->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
    $standby->append_conf('postgresql.conf', "hot_standby = on");
    $standby->start;
    $primary->wait_for_replay_catchup($standby);

    # The standby worker activates every existing index's replication slot
    # before it publishes workerPid, and that activation waits for a
    # not-yet-replayed xl_running_xacts record. Force one so it converges
    # promptly instead of waiting for the next naturally-occurring checkpoint.
    $primary->safe_psql('postgres', "SELECT pg_log_standby_snapshot();");
    $primary->wait_for_replay_catchup($standby);

    my $worker_pid = '';
    for (1 .. 100) {
        usleep(200_000);
        $worker_pid = $standby->safe_psql('postgres',
            "SELECT worker_pid FROM pg_stat_vamana_worker "
          . "WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');");
        chomp $worker_pid;
        last if $worker_pid =~ /^\d+$/;
    }
    ok($worker_pid =~ /^\d+$/, "the standby worker finishes its startup activation (pid=$worker_pid)");

    my $bg = $standby->background_psql('postgres',
        extra_params => [ '-U', 'unpriv' ], on_error_stop => 0);

    my ($out1, $err1) = $bg->query("SELECT svs_warmup_index('standby_warm_idx'::regclass);");
    is($err1, 1, 'a warm-up request on a standby fails instead of hanging forever');

    my $stuck = $standby->safe_psql('postgres',
        "SELECT count(*) FROM pg_stat_vamana_worker_slot "
      . "WHERE slot_kind = 'warmup' AND slot_status != 'empty';");
    chomp $stuck;
    is($stuck, '0', 'the warm-up request does not permanently strand its slot');

    my ($out2, $err2) = $bg->query("SELECT svs_warmup_index('standby_warm_idx'::regclass);");
    is($err2, 1, 'a second warm-up on the same backend also fails cleanly, not silently ignored');

    $bg->quit;
    $standby->stop;
    $primary->stop;
}

done_testing();
