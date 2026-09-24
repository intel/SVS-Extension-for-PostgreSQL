# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

package VamanaTestUtils;

# Shared helpers and deterministic test data for Vamana TAP tests.
#
# All test files call VamanaTestUtils::init() once at the top to get the
# shared scalar globals, then import the helper subs they need.

use strict;
use warnings FATAL => 'all';
use Exporter qw(import);
use Fcntl      qw(O_WRONLY O_CREAT O_EXCL);
use File::Temp qw(tempdir);
use POSIX      qw(waitpid _exit);
use Time::HiRes qw(usleep);

our @EXPORT_OK = qw(
    $dim $array_sql $query_sql $lv_query_sql
    $N @query_vecs $SYNC_SLEEP
    run_concurrent run_synchronized dir_size vamana_save_dir
    wait_for_worker wait_for_worker_db wait_for_slot_release
    orphan_slot_count wait_for_no_orphan_slots
    search_scratch_in_flight_bytes wait_for_search_scratch_in_flight
    park_search_scratch_reservation search_scratch_cost_for_relid
    release_search_scratch_reservation
    worker_committed_totals park_build
);
our %EXPORT_TAGS = (all => \@EXPORT_OK);

# ---------------------------------------------------------------------------
# Deterministic test data
#
# srand(42) is called once here so every test file that uses this module
# gets the same vectors regardless of load order.  Files that need
# additional vectors (e.g. $lv_query_sql) consume from the same sequence.
# ---------------------------------------------------------------------------
srand(42);

our $dim       = 16;
our $array_sql = join(",", ('random()') x $dim);
our $query_sql    = join(",", map { rand() } 1 .. $dim);
our $lv_query_sql = join(",", map { rand() } 1 .. $dim);

# Batch section: N distinct query vectors generated after $query_sql so that
# every test file sharing this module's srand(42) seed produces identical vectors.
our $N = 5;
our @query_vecs =
  map { join(",", map { sprintf("%.6f", rand()) } 1 .. $dim) } 1 .. $N;

# PL/pgSQL sleep block: produces no output; holds each concurrent client for
# 1 second so all N have connected before any vector query fires.
our $SYNC_SLEEP =
  'DO $sync_sleep$ BEGIN PERFORM pg_sleep(1.0); END $sync_sleep$;' . "\n";

# ---------------------------------------------------------------------------
# run_concurrent: fork $n children; child $i runs $sql_of->($i) and writes
# its result to a temp file.  Parent waits for all children and returns the
# results array.
#
# $pre_sql (optional): prepended to each child's SQL for synchronization.
# A PL/pgSQL DO block ensures the sleep produces no output, so comparisons
# against single-client baselines remain valid.
# ---------------------------------------------------------------------------
sub run_concurrent
{
    my ($node, $db, $n, $sql_of, $pre_sql) = @_;
    $pre_sql //= '';
    my $tmpdir = tempdir(CLEANUP => 1);

    # Set the mode explicitly rather than trusting File::Temp's default.
    chmod(0700, $tmpdir) == 1
      or die "could not set permissions on $tmpdir: $!";

    my @pids;

    for my $i (0 .. $n - 1)
    {
        my $pid = fork();
        die "fork: $!" unless defined $pid;

        if ($pid == 0)
        {
            # Child: run query, write result to temp file.
            # _exit() bypasses Perl END blocks so the test node is not
            # cleaned up by forked children.
            my $result =
              eval { $node->safe_psql($db, $pre_sql . $sql_of->($i)) } // '';
            # sysopen, not open: the mode is ours to state, not the umask's.
            # O_EXCL is safe here — $tmpdir is fresh and $i is unique.
            if (sysopen(my $fh, "$tmpdir/r$i.txt",
                    O_WRONLY | O_CREAT | O_EXCL, 0600))
            {
                print $fh $result;
                close $fh;
            }
            _exit(0);
        }
        push @pids, $pid;
    }

    waitpid($_, 0) for @pids;

    my @results;
    for my $i (0 .. $n - 1)
    {
        open(my $fh, '<', "$tmpdir/r$i.txt")
          or do { push @results, ''; next; };
        my $r = do { local $/; <$fh> };
        close $fh;
        push @results, $r;
    }
    return @results;
}

# ---------------------------------------------------------------------------
# run_synchronized: like run_concurrent, but guarantees all N clients submit
# their vector queries to the worker within the same batch window.
#
# Each child runs $pre_sql_of->($i) first (SET statements etc.) then blocks
# on a shared advisory lock keyed on $barrier_key.  The parent holds an
# exclusive lock on the same key until all N children are blocked (confirmed
# via pg_locks), then releases — all N children get the shared lock
# simultaneously and immediately run $search_sql_of->($i).
#
# DO blocks for lock acquire/release produce no output under psql -t.
# ---------------------------------------------------------------------------
sub run_synchronized
{
    my ($node, $db, $n, $pre_sql_of, $search_sql_of, $barrier_key) = @_;
    $barrier_key //= 4747;

    my $tmpdir = tempdir(CLEANUP => 1);

    # Set the mode explicitly rather than trusting File::Temp's default.
    chmod(0700, $tmpdir) == 1
      or die "could not set permissions on $tmpdir: $!";

    # Hold exclusive advisory lock so children block on the shared acquire.
    my $coord = $node->background_psql($db);
    $coord->query_safe("SELECT pg_advisory_lock($barrier_key);");

    my @pids;
    for my $i (0 .. $n - 1)
    {
        my $pid = fork();
        die "fork: $!" unless defined $pid;

        if ($pid == 0)
        {
            my $pre_sql    = $pre_sql_of->($i);
            my $search_sql = $search_sql_of->($i);
            my $full_sql   = $pre_sql
              . "DO \$adv_wait\$ BEGIN "
              . "PERFORM pg_advisory_lock_shared($barrier_key); "
              . "END \$adv_wait\$;\n"
              . $search_sql
              . "DO \$adv_rel\$ BEGIN "
              . "PERFORM pg_advisory_unlock_shared($barrier_key); "
              . "END \$adv_rel\$;\n";

            my $result = eval { $node->safe_psql($db, $full_sql) } // '';
            # sysopen, not open: the mode is ours to state, not the umask's.
            # O_EXCL is safe here — $tmpdir is fresh and $i is unique.
            if (sysopen(my $fh, "$tmpdir/r$i.txt",
                    O_WRONLY | O_CREAT | O_EXCL, 0600))
            {
                print $fh $result;
                close $fh;
            }
            _exit(0);
        }
        push @pids, $pid;
    }

    # Poll until all N children are waiting on the shared advisory lock.
    my $waiting = 0;
    for my $attempt (1 .. 120)
    {
        usleep(100_000);    # 100 ms
        $waiting = $node->safe_psql($db,
            "SELECT count(*) FROM pg_locks "
              . "WHERE locktype = 'advisory' AND granted = false "
              . "AND classid = 0 AND objid = $barrier_key;");
        chomp $waiting;
        last if int($waiting) >= $n;
    }
    die "Timed out waiting for $n advisory lock waiters after 12s"
      if int($waiting) < $n;
    usleep(50_000);         # 50 ms margin

    # Release exclusive lock: all N children get the shared lock simultaneously
    # and immediately run their SELECT queries.
    $coord->query_safe("SELECT pg_advisory_unlock($barrier_key);");
    $coord->quit;

    waitpid($_, 0) for @pids;

    my @results;
    for my $i (0 .. $n - 1)
    {
        open(my $fh, '<', "$tmpdir/r$i.txt")
          or do { push @results, ''; next; };
        my $r = do { local $/; <$fh> };
        close $fh;
        push @results, $r;
    }
    return @results;
}

# ---------------------------------------------------------------------------
# vamana_save_dir: on-disk save-directory path for an index, namespaced by
# database OID: $PGDATA/vamana_indexes/<dboid>/<relid>/.
# ---------------------------------------------------------------------------
sub vamana_save_dir
{
    my ($node, $db, $relid) = @_;
    my $dboid = $node->safe_psql('postgres',
        "SELECT oid FROM pg_database WHERE datname = '$db';");
    chomp $dboid;
    return $node->data_dir . "/vamana_indexes/$dboid/$relid";
}

# ---------------------------------------------------------------------------
# dir_size: sum file sizes at the top level of a directory only.
# Note this does not recurse: a vamana index directory holds the SVS payload
# in config/, data/ and graph/ subdirectories, which are not counted.
# ---------------------------------------------------------------------------
sub dir_size
{
    my ($dir) = @_;
    my $total = 0;
    for my $f (glob("$dir/*"))
    {
        $total += -s $f if -f $f;
    }
    return $total;
}

# ---------------------------------------------------------------------------
# wait_for_worker: poll pg_stat_activity until the vamana background worker
# appears (up to $attempts x 0.5s).  Returns the PID or '' on timeout.
# ---------------------------------------------------------------------------
sub wait_for_worker
{
    my ($node, $attempts) = @_;
    $attempts //= 30;
    my $pid = '';
    for my $i (1 .. $attempts)
    {
        usleep(500_000);
        $pid = $node->safe_psql('postgres',
            "SELECT pid FROM pg_stat_activity "
          . "WHERE backend_type = 'vamana worker' LIMIT 1;");
        chomp $pid;
        return $pid if $pid =~ /^\d+$/;
    }
    return '';
}

# ---------------------------------------------------------------------------
# wait_for_worker_db: like wait_for_worker, but for the worker serving a
# specific database.  With the launcher spawning one worker per enabled
# database, several workers can run at once, so a database filter is needed to
# identify the right one.
# ---------------------------------------------------------------------------
sub wait_for_worker_db
{
    my ($node, $db, $attempts) = @_;
    $attempts //= 30;
    my $pid = '';
    for my $i (1 .. $attempts)
    {
        usleep(500_000);
        $pid = $node->safe_psql('postgres',
            "SELECT pid FROM pg_stat_activity "
          . "WHERE backend_type = 'vamana worker' AND datname = '$db' LIMIT 1;");
        chomp $pid;
        return $pid if $pid =~ /^\d+$/;
    }
    return '';
}

# ---------------------------------------------------------------------------
# wait_for_slot_release: poll pg_stat_vamana_worker, queried from $query_db,
# until no row remains for $db_oid (up to $attempts x 0.5s).  Returns true on
# release, false on timeout.
# ---------------------------------------------------------------------------
sub wait_for_slot_release
{
    my ($node, $query_db, $db_oid, $attempts) = @_;
    $attempts //= 30;
    for my $i (1 .. $attempts)
    {
        my $count = $node->safe_psql($query_db,
            "SELECT count(*) FROM pg_stat_vamana_worker WHERE db_oid = $db_oid;");
        chomp $count;
        return 1 if $count eq '0';
        usleep(500_000);
    }
    return 0;
}

# ---------------------------------------------------------------------------
# orphan_slot_count: how many vamana replication slots in $db name an index
# that no longer exists.  Every such slot pins WAL and holds back catalog_xmin
# for the whole cluster with nothing left to replay, so zero is an invariant
# any test that drops an index can assert.
#
# Slots are database-specific and pg_class only shows the current database, so
# the query must run in the database that owns the slots.
# ---------------------------------------------------------------------------
sub orphan_slot_count
{
    my ($node, $db) = @_;
    my $count = $node->safe_psql($db, q{
        SELECT count(*) FROM pg_replication_slots s
        WHERE s.plugin = 'svs'
          AND s.database = current_database()
          AND s.slot_name ~ '^vamana_[0-9]+_[0-9]+$'
          AND NOT EXISTS (SELECT 1 FROM pg_class c
                          WHERE c.oid = split_part(s.slot_name, '_', 3)::oid);
    });
    chomp $count;
    return $count;
}

# ---------------------------------------------------------------------------
# wait_for_no_orphan_slots: poll orphan_slot_count until it reaches zero (up to
# $attempts x 0.5s).  Polling rather than checking once because a slot the
# worker was holding is dropped by the worker on its next cycle, not by the
# backend that committed the DROP.  Returns the final count, so a caller can
# report how many were left behind.
# ---------------------------------------------------------------------------
sub wait_for_no_orphan_slots
{
    my ($node, $db, $attempts) = @_;
    $attempts //= 30;
    my $count;
    for my $i (1 .. $attempts)
    {
        $count = orphan_slot_count($node, $db);
        return 0 if $count eq '0';
        usleep(500_000);
    }
    return $count;
}

# ---------------------------------------------------------------------------
# search_scratch_in_flight_bytes: this database's live search-scratch
# in-flight total, read from pg_stat_vamana_worker.
# ---------------------------------------------------------------------------
sub search_scratch_in_flight_bytes
{
    my ($node, $db) = @_;
    my $bytes = $node->safe_psql($db,
        "SELECT search_scratch_bytes_in_flight FROM pg_stat_vamana_worker "
      . "WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = '$db');");
    chomp $bytes;
    return $bytes;
}

# ---------------------------------------------------------------------------
# wait_for_search_scratch_in_flight: poll search_scratch_in_flight_bytes until
# it reaches $expected (up to $attempts x 0.1s).  Returns the final value, so
# a timeout is visible to the caller's own assertion rather than silently
# passing.
# ---------------------------------------------------------------------------
sub wait_for_search_scratch_in_flight
{
    my ($node, $db, $expected, $attempts) = @_;
    $attempts //= 100;
    my $bytes = '';
    for (1 .. $attempts)
    {
        $bytes = search_scratch_in_flight_bytes($node, $db);
        return $bytes if $bytes eq $expected;
        usleep(100_000);
    }
    return $bytes;
}

# ---------------------------------------------------------------------------
# park_search_scratch_reservation: attach 'wait' to the worker's
# vamana-search-scratch-reserved injection point (already fired for a search
# whose cost has just been admitted, before it runs against SVS), then run
# $search_sql in a fresh background session and wait for the worker to park
# there.  Requires injection_points already created in $db.
#
# Returns ($session, $client_pid, $worker_pid): $session is the still-open
# background_psql handle for $search_sql; $client_pid is that session's own
# backend pid (for a later pg_cancel_backend); $worker_pid is the vamana
# worker's own pid, parked at the injection point -- distinct from
# $client_pid.  The caller owns releasing the reservation, via
# release_search_scratch_reservation or by killing $worker_pid directly.
# ---------------------------------------------------------------------------
sub park_search_scratch_reservation
{
    my ($node, $db, $search_sql) = @_;
    my $point = 'vamana-search-scratch-reserved';

    $node->safe_psql($db, "SELECT injection_points_attach('$point', 'wait');");

    my $session = $node->background_psql($db, on_error_stop => 0);
    my $client_pid_out = $session->query('SELECT pg_backend_pid();');
    my ($client_pid) = $client_pid_out =~ /(\d+)/;
    $session->query_until(qr/park_search_scratch_reservation_started/,
        "\\echo park_search_scratch_reservation_started\n" . $search_sql);

    my $worker_pid = '';
    for (1 .. 100)
    {
        usleep(100_000);
        $worker_pid = $node->safe_psql($db,
            "SELECT pid FROM pg_stat_activity WHERE wait_event = '$point';");
        chomp $worker_pid;
        last if $worker_pid ne '';
    }
    return ($session, $client_pid, $worker_pid);
}

# ---------------------------------------------------------------------------
# search_scratch_cost_for_relid: the memoized per-query search-scratch cost
# currently charged to a search in flight against $relid. Only meaningful
# while that search's slot is still 'processing' -- typically read while
# parked via park_search_scratch_reservation.
# ---------------------------------------------------------------------------
sub search_scratch_cost_for_relid
{
    my ($node, $db, $relid) = @_;
    my $cost = $node->safe_psql($db,
        "SELECT search_scratch_bytes_per_query FROM pg_stat_vamana_worker_slot "
      . "WHERE index_relid = $relid AND slot_status = 'processing';");
    chomp $cost;
    return $cost;
}

# ---------------------------------------------------------------------------
# release_search_scratch_reservation: wake and detach a reservation parked by
# park_search_scratch_reservation, then let $session's search run to
# completion and close it.
# ---------------------------------------------------------------------------
sub release_search_scratch_reservation
{
    my ($node, $db, $session) = @_;
    my $point = 'vamana-search-scratch-reserved';

    $node->safe_psql($db, "SELECT injection_points_wakeup('$point');");
    $session->query('SELECT 1');
    $session->quit;
    $node->safe_psql($db, "SELECT injection_points_detach('$point');");
}

# ---------------------------------------------------------------------------
# worker_committed_totals: $db's own (build_bytes_committed,
# residency_bytes_committed) from the real, running worker's accounting.
# Named worker_committed_totals rather than committed_totals: an
# already-merged test file defines its own differently-shaped
# committed_totals (no $db parameter, hardcoded to 'postgres'), and this
# module's :all export tag is the whole @EXPORT_OK list, so a same-named
# export would collide with that file's own sub under warnings FATAL.
# ---------------------------------------------------------------------------
sub worker_committed_totals
{
    my ($node, $db) = @_;
    my $row = $node->safe_psql('postgres', qq(
        SELECT build_bytes_committed, residency_bytes_committed
        FROM pg_stat_vamana_worker
        WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = '$db');
    ));
    chomp $row;
    return split(/\|/, $row);
}

# ---------------------------------------------------------------------------
# park_build: attach 'wait' to $point, start a background CREATE INDEX of
# $idx on $tbl in $db, and return once it is parked there.  The caller is
# responsible for detaching and waking $point.
# ---------------------------------------------------------------------------
sub park_build
{
    my ($node, $db, $tbl, $idx, $point) = @_;

    $node->safe_psql('postgres', "SELECT injection_points_attach('$point', 'wait');");

    my $build = $node->background_psql($db, on_error_stop => 0);
    $build->query_until(qr/build_started/, qq(
        \\echo build_started
        CREATE INDEX $idx ON $tbl USING vamana (c1 vector_l2_ops);
    ));
    $node->wait_for_event('client backend', $point);

    return $build;
}

1;
