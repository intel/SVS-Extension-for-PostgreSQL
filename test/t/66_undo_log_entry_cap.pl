# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 66_undo_log_entry_cap.pl - svs.undo_log_max_entries bounds per-transaction
# undo-log memory independently of residency and build-memory budgets.
#
# Claim under test: a dedicated GUC rejects an INSERT once the current
# transaction's undo log has recorded svs.undo_log_max_entries entries, by
# refusing the statement in VamanaUndoReserve before the worker ever applies
# the insert to the graph. The cap counts array->count, not live entries, so
# entries pruned by ROLLBACK TO SAVEPOINT still hold the count down. The cap
# fires independently of residency_memory: a database with a far larger
# residency budget still hits the undo cap first.
#
# The GUC's production default (1,048,576 entries) is far too slow to drive
# to in a TAP test, so every case here lowers it to 1000 for the session,
# which exercises the same code path at the same cost as any other count.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

my $node = PostgreSQL::Test::Cluster->new('undo_log_entry_cap');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 10");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "max_worker_processes = 64");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->append_conf('postgresql.conf', "svs.max_search_work_mem = '1GB'");
$node->append_conf('postgresql.conf', "svs.max_residency_memory = '1024MB'");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");

my $CAP = 1000;

# ---------------------------------------------------------------------------
# enroll_fresh_db: create a fresh database, install both extensions, seed a
# small vamana index, and enroll it (from svs.launcher_database) so each
# trial below gets its own independent residency and undo-log accounting.
# ---------------------------------------------------------------------------
sub enroll_fresh_db
{
    my ($dbname, $seed_rows, $residency_mb_override) = @_;

    $node->safe_psql('postgres', "DROP DATABASE IF EXISTS $dbname;");
    $node->safe_psql('postgres', "CREATE DATABASE $dbname;");
    $node->safe_psql($dbname, "CREATE EXTENSION vector;");
    $node->safe_psql($dbname, "CREATE EXTENSION svs;");

    my $residency_sql = defined($residency_mb_override)
      ? "$residency_mb_override"
      : "NULL";
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled, residency_memory) "
      . "VALUES ('$dbname', true, $residency_sql);");
    my $pid = wait_for_worker_db($node, $dbname, 40);

    $node->safe_psql($dbname, "CREATE TABLE t (id bigint, v vector($dim));");
    if ($seed_rows > 0)
    {
        $node->safe_psql($dbname, insert_rows_sql(1, $seed_rows));
    }
    $node->safe_psql($dbname,
        "CREATE INDEX t_idx ON t USING vamana (v vector_l2_ops);");

    return $pid;
}

sub insert_rows_sql
{
    my ($lo, $hi) = @_;
    return "INSERT INTO t SELECT g, ARRAY[$array_sql]::vector($dim) "
      . "FROM generate_series($lo,$hi) g;";
}

sub row_count
{
    my ($dbname) = @_;
    my $n = $node->safe_psql($dbname, "SELECT count(*) FROM t;");
    chomp $n;
    return $n + 0;
}

# ===========================================================================
# Cases 1-5, 7: single database, cap lowered to $CAP for the session.
# ===========================================================================
diag("=== Cases 1-5, 7: core cap enforcement on one database ===");

my $worker_pid = enroll_fresh_db('undocap', 10, undef);

{
    my $bg = $node->background_psql('undocap', on_error_stop => 0);
    $bg->query_safe("SET svs.undo_log_max_entries = $CAP;");

    # --- Case 1: exactly $CAP inserts in one transaction commits cleanly. ---
    $bg->query_safe("BEGIN;");
    $bg->query_safe(insert_rows_sql(1, $CAP));
    $bg->query_safe("COMMIT;");
    is(row_count('undocap'), 10 + $CAP,
        "case 1: exactly \$CAP inserts in one transaction commits, all rows present");

    # --- Case 2: $CAP + 1 is rejected, at the pre-submit check. ---
    $bg->query_safe("\\set VERBOSITY verbose");
    $bg->query_safe("BEGIN;");
    $bg->query_safe(insert_rows_sql(1, $CAP));
    my $out = $bg->query(insert_rows_sql($CAP + 1, $CAP + 1));
    my $err = $bg->{stderr} // '';
    like($err, qr/svs\.undo_log_max_entries/,
        "case 2: cap+1 insert rejected, error names the GUC");
    like($err, qr/LOCATION:\s*VamanaUndoReserve/,
        "case 2: rejection happens in VamanaUndoReserve, not after the worker applied it");
    $bg->{stderr} = '';
    $bg->query_safe("\\set VERBOSITY default");
    $bg->query_safe("ROLLBACK;");

    # --- Case 3: rejected transaction's rows are gone; session still usable. ---
    is(row_count('undocap'), 10 + $CAP,
        "case 3: rows from the rejected transaction are absent after ROLLBACK");
    $bg->query_safe("BEGIN;");
    $bg->query_safe(insert_rows_sql(100000, 100004));
    $bg->query_safe("COMMIT;");
    is(row_count('undocap'), 10 + $CAP + 5,
        "case 3: session is usable afterward, a small transaction still commits");

    # --- Case 4: the cap accumulates across statements, not just within one. ---
    $bg->query_safe("BEGIN;");
    $bg->query_safe(insert_rows_sql(200000, 200000 + int(0.6 * $CAP) - 1));
    my $out2 = $bg->query(insert_rows_sql(300000, 300000 + int(0.6 * $CAP) - 1));
    my $err2 = $bg->{stderr} // '';
    like($err2, qr/svs\.undo_log_max_entries/,
        "case 4: a second statement that pushes the running total past the cap is rejected");
    $bg->{stderr} = '';
    $bg->query_safe("ROLLBACK;");
    is(row_count('undocap'), 10 + $CAP + 5,
        "case 4: the whole accumulating transaction rolled back, no partial rows");

    # --- Case 5: pruned (ROLLBACK TO SAVEPOINT) entries still count toward the cap. ---
    $bg->query_safe("BEGIN;");
    $bg->query_safe("SAVEPOINT sp1;");
    $bg->query_safe(insert_rows_sql(400000, 400000 + 399));
    $bg->query_safe("ROLLBACK TO sp1;");
    $bg->query_safe("SAVEPOINT sp2;");
    $bg->query_safe(insert_rows_sql(500000, 500000 + 399));
    $bg->query_safe("ROLLBACK TO sp2;");
    # 800 entries recorded so far (none live). 200 more reaches exactly $CAP.
    $bg->query_safe(insert_rows_sql(600000, 600000 + 199));
    my $out3 = $bg->query(insert_rows_sql(700000, 700000));
    my $err3 = $bg->{stderr} // '';
    like($err3, qr/svs\.undo_log_max_entries/,
        "case 5: one more insert after two SAVEPOINT/ROLLBACK TO cycles still hits the cap "
      . "(the array is never compacted)");
    $bg->{stderr} = '';
    $bg->query_safe("ROLLBACK;");
    is(row_count('undocap'), 10 + $CAP + 5,
        "case 5: nothing from the savepoint trial was committed");

    $bg->quit;
}

# --- Case 7: the worker survived every rejection above, and the index still works. ---
{
    my $pid_now = $node->safe_psql('postgres',
        "SELECT pid FROM pg_stat_activity "
      . "WHERE backend_type = 'vamana worker' AND datname = 'undocap';");
    chomp $pid_now;
    is($pid_now, $worker_pid,
        "case 7: worker pid is unchanged after repeated cap rejections");

    my $hits = $node->safe_psql('undocap',
        "SELECT count(*) FROM (SELECT id FROM t ORDER BY v <-> "
      . "(SELECT v FROM t LIMIT 1) LIMIT 5) s;");
    chomp $hits;
    is($hits, 5, "case 7: index scan still returns results after the rejections");
}

# ===========================================================================
# Case 6: budget independence. A second database with a much larger
# residency budget still hits the (same, small) undo cap first, and
# residency_bytes_committed at the error is far under that larger budget.
# ===========================================================================
diag("=== Case 6: cap fires independently of a much larger residency budget ===");

enroll_fresh_db('undocap_bigbudget', 10, 400);

{
    my $bg = $node->background_psql('undocap_bigbudget', on_error_stop => 0);
    $bg->query_safe("SET svs.undo_log_max_entries = $CAP;");
    $bg->query_safe("BEGIN;");
    $bg->query_safe(insert_rows_sql(1, $CAP));
    my $out = $bg->query(insert_rows_sql($CAP + 1, $CAP + 1));
    my $err = $bg->{stderr} // '';
    like($err, qr/svs\.undo_log_max_entries/,
        "case 6: cap still fires at the same count against a 400MB residency budget");
    $bg->{stderr} = '';
    $bg->query_safe("ROLLBACK;");
    $bg->quit;
}

my $residency_row = $node->safe_psql('postgres',
    "SELECT residency_bytes_committed, residency_memory_limit "
  . "FROM pg_stat_vamana_worker w JOIN pg_database d ON d.oid = w.db_oid "
  . "WHERE d.datname = 'undocap_bigbudget';");
chomp $residency_row;
my ($committed, $limit) = split(/\|/, $residency_row);
cmp_ok($committed + 0, '<', ($limit + 0) * 0.5,
    "case 6: residency_bytes_committed stayed well under the much larger "
  . "residency_memory_limit, so the undo cap -- not the residency budget --"
  . " is what stopped this transaction");

# ===========================================================================
# Case 8: GUC bounds and privilege.
# ===========================================================================
diag("=== Case 8: svs.undo_log_max_entries range bounds and privilege ===");

{
    my ($rc, $out, $err) =
      $node->psql('undocap', "SET svs.undo_log_max_entries = 15;");
    isnt($rc, 0, "case 8: 15 (below the minimum of 16) is rejected");

    ($rc, $out, $err) =
      $node->psql('undocap', "SET svs.undo_log_max_entries = 16;");
    is($rc, 0, "case 8: 16 (the minimum) is accepted");

    ($rc, $out, $err) =
      $node->psql('undocap', "SET svs.undo_log_max_entries = 16777217;");
    isnt($rc, 0, "case 8: 16777217 (above the maximum of 16777216) is rejected");

    ($rc, $out, $err) =
      $node->psql('undocap', "SET svs.undo_log_max_entries = 16777216;");
    is($rc, 0, "case 8: 16777216 (the maximum) is accepted");
}

{
    $node->safe_psql('undocap', "CREATE ROLE undocap_user LOGIN;");
    $node->safe_psql('undocap', "GRANT INSERT, SELECT ON t TO undocap_user;");

    my ($rc, $out, $err) = $node->psql('undocap',
        "SET svs.undo_log_max_entries = 99999;",
        extra_params => [ '-U', 'undocap_user' ]);
    isnt($rc, 0, "case 8: a non-superuser cannot raise svs.undo_log_max_entries");
    like($err // '', qr/permission denied/i,
        "case 8: the refusal is a permission error, not something else");

    # Lower the cluster-wide default so a non-superuser's session is bound by
    # a cap small enough to reach in this test, without that role ever being
    # able to set it itself.
    $node->safe_psql('postgres', "ALTER SYSTEM SET svs.undo_log_max_entries = 50;");
    $node->safe_psql('postgres', "SELECT pg_reload_conf();");

    my $before = row_count('undocap');
    my $sql = "BEGIN;\n" . insert_rows_sql(900000, 900000 + 50) . "\nCOMMIT;\n";
    ($rc, $out, $err) = $node->psql('undocap', $sql,
        extra_params => [ '-U', 'undocap_user' ]);
    isnt($rc, 0, "case 8: a non-superuser is still bound by the lowered cap (51 > 50)");
    is(row_count('undocap'), $before,
        "case 8: the over-cap transaction left no rows behind");

    $sql = "BEGIN;\n" . insert_rows_sql(910000, 910000 + 49) . "\nCOMMIT;\n";
    ($rc, $out, $err) = $node->psql('undocap', $sql,
        extra_params => [ '-U', 'undocap_user' ]);
    is($rc, 0, "case 8: exactly 50 inserts under the lowered cap still commits for that role");
    is(row_count('undocap'), $before + 50,
        "case 8: the at-cap transaction's rows are all present");

    $node->safe_psql('postgres', "ALTER SYSTEM RESET svs.undo_log_max_entries;");
    $node->safe_psql('postgres', "SELECT pg_reload_conf();");
}

done_testing();
