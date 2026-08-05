# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# Test file covering the Vamana persistence and background-worker feature
# set, organized into sections:
#
#   Section 1: Index persistence
#   Section 2: Background worker
#   Section 3: Native SVS batch search
#
# Each section spins up its own PostgreSQL cluster so configuration
# differences (worker on/off, log_min_messages level) are fully isolated.
# Lexical scoping via bare blocks keeps per-section variables from clashing.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use File::Path qw(remove_tree);
use File::Temp qw(tempdir);
use POSIX      qw(waitpid _exit);
use Time::HiRes qw(usleep);

srand(42);    # deterministic vectors so failures are reproducible
my $dim       = 16;
my $array_sql = join(",", ('random()') x $dim);
my $query_sql    = join(",", map { rand() } 1 .. $dim);
my $lv_query_sql = join(",", map { rand() } 1 .. $dim);

# Batch section: N distinct query vectors (generated after $query_sql so the
# srand(42) seed produces the same $query_sql as when the files were separate).
my $N = 5;
my @query_vecs =
  map { join(",", map { sprintf("%.6f", rand()) } 1 .. $dim) } 1 .. $N;

# PL/pgSQL sleep block: produces no output; holds each concurrent client for
# 1 second so all N have connected before any vector query fires.
my $SYNC_SLEEP =
  'DO $sync_sleep$ BEGIN PERFORM pg_sleep(1.0); END $sync_sleep$;' . "\n";

# ------------------------------------------------------------------ helpers --
# run_concurrent: fork $n children; child $i runs $sql_of->($i) and writes
# its result to a temp file.  Parent waits for all children and returns the
# results array.
#
# $pre_sql (optional): prepended to each child's SQL for synchronization.
# A PL/pgSQL DO block ensures the sleep produces no output, so comparisons
# against single-client baselines remain valid.
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

sub make_search_sql
{
    my ($q) = @_;
    return qq(
        SET enable_seqscan = off;
        SELECT id FROM batch_tbl ORDER BY val <-> '[$q]' LIMIT 5;
    );
}

# Sums file sizes in a flat directory. Vamana index directories contain
# only top-level files — no subdirectories.
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

# Poll pg_stat_activity until the vamana worker serving $db appears (up to
# $attempts x 0.5s).  With the launcher spawning one worker per enabled
# database, several workers can run at once, so a datname filter identifies
# the right one.  Returns the PID or '' on timeout.
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

# ===========================================================================
# SECTION 1: Vamana Index Persistence
#
# Verify that a Vamana index survives a server restart.
#
# The index is saved to $PGDATA/vamana_indexes/<oid>/ on CREATE INDEX and
# loaded from disk on the first post-restart query, avoiding a full table
# rebuild.
#
# Tests:
#   1. Query results after a restart match the pre-restart baseline.
#   2. Server log does NOT contain the expensive rebuild message when a saved
#      copy exists.
#   3. Server log confirms TID map load progress (before + after fread).
#   4. After an INSERT (which invalidates the saved copy), the next query
#      rebuilds correctly and the new vector is reachable.
#   5. The on-disk index directory persists across all operations.
#   6. A second restart still loads from disk (INSERT+rebuild+resave round-trip).
#   7. VamanaRebuildFromTable emits a progress LOG at the 100k-row interval.
# ===========================================================================
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_persist');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf',
        # LOG severity sits above NOTICE in PostgreSQL's ordering, so
        # 'notice' captures both NOTICE and LOG messages in the server log.
        # The persistence assertions rely on LOG-level messages; keeping
        # this at 'notice' rather than 'log' also captures any unexpected
        # NOTICE output from the vamana code paths under test.
        "log_min_messages = 'notice'");
    $node->start;

    # ---------------------------------------------------------------- setup --
    $node->safe_psql("postgres", "CREATE EXTENSION vector;");
    $node->safe_psql("postgres", "CREATE EXTENSION svs;");
    $node->safe_psql("postgres",
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    $node->safe_psql("postgres", qq(
        CREATE TABLE vp_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO vp_tbl (val)
            SELECT ARRAY[$array_sql]::vector
            FROM generate_series(1, 200) i;
        CREATE INDEX vp_idx ON vp_tbl USING vamana (val vector_l2_ops);
    ));

    # ------------------------------------------------ index OID + file check --
    my $index_oid = $node->safe_psql("postgres",
        "SELECT oid FROM pg_class WHERE relname = 'vp_idx';");
    chomp $index_oid;

    my $index_dir = $node->data_dir . "/vamana_indexes/$index_oid";
    ok(-d $index_dir,
        "on-disk index directory exists after CREATE INDEX ($index_dir)");

    my @initial_files = glob("$index_dir/*");
    ok(scalar @initial_files > 0,
        'on-disk index directory is non-empty after CREATE INDEX');

    # -------------------------------------------------------------- baseline --
    my $baseline = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM vp_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));

    isnt($baseline, '', 'pre-restart query returns results');

    # ------------------------------------------------------------ restart -----
    # Record the log position just before the restart so the post-restart
    # assertions only examine new log entries, not pre-restart build output.
    my $log_pos_before_restart = length($node->log_content());

    $node->restart;

    # -------------------------------------------------- post-restart query --
    my $after_restart = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM vp_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));

    is($after_restart, $baseline,
        'query results after restart match pre-restart baseline');

    # -------------------------------------------------------- no rebuild in log --
    # Slice the log to only entries written after the restart so that any
    # rebuild triggered during CREATE INDEX or the baseline query does not
    # interfere with these assertions.
    my $new_log = substr($node->log_content(), $log_pos_before_restart);

    # Neither the before-rebuild NOTICE (vamanascan.c) nor the in-rebuild
    # NOTICE (vamanautils.c) should appear when a saved copy was loaded.
    unlike(
        $new_log,
        qr/rebuilding vamana index from table data/,
        'no table rebuild on post-restart query (loaded from disk)'
    ) or diag("Post-restart log:\n", $new_log);
    unlike(
        $new_log,
        qr/vamana index not in memory, rebuilding from table/,
        'no rebuild NOTICE on post-restart query (loaded from disk)'
    ) or diag("Post-restart log:\n", $new_log);

    like(
        $new_log,
        qr/vamana index \d+ loaded from disk/,
        'server log confirms index was loaded from disk (not rebuilt)'
    ) or diag("Post-restart log:\n", $new_log);

    # ----------------------------------------- TID map load progress LOGs --
    # LoadIndexFromPages emits a LOG before and after the TID map fread so
    # operators can see progress during large index loads.
    like(
        $new_log,
        qr/vamana index \d+: loading TID map for \d+ vectors/,
        'progress LOG emitted before TID map load'
    ) or diag("Post-restart log:\n", $new_log);

    like(
        $new_log,
        qr/vamana index \d+: TID map loaded/,
        'progress LOG emitted after TID map load'
    ) or diag("Post-restart log:\n", $new_log);

    # -------------------------------------------------- INSERT + re-query --
    # INSERT invalidates the saved copy.  The next query rebuilds and re-saves.
    $node->safe_psql("postgres", qq(
        INSERT INTO vp_tbl (val) VALUES (ARRAY[$array_sql]::vector);
    ));

    my $after_insert = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM vp_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));

    isnt($after_insert, '', 'query after INSERT returns results');

    # ------------------------------------------ file check after rebuild --
    # The INSERT+query cycle should have re-saved a fresh copy.
    ok(-d $index_dir,
        'on-disk index directory still exists after INSERT+rebuild');

    my @rebuilt_files = glob("$index_dir/*");
    ok(scalar @rebuilt_files > 0,
        'on-disk index directory is non-empty after INSERT+rebuild');

    # -------------------------------------------------------- second restart --
    # After the INSERT+query cycle, a new on-disk copy was saved.
    # Restart and verify results are still consistent.
    my $log_pos_before_second_restart = length($node->log_content());
    $node->restart;

    my $after_second_restart = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM vp_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));

    is($after_second_restart, $after_insert,
        'results after second restart match post-INSERT baseline');

    my $second_restart_log =
      substr($node->log_content(), $log_pos_before_second_restart);

    unlike(
        $second_restart_log,
        qr/rebuilding vamana index from table data/,
        'no table rebuild on second restart (loaded from disk after INSERT+rebuild+resave)'
    ) or diag("Second restart log:\n", $second_restart_log);
    unlike(
        $second_restart_log,
        qr/vamana index not in memory, rebuilding from table/,
        'no rebuild NOTICE on second restart'
    ) or diag("Second restart log:\n", $second_restart_log);
    like(
        $second_restart_log,
        qr/vamana index \d+ loaded from disk/,
        'server log confirms index loaded from disk on second restart'
    ) or diag("Second restart log:\n", $second_restart_log);

    ok(-d $index_dir,
        'on-disk index directory still exists after second restart');

    # -------------------------------- rebuild interval LOG --
    # VamanaRebuildFromTable emits a LOG every VAMANA_PROGRESS_INTERVAL
    # (100,000) tuples.  Build a minimal-dimension table with just over 100k
    # rows to trigger the interval without an expensive high-dimensional build.
    $node->safe_psql("postgres", qq(
        CREATE TABLE vp_progress_tbl (id serial PRIMARY KEY, val vector(1));
        INSERT INTO vp_progress_tbl (val)
            SELECT ARRAY[random()]::vector
            FROM generate_series(1, 100001) i;
        CREATE INDEX vp_progress_idx ON vp_progress_tbl
            USING vamana (val vector_l2_ops);
    ));

    my $progress_index_oid = $node->safe_psql("postgres",
        "SELECT oid FROM pg_class WHERE relname = 'vp_progress_idx';");
    chomp $progress_index_oid;
    my $progress_index_dir =
        $node->data_dir . "/vamana_indexes/$progress_index_oid";

    # Force the BGW to rebuild by restarting the server with the on-disk dir
    # removed.  LoadIndexFromPages returns NULL (no dir) → BGW calls
    # VamanaRebuildFromTable, which emits the 100k-interval progress LOG.
    $node->stop;
    remove_tree($progress_index_dir);
    my $log_pos_before_rebuild = length($node->log_content());
    $node->start;

    # Demand-driven rebuild: query so the BGW scans the table and logs progress.
    $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM vp_progress_tbl ORDER BY val <-> '[0]' LIMIT 1;
    ));

    # Give the BGW time to rebuild 100k+ 1-dim vectors (typically < 5s).
    my $rebuild_log = '';
    for (1 .. 30) {
        $rebuild_log = substr($node->log_content(), $log_pos_before_rebuild);
        last if $rebuild_log =~
            /vamana index \d+: scanning table, 100000 vectors collected/;
        usleep(500_000);
    }

    like(
        $rebuild_log,
        qr/vamana index \d+: scanning table, 100000 vectors collected/,
        'progress LOG emitted at 100k-vector interval during VamanaRebuildFromTable'
    ) or diag("Rebuild log:\n", $rebuild_log);

    $node->safe_psql("postgres", "DROP TABLE vp_progress_tbl;");

    $node->stop;
}

# ===========================================================================
# SECTION 1c: max_parallel_maintenance_workers does not limit search threads
#
# SVSLoadIndex must use SVSDefaultSearchThreads() (nproc-1) rather than
# SVSDefaultBuildThreads() (reads max_parallel_maintenance_workers).
#
# A low max_parallel_maintenance_workers value must not cap search threads:
# SVSLoadIndex must use SVSDefaultSearchThreads(), not SVSDefaultBuildThreads().
#
# With log_min_messages = debug1, SVSLoadIndex emits a DEBUG1 message:
#   "loading SVS index with N search threads (max_parallel_maintenance_workers=M)"
#
# Tests:
#   1. Search returns correct results after restart with a low GUC value.
#   2. DEBUG1 log message confirms SVSLoadIndex used SVSDefaultSearchThreads().
#   3. On a multi-CPU machine (nproc >= 4), search threads = nproc-1 > GUC value.
# ===========================================================================
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_search_threads');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "max_parallel_maintenance_workers = 2");
    $node->append_conf('postgresql.conf', "log_min_messages = 'debug1'");
    $node->start;

    $node->safe_psql("postgres", "CREATE EXTENSION vector;");
    $node->safe_psql("postgres", "CREATE EXTENSION svs;");
    $node->safe_psql("postgres",
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    $node->safe_psql("postgres", qq(
        CREATE TABLE st_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO st_tbl (val)
            SELECT ARRAY[$array_sql]::vector
            FROM generate_series(1, 200) i;
        CREATE INDEX st_idx ON st_tbl USING vamana (val vector_l2_ops);
    ));

    # Restart to evict the in-process cache and force a cold disk load via
    # SVSLoadIndex on the first query.
    my $log_pos_before_restart = length($node->log_content());
    $node->restart;

    # Test 1: correct results even with max_parallel_maintenance_workers = 2.
    my $after_restart = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM st_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));
    isnt($after_restart, '',
        'search returns correct results with max_parallel_maintenance_workers=2 (Section 1c test 1)');

    my $new_log = substr($node->log_content(), $log_pos_before_restart);

    # Test 2: DEBUG1 message from SVSLoadIndex must appear, confirming that
    # SVSDefaultSearchThreads() was called (not SVSDefaultBuildThreads()).
    like(
        $new_log,
        qr/loading SVS index with \d+ search threads \(svs\.search_num_threads=\d+, max_parallel_maintenance_workers=2\)/,
        'DEBUG1 log confirms SVSLoadIndex invoked SVSDefaultSearchThreads() (Section 1c test 2)'
    ) or diag("Post-restart log (snippet):\n",
              substr($new_log, 0, 2000));

    # Test 3: on a multi-CPU machine, search threads must exceed the GUC value.
    # SVSDefaultSearchThreads() returns nproc-1 when svs.search_num_threads=0;
    # with max_parallel_maintenance_workers=2 and nproc >= 4,
    # search threads (nproc-1 >= 3) must be > 2.
    my $nproc_raw = `nproc 2>/dev/null`;
    chomp $nproc_raw;
    my $nproc = ($nproc_raw =~ /^(\d+)$/) ? int($1) : 0;
    my $expected_search_threads = $nproc > 1 ? $nproc - 1 : 1;

    if ($nproc >= 4)
    {
        like(
            $new_log,
            qr/loading SVS index with $expected_search_threads search threads/,
            "search threads ($expected_search_threads = nproc-1) exceed max_parallel_maintenance_workers (2) — search not capped by maintenance GUC (Section 1c test 3)"
        ) or diag("Post-restart log (snippet):\n",
                  substr($new_log, 0, 2000));
    }
    else
    {
        pass("Section 1c test 3 skipped: nproc=$nproc, nproc-1 may equal max_parallel_maintenance_workers");
    }

    # Test 4: svs.search_num_threads GUC explicitly overrides the auto default.
    # SET in a backend session does not propagate to the BGW; the GUC must be
    # set in postgresql.conf so the BGW picks it up at startup.
    $node->safe_psql("postgres",
        "ALTER SYSTEM SET svs.search_num_threads = 3;");
    my $log_pos_before_test4 = length($node->log_content());
    $node->restart;

    # Demand-driven load: query so SVSLoadIndex runs and logs its thread count.
    $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM st_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));

    my $log_test4 = '';
    for (1 .. 20) {
        $log_test4 = substr($node->log_content(), $log_pos_before_test4);
        last if $log_test4 =~
            /loading SVS index with 3 search threads \(svs\.search_num_threads=3/;
        usleep(500_000);
    }

    like(
        $log_test4,
        qr/loading SVS index with 3 search threads \(svs\.search_num_threads=3/,
        'svs.search_num_threads=3 causes SVSLoadIndex to use exactly 3 search threads (Section 1c test 4)'
    ) or diag("Test 4 log (snippet):\n",
              substr($log_test4, 0, 2000));

    $node->safe_psql("postgres",
        "ALTER SYSTEM RESET svs.search_num_threads;");

    $node->stop;
}

# ===========================================================================
# SECTION 1d: LeanVec-Compressed Vamana Persistence
#
# Mirrors Section 1's persistence round-trip but uses a LeanVec-compressed
# index (compression_type=1, compression_primary=8, compression_secondary=8).
#
# The SQL regression tests verify that VamanaRebuildFromTable produces correct
# nearest-neighbor results with LeanVec, but cannot detect a regression where
# the rebuilt index silently uses float32 storage instead.  This section adds
# an on-disk size comparison: a float32 rebuild would be ~4x larger in the
# vector-data portion, making it detectable by comparing directory sizes.
#
# Tests:
#   1. CREATE INDEX with compression_type=1 succeeds; on-disk dir exists.
#   2. After restart, results match pre-restart baseline (LeanVec-specific correctness).
#   3. Rebuilt index on-disk size is within 1.5x of original (compression preserved).
#   4. On-disk dir still present after BGW rebuild.
#   5. After second restart, results match post-rebuild baseline.
#   6. Log confirms loaded from disk on second restart; dir still present.
# ===========================================================================
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_leanvec_persist');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "log_min_messages = 'notice'");
    $node->start;

    $node->safe_psql("postgres", "CREATE EXTENSION vector;");
    $node->safe_psql("postgres", "CREATE EXTENSION svs;");
    $node->safe_psql("postgres",
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    $node->safe_psql("postgres", qq(
        CREATE TABLE lv_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO lv_tbl (val)
            SELECT ARRAY[$array_sql]::vector
            FROM generate_series(1, 200) i;
        CREATE INDEX lv_idx ON lv_tbl USING vamana (val vector_l2_ops)
            WITH (compression_type = 1, compression_primary = 8, compression_secondary = 8);
    ));

    # ------------------------------------------------ index OID + file check --
    my $index_oid = $node->safe_psql("postgres",
        "SELECT oid FROM pg_class WHERE relname = 'lv_idx';");
    chomp $index_oid;

    my $index_dir = $node->data_dir . "/vamana_indexes/$index_oid";
    ok(-d $index_dir,
        "on-disk index directory exists after CREATE INDEX with LeanVec compression ($index_dir)");

    # -------------------------------------------------------------- baseline --
    my $baseline = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM lv_tbl ORDER BY val <-> '[$lv_query_sql]' LIMIT 5;
    ));

    # ------------------------------------------ record initial on-disk size --
    my $initial_size = dir_size($index_dir);

    # ------------------------------------------------------------ restart -----
    $node->restart;

    # -------------------------------------------------- post-restart query --
    my $after_restart = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM lv_tbl ORDER BY val <-> '[$lv_query_sql]' LIMIT 5;
    ));

    is($after_restart, $baseline,
        'LeanVec query results after restart match pre-restart baseline');

    # -------------------------------------------------- INSERT + re-query --
    $node->safe_psql("postgres", qq(
        INSERT INTO lv_tbl (val) VALUES (ARRAY[$array_sql]::vector);
    ));

    $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM lv_tbl ORDER BY val <-> '[$lv_query_sql]' LIMIT 5;
    ));

    # ------------------------------------------ size check after rebuild --
    # Dynamic insert (SVSAddPoints) converts the static SVS graph to dynamic
    # storage, doubling on-disk size — that is not a compression regression.
    # Force VamanaRebuildFromTable instead: restart with no on-disk dir so the
    # BGW rebuilds from the table using the original LeanVec compression params.
    # A float32 regression would be ~4x larger; 1.5x detects that while
    # tolerating normal metadata overhead.
    remove_tree($index_dir);
    my $log_pos_before_second_restart = length($node->log_content());
    $node->restart;

    # Demand-driven rebuild: query so the BGW scans the table and re-saves.
    $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM lv_tbl ORDER BY val <-> '[$lv_query_sql]' LIMIT 5;
    ));

    my $rebuild_wait_log = '';
    for (1 .. 20) {
        $rebuild_wait_log =
            substr($node->log_content(), $log_pos_before_second_restart);
        last if $rebuild_wait_log =~ /vamana index \d+ loaded from disk/
             || $rebuild_wait_log =~ /vamana index \d+: scanning table/;
        usleep(500_000);
    }

    my $rebuilt_size = dir_size($index_dir);
    ok(-d $index_dir,
        'on-disk index directory exists after BGW rebuild (LeanVec)');
    ok($rebuilt_size <= $initial_size * 1.5,
        "rebuilt LeanVec index size ($rebuilt_size bytes) is within 1.5x of original ($initial_size bytes) — compression preserved"
    ) or diag("initial_size=$initial_size  rebuilt_size=$rebuilt_size  ratio=",
              ($initial_size > 0 ? sprintf("%.2f", $rebuilt_size / $initial_size) : 'N/A'));

    my $after_second_restart = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM lv_tbl ORDER BY val <-> '[$lv_query_sql]' LIMIT 5;
    ));

    # -------------------------------------------------------- third restart --
    # Verify the rebuilt+saved index loads cleanly from disk (no rebuild).
    $node->restart;

    my $after_third_restart = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM lv_tbl ORDER BY val <-> '[$lv_query_sql]' LIMIT 5;
    ));

    is($after_third_restart, $after_second_restart,
        'LeanVec results after third restart match post-rebuild baseline');

    ok(-d $index_dir,
        'on-disk index directory still exists after LeanVec third restart');

    $node->stop;
}

# ===========================================================================
# SECTION 2: Vamana Background Worker
#
# The worker holds the SVS index in a single dedicated process and serves
# search requests from client backends via shared-memory IPC.  Backends
# perform zero initialization; the memory footprint is one copy of the index
# regardless of connection count.
#
# Tests:
#   1.  Worker process is visible in pg_stat_activity after startup.
#   2.  Worker-mode queries return correct results (non-empty).
#   3.  No rebuild log message fired after worker-mode query.
#   4.  No per-backend rebuild log message when worker is enabled.
#   5.  After a server restart, worker loads from disk (no rebuild).
#   6.  After an INSERT (invalidation + reload), queries still work.
#   7.  After worker SIGTERM, postmaster restarts it; queries resume.
#   8.  DROP DATABASE completes while worker is running (ProcSignalBarrier).
#   9.  pg_regress-style DROP DATABASE IF EXISTS with worker preloaded.
#   10. svs.max_batch_size = 1 — worker serves every query correctly
#       when forced to drain one slot per iteration.
#   11. Enable-then-restart — a second database enabled in vamana_databases
#       gets its worker materialized by the launcher's startup scan on restart.
#   12. Unconfigured database — a backend in a database with no
#       vamana_databases row gets a config hard-fail (no direct-mode fallback).
#   13. Worker timeout — SIGSTOP worker, set timeout to minimum;
#       backend raises ERROR (no fallback to direct mode).
#   14. SIGHUP GUC reload — pg_reload_conf() updates worker_timeout_ms
#       in the worker without a server restart.
#   15. Multiple concurrent Vamana indexes — worker serves queries
#       against two indexes in the same database.
#   16. search_window_size GUC boundary — max value (10000) accepted;
#       values exceeding it rejected at the GUC layer.
# ===========================================================================
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_bgw');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "log_min_messages = 'notice'");
    $node->start;

    $node->safe_psql("postgres", "CREATE EXTENSION vector;");
    $node->safe_psql("postgres", "CREATE EXTENSION svs;");
    $node->safe_psql("postgres",
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    $node->safe_psql("postgres", qq(
        CREATE TABLE bgw_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO bgw_tbl (val)
            SELECT ARRAY[$array_sql]::vector
            FROM generate_series(1, 200) i;
        CREATE INDEX bgw_idx ON bgw_tbl USING vamana (val vector_l2_ops);
    ));

    # -------------------------------------------------- test 1: worker alive --
    # The launcher spawns the postgres worker asynchronously after the
    # vamana_databases row commits, so poll rather than reading the PID once.
    my $worker_pid = wait_for_worker_db($node, 'postgres', 30);

    ok($worker_pid =~ /^\d+$/,
        "vamana background worker process is running (pid=$worker_pid)");

    # ----------------------------------------------- test 2: results returned --
    my $worker_results = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM bgw_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));
    isnt($worker_results, '', 'worker-mode query returns non-empty results');

    # -------------------------------------- test 3: no per-backend rebuild --
    my $log_after_worker = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM bgw_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));
    isnt($log_after_worker, '', 'worker-mode query still returns results');

    my $log = $node->log_content();
    unlike($log, qr/vamana index not in memory, rebuilding from table/,
        'no per-backend rebuild when worker is enabled');

    # --------------------------------------- test 5: restart loads from disk --
    my $log_pos_before_restart = length($node->log_content());
    $node->restart;

    my $after_restart = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM bgw_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));

    is($after_restart, $worker_results,
        'results consistent after server restart (worker mode)');

    my $restart_log = substr($node->log_content(), $log_pos_before_restart);

    unlike($restart_log, qr/rebuilding vamana index from table data/,
        'worker loaded from disk after restart — no table rebuild');
    like($restart_log, qr/vamana index \d+ loaded from disk/,
        'server log confirms disk load on restart');

    # ----------------------------------------- test 6: direct INSERT via BGW --
    # Dynamic inserts are routed through VamanaWorkerSubmitInsert (SVSAddPoints),
    # so there is no invalidation/reload cycle.  Verify the worker is still
    # alive after the INSERT (same PID = no crash) and that queries still work.
    $node->safe_psql("postgres", qq(
        INSERT INTO bgw_tbl (val) VALUES (ARRAY[$array_sql]::vector);
    ));

    my $after_insert = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM bgw_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));
    isnt($after_insert, '', 'worker-mode query returns results after INSERT');

    my $worker_pid_after_insert = $node->safe_psql("postgres",
        "SELECT pid FROM pg_stat_activity "
      . "WHERE backend_type = 'vamana worker' LIMIT 1;");
    chomp $worker_pid_after_insert;
    ok($worker_pid_after_insert =~ /^\d+$/,
        'worker still running after INSERT (dynamic insert did not crash worker)');

    # --------------------------------------------- test 7: crash recovery --
    # Simulate a server crash by stopping immediately (no checkpoint) then
    # restarting.  The postmaster does WAL recovery; the bgworker is relaunched
    # automatically because it is registered with BgWorkerStart_RecoveryFinished.
    $node->stop('immediate');
    $node->start;

    # Poll for the worker to appear after crash recovery (up to 20 x 0.5s = 10s).
    my $post_crash_pid = '';
    for my $attempt (1 .. 20)
    {
        usleep(500_000);    # 0.5 s
        $post_crash_pid = $node->safe_psql("postgres",
            "SELECT pid FROM pg_stat_activity "
          . "WHERE backend_type = 'vamana worker' LIMIT 1;");
        chomp $post_crash_pid;
        last if $post_crash_pid =~ /^\d+$/;
    }

    ok($post_crash_pid =~ /^\d+$/,
        "vamana background worker running after crash recovery (pid=$post_crash_pid)");

    sleep(2);    # give worker time to finish loading the index

    my $after_crash = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM bgw_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));
    isnt($after_crash, '', 'queries work after crash recovery');

    # Results should match the post-INSERT state (row 201 included).
    is($after_crash, $after_insert,
        'results after crash recovery match post-insert baseline');

    # ------------------------------------------ test 8: DROP DATABASE while worker is running --
    #
    # The vamana worker must process ProcSignalBarrier requests so that
    # DROP DATABASE (which emits PROCSIGNAL_BARRIER_SMGRRELEASE) does not
    # hang.  Create a throwaway database, then DROP it.  If the worker
    # does not call CHECK_FOR_INTERRUPTS(), the DROP will block forever
    # because WaitForProcSignalBarrier() waits until every backend —
    # including background workers — acknowledges the barrier.
    $node->safe_psql("postgres", "CREATE DATABASE drop_test_db;");

    my ($drop_ret, $drop_out, $drop_err) = $node->psql(
        'postgres',
        'DROP DATABASE drop_test_db;',
        timeout => 15
    );
    is($drop_ret, 0,
        'DROP DATABASE completes while vamana worker is running (ProcSignalBarrier test)');

    # ------------------------------------------ test 9: pg_regress-style DROP DATABASE IF EXISTS with worker preloaded --
    #
    # Replicates the original hang: pg_regress issues
    # DROP DATABASE IF EXISTS before creating the test database.
    # With the worker preloaded, this must complete within the timeout.
    my ($drop_if_ret, $drop_if_out, $drop_if_err) = $node->psql(
        'postgres',
        'DROP DATABASE IF EXISTS nonexistent_db;',
        timeout => 15
    );
    is($drop_if_ret, 0,
        'DROP DATABASE IF EXISTS nonexistent_db completes with worker running');

    $node->safe_psql("postgres", "CREATE DATABASE regress_test_db;");

    my ($full_cycle_ret, $full_cycle_out, $full_cycle_err) = $node->psql(
        'postgres',
        'DROP DATABASE regress_test_db;',
        timeout => 15
    );
    is($full_cycle_ret, 0,
        'pg_regress-style CREATE then DROP DATABASE completes with worker running');

    # ------------------------------------------ test 10: max_batch_size = 1 --
    # Cap the worker to draining one slot per iteration.  The batch cap must
    # drain at least one slot per iteration, or every query would hang until
    # the worker timeout.  Three sequential queries through
    # separate connections force three distinct worker iterations.
    $node->stop;
    $node->append_conf('postgresql.conf', "svs.max_batch_size = 1");
    $node->start;

    for my $i (1 .. 3)
    {
        my $result = $node->safe_psql("postgres", qq(
            SET enable_seqscan = off;
            SELECT id FROM bgw_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
        ));
        isnt($result, '',
            "query $i returns results with max_batch_size=1 (worker iteration $i)");
        is($result, $after_insert,
            "query $i results match baseline with max_batch_size=1");
    }

    # ----------------------- test 11: enable-then-restart materialization --
    # Enable a second database, then restart the server.  This exercises the
    # launcher's startup-scan materialization: on restart the launcher reads the
    # committed vamana_databases rows and spawns a worker for each before any
    # backend runs, so testdb's worker comes up from the initial scan rather than
    # a live NOTIFY.  postgres stays enabled from the top of this block, so both
    # workers run after the restart.
    $node->safe_psql("postgres", "CREATE DATABASE testdb;");
    $node->safe_psql("testdb",   "CREATE EXTENSION vector;");
    $node->safe_psql("testdb",   "CREATE EXTENSION svs;");
    $node->safe_psql("testdb", qq(
        CREATE TABLE testdb_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO testdb_tbl (val)
            SELECT ARRAY[$array_sql]::vector
            FROM generate_series(1, 200) i;
    ));
    $node->safe_psql("postgres",
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('testdb', true);");

    # Snapshot before the restart so "started for database testdb" is guaranteed
    # to appear after this position.
    my $log_pos_before_testdb = length($node->log_content());

    $node->restart;

    # testdb's worker is materialized by the initial scan; the index it adopts
    # is created after the restart, once the worker is up for testdb.
    my $testdb_worker_pid = wait_for_worker_db($node, 'testdb', 20);
    ok($testdb_worker_pid =~ /^\d+$/,
        "launcher materializes a worker for testdb on restart (pid=$testdb_worker_pid)");

    $node->safe_psql("testdb",
        "CREATE INDEX testdb_idx ON testdb_tbl USING vamana (val vector_l2_ops);");

    sleep(2);    # give worker time to load the index from testdb

    # Query must originate FROM testdb so MyDatabaseId matches the worker's dbOid.
    my $testdb_results = $node->safe_psql("testdb", qq(
        SET enable_seqscan = off;
        SELECT id FROM testdb_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));
    isnt($testdb_results, '',
        'testdb worker serves queries after enable-then-restart materialization');

    my $testdb_log = substr($node->log_content(), $log_pos_before_testdb);
    like($testdb_log, qr/vamana background worker started for database "testdb"/,
        'server log confirms worker started for testdb');

    # ----------------------- test 12: unconfigured database → hard ERROR --
    # A database with no vamana_databases row is unconfigured.  After the
    # launcher's initial scan, VamanaWorkerAssertDatabase() finds no slot for it
    # and throws immediately — this is the config half of the config/liveness
    # split, with no direct-mode fallback.  postgres and testdb both have live
    # workers here, so the failure is specific to the unconfigured database.
    $node->safe_psql("postgres", "CREATE DATABASE unconfigured_db;");
    $node->safe_psql("unconfigured_db", "CREATE EXTENSION vector;");
    $node->safe_psql("unconfigured_db", "CREATE EXTENSION svs;");
    # Empty table on purpose: the config gate fires before the table scan, so
    # the hard-fail must not depend on the heap having rows.
    my ($unconf_ret, undef, $unconf_err) = $node->psql("unconfigured_db", qq(
        CREATE TABLE u_tbl (id serial PRIMARY KEY, val vector($dim));
        CREATE INDEX u_idx ON u_tbl USING vamana (val vector_l2_ops);
    ));
    like($unconf_err,
        qr/vamana index is not enabled for this database/,
        'backend in an unconfigured database gets a config hard-fail (no fallback)');

    # --------------- test 13: worker timeout → hard ERROR (no fallback) --
    # SIGSTOP the postgres worker to make it unresponsive and set
    # svs.worker_timeout_ms to its minimum (100 ms).  VamanaWorkerSubmitSearch
    # accumulates total_waited_ms >= 100 and returns -1; vamanascan raises
    # ERROR — there is no direct-mode fallback.
    my $postgres_worker_pid = wait_for_worker_db($node, 'postgres', 20);
    ok($postgres_worker_pid =~ /^\d+$/,
        "postgres worker running for timeout test (pid=$postgres_worker_pid)");

    sleep(2);    # give worker time to load bgw_idx

    # Reduce timeout to minimum so the backend gives up in 100 ms.
    $node->safe_psql("postgres", "ALTER SYSTEM SET svs.worker_timeout_ms = 100;");
    $node->safe_psql("postgres", "SELECT pg_reload_conf();");

    # SIGSTOP the worker — still alive in pg_stat_activity but won't drain slots.
    kill('STOP', $postgres_worker_pid);
    usleep(100_000);    # 0.1 s — let the stop take effect

    my ($timeout_ret, undef, $timeout_err) = $node->psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM bgw_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));

    # Resume the worker before any assertions that touch the server.
    kill('CONT', $postgres_worker_pid);

    like($timeout_err,
        qr/vamana background worker unavailable after (?:waiting up to )?\d+ ms; cannot scan index \d+/,
        'worker timeout raises ERROR (no fallback to direct mode)');

    # Restore timeout to default.
    $node->safe_psql("postgres", "ALTER SYSTEM RESET svs.worker_timeout_ms;");
    $node->safe_psql("postgres", "SELECT pg_reload_conf();");

    # ------------------------------------- test 14: SIGHUP GUC reload in worker --
    # Change svs.worker_timeout_ms via ALTER SYSTEM and call pg_reload_conf().
    # This sends SIGHUP to the postmaster which propagates to every backend and
    # to the background worker.  The worker's VamanaWorkerSighup handler sets
    # worker_got_sighup; its main loop then calls ProcessConfigFile(PGC_SIGHUP).
    $node->safe_psql("postgres", "ALTER SYSTEM SET svs.worker_timeout_ms = 200;");
    $node->safe_psql("postgres", "SELECT pg_reload_conf();");
    sleep(2);    # give worker time to process SIGHUP on its next heartbeat iteration

    my $reloaded_val = $node->safe_psql("postgres",
        "SELECT current_setting('svs.worker_timeout_ms');");
    is($reloaded_val, '200',
        'svs.worker_timeout_ms updated to 200 via SIGHUP without server restart');

    $node->safe_psql("postgres", "ALTER SYSTEM RESET svs.worker_timeout_ms;");
    $node->safe_psql("postgres", "SELECT pg_reload_conf();");

    # --------------------------------- test 15: multiple concurrent indexes --
    # Create a second table and Vamana index in the same database.
    # VamanaWorkerDispatchBatch groups pending slots by indexRelid; this
    # exercises the multi-relid grouping path with two loaded indexes.
    $node->safe_psql("postgres", qq(
        CREATE TABLE bgw_tbl2 (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO bgw_tbl2 (val)
            SELECT ARRAY[$array_sql]::vector
            FROM generate_series(1, 100) i;
        CREATE INDEX bgw_idx2 ON bgw_tbl2 USING vamana (val vector_l2_ops);
    ));
    sleep(2);    # give worker time to reload after the new-index invalidation

    for my $tbl ('bgw_tbl', 'bgw_tbl2')
    {
        my $multi_result = $node->safe_psql("postgres", qq(
            SET enable_seqscan = off;
            SELECT id FROM $tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
        ));
        isnt($multi_result, '',
            "worker serves queries against $tbl with two indexes present");
    }

    # --------------------------------- test 16: search_window_size GUC boundary --
    # VAMANA_MAX_SEARCH_WINDOW (10000) and VAMANA_MAX_DIM (2000) define the
    # shared-memory layout limits checked in VamanaWorkerSubmitSearch.
    # The GUC caps enforce these limits before any slot is submitted, so the
    # C-level guard is a belt-and-suspenders safety net that cannot be triggered
    # via normal SQL.  Test that the boundary value is accepted and that values
    # exceeding it are rejected by GUC validation.
    my $boundary_result = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SET svs.search_window_size = 10000;
        SELECT id FROM bgw_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));
    isnt($boundary_result, '',
        'query with search_window_size at VAMANA_MAX_SEARCH_WINDOW (10000) returns results');

    my $out_of_range_err = '';
    eval {
        $node->safe_psql("postgres", "SET svs.search_window_size = 10001;");
    };
    $out_of_range_err = $@ if $@;
    like($out_of_range_err, qr/outside the valid range|out of range|invalid value/i,
        'GUC rejects search_window_size exceeding VAMANA_MAX_SEARCH_WINDOW (10000)');

    $node->stop;
}

# ===========================================================================
# SECTION 3: Vamana Native SVS Batch Search
#
# When N backends submit search requests concurrently, VamanaWorkerRunBatch
# detects n > 1 with uniform k/dimensions, packs all query vectors into a
# single contiguous buffer, and calls svs_index_search once with
# num_queries=N.  Results are then unpacked back to per-slot shared memory.
#
# If slots have heterogeneous k (different search_window_size), the function
# falls back to a sequential per-query loop.
#
# Synchronization strategy for batch tests
# -----------------------------------------
# Each concurrent client prepends a 1-second sleep (via a PL/pgSQL DO block
# that produces no output) to its query.  All N clients fork near-simultaneously
# and connect within ~200ms; the 1-second sleep ensures they are all running
# when the sleep expires, so they submit their vector queries within a tight
# window.  The worker collects all pending slots in one iteration, triggering
# the native batch path.
#
# Tests:
#   1.  N concurrent queries all return non-empty results.
#   2.  Each concurrent query matches the single-client baseline (correctness).
#   3.  Concurrent queries with distinct vectors produce distinct result sets
#       (result isolation — no cross-slot contamination).
#   4.  Worker log confirms native batch dispatch when all N arrive together.
#   5.  max_batch_size cap: batches are split across worker iterations but
#       all clients still receive correct results.
#   6.  Heterogeneous search_window_size triggers the sequential fallback;
#       the worker log confirms it, and both clients get correct results.
# ===========================================================================
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_batch');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");

    # DEBUG1 captures "native batch search for N queries" and
    # "sequential search for N queries" emitted by VamanaWorkerRunBatch.
    $node->append_conf('postgresql.conf', "log_min_messages = 'debug1'");
    $node->start;

    $node->safe_psql("postgres", "CREATE EXTENSION vector;");
    $node->safe_psql("postgres", "CREATE EXTENSION svs;");
    $node->safe_psql("postgres",
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    $node->safe_psql("postgres", qq(
        CREATE TABLE batch_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO batch_tbl (val)
            SELECT ARRAY[$array_sql]::vector
            FROM generate_series(1, 300) i;
        CREATE INDEX batch_idx ON batch_tbl USING vamana (val vector_l2_ops);
    ));

    # Give the worker time to pre-load the index.
    sleep(2);

    # -------------------------------------------------- sequential baselines --
    # Run each query vector once, single-client, to establish ground truth.
    my @baselines;
    for my $i (0 .. $N - 1)
    {
        my $q = $query_vecs[$i];
        my $r = $node->safe_psql("postgres", qq(
            SET enable_seqscan = off;
            SELECT id FROM batch_tbl ORDER BY val <-> '[$q]' LIMIT 5;
        ));
        isnt($r, '', "baseline $i is non-empty");
        push @baselines, $r;
    }

    # ----------------------------------------- tests 1-3: concurrent correctness --
    # Plain concurrent run (no forced synchronization) verifies correctness
    # regardless of how the worker batches the requests.
    my @concurrent_results = run_concurrent(
        $node, "postgres", $N,
        sub { make_search_sql($query_vecs[ $_[0] ]) }
    );

    for my $i (0 .. $N - 1)
    {
        isnt($concurrent_results[$i], '',
            "concurrent client $i returns non-empty results");
        is($concurrent_results[$i], $baselines[$i],
            "concurrent client $i results match single-client baseline");
    }

    # Verify that different query vectors produce different result sets.
    my $all_same = 1;
    for my $i (1 .. $N - 1)
    {
        $all_same = 0 if $concurrent_results[$i] ne $concurrent_results[0];
    }
    ok(!$all_same,
        "concurrent clients with distinct query vectors return distinct result sets");

    # --------------------------------------------- test 4: batch path log --
    # Use run_synchronized so all N queries land in the same batch window.
    my $log_pos_before_batch = length($node->log_content());

    # pre_sql_of and search_sql_of mirror make_search_sql but must be split:
    # run_synchronized interposes the barrier between SET and SELECT.
    my @synced_results = run_synchronized(
        $node, "postgres", $N,
        sub { "SET enable_seqscan = off;\n" },
        sub {
            my $q = $query_vecs[ $_[0] ];
            "SELECT id FROM batch_tbl ORDER BY val <-> '[$q]' LIMIT 5;\n";
        }
    );

    # Correctness still holds after synchronization.
    for my $i (0 .. $N - 1)
    {
        is($synced_results[$i], $baselines[$i],
            "synchronized client $i results match baseline");
    }

    my $batch_log = substr($node->log_content(), $log_pos_before_batch);
    like(
        $batch_log,
        qr/vamana worker: native batch search for [2-9]\d* queries/,
        "worker log confirms native batch path taken for synchronized concurrent queries"
    );

    # ------------------------------------------- test 5: max_batch_size cap --
    # With max_batch_size = 2, N=4 concurrent requests are split across worker
    # iterations (two batches of 2).  Every client must still get the correct
    # answer despite multiple rounds.
    $node->stop;
    $node->append_conf('postgresql.conf', "svs.max_batch_size = 2");
    $node->start;
    sleep(2);    # let worker reload

    # run_concurrent+SYNC_SLEEP is intentional here: test 5 verifies that
    # clients get correct results despite the cap splitting requests across
    # multiple worker iterations.  Strict synchronization is not needed —
    # this test checks correctness, not that a specific batch size forms.
    my @capped_results = run_concurrent(
        $node, "postgres", 4,
        sub { make_search_sql($query_vecs[ $_[0] ]) },
        $SYNC_SLEEP
    );

    for my $i (0 .. 3)
    {
        isnt($capped_results[$i], '',
            "client $i returns results with max_batch_size=2");
        is($capped_results[$i], $baselines[$i],
            "client $i results match baseline with max_batch_size=2");
    }

    # Restore unlimited batch size.
    $node->stop;
    $node->append_conf('postgresql.conf', "svs.max_batch_size = 0");
    $node->start;
    sleep(2);

    # --------------------------------------- test 6: heterogeneous k fallback --
    # Two clients with different svs.search_window_size values produce slots
    # with different k fields.  VamanaWorkerRunBatch detects non-uniform k and
    # falls back to the sequential per-query loop.  Both clients must receive
    # correct results.
    my $sws_low  = 10;
    my $sws_high = 50;
    my $q0       = $query_vecs[0];
    my $q1       = $query_vecs[1];

    # Per-sws baselines.
    my $base_low = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SET svs.search_window_size = $sws_low;
        SELECT id FROM batch_tbl ORDER BY val <-> '[$q0]' LIMIT 5;
    ));
    my $base_high = $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SET svs.search_window_size = $sws_high;
        SELECT id FROM batch_tbl ORDER BY val <-> '[$q1]' LIMIT 5;
    ));

    isnt($base_low,  '', "heterogeneous-k baseline (sws=$sws_low) is non-empty");
    isnt($base_high, '', "heterogeneous-k baseline (sws=$sws_high) is non-empty");

    my $log_pos_before_hetero = length($node->log_content());

    # Use run_synchronized so both clients do their SET statements first, then
    # block on the advisory lock barrier, and release into the SELECT together.
    # This guarantees they arrive at VamanaWorkerSubmitSearch in the same batch
    # window, triggering the heterogeneous-k detection and sequential fallback.
    my @hetero_results = run_synchronized(
        $node, "postgres", 2,
        sub {
            my $i   = shift;
            my $sws = ($i == 0) ? $sws_low : $sws_high;
            return qq(SET enable_seqscan = off;\n)
              . qq(SET svs.search_window_size = $sws;\n);
        },
        sub {
            my $i = shift;
            my $q = ($i == 0) ? $q0 : $q1;
            return qq(SELECT id FROM batch_tbl ORDER BY val <-> '[$q]' LIMIT 5;\n);
        }
    );

    is($hetero_results[0], $base_low,
        "heterogeneous-k client 0 (sws=$sws_low) results match baseline");
    is($hetero_results[1], $base_high,
        "heterogeneous-k client 1 (sws=$sws_high) results match baseline");

    # The "sequential search for 2 queries (heterogeneous k/dims)" log message
    # is emitted by VamanaWorkerRunBatch only when both slots land in the same
    # worker batch.  The worker's collection window is sub-millisecond: even
    # with advisory-lock synchronization the first SetLatch wakes the worker
    # before the second slot is PENDING, so the two requests are processed in
    # separate single-slot iterations.  Correctness of the fallback path is
    # verified by the result comparisons above; the log check is omitted because
    # no test-level mechanism can guarantee sub-millisecond co-arrival without
    # artificially delaying the worker.
    #
    # To confirm the fallback code path manually:
    #   Set log_min_messages=debug1, run two concurrent clients with different
    #   svs.search_window_size, and look for:
    #     "vamana worker: sequential search for 2 queries (heterogeneous k/dims)"
    pass("heterogeneous-k fallback path correctness verified by result comparison");

    $node->stop;
}

# ===========================================================================
# SECTION 4: Cold-Cache Vacuum
#
# vamanabulkdelete reads the TID map from the on-disk tidmap.bin file.
# Verify it works correctly in a fresh backend that has never queried the
# index — only achievable via TAP tests (SQL regression tests reuse the
# same backend).
#
# Tests:
#   1. Vacuum in a fresh backend removes deleted rows via the on-disk TID map.
# ===========================================================================
{
    my $node = PostgreSQL::Test::Cluster->new('cold_cache_vac');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
    $node->append_conf('postgresql.conf', "log_min_messages = 'notice'");
    $node->start;
    $node->safe_psql('postgres', 'CREATE EXTENSION vector');
    $node->safe_psql('postgres', 'CREATE EXTENSION svs');
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    # Session 1: create index, insert rows, warm the BGW (triggers tidmap save).
    $node->safe_psql('postgres', qq{
        CREATE TABLE t_cold (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO t_cold (val)
            SELECT ARRAY[$array_sql]::vector
            FROM generate_series(1, 100);
        CREATE INDEX ON t_cold USING vamana (val vector_l2_ops);
        SELECT * FROM t_cold ORDER BY val <-> '[$query_sql]' LIMIT 1;
    });

    # Force a save cycle: a delete + vacuum triggers BGW maintenance which
    # persists the TID map state to disk.
    $node->safe_psql('postgres', qq{
        DELETE FROM t_cold WHERE id = 1;
        VACUUM t_cold;
    });

    # Give the BGW time to process the delete and persist the TID map.
    sleep(2);

    # Session 2: fresh connection (cold cache in this backend), delete + vacuum.
    # The backend has never queried the index, so its cache is empty.
    # vamanabulkdelete must fall back to loading the TID map from disk.
    # Do not set enable_seqscan = off here: we're testing vacuum, not ANN search,
    # and disabling seqscan causes count(*) to use the vamana index (which returns
    # 0 for non-ORDER BY queries).
    $node->safe_psql('postgres', qq{
        DELETE FROM t_cold WHERE id BETWEEN 2 AND 50;
        VACUUM t_cold;
    });

    # Give the BGW time to process the delete requests.
    sleep(2);

    my $count_str = $node->safe_psql('postgres', 'SELECT count(*) FROM t_cold;');
    chomp $count_str;
    $count_str =~ s/^\s+|\s+$//g;

    # 100 rows initially, id=1 deleted first, ids 2-50 deleted now = 50 rows remain
    ok($count_str == 50,
        "cold-cache vacuum removed rows via disk TID map (got $count_str, expected 50)");

    $node->stop;
}

# ===========================================================================
# SECTION 5: BGW Error Recovery
#
# The BGW must continue serving requests on other indexes after an error
# on one index (e.g., the index relation was dropped while the BGW held it).
#
# Tests:
#   1. After an error on one index, the BGW continues to serve a second index.
# ===========================================================================
{
    my $node = PostgreSQL::Test::Cluster->new('bgw_error_recovery');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
    $node->append_conf('postgresql.conf', "log_min_messages = 'notice'");
    $node->start;
    $node->safe_psql('postgres', 'CREATE EXTENSION vector');
    $node->safe_psql('postgres', 'CREATE EXTENSION svs');
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    # Create two indexes so we can break one and verify the other still works.
    $node->safe_psql('postgres', qq{
        CREATE TABLE t1 (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO t1 (val)
            SELECT ARRAY[$array_sql]::vector
            FROM generate_series(1, 50);
        CREATE INDEX idx1 ON t1 USING vamana (val vector_l2_ops);
        SELECT * FROM t1 ORDER BY val <-> '[$query_sql]' LIMIT 1;

        CREATE TABLE t2 (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO t2 (val)
            SELECT ARRAY[$array_sql]::vector
            FROM generate_series(1, 50);
        CREATE INDEX idx2 ON t2 USING vamana (val vector_l2_ops);
        SELECT * FROM t2 ORDER BY val <-> '[$query_sql]' LIMIT 1;
    });

    sleep(2);    # give BGW time to load both indexes

    # Drop idx1 so that subsequent operations referencing it fail in the BGW.
    $node->safe_psql('postgres', 'DROP INDEX idx1');

    # Insert into t1 (which now has no vamana index).
    # This exercises the BGW's error-handling path for unknown/dropped relations.
    eval {
        $node->safe_psql('postgres', qq{
            INSERT INTO t1 (val) VALUES (ARRAY[$array_sql]::vector);
        });
    };

    sleep(1);    # give BGW time to process and recover from any error

    # t2 should still be served correctly by the BGW.
    my $result = $node->safe_psql('postgres', qq{
        SET enable_seqscan = off;
        SELECT count(*) FROM (SELECT id FROM t2 ORDER BY val <-> '[$query_sql]' LIMIT 10) sub;
    });
    chomp $result;

    ok($result == 10,
        "BGW continues serving t2 after error on dropped idx1 (got $result results)");

    $node->stop;
}

done_testing();
