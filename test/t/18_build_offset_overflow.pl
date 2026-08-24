# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 18_build_offset_overflow.pl — row-offset overflow in the build path.
#
# The build path fills a correctly-sized buffer using a per-vector offset
# computed as a plain int multiplication, which silently wraps once
# row_count * dimensions exceeds INT_MAX. Reaching that needs ~1.08M rows
# at the 2000-dimension cap, so this is opt-in rather than run by default.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

if (($ENV{enable_slow_tests} // 'no') ne 'yes')
{
    plan skip_all => 'set enable_slow_tests=yes to run the ~8GB row-offset overflow test';
}

{
    my $node = PostgreSQL::Test::Cluster->new('vamana_build_offset_overflow');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "maintenance_work_mem = '2GB'");
    $node->append_conf('postgresql.conf', "svs.worker_startup_timeout_ms = 600000");
    $node->start;

    $node->safe_psql('postgres', "CREATE EXTENSION vector;");
    $node->safe_psql('postgres', "CREATE EXTENSION svs;");
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    my $overflow_dim  = 2000;
    my $overflow_rows = 1_075_000;    # (dim * rows) > INT_MAX by a safe margin

    $node->safe_psql('postgres', qq(
        SET statement_timeout = 0;
        CREATE TABLE overflow_tbl (id serial PRIMARY KEY, val vector($overflow_dim));
        INSERT INTO overflow_tbl (id, val)
            SELECT i, (SELECT ARRAY_AGG(random()) FROM generate_series(1, $overflow_dim))::vector
            FROM generate_series(1, $overflow_rows) i;
    ));

    my $log_pos = length($node->log_content());
    my $build_survived = eval {
        $node->safe_psql('postgres', qq(
            SET statement_timeout = 0;
            CREATE INDEX overflow_idx ON overflow_tbl USING vamana (val vector_l2_ops);
        ));
        1;
    };
    my $build_log = substr($node->log_content(), $log_pos);

    if (!$build_survived || $build_log =~ /terminated by signal|Segmentation fault/)
    {
        fail('build does not crash once row_count * dimensions exceeds INT_MAX');
        diag("build crashed; server log:\n$build_log");
    }
    else
    {
        # A row near the end of the ID range is the one a wrapped offset
        # would have overwritten or read from the wrong location.
        my $high_id = $overflow_rows - 1;
        my $result = $node->safe_psql('postgres', qq(
            SET enable_seqscan = off;
            SELECT id FROM overflow_tbl WHERE id = $high_id
                ORDER BY val <-> (SELECT val FROM overflow_tbl WHERE id = $high_id) LIMIT 1;
        ));
        chomp $result;
        is($result, "$high_id",
            'the last row is still findable by its own vector after a build spanning the '
          . 'INT_MAX row-offset boundary');

        $node->safe_psql('postgres', "DROP TABLE overflow_tbl;");
        $node->stop;
    }
}

done_testing();
