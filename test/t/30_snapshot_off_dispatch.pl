# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 30_snapshot_off_dispatch.pl - an unrelated open transaction must not tie up
# the worker's single dispatch loop after CREATE INDEX.
#
# VamanaWorkerProcessLoadSlot used to call VamanaReplicationBuildSnapshot
# synchronously, immediately after publishing VAMANA_SLOT_DONE.  That call
# reaches core's DecodingContextFindStartpoint, which blocks in
# XactLockTableWait for every transaction that was already running when the
# index's replication slot was created -- including transactions with
# nothing to do with the index or its table.  The worker's dispatch loop is
# single-threaded, so that block stalled every other write in the same
# database for as long as the unrelated transaction stayed open.
#
# This test holds an unrelated transaction open across a CREATE INDEX, then
# checks two things: a write to a different, already-consistent index
# succeeds quickly instead of stalling for the unrelated transaction's
# lifetime, and the worker goes on servicing further requests rather than
# merely returning once by coincidence.  It also confirms the deferred
# snapshot is not abandoned: it reaches consistency once the unrelated
# transaction ends.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep gettimeofday tv_interval);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

# Long enough that the old synchronous BuildSnapshot call, which waits for
# this transaction's XactLockTableWait to release, would blow well past
# svs.worker_timeout_ms below, and to leave headroom for the repeated-defer
# samples taken later in this window; short enough to keep the suite fast.
my $UNRELATED_TXN_SECONDS = 8;

my $node = PostgreSQL::Test::Cluster->new('snapshot_off_dispatch');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_wal_senders = 4");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->append_conf('postgresql.conf', "svs.worker_timeout_ms = 2000");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres',
    "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

wait_for_worker($node, 30);

# A second, already-consistent index on its own table.  A write landing here
# quickly proves the worker was free to service an unrelated request, rather
# than the same statement happening to be fast for some unrelated reason.
$node->safe_psql('postgres', qq{
    CREATE TABLE warm_tbl (id serial PRIMARY KEY, val vector($dim));
    INSERT INTO warm_tbl (val)
        SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 20);
    CREATE INDEX warm_idx ON warm_tbl USING vamana (val vector_l2_ops);
});

# Let warm_idx's own snapshot build finish before the timed part of the test
# begins, so nothing measured below is attributable to warm_idx's own slot.
{
    my $warm_dboid = $node->safe_psql('postgres',
        "SELECT oid FROM pg_database WHERE datname = 'postgres';");
    chomp $warm_dboid;
    my $warm_indexoid = $node->safe_psql('postgres',
        "SELECT oid FROM pg_class WHERE relname = 'warm_idx';");
    chomp $warm_indexoid;
    my $warm_slot = "vamana_${warm_dboid}_${warm_indexoid}";

    my $warm_consistent = 0;
    for (1 .. 40)
    {
        usleep(500_000);
        my $confirmed = $node->safe_psql('postgres', qq{
            SELECT confirmed_flush_lsn IS NOT NULL
            FROM pg_replication_slots WHERE slot_name = '$warm_slot';
        });
        chomp $confirmed;
        if ($confirmed eq 't')
        {
            $warm_consistent = 1;
            last;
        }
    }
    ok($warm_consistent, 'warm_idx reaches snapshot consistency on an idle worker');
}

$node->safe_psql('postgres', qq{
    CREATE TABLE dispatch_tbl (id serial PRIMARY KEY, val vector($dim));
    INSERT INTO dispatch_tbl (val)
        SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 20);
});

# Session A: an unrelated transaction with nothing to do with dispatch_tbl or
# warm_idx, held open across the CREATE INDEX below.
my $session_a = $node->background_psql('postgres');
$session_a->query_safe("BEGIN;");
$session_a->query_safe("SELECT txid_current();");
$session_a->query_until(qr//, "SELECT pg_sleep($UNRELATED_TXN_SECONDS);\n");

# Give session A's transaction time to register as running before CREATE
# INDEX runs, so its xid is captured in the running-xacts snapshot the new
# index's slot activation depends on.
usleep(500_000);

$node->safe_psql('postgres', qq{
    CREATE INDEX dispatch_idx ON dispatch_tbl USING vamana (val vector_l2_ops);
});

# The regression: a write against the unrelated, already-consistent warm_idx
# must not be held up by dispatch_idx's snapshot build.  This has to be an
# INSERT rather than a same-value UPDATE: a HOT update whose indexed columns
# do not change never reaches the vamana access method's insert path at all,
# which would make the assertion pass for a reason that has nothing to do
# with the worker.  svs.worker_timeout_ms (2 s) bounds the wait; session A's
# transaction, held open for $UNRELATED_TXN_SECONDS (6 s), is well past that
# bound, so this only passes if the worker never blocked on it.
my $t0 = [gettimeofday];
my ($ret, $stdout, $stderr) = $node->psql('postgres',
    "INSERT INTO warm_tbl (val) SELECT ARRAY[$array_sql]::vector;");
my $elapsed_ms = tv_interval($t0) * 1000;

is($ret, 0, 'INSERT into the unrelated, already-resident index succeeds')
    or diag("stderr: $stderr");
cmp_ok($elapsed_ms, '<', 2000,
    "INSERT into the unrelated index returns well under svs.worker_timeout_ms "
  . "(took ${elapsed_ms} ms), proving the worker was not blocked on "
  . "session A's still-open transaction");

my $worker_pid = $node->safe_psql('postgres',
    "SELECT pid FROM pg_stat_activity WHERE backend_type = 'vamana worker';");
chomp $worker_pid;
ok($worker_pid =~ /^\d+$/,
    'the vamana worker is still alive, not merely fast because it crashed');

# The worker must go on servicing requests for the rest of session A's open
# window, not just the one issued immediately after CREATE INDEX.
usleep(1_000_000);
my ($ret2, $stdout2, $stderr2) = $node->psql('postgres',
    "INSERT INTO warm_tbl (val) SELECT ARRAY[$array_sql]::vector;");
is($ret2, 0,
    'a second unrelated write, issued partway through the open window, also succeeds')
    or diag("stderr: $stderr2");

# The repeated-defer path: session A's xid is still listed as running in
# every xl_running_xacts record the worker reads for the rest of this window,
# so VamanaWorkerActivatePendingSnapshots must keep deferring dispatch_idx's
# slot activation on each of its 200 ms-spaced retries rather than reaching a
# wrong CONSISTENT verdict on a stale or partial scan.  Sampling several
# times across the remainder of session A's open window, each sample well
# past the previous one's retry interval, exercises that repeatedly, not just
# the single defer-then-converge transition covered once session A commits
# below.
{
    my $dboid_mid = $node->safe_psql('postgres',
        "SELECT oid FROM pg_database WHERE datname = 'postgres';");
    chomp $dboid_mid;
    my $indexoid_mid = $node->safe_psql('postgres',
        "SELECT oid FROM pg_class WHERE relname = 'dispatch_idx';");
    chomp $indexoid_mid;
    my $slot_name_mid = "vamana_${dboid_mid}_${indexoid_mid}";

    for my $sample (1 .. 3)
    {
        usleep(700_000);    # > the 200 ms retry cadence, so each sample lands
                             # on a fresh retry attempt rather than the same one
        my $confirmed_mid = $node->safe_psql('postgres', qq{
            SELECT confirmed_flush_lsn IS NOT NULL
            FROM pg_replication_slots WHERE slot_name = '$slot_name_mid';
        });
        chomp $confirmed_mid;
        is($confirmed_mid, 'f',
            "dispatch_idx still correctly deferred on retry sample $sample "
          . "while session A's transaction remains open");
    }
}

# Let session A finish, so the snapshot build the fix deferred can actually
# converge; confirm it does -- deferred, not abandoned.
$session_a->query_safe("SELECT 1;");    # drains the pg_sleep() result first
$session_a->query_safe("COMMIT;");
$session_a->quit;

my $dboid = $node->safe_psql('postgres',
    "SELECT oid FROM pg_database WHERE datname = 'postgres';");
chomp $dboid;
my $indexoid = $node->safe_psql('postgres',
    "SELECT oid FROM pg_class WHERE relname = 'dispatch_idx';");
chomp $indexoid;
my $slot_name = "vamana_${dboid}_${indexoid}";

my $consistent = 0;
for (1 .. 20)
{
    usleep(500_000);
    my $confirmed = $node->safe_psql('postgres', qq{
        SELECT confirmed_flush_lsn IS NOT NULL
        FROM pg_replication_slots WHERE slot_name = '$slot_name';
    });
    chomp $confirmed;
    if ($confirmed eq 't')
    {
        $consistent = 1;
        last;
    }
}
ok($consistent,
    "dispatch_idx's snapshot reaches consistency once session A's "
  . "transaction ends, so deferring it did not abandon it");

$node->stop;

done_testing();
