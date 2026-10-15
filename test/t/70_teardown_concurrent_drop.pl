# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 70_teardown_concurrent_drop.pl -- natural-timing concurrency probe for
# svs_teardown_database().
#
# svs_teardown_database() enumerates every vamana index in the current
# database with one SPI query, then walks the result set resolving each
# index's relation and schema name per OID (EnumerateVamanaIndexes() in
# src/vamana_teardown.c). This test runs an unprivileged reader looping
# svs_teardown_database() against a database whose enumeration list is kept
# wide (many long-lived indexes it cannot drop, owned by someone else) while
# a separate session repeatedly creates and drops a transient index, so the
# enumeration loop stays open longer per call and DROP INDEX commits land as
# often as possible during it. It asserts the server never crashes and that
# ordinary per-index result rows keep coming back, including for the index
# the owner is actively churning.
#
# Budget-based, not TAP-plan-based: this measures a race's hit rate, so the
# meaningful output is the iteration count and the crash flag, not a fixed
# assertion count beyond "no crash" and "normal rows kept coming back".

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(time);

my $BUDGET_SECONDS = $ENV{TEARDOWN_RACE_BUDGET_SECONDS} // 30;
my $WIDE_INDEX_COUNT = $ENV{TEARDOWN_RACE_WIDE_INDEX_COUNT} // 10;

my $node = PostgreSQL::Test::Cluster->new('teardown_concurrent_drop');
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
    "CREATE ROLE teardown_race_reader LOGIN;"
  . "GRANT CONNECT ON DATABASE postgres TO teardown_race_reader;");

# Widen the enumeration loop: WIDE_INDEX_COUNT long-lived indexes, owned by
# the superuser, which teardown_race_reader can enumerate but never drop
# (ownership check fails every time) -- each teardown call walks all of them
# plus the transient one, so the window is open longer per call and more
# often.
$node->safe_psql('postgres', "CREATE TABLE tsr_wide (id serial primary key, v vector(3));");
$node->safe_psql('postgres',
    "INSERT INTO tsr_wide (v) SELECT ARRAY[random(),random(),random()]::vector(3) "
  . "FROM generate_series(1, 50);");
for my $i (1 .. $WIDE_INDEX_COUNT)
{
    $node->safe_psql('postgres',
        "CREATE INDEX tsr_wide_idx_$i ON tsr_wide USING vamana (v vector_l2_ops);");
}

# The transient table/index that session B repeatedly creates and drops.
$node->safe_psql('postgres', "CREATE TABLE tsr_churn (id serial primary key, v vector(3));");
$node->safe_psql('postgres',
    "INSERT INTO tsr_churn (v) SELECT ARRAY[random(),random(),random()]::vector(3) "
  . "FROM generate_series(1, 20);");

my $session_a = $node->background_psql('postgres',
    connstr => $node->connstr('postgres') . " user=teardown_race_reader");
my $session_b = $node->background_psql('postgres');

my $log_pos = length($node->log_content());
my $start   = time();
my $iterations_a = 0;
my $iterations_b = 0;
my $crashed       = 0;
my $saw_churn_row = 0;
my $churn_exists  = 0;

# Toggle the churn index's existence every few passes rather than inside
# every single pass: a create-then-immediately-drop cycle finishes faster
# than A's own round trip, so A would almost never see it exist. Leaving it
# up for several consecutive passes gives A a real chance to enumerate it
# while it is still there, including the pass where B's drop lands.
while (time() - $start < $BUDGET_SECONDS)
{
    if ($iterations_a % 4 == 0)
    {
        if ($churn_exists)
        {
            $session_b->query_until(qr/toggle_done\n/,
                "DROP INDEX tsr_churn_idx; \\echo toggle_done\n");
            $churn_exists = 0;
        }
        else
        {
            $session_b->query_until(qr/toggle_done\n/,
                "CREATE INDEX tsr_churn_idx ON tsr_churn USING vamana (v vector_l2_ops); "
              . "\\echo toggle_done\n");
            $churn_exists = 1;
        }
        $iterations_b++;
    }

    my $result = $session_a->query_until(qr/teardown_done\n/,
        "SELECT index_name, dropped FROM svs_teardown_database() "
      . "WHERE index_name LIKE '%tsr_churn%'; \\echo teardown_done\n");
    $iterations_a++;
    $saw_churn_row = 1 if $result =~ /tsr_churn_idx\s*\|\s*f/;

    my $alive = eval { $node->safe_psql('postgres', "SELECT 1;") };
    if (!defined($alive) || $alive ne '1')
    {
        $crashed = 1;
        last;
    }

    last if $node->log_content() =~ /terminated by signal|server closed the connection unexpectedly/;
}

$session_a->quit;
$session_b->quit;

my $log = substr($node->log_content(), $log_pos);
my @sig_lines = ($log =~ /(.*terminated by signal.*)/g);
my @restart_lines = ($log =~ /(.*terminating any other active server processes.*)/g);

diag("budget: ${BUDGET_SECONDS}s; A (svs_teardown_database) iterations: $iterations_a; "
   . "B (create/drop churn index) iterations: $iterations_b");
diag("wide index count: $WIDE_INDEX_COUNT");
diag("crash signal lines: " . scalar(@sig_lines));
diag("server became unreachable mid-loop: " . ($crashed ? "yes" : "no"));
for my $line (@sig_lines) { diag("  $line"); }
for my $line (@restart_lines) { diag("  $line"); }

is($crashed, 0, 'the server stays reachable throughout the loop (SELECT 1 keeps working)');

is(scalar(@sig_lines), 0,
    'svs_teardown_database() survives concurrent DROP INDEX/CREATE INDEX churn '
  . "without a backend crash over $iterations_a enumeration passes");

ok($saw_churn_row,
    'at least one pass caught the churned index mid-flight and returned a normal '
  . 'dropped=false result row for it');

$node->stop;

done_testing();
