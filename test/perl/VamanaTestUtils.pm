package VamanaTestUtils;

# Shared helpers and deterministic test data for Vamana TAP tests.
#
# All test files call VamanaTestUtils::init() once at the top to get the
# shared scalar globals, then import the helper subs they need.

use strict;
use warnings FATAL => 'all';
use Exporter qw(import);
use File::Temp qw(tempdir);
use POSIX      qw(waitpid _exit);
use Time::HiRes qw(usleep);

our @EXPORT_OK = qw(
    $dim $array_sql $query_sql $lv_query_sql
    $N @query_vecs $SYNC_SLEEP
    run_concurrent run_synchronized dir_size
    wait_for_worker
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

# Batch section: N distinct query vectors generated after $query_sql so the
# srand(42) seed produces the same $query_sql as in the original merged file.
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
            if (open(my $fh, '>', "$tmpdir/r$i.txt"))
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
            if (open(my $fh, '>', "$tmpdir/r$i.txt"))
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
# dir_size: sum file sizes in a flat directory.
# Vamana index directories contain only top-level files — no subdirectories.
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
          . "WHERE backend_type = 'vamana background worker' LIMIT 1;");
        chomp $pid;
        return $pid if $pid =~ /^\d+$/;
    }
    return '';
}

1;
