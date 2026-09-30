# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL
#
# 49_vamana_slot_consistency_repeat_crash.pl — regression test for is#191
# (R9): a second crash landing in the fresh, not-yet-consistent slot that the
# fix's own heap rebuild creates.
#
# The fix in VamanaWorkerGetOrLoadIndex (src/vamanaworkerindex.c) recovers a
# crash that landed before the original slot reached CONSISTENT by rebuilding
# from the heap, which creates a brand-new replication slot as part of its
# normal build path. That new slot has exactly the same kind of
# not-yet-CONSISTENT window the original one did. This test crashes a SECOND
# time, before the rebuild-created slot has had a chance to reach
# consistency, with more rows inserted in between, and confirms nothing is
# lost across either recovery. Without the fix's per-load (not per-relid)
# check, a naive "only check once" implementation would pass the first crash
# but fail this one.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

my $node = PostgreSQL::Test::Cluster->new('r9_repeat_crash');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 10");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->append_conf('postgresql.conf', "fsync = on");
$node->append_conf('postgresql.conf', "svs.worker_timeout_ms = 30000");
$node->append_conf('postgresql.conf', "svs.checkpoint_min_ops = 1");
$node->append_conf('postgresql.conf', "svs.checkpoint_debounce_window = 1");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres',
    "INSERT INTO vamana_databases (datname) VALUES ('postgres');");
wait_for_worker_db($node, 'postgres', 40);

$node->safe_psql('postgres', qq{
    CREATE TABLE rc_tbl (id serial PRIMARY KEY, val vector($dim));
    INSERT INTO rc_tbl (val)
        SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 50);
    CREATE INDEX rc_idx ON rc_tbl USING vamana (val vector_l2_ops);
});
wait_for_worker_db($node, 'postgres', 30);

my $search_sql = qq{
    SET enable_seqscan = off;
    SELECT count(*), count(DISTINCT id) FROM (
        SELECT id FROM rc_tbl ORDER BY val <-> '[$query_sql]'
        LIMIT 100000
    ) s;
};
sub counts
{
    my $c = $node->safe_psql('postgres', $search_sql);
    chomp $c;
    return split(/\|/, $c);
}
sub wait_for_full_recall
{
    my ($rows) = @_;
    my ($total, $distinct) = ('', '');
    for (1 .. 120)
    {
        ($total, $distinct) = counts();
        last if $distinct eq "$rows" && $total eq "$rows";
        usleep(500_000);
    }
    return ($total, $distinct);
}

# First crash: lands before rc_idx's original slot ever reaches CONSISTENT.
# This is exactly 56_'s round 1 shape, triggering the fix's heap rebuild.
$node->safe_psql('postgres', qq{
    INSERT INTO rc_tbl (val)
        SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 5);
});
$node->stop('immediate');
$node->start;
wait_for_worker_db($node, 'postgres', 30);

my ($total1, $distinct1) = wait_for_full_recall(55);
is($total1, $distinct1, 'first recovery: no duplicate TIDs');
is($distinct1, 55, "first recovery: full recall after the fix's heap rebuild")
    or diag("first recovery: got total=$total1 distinct=$distinct1");

# Second crash: immediately after, before the rebuild-created slot has had
# any real chance to reach CONSISTENT (no wait_for a consistency signal here
# -- that is the point: this crash targets the NEW slot's own fresh window).
$node->safe_psql('postgres', qq{
    INSERT INTO rc_tbl (val)
        SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 5);
});
$node->stop('immediate');
$node->start;
wait_for_worker_db($node, 'postgres', 30);

my ($total2, $distinct2) = wait_for_full_recall(60);
is($total2, $distinct2, 'second recovery: no duplicate TIDs');
is($distinct2, 60,
    "second recovery: full recall after a SECOND crash in the rebuild-created slot's own window")
    or diag("second recovery: got total=$total2 distinct=$distinct2");

$node->stop;
done_testing();
