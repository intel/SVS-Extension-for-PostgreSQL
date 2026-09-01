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

1;
