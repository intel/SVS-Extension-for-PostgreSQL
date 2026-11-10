# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 71_teardown_rr_snapshot_split.pl -- deterministic concurrency test for
# svs_teardown_database()'s enumeration against a transaction that opened
# before a concurrent DROP INDEX committed.
#
# svs_teardown_database() enumerates every vamana index in the current
# database with one read-only SPI query, then resolves each index's
# relation and schema name by OID (EnumerateVamanaIndexes() in
# src/vamana_teardown.c). Under REPEATABLE READ, the enumeration query runs
# under the session's transaction snapshot, which can be fixed well before
# a later statement in that same transaction. If an index is dropped and
# committed by another session in between, and the enumeration's
# transaction snapshot still predates that drop while the later name
# resolution does not, the resolution can be asked to name a relation that
# no longer exists. This test interleaves exactly that: an unprivileged
# session opens a transaction, takes its snapshot with an initial
# statement, waits for another session to drop one index and commit, then
# calls svs_teardown_database() as a later statement in the same still-open
# transaction. It asserts the server stays up and that the vanished index
# produces no result row while an unrelated, undroppable index still
# reports its normal ownership-failure row. A READ COMMITTED run of the
# same interleaving is included as a control.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('teardown_rr_snapshot_split');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_wal_senders = 4");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres',
    "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

$node->safe_psql('postgres',
    "CREATE ROLE teardown_rr_reader LOGIN;"
  . "GRANT CONNECT ON DATABASE postgres TO teardown_rr_reader;");

$node->safe_psql('postgres', "CREATE TABLE trr_victim (id serial primary key, v vector(3));");
$node->safe_psql('postgres',
    "INSERT INTO trr_victim (v) SELECT ARRAY[random(),random(),random()]::vector(3) "
  . "FROM generate_series(1, 20);");

$node->safe_psql('postgres', "CREATE TABLE trr_control (id serial primary key, v vector(3));");
$node->safe_psql('postgres',
    "INSERT INTO trr_control (v) SELECT ARRAY[random(),random(),random()]::vector(3) "
  . "FROM generate_series(1, 20);");
$node->safe_psql('postgres',
    "CREATE INDEX trr_control_idx ON trr_control USING vamana (v vector_l2_ops);");

for my $case (
    { label => 'REPEATABLE READ', begin => 'BEGIN ISOLATION LEVEL REPEATABLE READ;' },
    { label => 'READ COMMITTED',  begin => 'BEGIN ISOLATION LEVEL READ COMMITTED;' },
  )
{
    my $label = $case->{label};

    $node->safe_psql('postgres',
        "CREATE INDEX trr_victim_idx ON trr_victim USING vamana (v vector_l2_ops);");

    my $log_pos = length($node->log_content());

    my $session_a = $node->background_psql('postgres',
        connstr => $node->connstr('postgres') . " user=teardown_rr_reader");
    my $session_b = $node->background_psql('postgres');

    $session_a->query_until(qr/snap_done\n/,
        $case->{begin} . " SELECT 1; \\echo snap_done\n");

    $session_b->query_until(qr/drop_done\n/,
        "DROP INDEX trr_victim_idx; \\echo drop_done\n");

    my $result = $session_a->query_until(qr/teardown_done\n/,
        "SELECT index_name, dropped FROM svs_teardown_database() "
      . "ORDER BY index_name; \\echo teardown_done\n");

    $session_a->query_until(qr/commit_done\n/, "COMMIT; \\echo commit_done\n");

    $session_a->quit;
    $session_b->quit;

    my $log = substr($node->log_content(), $log_pos);
    my @sig_lines = ($log =~ /(.*terminated by signal.*)/g);

    is(scalar(@sig_lines), 0, "[$label] no backend crash in the server log");

    my $alive = $node->safe_psql('postgres', "SELECT 1;");
    is($alive, '1', "[$label] the server stays reachable after the interleaving");

    unlike($result, qr/trr_victim_idx/,
        "[$label] the concurrently-dropped index produces no result row");

    like($result, qr/trr_control_idx\s*\|\s*f/,
        "[$label] the unrelated, undroppable index still reports its normal "
      . "ownership-failure row");

    # Clean up in case the fix skipped the victim's drop; the index is
    # already gone from the owner's successful DROP INDEX above in the
    # pre-fix case, but a reverted-fix run that crashed never reaches here.
    $node->safe_psql('postgres', "DROP INDEX IF EXISTS trr_victim_idx;");
}

$node->stop;

done_testing();
