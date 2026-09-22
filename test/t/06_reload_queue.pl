# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 06_reload_queue.pl — evict_all fallback when the per-OID reload
# queue overflows.
#
# VAMANA_MAX_RELOAD_QUEUE is 16.  When 17 distinct index OIDs are enqueued
# before the worker drains any, VamanaWorkerSignalReload exhausts the CAS
# slots and sets evict_all=1.  The worker evicts its whole cache and each
# index reloads on its next request, so no invalidation is silently dropped.

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

# A subset of the 17 tables is enough to exercise the query and post-drain
# result-check loops together with the reload-queue overflow itself.
my $N_QUERY_TABLES = 8;

{
    my $node = PostgreSQL::Test::Cluster->new('vamana_reload_queue');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 16");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
    $node->start;

    $node->safe_psql('postgres', "CREATE EXTENSION vector;");
    $node->safe_psql('postgres', "CREATE EXTENSION svs;");
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

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

    for my $i (0 .. $N_QUERY_TABLES - 1)
    {
        $node->safe_psql('postgres', qq{
            SET enable_seqscan = off;
            SELECT id FROM rq_tbl_$i ORDER BY val <-> '[$query_sql]' LIMIT 1;
        });
    }

    my $before = $node->safe_psql('postgres',
        "SELECT evict_all FROM pg_stat_vamana_worker LIMIT 1;");
    chomp $before;
    ok($before eq 'f', 'evict_all starts false');

    kill('STOP', $worker_pid);

    for my $i (0 .. $N_TABLES - 1)
    {
        $node->safe_psql('postgres', "TRUNCATE rq_tbl_$i;");
    }

    my $after = $node->safe_psql('postgres',
        "SELECT evict_all FROM pg_stat_vamana_worker LIMIT 1;");
    chomp $after;
    ok($after eq 't',
        'evict_all set after queue overflow (17 TRUNCATEs against 16-slot queue)');

    kill('CONT', $worker_pid);

    my $cleared = 0;
    for my $attempt (1 .. 60)
    {
        usleep(500_000);
        my $flag = $node->safe_psql('postgres',
            "SELECT evict_all FROM pg_stat_vamana_worker LIMIT 1;");
        chomp $flag;
        if ($flag eq 'f')
        {
            $cleared = 1;
            last;
        }
    }
    ok($cleared, 'evict_all cleared after worker resumes');

    # The evict_all handler returns before draining the per-OID reload queue
    # (vamanaworker.c VamanaWorkerProcessReloads), so the 16 relids already
    # queued when the 17th signal tripped evict_all are still sitting there.
    # The worker's very next cycle drains all 16 through the per-OID loop.
    # Confirm it survives draining that many distinct indexes in one pass.
    my $pid_after_overflow = $node->safe_psql('postgres',
        "SELECT pid FROM pg_stat_activity "
      . "WHERE backend_type = 'vamana worker' LIMIT 1;");
    chomp $pid_after_overflow;
    is($pid_after_overflow, $worker_pid,
        'worker survived the queue-overflow drain (same pid, no crash-restart)');

    my $hb1 = $node->safe_psql('postgres',
        "SELECT extract(epoch from heartbeat_ts) FROM pg_stat_vamana_worker LIMIT 1;");
    chomp $hb1;
    sleep(2);
    my $hb2 = $node->safe_psql('postgres',
        "SELECT extract(epoch from heartbeat_ts) FROM pg_stat_vamana_worker LIMIT 1;");
    chomp $hb2;
    ok($hb2 > $hb1, 'worker heartbeat advances after the overflow drain');

    # Restrict the crash check to the per-database worker itself: a normal
    # $node->stop() later in this test logs unrelated "vamana launcher" and
    # "logical replication launcher" background-worker exits at shutdown,
    # which also read "exited with exit code 1" and are not a crash.
    my $log = slurp_file($node->logfile);
    unlike($log, qr/background worker "vamana worker[^"]*".*exited with exit code 1/,
        'no worker crash-exit in the server log');
    unlike($log, qr/Segmentation fault/,
        'no segfault in the server log');
    unlike($log, qr/vamana worker: failed to load index \d+/,
        'draining 16 distinct indexes in one pass loads every one, none refused');

    my $nonempty = 0;
    for my $i (0 .. $N_QUERY_TABLES - 1)
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
        'queried indexes return 0 results after TRUNCATE and reload');

    $node->stop;
}

done_testing();
