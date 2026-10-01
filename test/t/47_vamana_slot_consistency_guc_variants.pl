# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL
#
# 47_vamana_slot_consistency_guc_variants.pl — regression test: confirms the
# fix in VamanaWorkerGetOrLoadIndex (src/vamanaworkerindex.c) holds at
# default checkpoint GUCs, not just under the aggressive settings
# 46_vamana_slot_consistency_crash_recall.pl uses. Before the fix, a crash
# right after an insert lost rows even with svs.checkpoint_min_ops at its
# default of 10000 and svs.checkpoint_debounce_window at its default of 300s
# -- i.e. with zero checkpoint activity of any kind, because the loss is
# caused by the index's replication slot not yet having reached its initial
# CONSISTENT point, not by anything checkpoint-related. See the comment
# above VamanaWorkerGetOrLoadIndex in src/vamanaworkerindex.c for the full
# mechanism.
#
# D1: true defaults, insert 5 rows, crash immediately (no wait).
# D2: checkpoint_debounce_window=1 alone (min_ops stays default 10000):
#     insert 5 rows, wait past the 1s debounce, crash. Uses 5 rows, not a
#     count near the default ~100-row search window, so the assertions
#     can actually detect loss.
# D3: checkpoint_min_ops=1 alone (debounce stays default 300s): insert 5
#     rows, crash immediately (no wait).

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

sub build_node
{
    my ($name, @extra_conf) = @_;
    my $node = PostgreSQL::Test::Cluster->new($name);
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
    $node->append_conf('postgresql.conf', "fsync = on");
    $node->append_conf('postgresql.conf', "svs.worker_timeout_ms = 30000");
    $node->append_conf('postgresql.conf', $_) for @extra_conf;
    $node->start;
    $node->safe_psql('postgres', "CREATE EXTENSION vector;");
    $node->safe_psql('postgres', "CREATE EXTENSION svs;");
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname) VALUES ('postgres');");
    wait_for_worker_db($node, 'postgres', 40);
    return $node;
}

sub run_variant
{
    my ($label, $quiet_wait_s, @extra_conf) = @_;

    my $node = build_node("r9_guc_$label", @extra_conf);
    $node->safe_psql('postgres', qq{
        CREATE TABLE d_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO d_tbl (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 50);
        CREATE INDEX d_idx ON d_tbl USING vamana (val vector_l2_ops);
    });
    wait_for_worker_db($node, 'postgres', 30);

    $node->safe_psql('postgres', qq{
        INSERT INTO d_tbl (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 5);
    });
    my $rows = 55;

    sleep($quiet_wait_s) if $quiet_wait_s > 0;

    $node->stop('immediate');
    $node->start;
    wait_for_worker_db($node, 'postgres', 30);

    my $search_sql = qq{
        SET enable_seqscan = off;
        SELECT count(*), count(DISTINCT id) FROM (
            SELECT id FROM d_tbl ORDER BY val <-> '[$query_sql]'
            LIMIT 100000
        ) s;
    };
    my ($total, $distinct) = ('', '');
    for (1 .. 120)
    {
        my $c = $node->safe_psql('postgres', $search_sql);
        chomp $c;
        ($total, $distinct) = split(/\|/, $c);
        last if $distinct eq "$rows" && $total eq "$rows";
        usleep(500_000);
    }
    is($total, $distinct, "$label: no duplicate TIDs");
    is($distinct, $rows, "$label: full recall ($rows rows) after the crash")
        or diag("$label: got total=$total distinct=$distinct");

    $node->stop;
}

run_variant('d1_true_defaults', 0);
run_variant('d2_debounce1_alone', 2, "svs.checkpoint_debounce_window = 1");
run_variant('d3_minops1_alone', 0, "svs.checkpoint_min_ops = 1");

done_testing();
