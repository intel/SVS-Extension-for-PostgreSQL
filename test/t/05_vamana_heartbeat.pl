# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 05_vamana_heartbeat.pl — heartbeat timestamp for hung worker detection.
#
# The BGW writes heartbeat_ts to VamanaWorkerShmem each main loop iteration
# (~1 s).  Backends read it in VamanaWorkerIsAvailable: if the timestamp is
# stale, the worker is presumed hung and the backend errors out immediately
# rather than stalling for the full timeout.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

{
    my $node = PostgreSQL::Test::Cluster->new('vamana_heartbeat');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "svs.worker_database = 'postgres'");
    $node->start;

    $node->safe_psql('postgres', "CREATE EXTENSION vector;");
    $node->safe_psql('postgres', "CREATE EXTENSION svs;");

    my $hb_dim  = 4;
    my $hb_seed = join(",", ('random()') x $hb_dim);
    my $hb_qvec = join(",", map { sprintf("%.4f", rand()) } 1 .. $hb_dim);

    $node->safe_psql('postgres', qq{
        CREATE TABLE hb_tbl (id serial PRIMARY KEY, val vector($hb_dim));
        INSERT INTO hb_tbl (val)
            SELECT ARRAY[$hb_seed]::vector
            FROM generate_series(1, 50);
        CREATE INDEX ON hb_tbl USING vamana (val vector_l2_ops);
    });

    my $hb_worker_pid = wait_for_worker($node, 30);
    ok($hb_worker_pid =~ /^\d+$/, "worker running (pid=$hb_worker_pid)");

    sleep(2);

    my $hb_baseline = $node->safe_psql('postgres', qq{
        SET enable_seqscan = off;
        SELECT count(*) FROM (
            SELECT id FROM hb_tbl ORDER BY val <-> '[$hb_qvec]' LIMIT 5
        ) sub;
    });
    chomp $hb_baseline;
    ok($hb_baseline > 0, "baseline search returns results");

    my ($ts_ret, $hb_ts, $ts_err) = $node->psql('postgres',
        "SELECT heartbeat_ts FROM pg_stat_vamana_worker LIMIT 1;");
    chomp $hb_ts if defined $hb_ts;
    $hb_ts //= '';
    ok($ts_ret == 0 && $hb_ts ne '',
        'heartbeat_ts column present in pg_stat_vamana_worker and non-null'
    ) or diag("psql exit=$ts_ret err=$ts_err");

    my ($age_ret, $hb_age_s, $age_err) = $node->psql('postgres',
        "SELECT extract(epoch from (now() - heartbeat_ts))::int "
      . "FROM pg_stat_vamana_worker LIMIT 1;");
    chomp $hb_age_s if defined $hb_age_s;
    $hb_age_s //= '';
    ok($age_ret == 0 && $hb_age_s =~ /^\d+$/ && $hb_age_s <= 3,
        "heartbeat_ts is recent (age=${hb_age_s}s, expected <= 3s)"
    ) or diag("psql exit=$age_ret err=$age_err");

    $node->safe_psql('postgres',
        "ALTER SYSTEM SET svs.worker_timeout_ms = 10000;");
    $node->safe_psql('postgres', "SELECT pg_reload_conf();");
    usleep(500_000);

    $hb_worker_pid = $node->safe_psql('postgres',
        "SELECT pid FROM pg_stat_activity "
      . "WHERE backend_type = 'vamana background worker' LIMIT 1;");
    chomp $hb_worker_pid;

    kill('STOP', $hb_worker_pid);

    sleep(4);

    my ($hb_ret, undef, $hb_err);
    my $hb_elapsed;
    eval {
        my $t0 = time();
        ($hb_ret, undef, $hb_err) = $node->psql('postgres', qq{
            SET enable_seqscan = off;
            SELECT id FROM hb_tbl ORDER BY val <-> '[$hb_qvec]' LIMIT 5;
        });
        $hb_elapsed = time() - $t0;
    };

    kill('CONT', $hb_worker_pid);

    $hb_elapsed //= 99;
    $hb_err     //= '';

    ok($hb_elapsed < 3,
        "query errors out quickly when heartbeat is stale "
      . "(elapsed=${hb_elapsed}s, expected < 3s; worker_timeout_ms=10000)");

    like($hb_err,
        qr/vamana background worker unavailable/i,
        "error message indicates worker is unavailable");

    $node->safe_psql('postgres',
        "ALTER SYSTEM RESET svs.worker_timeout_ms;");
    $node->safe_psql('postgres', "SELECT pg_reload_conf();");

    $node->stop;
}

done_testing();
