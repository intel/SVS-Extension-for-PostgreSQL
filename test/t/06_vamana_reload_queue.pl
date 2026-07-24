# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 06_vamana_reload_queue.pl — reload_all overflow when the per-OID reload
# queue is full.
#
# VAMANA_MAX_RELOAD_QUEUE is 16.  When 17 distinct index OIDs are enqueued
# before the worker drains any, VamanaWorkerSignalReload exhausts the CAS
# slots and sets reload_all=1 so no reload is silently dropped.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

my $N_TABLES = 17;    # one more than VAMANA_MAX_RELOAD_QUEUE (16)

{
    my $node = PostgreSQL::Test::Cluster->new('vamana_reload_queue');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 16");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "svs.worker_database = 'postgres'");
    $node->start;

    $node->safe_psql('postgres', "CREATE EXTENSION vector;");
    $node->safe_psql('postgres', "CREATE EXTENSION svs;");

    for my $i (0 .. $N_TABLES - 1)
    {
        $node->safe_psql('postgres', qq{
            CREATE TABLE rq_tbl_$i (id serial PRIMARY KEY, val vector($dim));
            INSERT INTO rq_tbl_$i (val)
                SELECT ARRAY[$array_sql]::vector
                FROM generate_series(1, 10);
            CREATE INDEX ON rq_tbl_$i USING vamana (val vector_l2_ops);
        });
    }

    my $worker_pid = wait_for_worker($node, 30);
    ok($worker_pid =~ /^\d+$/, "worker running (pid=$worker_pid)");

    sleep(2);

    for my $i (0 .. $N_TABLES - 1)
    {
        $node->safe_psql('postgres', qq{
            SET enable_seqscan = off;
            SELECT id FROM rq_tbl_$i ORDER BY val <-> '[$query_sql]' LIMIT 1;
        });
    }

    my $before = $node->safe_psql('postgres',
        "SELECT reload_all FROM pg_stat_vamana_worker LIMIT 1;");
    chomp $before;
    ok($before eq 'f', 'reload_all starts false');

    kill('STOP', $worker_pid);

    for my $i (0 .. $N_TABLES - 1)
    {
        $node->safe_psql('postgres', "TRUNCATE rq_tbl_$i;");
    }

    my $after = $node->safe_psql('postgres',
        "SELECT reload_all FROM pg_stat_vamana_worker LIMIT 1;");
    chomp $after;
    ok($after eq 't',
        'reload_all set after queue overflow (17 TRUNCATEs against 16-slot queue)');

    kill('CONT', $worker_pid);

    my $cleared = 0;
    for my $attempt (1 .. 60)
    {
        usleep(500_000);
        my $flag = $node->safe_psql('postgres',
            "SELECT reload_all FROM pg_stat_vamana_worker LIMIT 1;");
        chomp $flag;
        if ($flag eq 'f')
        {
            $cleared = 1;
            last;
        }
    }
    ok($cleared, 'reload_all cleared after worker resumes');

    my $nonempty = 0;
    for my $i (0 .. $N_TABLES - 1)
    {
        my $cnt = $node->safe_psql('postgres', qq{
            SET enable_seqscan = off;
            SELECT count(*) FROM (
                SELECT id FROM rq_tbl_$i
                ORDER BY val <-> '[$query_sql]' LIMIT 5
            ) sub;
        });
        chomp $cnt;
        $nonempty++ if $cnt ne '0';
    }
    ok($nonempty == 0,
        'all 17 indexes return 0 results after TRUNCATE and reload');

    $node->stop;
}

done_testing();
