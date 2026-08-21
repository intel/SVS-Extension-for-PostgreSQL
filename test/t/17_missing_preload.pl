# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 17_missing_preload.pl — svs loaded without shared_preload_libraries.
#
# CREATE EXTENSION svs succeeds even without preload; VamanaWorkerShmemHeaderPtr
# stays NULL. Three independent SQL paths reach it afterward: the stats views,
# the precommit reservation trigger on vamana_databases, and CREATE INDEX's
# up-front database-enabled check. Each must fail with a clean ERROR, not
# crash the backend.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

# Start a node without svs in shared_preload_libraries, then run $setup_sql
# (via safe_psql, expected to succeed) followed by $trigger_sql (via psql, the
# statement under test). Assert $trigger_sql fails cleanly rather than
# crashing the backend.
#
# Each case gets its own node: restart_after_crash defaults to off for TAP
# nodes, so a crashed postmaster in one case never comes back for the next.
sub run_case
{
    my ($name, $setup_sql, $trigger_sql, $desc) = @_;

    my $node = PostgreSQL::Test::Cluster->new($name);
    $node->init;
    $node->start;
    $node->safe_psql('postgres', 'CREATE EXTENSION vector;');
    $node->safe_psql('postgres', 'CREATE EXTENSION svs;');

    my $log_offset = $node->wait_for_log(qr/database system is ready to accept connections/);

    $node->safe_psql('postgres', $setup_sql) if defined $setup_sql;

    my (undef, undef, $stderr) = $node->psql('postgres', $trigger_sql);

    like($stderr, qr/vamana shared worker state is not initialized/,
        "$desc: reports a clean error");

    my $crashed = $node->log_contains(
        qr/terminated by signal|server closed the connection unexpectedly/,
        $log_offset);

    ok(!$crashed, "$desc: does not crash the backend");

    $node->stop unless $crashed;
}

run_case('vamana_no_preload_stats', undef,
    'SELECT * FROM pg_stat_vamana_worker;',
    'pg_stat_vamana_worker without preload');

run_case('vamana_no_preload_reserve',
    q{INSERT INTO vamana_databases (datname, enabled) VALUES (current_database(), false);},
    q{UPDATE vamana_databases SET enabled = true WHERE datname = current_database();},
    'enabling a database without preload');

run_case('vamana_no_preload_build', <<'SQL',
CREATE TABLE np_tbl (id serial PRIMARY KEY, val vector(4));
INSERT INTO np_tbl (val) VALUES ('[1,2,3,4]'), ('[4,3,2,1]');
SQL
    'CREATE INDEX np_idx ON np_tbl USING vamana (val vector_l2_ops);',
    'building a vamana index without preload');

done_testing();
