# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 33_launcher_truncate_bypass.pl -- TRUNCATE vamana_databases must be
# rejected while a vamana index still exists, exactly like DELETE, so an
# index's on-disk save directory and WAL-retaining replication slot are
# never orphaned by wiping the catalog out from under it.
#
# Code under test: sql/svs--0.1.0.sql (the new BEFORE TRUNCATE trigger),
#                   src/vamana_databases.c
#                   (vamana_databases_reject_truncate_with_live_indexes)
#
# TRUNCATE bypasses row-level triggers entirely, so the pre-existing BEFORE
# DELETE FOR EACH ROW guard (vamana_databases_reject_delete_with_live_indexes)
# never fires for it. The table owner also retains TRUNCATE regardless of
# REVOKE TRUNCATE ... FROM PUBLIC.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

my $node = PostgreSQL::Test::Cluster->new('truncate_bypass');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 10");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres',
    "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

my $worker_pid = wait_for_worker_db($node, 'postgres', 40);
ok($worker_pid =~ /^\d+$/, "worker running (pid=$worker_pid)");

$node->safe_psql('postgres', qq{
    CREATE TABLE t33 (id serial PRIMARY KEY, val vector($dim));
    INSERT INTO t33 (val)
        SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 200) i;
    CREATE INDEX i33 ON t33 USING vamana (val vector_l2_ops);
});

my $relid = $node->safe_psql('postgres', "SELECT 'i33'::regclass::oid;");
chomp $relid;
my $save_dir = vamana_save_dir($node, 'postgres', $relid);
ok(-d $save_dir, "index save directory exists ($save_dir)");

my $slots = $node->safe_psql('postgres',
    "SELECT count(*) FROM pg_replication_slots WHERE slot_name LIKE 'vamana_%';");
chomp $slots;
cmp_ok($slots, '>=', 1, "the index's replication slot exists ($slots slot(s))");

my $index_count = $node->safe_psql('postgres',
    "SELECT index_count FROM pg_stat_vamana_worker "
  . "WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = current_database());");
chomp $index_count;
is($index_count, '1', 'the shmem live-index counter the guard reads says 1');

# ---------------------------------------------------------------------------
# TRUNCATE is rejected, exactly like DELETE.
# ---------------------------------------------------------------------------
{
    my ($del_rc, undef, $del_err) = $node->psql('postgres',
        "DELETE FROM vamana_databases WHERE datname = 'postgres';");
    isnt($del_rc, 0, 'DELETE is still correctly rejected while a vamana index exists');
    like($del_err, qr/cannot remove "postgres" from vamana_databases: 1 vamana index\(es\) still exist/,
        'DELETE rejection names the live index count');

    my $log_pos = length($node->log_content());

    my ($rc, undef, $err) = $node->psql('postgres', "TRUNCATE vamana_databases;");

    isnt($rc, 0, 'TRUNCATE is rejected while a vamana index still exists');
    like($err, qr/cannot truncate vamana_databases: 1 vamana index\(es\) still exist in database "postgres"/,
        'the rejection names the database and its live index count');
    like($err, qr/run svs_teardown_database\(\) in "postgres" first/,
        'the rejection gives the actionable teardown hint');

    my $rows = $node->safe_psql('postgres', "SELECT count(*) FROM vamana_databases;");
    chomp $rows;
    isnt($rows, '0', 'the row survives -- nothing was wiped');

    ok(-d $save_dir, 'the index save directory is still intact');

    my $orphan_slots = $node->safe_psql('postgres',
        "SELECT count(*) FROM pg_replication_slots WHERE slot_name LIKE 'vamana_%';");
    chomp $orphan_slots;
    cmp_ok($orphan_slots, '>=', 1, 'the replication slot is still intact');

    # Nothing should have been disrupted: the worker is still alive and no
    # shutdown was logged.
    usleep(1_000_000);
    my $log = substr($node->log_content(), $log_pos);
    my $alive = kill(0, $worker_pid) ? 1 : 0;
    is($alive, 1, 'the worker is still alive after the rejected TRUNCATE');
    unlike($log, qr/vamana background worker shutting down/,
        'no shutdown was triggered by the rejected TRUNCATE');
}

# ---------------------------------------------------------------------------
# Once the index is torn down, TRUNCATE is allowed again.
# ---------------------------------------------------------------------------
{
    $node->safe_psql('postgres', "SELECT dropped FROM svs_teardown_database();");

    my $index_count_after = $node->safe_psql('postgres',
        "SELECT index_count FROM pg_stat_vamana_worker "
      . "WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = current_database());");
    chomp $index_count_after;
    is($index_count_after, '0', 'no vamana indexes remain after teardown');

    my ($rc, $out, $err) = $node->psql('postgres', "TRUNCATE vamana_databases;");
    is($rc, 0, 'TRUNCATE now succeeds once no vamana indexes remain')
      or diag($err);
}

$node->stop;

done_testing();
