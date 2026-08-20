# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 15_vamana_worker_lifecycle.pl — worker drain-and-stop shutdown routine.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use File::Temp qw(tempdir);
use POSIX qw(_exit);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

# Poll until the vamana worker pid differs from $old (and is numeric), or
# timeout.  Returns the new pid, or '' on timeout.  wait_for_worker reports only
# the current pid, so a restart's new pid needs its own wait.
sub wait_for_new_worker_pid
{
    my ($node, $old, $attempts) = @_;
    $attempts //= 60;
    for my $i (1 .. $attempts)
    {
        usleep(500_000);
        my $pid = $node->safe_psql('postgres',
            "SELECT pid FROM pg_stat_activity "
          . "WHERE backend_type = 'vamana worker' LIMIT 1;");
        chomp $pid;
        return $pid if $pid =~ /^\d+$/ && $pid ne $old;
    }
    return '';
}

# Sample the worker pid every 0.5s for $secs seconds and return the number of
# distinct pids seen.  A settled worker yields exactly one; a terminate/respawn
# loop yields many.
sub count_distinct_worker_pids
{
    my ($node, $secs) = @_;
    my %seen;
    for my $i (1 .. ($secs * 2))
    {
        my $pid = $node->safe_psql('postgres',
            "SELECT pid FROM pg_stat_activity "
          . "WHERE backend_type = 'vamana worker' LIMIT 1;");
        chomp $pid;
        $seen{$pid} = 1 if $pid =~ /^\d+$/;
        usleep(500_000);
    }
    return scalar keys %seen;
}

# A SIGTERM must run the graceful drain, not raise FATAL mid-loop.  The drain's
# entry log line proves the flag-only handler is in effect: had the handler set
# ProcDiePending, the next CHECK_FOR_INTERRUPTS would FATAL before the drain
# could log anything.
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_lifecycle');
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
        CREATE TABLE life_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO life_tbl (val)
            SELECT ARRAY[$array_sql]::vector
            FROM generate_series(1, 200) i;
        CREATE INDEX life_idx ON life_tbl USING vamana (val vector_l2_ops);
    ));

    my $worker_pid = wait_for_worker($node);
    ok($worker_pid =~ /^\d+$/, "vamana worker running (pid=$worker_pid)");

    # Warm the cache so the drain has a cached index to work through.
    $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM life_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));

    my $log_pos = length($node->log_content());

    kill('TERM', $worker_pid);

    $node->wait_for_log(qr/vamana background worker shutting down/, $log_pos);
    pass('SIGTERM reaches the graceful drain sequence');

    my $shutdown_log = substr($node->log_content(), $log_pos);
    unlike($shutdown_log,
        qr/terminating connection due to administrator command/,
        'worker does not FATAL mid-loop on SIGTERM');

    $node->stop;
}

# A request already enqueued when SIGTERM lands must be serviced by the drain's
# final sweep, not abandoned.  Freezing the worker lets the backend publish a
# PENDING slot; SIGCONT then delivers the queued SIGTERM into the drain.
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_inflight');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "log_min_messages = 'notice'");
    # Generous timeout so the backend does not self-cancel before the resumed
    # worker services it.
    $node->append_conf('postgresql.conf', "svs.worker_timeout_ms = 30000");
    $node->start;

    $node->safe_psql("postgres", "CREATE EXTENSION vector;");
    $node->safe_psql("postgres", "CREATE EXTENSION svs;");
    $node->safe_psql("postgres",
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    $node->safe_psql("postgres", qq(
        CREATE TABLE inflight_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO inflight_tbl (val)
            SELECT ARRAY[$array_sql]::vector
            FROM generate_series(1, 200) i;
        CREATE INDEX inflight_idx ON inflight_tbl USING vamana (val vector_l2_ops);
    ));

    my $worker_pid = wait_for_worker($node);
    ok($worker_pid =~ /^\d+$/, "vamana worker running (pid=$worker_pid)");

    # Warm the cache so the search is served from memory, not a cold load.
    $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM inflight_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));

    kill('STOP', $worker_pid);
    usleep(100_000);

    my $tmpdir = tempdir(CLEANUP => 1);
    my $child = fork();
    die "fork: $!" unless defined $child;
    if ($child == 0)
    {
        my $r = eval {
            $node->safe_psql("postgres", qq(
                SET enable_seqscan = off;
                SELECT id FROM inflight_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
            ));
        } // '';
        if (open(my $fh, '>', "$tmpdir/result.txt")) { print $fh $r; close $fh; }
        _exit(0);
    }

    # Wait until the backend has published its PENDING slot and is blocked.
    my $pending = 0;
    for (1 .. 50)
    {
        usleep(100_000);
        my $s = $node->safe_psql("postgres",
            "SELECT count(*) FROM pg_stat_vamana_worker_slot "
          . "WHERE slot_status = 'pending';");
        chomp $s;
        if ($s ne '0') { $pending = 1; last; }
    }
    ok($pending, 'request is PENDING while the worker is frozen');

    kill('TERM', $worker_pid);
    kill('CONT', $worker_pid);

    waitpid($child, 0);

    my $result = '';
    if (open(my $fh, '<', "$tmpdir/result.txt"))
    {
        local $/; $result = <$fh>; close $fh;
    }
    isnt($result, '',
        'in-flight request is serviced by the drain, not abandoned');

    $node->stop;
}

# The drain checkpoints every cached index before exit, ignoring the debounce
# policy that governs the steady-state sweep, and advances each slot's
# confirmed_flush_lsn to the checkpoint LSN.  A subsequent restart then loads
# every index from its current on-disk save rather than rebuilding, proving disk
# state matches the in-memory state the drain flushed.
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_drain_ckpt');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "log_min_messages = debug1");
    # Suppress the steady-state checkpoint so any checkpoint observed at
    # shutdown can only come from the drain's unconditional sweep.
    $node->append_conf('postgresql.conf', "svs.checkpoint_min_ops = 999999");
    $node->append_conf('postgresql.conf', "svs.checkpoint_debounce_window = 999999");
    $node->start;

    $node->safe_psql("postgres", "CREATE EXTENSION vector;");
    $node->safe_psql("postgres", "CREATE EXTENSION svs;");
    $node->safe_psql("postgres",
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");
    wait_for_worker($node, 30);

    my @idx = (1, 2, 3);
    for my $n (@idx)
    {
        $node->safe_psql("postgres", qq(
            CREATE TABLE ckpt_tbl$n (id serial PRIMARY KEY, val vector($dim));
            INSERT INTO ckpt_tbl$n (val)
                SELECT ARRAY[$array_sql]::vector
                FROM generate_series(1, 100) i;
            CREATE INDEX ckpt_idx$n ON ckpt_tbl$n USING vamana (val vector_l2_ops);
        ));
    }

    # Warm every index into the worker cache and record baseline results.
    my %baseline;
    for my $n (@idx)
    {
        $baseline{$n} = $node->safe_psql("postgres", qq(
            SET enable_seqscan = off;
            SELECT id FROM ckpt_tbl$n ORDER BY val <-> '[$query_sql]' LIMIT 5;
        ));
    }

    # Writes after the (suppressed) steady-state checkpoint: their WAL must be
    # captured by the drain, advancing each slot past this LSN.
    for my $n (@idx)
    {
        $node->safe_psql("postgres",
            "INSERT INTO ckpt_tbl$n (val) VALUES (ARRAY[$array_sql]::vector);");
    }
    my $pre_lsn = $node->safe_psql("postgres", "SELECT pg_current_wal_lsn();");
    chomp $pre_lsn;

    my %slot;
    for my $n (@idx)
    {
        my $oid = $node->safe_psql("postgres",
            "SELECT oid FROM pg_class WHERE relname = 'ckpt_idx$n';");
        chomp $oid;
        my $dboid = $node->safe_psql("postgres",
            "SELECT oid FROM pg_database WHERE datname = 'postgres';");
        chomp $dboid;
        $slot{$n} = "vamana_${dboid}_${oid}";
    }

    my $worker_pid = wait_for_worker($node, 30);
    my $log_pos = length($node->log_content());

    kill('TERM', $worker_pid);
    $node->wait_for_log(qr/vamana background worker shutting down/, $log_pos);

    # Wait for the worker process to disappear (drain finished, proc_exit).
    for (1 .. 50)
    {
        usleep(100_000);
        my $alive = $node->safe_psql("postgres",
            "SELECT count(*) FROM pg_stat_activity "
          . "WHERE backend_type = 'vamana worker';");
        chomp $alive;
        last if $alive eq '0';
    }

    my $shutdown_log = substr($node->log_content(), $log_pos);
    my %checkpointed;
    while ($shutdown_log =~ /vamana index (\d+): checkpoint complete/g)
    {
        $checkpointed{$1} = 1;
    }
    is(scalar keys %checkpointed, scalar @idx,
        "drain checkpoints every cached index (" . scalar(@idx) . ")");

    unlike($shutdown_log, qr/drain budget of \d+ ms exhausted/,
        "the default budget is not exhausted — the drain completes in full");

    my $lsn_ok = 1;
    for my $n (@idx)
    {
        my $lsn = $node->safe_psql("postgres", qq(
            SELECT confirmed_flush_lsn FROM pg_replication_slots
            WHERE slot_name = '$slot{$n}';
        ));
        chomp $lsn;
        my $diff = $node->safe_psql("postgres",
            "SELECT pg_wal_lsn_diff('$lsn', '$pre_lsn') >= 0;");
        chomp $diff;
        $lsn_ok = 0 unless $diff eq 't';
    }
    ok($lsn_ok,
        "each slot's confirmed_flush_lsn advanced to/past the last write");

    # Restart: every index must load from its current on-disk save, not rebuild.
    my $restart_pos = length($node->log_content());
    $node->restart;
    wait_for_worker($node, 30);

    my $results_match = 1;
    for my $n (@idx)
    {
        my $r = $node->safe_psql("postgres", qq(
            SET enable_seqscan = off;
            SELECT id FROM ckpt_tbl$n ORDER BY val <-> '[$query_sql]' LIMIT 5;
        ));
        $results_match = 0 unless $r eq $baseline{$n};
    }
    ok($results_match,
        "post-restart results match pre-drain state (disk matches memory)");

    my $restart_log = substr($node->log_content(), $restart_pos);
    unlike($restart_log, qr/rebuilding vamana index from table data/,
        "no table rebuild after restart — indexes loaded from the drained save");

    $node->stop;
}

# A standby worker never persists: its drain absorbs streamed WAL with a final
# slot drain and exits without calling PerformCheckpoint (which would trip its
# !RecoveryInProgress assert).  A physical slot plus hot_standby_feedback pins
# the primary's catalog_xmin so the standby's logical slot is never invalidated
# and the worker keeps a stable pid across the test.
{
    my $primary = PostgreSQL::Test::Cluster->new('vamana_life_primary');
    $primary->init(allows_streaming => 1);
    $primary->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $primary->append_conf('postgresql.conf', "wal_level = logical");
    $primary->append_conf('postgresql.conf', "max_replication_slots = 10");
    $primary->append_conf('postgresql.conf', "max_wal_senders = 10");
    $primary->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
    $primary->start;

    $primary->safe_psql('postgres',
        "SELECT pg_create_physical_replication_slot('standby_phys');");
    $primary->safe_psql('postgres', "CREATE EXTENSION vector;");
    $primary->safe_psql('postgres', "CREATE EXTENSION svs;");
    $primary->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");
    $primary->safe_psql('postgres', qq{
        CREATE TABLE st_tbl (id serial, val vector($dim));
        CREATE INDEX st_idx ON st_tbl USING vamana (val vector_l2_ops);
        INSERT INTO st_tbl (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 20);
    });
    wait_for_worker($primary, 30);

    my $backup = 'life_standby_backup';
    $primary->backup($backup);

    my $standby = PostgreSQL::Test::Cluster->new('vamana_life_standby');
    $standby->init_from_backup($primary, $backup, has_streaming => 1);
    $standby->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $standby->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
    $standby->append_conf('postgresql.conf', "log_min_messages = debug1");
    $standby->append_conf('postgresql.conf', "hot_standby = on");
    $standby->append_conf('postgresql.conf', "hot_standby_feedback = on");
    $standby->append_conf('postgresql.conf', "primary_slot_name = 'standby_phys'");
    $standby->start;
    $primary->wait_for_replay_catchup($standby);

    # The pid that logs readiness is the one that finished bootstrap and reached
    # the main loop; anchor on a captured offset so an earlier line cannot match.
    my $ready_off = length($standby->log_content());
    $standby->wait_for_log(
        qr/vamana background worker started for database/, $ready_off);
    my ($loop_pid) = substr($standby->log_content(), $ready_off)
        =~ /\[(\d+)\] LOG:  vamana background worker started for database/;
    my $sb_pid = wait_for_worker($standby, 30);
    ok(defined $loop_pid && $loop_pid == $sb_pid,
        "standby vamana worker reached the main loop (pid=$sb_pid)");

    # Drive continuous WAL so the worker is actively decoding inside the drain
    # when the signal lands, exercising the shutdown path under load rather than
    # while idle in WaitLatch.
    my $load = fork();
    die "fork: $!" unless defined $load;
    if ($load == 0)
    {
        for (1 .. 2000)
        {
            eval { $primary->safe_psql('postgres',
                "INSERT INTO st_tbl (val) VALUES (ARRAY[$array_sql]::vector);"); };
        }
        _exit(0);
    }
    usleep(1_000_000);

    my $log_pos = length($standby->log_content());
    kill('TERM', $sb_pid);
    $standby->wait_for_log(qr/vamana background worker shutting down/, $log_pos);

    for (1 .. 50)
    {
        usleep(100_000);
        my $alive = $standby->safe_psql("postgres",
            "SELECT count(*) FROM pg_stat_activity "
          . "WHERE backend_type = 'vamana worker';");
        chomp $alive;
        last if $alive eq '0';
    }

    my $shutdown_log = substr($standby->log_content(), $log_pos);
    unlike($shutdown_log, qr/checkpoint complete/,
        "standby drain performs no checkpoint");
    # The shutdown cancel must not be misread as a corrupt change or a decode
    # failure: neither the skip warning nor the rebuild recovery may fire.
    unlike($shutdown_log, qr/skipping change/,
        "shutdown cancel is not misclassified as a skipped change");
    unlike($shutdown_log, qr/unrecoverable decoding error/,
        "shutdown cancel does not force a spurious heap rebuild");

    kill('TERM', $load);
    waitpid($load, 0);
    $standby->stop;
    $primary->stop;
}

# One index whose checkpoint fails at shutdown must not stop the others: the
# drain isolates each index's checkpoint, logs the failure, and still exits
# cleanly.  A read-only save directory forces a real save failure for exactly
# one index while the others stay writable.
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_ckpt_isolation');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "log_min_messages = debug1");
    $node->start;

    $node->safe_psql("postgres", "CREATE EXTENSION vector;");
    $node->safe_psql("postgres", "CREATE EXTENSION svs;");
    $node->safe_psql("postgres",
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");
    wait_for_worker($node, 30);

    my @idx = (1, 2, 3);
    my %relid;
    for my $n (@idx)
    {
        $node->safe_psql("postgres", qq(
            CREATE TABLE iso_tbl$n (id serial PRIMARY KEY, val vector($dim));
            INSERT INTO iso_tbl$n (val)
                SELECT ARRAY[$array_sql]::vector
                FROM generate_series(1, 100) i;
            CREATE INDEX iso_idx$n ON iso_tbl$n USING vamana (val vector_l2_ops);
        ));
        my $oid = $node->safe_psql("postgres",
            "SELECT oid FROM pg_class WHERE relname = 'iso_idx$n';");
        chomp $oid;
        $relid{$n} = $oid;

        # Warm into the worker cache so the drain has it to checkpoint.
        $node->safe_psql("postgres", qq(
            SET enable_seqscan = off;
            SELECT id FROM iso_tbl$n ORDER BY val <-> '[$query_sql]' LIMIT 5;
        ));
    }

    # A steady-state checkpoint must create the victim's save dir before we can
    # make it read-only.
    my $victim = $idx[1];
    my $victim_dir = vamana_save_dir($node, 'postgres', $relid{$victim});
    for (1 .. 100)
    {
        usleep(100_000);
        last if -d $victim_dir;
    }
    ok(-d $victim_dir, "victim index save directory exists before shutdown");

    # Read-only: the drain's save writes temp files inside it and fails with
    # EACCES for this index only.
    chmod 0500, $victim_dir;

    my $worker_pid = wait_for_worker($node, 30);
    my $log_pos = length($node->log_content());

    kill('TERM', $worker_pid);
    $node->wait_for_log(qr/vamana background worker shutting down/, $log_pos);
    for (1 .. 100)
    {
        usleep(100_000);
        last if $node->log_content()
            =~ /\(PID $worker_pid\) exited with exit code/;
    }

    # Restore perms so the cluster tears down cleanly.
    chmod 0700, $victim_dir;

    my $log = substr($node->log_content(), $log_pos);

    my %complete;
    $complete{$1} = 1
        while $log =~ /vamana index (\d+): checkpoint complete/g;
    my %failed;
    $failed{$1} = 1
        while $log =~ /vamana shutdown: index (\d+) not checkpointed/g;

    ok($failed{$relid{$victim}}, "the failing index is logged as not checkpointed");

    my $others_ok = 1;
    for my $n (@idx)
    {
        next if $n == $victim;
        $others_ok = 0 unless $complete{$relid{$n}};
    }
    ok($others_ok, "every other index is still checkpointed");

    unlike($log, qr/\(PID $worker_pid\) exited with exit code 1/,
        "worker exits cleanly despite the per-index checkpoint failure");

    $node->stop;
}

# A request that re-checks accepting, stalls, then publishes PENDING after the
# drain's final sweep must self-cancel through its own bounded wait, never
# orphaning the slot or hanging.  An injection point parks a scan between the
# accepting re-check and the PENDING store; the worker then drains and exits
# before the scan is released.
SKIP: {
    skip 'injection points not enabled in this build', 4
        unless ($ENV{enable_injection_points} // '') eq 'yes';

    my $node = PostgreSQL::Test::Cluster->new('vamana_late_publish');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "log_min_messages = debug1");
    # Short IPC timeout so the late-publish self-cancel resolves quickly.
    $node->append_conf('postgresql.conf', "svs.worker_timeout_ms = 2000");
    $node->start;

    skip 'injection_points extension not installed', 4
        unless $node->check_extension('injection_points');

    $node->safe_psql("postgres", "CREATE EXTENSION vector;");
    $node->safe_psql("postgres", "CREATE EXTENSION svs;");
    $node->safe_psql("postgres", "CREATE EXTENSION injection_points;");
    $node->safe_psql("postgres",
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");
    wait_for_worker($node, 30);

    $node->safe_psql("postgres", qq(
        CREATE TABLE lp_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO lp_tbl (val)
            SELECT ARRAY[$array_sql]::vector
            FROM generate_series(1, 200) i;
        CREATE INDEX lp_idx ON lp_tbl USING vamana (val vector_l2_ops);
    ));

    # Warm the cache so the scan is served from memory.
    $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM lp_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));

    $node->safe_psql("postgres",
        "SELECT injection_points_attach('vamana-enqueue-before-publish', 'wait');");

    # on_error_stop => 0 so the parked scan's expected "worker unavailable"
    # error does not tear down the session; a follow-up query then proves it
    # recovered rather than hung.
    my $scan = $node->background_psql('postgres', on_error_stop => 0);
    $scan->query_until(qr/scan_started/, qq(
        \\echo scan_started
        SET enable_seqscan = off;
        SELECT id FROM lp_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));

    $node->wait_for_event('client backend', 'vamana-enqueue-before-publish');

    # Disable first so the launcher will not respawn, then SIGTERM the worker to
    # make it drain and exit past the parked backend.
    my $worker_pid = $node->safe_psql("postgres",
        "SELECT pid FROM pg_stat_activity WHERE backend_type = 'vamana worker';");
    chomp $worker_pid;
    $node->safe_psql("postgres",
        "UPDATE vamana_databases SET enabled = false WHERE datname = 'postgres';");

    my $log_pos = length($node->log_content());
    kill('TERM', $worker_pid);
    $node->wait_for_log(qr/vamana background worker shutting down/, $log_pos);
    for (1 .. 100)
    {
        usleep(100_000);
        my $alive = $node->safe_psql("postgres",
            "SELECT count(*) FROM pg_stat_activity "
          . "WHERE backend_type = 'vamana worker';");
        chomp $alive;
        last if $alive eq '0';
    }

    # Release the parked backend: it stores PENDING to a departed worker and
    # must self-cancel at worker_timeout_ms, then remain a usable session.
    my $wake_pos = length($node->log_content());
    $node->safe_psql("postgres",
        "SELECT injection_points_wakeup('vamana-enqueue-before-publish');");

    my $scan_out = $scan->query('SELECT 42');
    like($scan_out, qr/42/,
        'late-publish scan self-cancels and its session stays usable');

    $node->wait_for_log(qr/vamana worker timed out/, $wake_pos);
    my $after_wake = substr($node->log_content(), $wake_pos);
    like($after_wake, qr/vamana worker timed out/,
        'the orphaned request times out on its own bounded wait');

    my $pending = $node->safe_psql("postgres",
        "SELECT count(*) FROM pg_stat_vamana_worker_slot "
      . "WHERE slot_status = 'pending';");
    chomp $pending;
    is($pending, '0', 'no slot is left stuck in PENDING');

    $scan->quit;
    $node->safe_psql("postgres",
        "SELECT injection_points_detach('vamana-enqueue-before-publish');");

    # A fresh request with the worker gone takes the bounded-wait path and
    # errors rather than hanging.
    my $arm_a = $node->psql('postgres', qq(
        SET enable_seqscan = off;
        SELECT id FROM lp_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));
    isnt($arm_a, 0,
        'a request arriving after the worker exits errors, not hangs');

    $node->stop;
}

# A drain that overruns svs.shutdown_drain_budget_ms stops before the remaining
# indexes: it checkpoints the ones it reaches, leaves the rest at their prior
# confirmed_flush_lsn, logs the exhaustion, and still exits cleanly.  An
# injection point stalls the drain after the first index so the budget expires
# deterministically rather than racing a sub-millisecond checkpoint.
SKIP: {
    skip 'injection points not enabled in this build', 5
        unless ($ENV{enable_injection_points} // '') eq 'yes';

    my $node = PostgreSQL::Test::Cluster->new('vamana_drain_budget');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "log_min_messages = debug1");
    # Suppress steady-state checkpoints so slot LSNs move only at the drain.
    $node->append_conf('postgresql.conf', "svs.checkpoint_min_ops = 999999");
    $node->append_conf('postgresql.conf', "svs.checkpoint_debounce_window = 999999");
    $node->append_conf('postgresql.conf', "svs.shutdown_drain_budget_ms = 500");
    $node->start;

    skip 'injection_points extension not installed', 5
        unless $node->check_extension('injection_points');

    $node->safe_psql("postgres", "CREATE EXTENSION vector;");
    $node->safe_psql("postgres", "CREATE EXTENSION svs;");
    $node->safe_psql("postgres", "CREATE EXTENSION injection_points;");
    $node->safe_psql("postgres",
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");
    wait_for_worker($node, 30);

    my @idx = (1, 2, 3);
    my %slot;
    for my $n (@idx)
    {
        $node->safe_psql("postgres", qq(
            CREATE TABLE budget_tbl$n (id serial PRIMARY KEY, val vector($dim));
            INSERT INTO budget_tbl$n (val)
                SELECT ARRAY[$array_sql]::vector
                FROM generate_series(1, 100) i;
            CREATE INDEX budget_idx$n ON budget_tbl$n USING vamana (val vector_l2_ops);
        ));
        $node->safe_psql("postgres", qq(
            SET enable_seqscan = off;
            SELECT id FROM budget_tbl$n ORDER BY val <-> '[$query_sql]' LIMIT 5;
        ));
        my $oid = $node->safe_psql("postgres",
            "SELECT oid FROM pg_class WHERE relname = 'budget_idx$n';");
        chomp $oid;
        my $dboid = $node->safe_psql("postgres",
            "SELECT oid FROM pg_database WHERE datname = 'postgres';");
        chomp $dboid;
        $slot{$n} = "vamana_${dboid}_${oid}";
    }

    # Writes past the suppressed steady-state checkpoint: an index the drain
    # reaches advances past this LSN, a skipped one stays behind.
    for my $n (@idx)
    {
        $node->safe_psql("postgres",
            "INSERT INTO budget_tbl$n (val) VALUES (ARRAY[$array_sql]::vector);");
    }

    my %pre_lsn;
    for my $n (@idx)
    {
        my $lsn = $node->safe_psql("postgres",
            "SELECT confirmed_flush_lsn FROM pg_replication_slots "
          . "WHERE slot_name = '$slot{$n}';");
        chomp $lsn;
        $pre_lsn{$n} = $lsn;
    }

    $node->safe_psql("postgres",
        "SELECT injection_points_attach('vamana-drain-checkpoint-slow', 'wait');");

    my $worker_pid = $node->safe_psql("postgres",
        "SELECT pid FROM pg_stat_activity WHERE backend_type = 'vamana worker';");
    chomp $worker_pid;

    my $log_pos = length($node->log_content());
    kill('TERM', $worker_pid);

    # The worker checkpoints the first index, then parks at the point.
    $node->wait_for_event('vamana worker', 'vamana-drain-checkpoint-slow');

    # Sleep past the budget so the next pre-check trips once the worker resumes.
    usleep(1_000_000);
    $node->safe_psql("postgres",
        "SELECT injection_points_wakeup('vamana-drain-checkpoint-slow');");

    for (1 .. 100)
    {
        usleep(100_000);
        last if $node->log_content()
            =~ /\(PID $worker_pid\) exited with exit code/;
    }
    $node->safe_psql("postgres",
        "SELECT injection_points_detach('vamana-drain-checkpoint-slow');");

    my $log = substr($node->log_content(), $log_pos);

    my %complete;
    $complete{$1} = 1 while $log =~ /vamana index (\d+): checkpoint complete/g;

    like($log,
        qr/drain budget of 500 ms exhausted; \d+ of \d+ indexes not checkpointed/,
        "an overrun drain logs budget exhaustion");
    ok(scalar keys %complete >= 1,
        "the drain checkpoints the indexes it reaches before the budget expires");
    ok(scalar keys %complete < scalar @idx,
        "the drain leaves the unreached indexes uncheckpointed");

    my $frozen_ok = 1;
    for my $n (@idx)
    {
        my $oid = $node->safe_psql("postgres",
            "SELECT oid FROM pg_class WHERE relname = 'budget_idx$n';");
        chomp $oid;
        next if $complete{$oid};
        my $now_lsn = $node->safe_psql("postgres",
            "SELECT confirmed_flush_lsn FROM pg_replication_slots "
          . "WHERE slot_name = '$slot{$n}';");
        chomp $now_lsn;
        $frozen_ok = 0 unless $now_lsn eq $pre_lsn{$n};
    }
    ok($frozen_ok,
        "a skipped index's slot stays at its pre-shutdown confirmed_flush_lsn");

    unlike($log, qr/\(PID $worker_pid\) exited with exit code 1/,
        "worker exits cleanly despite the budget cutoff");

    $node->stop;
}

# Fast shutdown (SIGTERM) reaches the graceful drain and the budget bounds it,
# so pg_ctl never escalates: the drain line and the budget-exhaustion line both
# appear, no immediate-shutdown request is logged, and the worker exits cleanly.
# A 1 ms budget is outrun by real disk saves, so index 0 completes and the
# between-index guard trips without needing an injection point.
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_fast_shutdown');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "log_min_messages = debug1");
    $node->append_conf('postgresql.conf', "svs.checkpoint_min_ops = 999999");
    $node->append_conf('postgresql.conf', "svs.checkpoint_debounce_window = 999999");
    $node->append_conf('postgresql.conf', "svs.shutdown_drain_budget_ms = 1");
    $node->start;

    $node->safe_psql("postgres", "CREATE EXTENSION vector;");
    $node->safe_psql("postgres", "CREATE EXTENSION svs;");
    $node->safe_psql("postgres",
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");
    my $worker_pid = wait_for_worker($node, 30);

    for my $n (1, 2, 3)
    {
        $node->safe_psql("postgres", qq(
            CREATE TABLE fast_tbl$n (id serial PRIMARY KEY, val vector($dim));
            INSERT INTO fast_tbl$n (val)
                SELECT ARRAY[$array_sql]::vector
                FROM generate_series(1, 100) i;
            CREATE INDEX fast_idx$n ON fast_tbl$n USING vamana (val vector_l2_ops);
        ));
        $node->safe_psql("postgres", qq(
            SET enable_seqscan = off;
            SELECT id FROM fast_tbl$n ORDER BY val <-> '[$query_sql]' LIMIT 5;
        ));
    }

    my $log_pos = length($node->log_content());
    $node->stop;   # fast
    my $log = substr($node->log_content(), $log_pos);

    like($log, qr/vamana background worker shutting down/,
        "fast shutdown runs the graceful drain, not quickdie");
    like($log,
        qr/drain budget of 1 ms exhausted; \d+ of \d+ indexes not checkpointed/,
        "the granular budget bounds the drain under fast shutdown");
    unlike($log, qr/received immediate shutdown request/,
        "fast shutdown does not escalate to immediate");
    unlike($log, qr/\(PID $worker_pid\) exited with exit code 1/,
        "the worker exits cleanly under fast shutdown");
}

# Immediate shutdown (SIGQUIT) bypasses the flag-only handler: the worker takes
# the crash-equivalent quickdie path and never drains; replay recovers on the
# next start.
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_immediate_shutdown');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "log_min_messages = debug1");
    $node->start;

    $node->safe_psql("postgres", "CREATE EXTENSION vector;");
    $node->safe_psql("postgres", "CREATE EXTENSION svs;");
    $node->safe_psql("postgres",
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");
    wait_for_worker($node, 30);

    $node->safe_psql("postgres", qq(
        CREATE TABLE imm_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO imm_tbl (val)
            SELECT ARRAY[$array_sql]::vector
            FROM generate_series(1, 100) i;
        CREATE INDEX imm_idx ON imm_tbl USING vamana (val vector_l2_ops);
    ));
    $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM imm_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
    ));

    my $log_pos = length($node->log_content());
    $node->stop('immediate');
    my $log = substr($node->log_content(), $log_pos);

    like($log, qr/received immediate shutdown request/,
        "immediate shutdown request reaches the postmaster");
    unlike($log, qr/vamana background worker shutting down/,
        "immediate shutdown skips the worker drain");
}

# svs_restart_worker bounces a database's worker exactly once and then settles.
# The regression it guards against is a perpetual terminate/respawn loop: the
# liveness pass reaping the stopped handle before restart convergence can
# respawn it, so the worker never converges and its pid churns forever.
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_restart');
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
        CREATE TABLE restart_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO restart_tbl (val)
            SELECT ARRAY[$array_sql]::vector
            FROM generate_series(1, 200) i;
        CREATE INDEX restart_idx ON restart_tbl USING vamana (val vector_l2_ops);
    ));

    my $pid1 = wait_for_worker($node, 30);
    ok($pid1 =~ /^\d+$/, "worker running before restart (pid=$pid1)");

    $node->safe_psql("postgres", "SELECT svs_restart_worker('postgres');");

    my $pid2 = wait_for_new_worker_pid($node, $pid1);
    ok($pid2 =~ /^\d+$/, "worker respawned with a new pid (pid=$pid2)");
    isnt($pid2, $pid1, "restart replaced the worker (pid $pid1 -> $pid2)");

    # Once respawned, the worker must hold steady: exactly one pid over the
    # window, not a churn of terminate/respawn cycles.
    my $distinct = count_distinct_worker_pids($node, 6);
    is($distinct, 1,
        "worker pid holds steady after restart (no terminate/respawn loop)");

    # A second call bounces the worker again, proving repeatability.
    $node->safe_psql("postgres", "SELECT svs_restart_worker('postgres');");
    my $pid3 = wait_for_new_worker_pid($node, $pid2);
    ok($pid3 =~ /^\d+$/ && $pid3 ne $pid2,
        "second restart bounces the worker again (pid=$pid3)");

    $node->stop;
}

# svs_restart_worker rejects databases it cannot restart with actionable errors,
# leaving restart_generation untouched.
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_restart_errors');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->start;

    $node->safe_psql("postgres", "CREATE EXTENSION vector;");
    $node->safe_psql("postgres", "CREATE EXTENSION svs;");
    $node->safe_psql("postgres",
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', false);");

    my ($rc, $out, $err) = $node->psql('postgres',
        "SELECT svs_restart_worker('postgres');");
    isnt($rc, 0, "restart on a paused database errors");
    like($err, qr/is paused/, "paused database error is actionable");

    ($rc, $out, $err) = $node->psql('postgres',
        "SELECT svs_restart_worker('no_such_db');");
    isnt($rc, 0, "restart on an unconfigured database errors");
    like($err, qr/is not configured for vamana/,
        "unconfigured database error is actionable");

    $node->stop;
}

done_testing();
