# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 10_vamana_idle_worker_visibility.pl — worker visibility in pg_stat_vamana_worker.
#
# A worker for an enabled database with no vamana indexes is still a live,
# reserved slot: pg_stat_vamana_worker reports it 'running' with a pid, a
# heartbeat, and index_count = 0.  With several databases enabled, the shmem
# array holds entries past slots[0]; each database resolves to its own slot and
# its own index counter, keyed on dbOid rather than array position.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

sub start_node
{
    my ($name) = @_;
    my $node = PostgreSQL::Test::Cluster->new($name);
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
    $node->start;
    $node->safe_psql('postgres', "CREATE EXTENSION vector;");
    $node->safe_psql('postgres', "CREATE EXTENSION svs;");
    return $node;
}

# One worker row's columns for a database, by name.  Returns a hashref keyed on
# the pg_stat_vamana_worker column names, or undef if the database has no row.
sub worker_row
{
    my ($node, $db) = @_;
    my $oid = $node->safe_psql('postgres',
        "SELECT oid FROM pg_database WHERE datname = '$db';");
    chomp $oid;
    my $line = $node->safe_psql('postgres', qq{
        SELECT worker_pid, worker_state, index_count,
               (heartbeat_ts IS NOT NULL)::text
        FROM pg_stat_vamana_worker WHERE db_oid = $oid;
    });
    chomp $line;
    return undef if $line eq '';
    my @f = split /\|/, $line;
    return {
        worker_pid    => $f[0],
        worker_state  => $f[1],
        index_count   => $f[2],
        has_heartbeat => $f[3],
    };
}

# ---------------------------------------------------------------------------
# An idle worker (enabled database, zero indexes) is fully visible: the row
# reports 'running' with a live pid, a heartbeat, and index_count = 0.  The slot
# is reserved and the worker is serving; it simply has no indexes yet.
# ---------------------------------------------------------------------------
{
    my $node = start_node('vamana_idle_visible');
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    my $pid = wait_for_worker_db($node, 'postgres', 40);
    ok($pid =~ /^\d+$/, "idle-database worker is running (pid=$pid)");

    my $row = worker_row($node, 'postgres');
    ok(defined $row, 'idle worker has a pg_stat_vamana_worker row');
    is($row->{worker_state}, 'running',
        'idle worker reports running even with no indexes');
    is($row->{index_count}, '0', 'idle worker reports index_count = 0');
    is($row->{worker_pid}, $pid, 'row worker_pid matches the running worker');

    # workerPid is published before the main loop writes the first heartbeat, so
    # a freshly-started worker can briefly show a NULL heartbeat_ts (which the
    # 'running' state tolerates, since a never-beaten worker is not stale).  Poll
    # until the first beat lands, proving an idle worker does heartbeat.
    for (1 .. 40) {
        $row = worker_row($node, 'postgres');
        last if defined $row && $row->{has_heartbeat} eq 'true';
        usleep(200_000);
    }
    is($row->{has_heartbeat}, 'true', 'idle worker publishes a heartbeat');

    $node->stop;
}

# ---------------------------------------------------------------------------
# With four databases enabled, the shmem array holds several reserved entries,
# not just slots[0].  Each database resolves to its own row with a distinct pid,
# and an index built in one database moves only that database's counter — the
# lookup and per-database counter key on dbOid, not on array position.
# ---------------------------------------------------------------------------
{
    my $node = start_node('vamana_arbitrary_position');

    for my $db (qw(pos_a pos_b pos_c)) {
        $node->safe_psql('postgres', "CREATE DATABASE $db;");
        $node->safe_psql($db, "CREATE EXTENSION vector;");
        $node->safe_psql($db, "CREATE EXTENSION svs;");
    }
    $node->safe_psql('postgres', qq{
        INSERT INTO vamana_databases (datname, enabled) VALUES
            ('postgres', true), ('pos_a', true), ('pos_b', true), ('pos_c', true);
    });

    # Wait for all four workers so every slot is reserved and serving.
    my $count = 0;
    for (1 .. 80) {
        usleep(500_000);
        $count = $node->safe_psql('postgres',
            "SELECT count(*) FROM pg_stat_vamana_worker WHERE worker_pid IS NOT NULL;");
        chomp $count;
        last if $count >= 4;
    }
    is($count, '4', 'all four databases have a reserved, running worker');

    # Every database resolves to its own running slot with a distinct pid.
    my %pid;
    for my $db (qw(postgres pos_a pos_b pos_c)) {
        my $row = worker_row($node, $db);
        ok(defined $row && $row->{worker_state} eq 'running',
            "$db resolves to its own running slot (entry past slots[0])");
        $pid{$db} = $row->{worker_pid} if defined $row;
    }
    my %seen;
    $seen{$_}++ for values %pid;
    is(scalar(keys %seen), scalar(keys %pid),
        'each database resolves to a distinct worker pid (lookup keys on dbOid)');

    # Build an index in exactly one database; its counter must move and no other
    # database's counter may — the per-database counter is keyed on dbOid, not a
    # shared or position-indexed cell.
    $node->safe_psql('pos_b', qq{
        CREATE TABLE t (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO t (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 20);
        CREATE INDEX t_idx ON t USING vamana (val vector_l2_ops);
    });

    is(worker_row($node, 'pos_b')->{index_count}, '1',
        'index_count is 1 for the database that built an index');
    for my $db (qw(postgres pos_a pos_c)) {
        is(worker_row($node, $db)->{index_count}, '0',
            "index_count stays 0 for $db (no cross-database bleed)");
    }

    $node->stop;
}

# ---------------------------------------------------------------------------
# A reader never observes a half-published slot.  Reserving a slot holds the
# header lock exclusively while it publishes the entry; a stat reader takes the
# same lock shared, so it must block until the reservation is whole rather than
# read a partially-initialised entry.  The injection point pauses a reservation
# at exactly that midpoint to prove it deterministically.
# ---------------------------------------------------------------------------
SKIP: {
    skip 'server not built with --enable-injection-points', 3
        if (($ENV{enable_injection_points} // 'no') ne 'yes');

    my $node = start_node('vamana_reserve_no_torn_read');
    $node->safe_psql('postgres', "CREATE EXTENSION injection_points;");

    # Bring up the launcher-database worker first, so the only reservation left
    # to fire the midpoint is the one this test triggers below.
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");
    wait_for_worker_db($node, 'postgres', 40);
    $node->safe_psql('postgres', "CREATE DATABASE torn_db;");

    my $base = $node->safe_psql('postgres',
        "SELECT count(*) FROM pg_stat_vamana_worker;");
    chomp $base;

    # Control session: arms the waitpoint, observes it, and wakes it.
    my $ctl = $node->background_psql('postgres');
    $ctl->query_safe(
        "SELECT injection_points_attach('vamana-reserve-slot-midpoint', 'wait');");

    # Reserver session: enabling torn_db reserves its slot at commit, which
    # parks inside the exclusive lock at the midpoint.  Fire and do not wait.
    my $reserver = $node->background_psql('postgres');
    $reserver->query_until(qr//,
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('torn_db', true);\n");

    # Wait until the reserver is parked at the midpoint, still holding the lock.
    my $parked = '';
    for (1 .. 100) {
        usleep(100_000);
        $parked = $ctl->query(
            "SELECT pid FROM pg_stat_activity "
          . "WHERE wait_event = 'vamana-reserve-slot-midpoint';");
        last if $parked ne '';
    }
    isnt($parked, '', 'a reservation parks at the mid-publish point');

    # Fire a stat read that races the paused reservation.  It must not read the
    # half-published entry: it takes the header lock shared and so blocks behind
    # the reservation's exclusive hold.  An LWLock wait ignores statement_timeout,
    # so run it in the background and observe the block rather than waiting on it.
    my $reader = $node->background_psql('postgres');
    $reader->query_until(qr//,
        "SELECT count(*) FROM pg_stat_vamana_worker;\n");

    my $blocked = '';
    for (1 .. 100) {
        usleep(100_000);
        $blocked = $ctl->query(
            "SELECT pid FROM pg_stat_activity "
          . "WHERE wait_event = 'vamana_worker_header' AND wait_event_type = 'LWLock';");
        last if $blocked ne '';
    }
    isnt($blocked, '', 'a racing stat read blocks on the header lock (no torn read)');

    # Wake the reservation; it finishes publishing and drops the lock, unblocking
    # the reader.  The committed state now shows exactly one whole new row — the
    # entry the reader was kept from seeing half-formed.
    $ctl->query_safe(
        "SELECT injection_points_wakeup('vamana-reserve-slot-midpoint');");
    $ctl->query_safe(
        "SELECT injection_points_detach('vamana-reserve-slot-midpoint');");

    my $after = $node->safe_psql('postgres',
        "SELECT count(*) FROM pg_stat_vamana_worker;");
    chomp $after;
    is($after, $base + 1,
        'the completed reservation is visible as exactly one whole new row');

    $reader->quit;
    $reserver->quit;
    $ctl->quit;
    $node->stop;
}

# ---------------------------------------------------------------------------
# pg_stat_vamana_worker_slot() copies scalars out under the header LW_SHARED
# lock and defers text/tuplestore formatting until after the lock is
# released, mirroring pg_stat_vamana_worker's hydrate/format split.  A reader
# parked mid-format must not hold up a concurrent reservation, which needs
# the header lock LW_EXCLUSIVE.
# ---------------------------------------------------------------------------
SKIP: {
    skip 'server not built with --enable-injection-points', 3
        if (($ENV{enable_injection_points} // 'no') ne 'yes');

    my $node = start_node('vamana_slot_stat_no_lock_hold');
    $node->safe_psql('postgres', "CREATE EXTENSION injection_points;");
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");
    wait_for_worker_db($node, 'postgres', 40);
    $node->safe_psql('postgres', "CREATE DATABASE slot_stat_db2;");

    my $ctl = $node->background_psql('postgres');
    $ctl->query_safe(
        "SELECT injection_points_attach('vamana-slot-stat-emit-row', 'wait');");

    my $reader = $node->background_psql('postgres');
    $reader->query_until(qr//, "SELECT count(*) FROM pg_stat_vamana_worker_slot();\n");

    my $parked = '';
    for (1 .. 100) {
        usleep(100_000);
        $parked = $ctl->query(
            "SELECT pid FROM pg_stat_activity "
          . "WHERE wait_event = 'vamana-slot-stat-emit-row';");
        last if $parked ne '';
    }
    isnt($parked, '', 'a slot-stat reader parks mid-format');

    # Reserver: fire-and-forget; an LWLock wait ignores statement_timeout, so
    # completion is observed by polling pg_stat_activity, never awaited directly.
    my $reserver = $node->background_psql('postgres');
    my $reserver_pid = $reserver->query('SELECT pg_backend_pid();');
    chomp $reserver_pid;
    $reserver->query_until(qr//,
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('slot_stat_db2', true);\n");

    my $done = '';
    my $blocked_on_header = '';
    for (1 .. 100) {
        usleep(100_000);
        my $row = $ctl->query(
            "SELECT wait_event_type, wait_event, state FROM pg_stat_activity "
          . "WHERE pid = $reserver_pid;");
        if ($row =~ /\|idle$/) {
            $done = 1;
            last;
        }
        $blocked_on_header = $row if $row =~ /^LWLock\|vamana_worker_header\|/;
    }
    ok($done,
        'reserving a new slot completes while a slot-stat reader is parked mid-format');
    is($blocked_on_header, '',
        'the reservation never blocks on the header lock behind the parked reader');

    # The callback hits this point once per slot, not once overall: detach
    # BEFORE waking so the reader's next iteration finds no attachment and
    # just proceeds, instead of parking again.
    $ctl->query_safe(
        "SELECT injection_points_detach('vamana-slot-stat-emit-row');");
    $ctl->query_safe(
        "SELECT injection_points_wakeup('vamana-slot-stat-emit-row');");

    for (1 .. 100) {
        usleep(100_000);
        my $state = $ctl->query(
            "SELECT state FROM pg_stat_activity WHERE pid = $reserver_pid;");
        last if $state eq 'idle' || $state eq '';
    }

    $reader->quit;
    $reserver->quit;
    $ctl->quit;
    $node->stop;
}

done_testing();
