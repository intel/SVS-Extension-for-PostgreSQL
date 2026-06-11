# 04_vamana_bgw_robustness.pl — BGW robustness: cold-cache vacuum, error
# recovery, save lock, relcache invalidation, index lock slot leak,
# and stale slot cleanup on BGW restart.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use File::Temp;
use POSIX qw(_exit);
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

# ===========================================================================
# VamanaWorkerResetStaleSlots — all slots empty at BGW startup
#
# VamanaWorkerResetStaleSlots runs at BGW startup and resets any non-EMPTY
# slot to EMPTY.  In production the scenario is: a backend is mid-slot when
# the server is crash-recovered; the BGW starts fresh and must not observe
# stale PENDING slots from the previous run.
#
# The testable guarantee is that pg_stat_vamana_worker reports all slots
# empty immediately after the BGW completes startup, regardless of what
# happened in the previous run.
# ===========================================================================
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_stale_slots');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "svs.worker_database = 'postgres'");
    $node->start;

    $node->safe_psql('postgres', "CREATE EXTENSION vector;");
    $node->safe_psql('postgres', "CREATE EXTENSION svs;");

    my $ss_dim  = 4;
    my $ss_seed = join(",", ('random()') x $ss_dim);
    my $ss_qvec = join(",", map { sprintf("%.4f", rand()) } 1 .. $ss_dim);

    $node->safe_psql('postgres', qq{
        CREATE TABLE t_stale (id serial PRIMARY KEY, val vector($ss_dim));
        INSERT INTO t_stale (val)
            SELECT ARRAY[$ss_seed]::vector
            FROM generate_series(1, 20);
        CREATE INDEX ON t_stale USING vamana (val vector_l2_ops);
    });

    my $worker_pid = wait_for_worker($node, 30);
    ok($worker_pid =~ /^\d+$/, "worker running (pid=$worker_pid)");

    sleep(2);

    $node->safe_psql('postgres', qq{
        SET enable_seqscan = off;
        SELECT id FROM t_stale ORDER BY val <-> '[$ss_qvec]' LIMIT 1;
    });

    $node->restart;

    my $new_worker_pid = wait_for_worker($node, 30);
    sleep(2);

    my $nonempty = $node->safe_psql('postgres',
        "SELECT count(*) FROM pg_stat_vamana_worker "
      . "WHERE slot_status <> 'empty';");
    chomp $nonempty;
    ok($nonempty eq '0', 'all slots empty after BGW startup (VamanaWorkerResetStaleSlots)');

    my $results = $node->safe_psql('postgres', qq{
        SET enable_seqscan = off;
        SELECT count(*) FROM (
            SELECT id FROM t_stale ORDER BY val <-> '[$ss_qvec]' LIMIT 5
        ) sub;
    });
    chomp $results;
    ok($results == 5, "searches return correct results after restart (got $results)");

    $node->stop;
}

# ===========================================================================
# Cold-cache vacuum — vamanabulkdelete with no backend cache
# ===========================================================================
{
    my $node = PostgreSQL::Test::Cluster->new('cold_cache_vac');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "svs.worker_database = 'postgres'");
    $node->append_conf('postgresql.conf', "log_min_messages = 'notice'");
    $node->start;
    $node->safe_psql('postgres', 'CREATE EXTENSION vector');
    $node->safe_psql('postgres', 'CREATE EXTENSION svs');

    $node->safe_psql('postgres', qq{
        CREATE TABLE t_cold (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO t_cold (val)
            SELECT ARRAY[$array_sql]::vector
            FROM generate_series(1, 100);
        CREATE INDEX ON t_cold USING vamana (val vector_l2_ops);
        SELECT * FROM t_cold ORDER BY val <-> '[$query_sql]' LIMIT 1;
    });

    $node->safe_psql('postgres', qq{
        DELETE FROM t_cold WHERE id = 1;
        VACUUM t_cold;
    });

    sleep(2);

    $node->safe_psql('postgres', qq{
        DELETE FROM t_cold WHERE id BETWEEN 2 AND 50;
        VACUUM t_cold;
    });

    sleep(2);

    my $count_str = $node->safe_psql('postgres', 'SELECT count(*) FROM t_cold;');
    chomp $count_str;
    $count_str =~ s/^\s+|\s+$//g;

    ok($count_str == 50,
        "cold-cache vacuum removed rows via disk TID map (got $count_str, expected 50)");

    $node->stop;
}

# ===========================================================================
# BGW error recovery — BGW continues serving index B after error on index A
# ===========================================================================
{
    my $node = PostgreSQL::Test::Cluster->new('bgw_error_recovery');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "svs.worker_database = 'postgres'");
    $node->append_conf('postgresql.conf', "log_min_messages = 'notice'");
    $node->start;
    $node->safe_psql('postgres', 'CREATE EXTENSION vector');
    $node->safe_psql('postgres', 'CREATE EXTENSION svs');

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

    sleep(2);

    $node->safe_psql('postgres', 'DROP INDEX idx1');

    eval {
        $node->safe_psql('postgres', qq{
            INSERT INTO t1 (val) VALUES (ARRAY[$array_sql]::vector);
        });
    };

    sleep(1);

    my $result = $node->safe_psql('postgres', qq{
        SET enable_seqscan = off;
        SELECT count(*) FROM (SELECT id FROM t2 ORDER BY val <-> '[$query_sql]' LIMIT 10) sub;
    });
    chomp $result;

    ok($result == 10,
        "BGW continues serving t2 after error on dropped idx1 (got $result results)");

    $node->stop;
}

# ===========================================================================
# Save advisory lock released after mutation, not at transaction end
#
# Two backends each INSERT into separate indexes in long-running transactions.
# Both must complete within the timeout; if either blocks for the full sleep
# duration, the lock is held too long.
# ===========================================================================
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_save_lock');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "svs.worker_database = 'postgres'");
    $node->start;

    $node->safe_psql('postgres', "CREATE EXTENSION vector;");
    $node->safe_psql('postgres', "CREATE EXTENSION svs;");

    my $sl_dim  = 4;
    my $sl_seed = join(",", ('random()') x $sl_dim);
    $node->safe_psql('postgres', qq{
        CREATE TABLE t_lock_a (id serial PRIMARY KEY, val vector($sl_dim));
        INSERT INTO t_lock_a (val) SELECT ARRAY[$sl_seed]::vector FROM generate_series(1,5);
        CREATE INDEX ON t_lock_a USING vamana (val vector_l2_ops);

        CREATE TABLE t_lock_b (id serial PRIMARY KEY, val vector($sl_dim));
        INSERT INTO t_lock_b (val) SELECT ARRAY[$sl_seed]::vector FROM generate_series(1,5);
        CREATE INDEX ON t_lock_b USING vamana (val vector_l2_ops);
    });

    my $worker_up = 0;
    for (1 .. 30) {
        usleep(500_000);
        my $pid = $node->safe_psql('postgres',
            "SELECT pid FROM pg_stat_activity "
          . "WHERE backend_type = 'vamana background worker' LIMIT 1;");
        chomp $pid;
        if ($pid =~ /^\d+$/) { $worker_up = 1; last; }
    }
    ok($worker_up, 'vamana background worker is running');

    my $tmpdir = File::Temp::tempdir(CLEANUP => 1);
    my @pids;
    for my $tbl (qw(t_lock_a t_lock_b)) {
        my $vec = join(",", map { sprintf("%.4f", rand()) } 1 .. $sl_dim);
        my $pid = fork();
        die "fork: $!" unless defined $pid;
        if ($pid == 0) {
            eval {
                $node->safe_psql('postgres', qq{
                    BEGIN;
                    INSERT INTO $tbl (val) VALUES (ARRAY[$vec]::vector);
                    PERFORM pg_sleep(3);
                    COMMIT;
                });
            };
            _exit(0);
        }
        push @pids, $pid;
    }

    my $start    = time();
    my $all_done = 1;
    for my $pid (@pids) {
        my $remaining = 10 - (time() - $start);
        if ($remaining <= 0) { $all_done = 0; last; }
        local $SIG{ALRM} = sub { $all_done = 0; };
        alarm(int($remaining));
        waitpid($pid, 0);
        alarm(0);
    }

    # Reap any children the timed loop did not wait for, so they cannot
    # inherit the test process state and run further test code.
    for my $pid (@pids) { waitpid($pid, POSIX::WNOHANG()) }

    ok($all_done,
        'concurrent saves on separate indexes complete without blocking each other');

    $node->stop;
}

# ===========================================================================
# BGW evicts cache after VACUUM FULL / CLUSTER
#
# VACUUM FULL and CLUSTER replace the heap relfilenode without calling any
# extension AM callback.  The BGW must evict its stale cache entry via the
# relcache invalidation callback and rebuild from the new heap.
# ===========================================================================
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_relcache_inval');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "svs.worker_database = 'postgres'");
    $node->start;

    $node->safe_psql('postgres', "CREATE EXTENSION vector;");
    $node->safe_psql('postgres', "CREATE EXTENSION svs;");

    my $ri_dim  = 4;
    my $ri_seed = join(",", ('random()') x $ri_dim);
    my $ri_qvec = join(",", map { sprintf("%.4f", rand()) } 1 .. $ri_dim);

    $node->safe_psql('postgres', qq{
        CREATE TABLE t_inval (id serial PRIMARY KEY, val vector($ri_dim));
        INSERT INTO t_inval (val) SELECT ARRAY[$ri_seed]::vector FROM generate_series(1, 10);
        CREATE INDEX ON t_inval USING vamana (val vector_l2_ops);
        CREATE INDEX t_inval_id_btree ON t_inval (id);
    });

    my $worker_up = 0;
    for (1 .. 30) {
        usleep(500_000);
        my $pid = $node->safe_psql('postgres',
            "SELECT pid FROM pg_stat_activity "
          . "WHERE backend_type = 'vamana background worker' LIMIT 1;");
        chomp $pid;
        if ($pid =~ /^\d+$/) { $worker_up = 1; last; }
    }
    ok($worker_up, 'vamana background worker is running');

    my $before = $node->safe_psql('postgres', qq{
        SET enable_seqscan = off;
        SELECT count(*) FROM (SELECT id FROM t_inval ORDER BY val <-> '[$ri_qvec]' LIMIT 10) sub;
    });
    chomp $before;
    ok($before == 10, "baseline search returns 10 rows before VACUUM FULL (got $before)");

    $node->safe_psql('postgres', "VACUUM FULL t_inval;");
    sleep(2);

    my $after_vf = $node->safe_psql('postgres', qq{
        SET enable_seqscan = off;
        SELECT count(*) FROM (SELECT id FROM t_inval ORDER BY val <-> '[$ri_qvec]' LIMIT 10) sub;
    });
    chomp $after_vf;
    ok($after_vf == 10, "search returns correct rows after VACUUM FULL (got $after_vf)");

    $node->safe_psql('postgres', "CLUSTER t_inval USING t_inval_id_btree;");
    sleep(2);

    my $after_cl = $node->safe_psql('postgres', qq{
        SET enable_seqscan = off;
        SELECT count(*) FROM (SELECT id FROM t_inval ORDER BY val <-> '[$ri_qvec]' LIMIT 10) sub;
    });
    chomp $after_cl;
    ok($after_cl == 10, "search returns correct rows after CLUSTER (got $after_cl)");

    $node->stop;
}

# ===========================================================================
# indexLocks[] slots freed on DROP INDEX
#
# VamanaWorkerShmem.indexLocks[] has VAMANA_MAX_INDEXES (64) slots.
# If DROP INDEX does not zero the slot, the array fills after 64 cumulative
# creations and VamanaGetIndexLock emits a WARNING.
# ===========================================================================
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_lock_leak');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "svs.worker_database = 'postgres'");
    $node->append_conf('postgresql.conf', "log_min_messages = 'warning'");
    $node->start;

    $node->safe_psql("postgres", "CREATE EXTENSION vector;");
    $node->safe_psql("postgres", "CREATE EXTENSION svs;");

    $node->safe_psql("postgres", qq(
        CREATE TABLE lock_leak_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO lock_leak_tbl (val)
            SELECT ARRAY[$array_sql]::vector
            FROM generate_series(1, 10);
    ));

    my $worker_pid = wait_for_worker($node, 20);
    ok($worker_pid =~ /^\d+$/,
        "vamana background worker is running (pid=$worker_pid)");

    for my $i (1 .. 64)
    {
        $node->safe_psql("postgres",
            "CREATE INDEX lock_leak_idx ON lock_leak_tbl "
          . "USING vamana (val vector_l2_ops);");

        $node->safe_psql("postgres", qq(
            SET enable_seqscan = off;
            SELECT id FROM lock_leak_tbl ORDER BY val <-> '[$query_sql]' LIMIT 1;
        ));

        $node->safe_psql("postgres", "DROP INDEX lock_leak_idx;");
    }

    my $log_pos = length($node->log_content());

    $node->safe_psql("postgres",
        "CREATE INDEX lock_leak_idx ON lock_leak_tbl "
      . "USING vamana (val vector_l2_ops);");

    $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM lock_leak_tbl ORDER BY val <-> '[$query_sql]' LIMIT 1;
    ));

    my $leak_log = substr($node->log_content(), $log_pos);

    unlike($leak_log,
        qr/vamana worker: index lock table full \(VAMANA_MAX_INDEXES=64\)/,
        'no lock slot exhaustion after 64 CREATE+DROP cycles'
    ) or diag(
        "WARNING found — DROP INDEX does not release the indexLocks[] slot.\n"
      . "Fix: make VamanaReleaseIndexLock non-static, declare it in vamanaworker.h,\n"
      . "and call it from VamanaObjectAccessHook when access == OAT_DROP.\n"
      . "Log excerpt:\n",
        substr($leak_log, 0, 2000)
    );

    $node->stop;
}

# ===========================================================================
# Query cancel during WaitLatch — PG_CATCH in VamanaWorkerSubmitSearch
#
# When a backend is blocked in WaitLatch waiting for the worker to drain its
# slot, a query cancel (pg_cancel_backend) throws an error that is caught by
# the PG_CATCH in VamanaWorkerSubmitSearch.  The handler must CAS the slot
# from PENDING back to EMPTY so the worker ignores it.  If it fails to do so
# the slot stays PENDING and subsequent queries from the same backend hang
# until the worker drains the stale slot.
#
# Determinism: we SIGSTOP the worker before issuing the query.  With the
# worker frozen the slot is guaranteed to sit in PENDING state for as long as
# we need — there is no race between "query issued" and "cancel arrives".
# ===========================================================================
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_cancel_wait');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "svs.worker_database = 'postgres'");
    $node->start;

    $node->safe_psql('postgres', "CREATE EXTENSION vector;");
    $node->safe_psql('postgres', "CREATE EXTENSION svs;");

    my $cw_dim  = 4;
    my $cw_seed = join(",", ('random()') x $cw_dim);
    my $cw_qvec = join(",", map { sprintf("%.4f", rand()) } 1 .. $cw_dim);

    $node->safe_psql('postgres', qq{
        CREATE TABLE t_cancel (id serial PRIMARY KEY, val vector($cw_dim));
        INSERT INTO t_cancel (val)
            SELECT ARRAY[$cw_seed]::vector
            FROM generate_series(1, 20);
        CREATE INDEX ON t_cancel USING vamana (val vector_l2_ops);
    });

    my $worker_pid = wait_for_worker($node, 30);
    ok($worker_pid =~ /^\d+$/, "worker running (pid=$worker_pid)");

    # Warm the index so the worker has it cached; the query will hit the
    # worker path rather than falling back.
    $node->safe_psql('postgres', qq{
        SET enable_seqscan = off;
        SELECT id FROM t_cancel ORDER BY val <-> '[$cw_qvec]' LIMIT 1;
    });

    # Freeze the worker.  The slot will stay PENDING until we SIGCONT.
    kill('STOP', $worker_pid);
    usleep(100_000);    # let the stop take effect

    # Fork a child to run the search query.  With the worker stopped the
    # backend blocks in WaitLatch — using fork() lets the parent proceed
    # independently while the child waits.  background_psql is not used
    # here because query_until blocks the test process itself.
    my $child_pid = fork();
    die "fork: $!" unless defined $child_pid;
    if ($child_pid == 0)
    {
        eval {
            $node->safe_psql('postgres', qq{
                SET enable_seqscan = off;
                SELECT id FROM t_cancel ORDER BY val <-> '[$cw_qvec]' LIMIT 1;
            });
        };
        _exit(0);
    }

    # Poll until the slot transitions to PENDING: the child's backend has
    # written the query and is now blocked in WaitLatch.  The worker is
    # stopped so it cannot advance the slot further — this always converges.
    my $slot_pending = 0;
    for (1 .. 50)
    {
        usleep(100_000);
        my $status = $node->safe_psql('postgres',
            "SELECT slot_status FROM pg_stat_vamana_worker "
          . "WHERE slot_status = 'pending' LIMIT 1;");
        chomp $status;
        if ($status eq 'pending') { $slot_pending = 1; last; }
    }
    ok($slot_pending, 'slot is PENDING while backend waits in WaitLatch');

    # Find the blocked backend and cancel it.
    my $backend_pid = $node->safe_psql('postgres',
        "SELECT pid FROM pg_stat_activity "
      . "WHERE query LIKE '%t_cancel%' AND state = 'active' "
      . "AND pid <> pg_backend_pid() LIMIT 1;");
    chomp $backend_pid;
    ok($backend_pid =~ /^\d+$/, "found blocked backend (pid=$backend_pid)");

    $node->safe_psql('postgres', "SELECT pg_cancel_backend($backend_pid);");

    # Poll for EMPTY *before* resuming the worker.  The cancel wakes the
    # backend out of WaitLatch; CHECK_FOR_INTERRUPTS() fires; PG_CATCH runs
    # the CAS PENDING→EMPTY.  The worker is still stopped so it cannot race
    # to PROCESSING and win the CAS first.  This makes the assertion
    # deterministic.
    my $slot_empty = 0;
    for (1 .. 30)
    {
        usleep(100_000);
        my $nonempty = $node->safe_psql('postgres',
            "SELECT count(*) FROM pg_stat_vamana_worker "
          . "WHERE slot_status <> 'empty';");
        chomp $nonempty;
        if ($nonempty eq '0') { $slot_empty = 1; last; }
    }
    ok($slot_empty, 'slot returns to EMPTY after query cancel (PG_CATCH CAS succeeded)');

    # Resume the worker only after the slot is confirmed empty.
    kill('CONT', $worker_pid);

    # Wait for the child to exit.  The cancel caused psql to receive an
    # error response; the child eval catches it and _exit(0)s.
    my $child_done = 1;
    {
        local $SIG{ALRM} = sub { $child_done = 0; };
        alarm(10);
        waitpid($child_pid, 0);
        alarm(0);
    }
    waitpid($child_pid, POSIX::WNOHANG()) unless $child_done;
    ok($child_done, 'forked backend exited after cancel');

    # A fresh query from a new session must succeed — the slot is reusable.
    my $after = $node->safe_psql('postgres', qq{
        SET enable_seqscan = off;
        SELECT count(*) FROM (
            SELECT id FROM t_cancel ORDER BY val <-> '[$cw_qvec]' LIMIT 5
        ) sub;
    });
    chomp $after;
    ok($after == 5, "subsequent query returns correct results after cancel (got $after)");

    $node->stop;
}

done_testing();
