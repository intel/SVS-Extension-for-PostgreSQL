# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 52_slot_drop_failure_retry.pl: a non-BUSY TryDropSlot failure is retried
# instead of discarded.
#
# Before this fix, VamanaRetireIndexArtifacts only handed a drop to the
# worker's queue when TryDropSlot returned BUSY; FAILED took the same early
# return as DONE, so a transient drop failure (disk full, permission error,
# or -- after this same fix -- a foreign-plugin ownership refusal) got one
# WARNING from inside TryDropSlot itself and was never attempted again. The
# slot's restart_lsn stayed pinned and WAL accumulated behind it forever,
# with no further sign of trouble.
#
# This forces that failure deterministically with an injection point inside
# TryDropSlot's PG_TRY block, so every attempt -- the backend's at DROP INDEX
# commit, and the worker's when it dequeues the handed-off request -- fails
# the same way until the point is detached. The fix routes FAILED through
# the same worker hand-off BUSY already used, and the worker re-queues a
# FAILED attempt instead of clearing it, so the drop is retried on a
# throttled cadence (VAMANA_SLOT_DROP_RETRY_INTERVAL_MS) rather than once.
# Seeing more than one "will retry" line proves the retry loop runs; seeing
# the slot actually disappear once the point is detached proves the retried
# drop can still succeed.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

if (($ENV{enable_injection_points} // 'no') ne 'yes')
{
    plan skip_all => 'server not built with --enable-injection-points';
}

sub wait_for_slot_count
{
    my ($node, $slot_name, $want, $attempts) = @_;
    $attempts //= 20;
    for (1 .. $attempts)
    {
        my $cnt = $node->safe_psql('postgres', qq{
            SELECT count(*) FROM pg_replication_slots
            WHERE slot_name = '$slot_name';
        });
        chomp $cnt;
        return 1 if $cnt == $want;
        usleep(500_000);
    }
    return 0;
}

# Polls log_contains rather than wait_for_log, which croaks on timeout.
sub wait_for_log_line
{
    my ($node, $regex, $offset, $timeout_s) = @_;
    $timeout_s //= 10;
    for (1 .. $timeout_s * 2)
    {
        return 1 if $node->log_contains($regex, $offset);
        usleep(500_000);
    }
    return 0;
}

sub count_log_lines
{
    my ($node, $regex, $offset) = @_;
    my $log = PostgreSQL::Test::Utils::slurp_file($node->logfile, $offset);
    my @matches = ($log =~ /$regex/g);
    return scalar @matches;
}

my $node = PostgreSQL::Test::Cluster->new('slot_drop_failure_retry');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 10");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres', "CREATE EXTENSION injection_points;");
$node->safe_psql('postgres',
    "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

my $worker_pid = wait_for_worker($node, 30);
ok($worker_pid ne '', 'the worker starts for the postgres database');

$node->safe_psql('postgres', qq{
    CREATE TABLE drop_retry_tbl (id serial PRIMARY KEY, val vector($dim));
    INSERT INTO drop_retry_tbl (val)
        SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 5);
    CREATE INDEX drop_retry_idx ON drop_retry_tbl USING vamana (val vector_l2_ops);
});

my $dboid = $node->safe_psql('postgres',
    "SELECT oid FROM pg_database WHERE datname = 'postgres';");
chomp $dboid;
my $ioid = $node->safe_psql('postgres',
    "SELECT oid FROM pg_class WHERE relname = 'drop_retry_idx';");
chomp $ioid;
my $slot_name = "vamana_${dboid}_${ioid}";

ok(wait_for_slot_count($node, $slot_name, 1),
    'slot exists before the injected drop failure');

$node->safe_psql('postgres',
    "SELECT injection_points_attach('vamana-slot-drop-fail', 'error');");

my $log_offset = -s $node->logfile;

my $ret = $node->psql('postgres', "DROP INDEX drop_retry_idx;");
is($ret, 0,
    'DROP INDEX commits immediately even though its slot drop keeps failing');

ok(wait_for_log_line($node,
        qr/could not drop replication slot of removed index $ioid; will retry/,
        $log_offset, 10),
    'the worker logs a retry attempt for the handed-off FAILED drop');

# wait_for_log_line only proves a match exists somewhere in the log, so it
# returns true instantly off the one occurrence already seen above; waiting
# for a *second* occurrence needs an explicit poll past the throttle
# interval (VAMANA_SLOT_DROP_RETRY_INTERVAL_MS), not a re-check of the same
# condition.
my $retry_count = 0;
for (1 .. 20)          # 10 s, past two retry intervals
{
    $retry_count = count_log_lines($node,
        qr/could not drop replication slot of removed index $ioid; will retry/,
        $log_offset);
    last if $retry_count >= 2;
    usleep(500_000);
}
ok($retry_count >= 2,
    'a second retry attempt is also logged: the request was requeued, not spent after one try');

ok(count_log_lines($node,
        qr/error triggered for injection point vamana-slot-drop-fail/,
        $log_offset) >= 2,
    'both the backend\'s own attempt (at DROP INDEX commit) and the worker\'s hit the fault, '
  . 'not just one of them');

ok(wait_for_slot_count($node, $slot_name, 1),
    'the slot still exists: it was not mistaken for a completed drop while the fault was active');

$node->safe_psql('postgres',
    "SELECT injection_points_detach('vamana-slot-drop-fail');");

ok(wait_for_log_line($node,
        qr/dropped replication slot of removed index $ioid\b/,
        $log_offset, 15),
    'once the fault clears, a later retry succeeds and the slot is dropped');

ok(wait_for_slot_count($node, $slot_name, 0),
    'the slot is gone once the retry finally succeeds');

ok(wait_for_worker($node, 10),
    'the worker is still alive after retrying the failed drop to completion');

$node->stop;

done_testing();
