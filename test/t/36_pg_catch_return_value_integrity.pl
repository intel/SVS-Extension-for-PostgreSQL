# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 29_pg_catch_return_value_integrity.pl — regression coverage for the two
# PG_CATCH()-assigned return values that needed a volatile qualifier to avoid
# -Wclobbered's longjmp hazard: TryDropSlot's result and
# VamanaTryCheckpointCachedIndex's succeeded.  Both are assigned inside
# PG_CATCH() and read after PG_END_TRY(), on a path that falls through
# normally rather than re-throwing.
#
# A test cannot force the specific register-allocation miscompile the
# hazard describes, but it can force the exact PG_CATCH() arm to run and
# assert on the one caller-visible signal that actually depends on the
# assigned value surviving to the read, rather than on a side effect (like
# LSN advancement, or the command committing) that every possible clobbered
# value produces identically.  For TryDropSlot, that signal is the BUSY arm
# specifically: BUSY and FAILED both drive the same worker hand-off, so only
# DONE is distinguishable from them, and forcing DONE proves nothing about
# surviving the longjmp (it is also this function's zero-initialized default,
# so a clobbered read that happens to land on DONE looks identical to a
# correct one).  BUSY is reliably reproducible from outside the server
# (externally holding the slot); FAILED is not, without an injection point.
# For VamanaTryCheckpointCachedIndex,
# that signal is the "will retry" LOG line its callers emit on failure and
# only on failure -- not LSN state, which is decided inside PerformCheckpoint
# before succeeded is ever read.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);
use IPC::Run;

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

if (($ENV{enable_injection_points} // 'no') ne 'yes')
{
    plan skip_all => 'server not built with --enable-injection-points';
}

sub current_lsn
{
    my ($node, $slot_name) = @_;
    my $lsn = $node->safe_psql('postgres', qq{
        SELECT confirmed_flush_lsn FROM pg_replication_slots
        WHERE slot_name = '$slot_name';
    });
    chomp $lsn;
    return $lsn;
}

sub wait_for_lsn_advance
{
    my ($node, $slot_name, $baseline, $timeout_s) = @_;
    $timeout_s //= 10;
    for (1 .. $timeout_s * 2)
    {
        usleep(500_000);
        my $lsn = current_lsn($node, $slot_name);
        return 1 if $lsn ne $baseline && $lsn ne '';
    }
    return 0;
}

sub wait_for_slot
{
    my ($node, $slot_name, $attempts) = @_;
    $attempts //= 20;
    for (1 .. $attempts)
    {
        usleep(500_000);
        my $cnt = $node->safe_psql('postgres', qq{
            SELECT count(*) FROM pg_replication_slots
            WHERE slot_name = '$slot_name';
        });
        chomp $cnt;
        return 1 if $cnt == 1;
    }
    return 0;
}

# Polls log_contains rather than wait_for_log, which croaks on timeout: a
# timeout here is a real (if unlikely) test failure, not a harness error.
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

# Issues pg_log_backend_memory_contexts() for $pid, then polls the log from
# $offset for that backend's ErrorContext line and returns its "used" figure.
# Returns undef on timeout.
sub get_error_context_used
{
    my ($node, $pid, $offset, $timeout_s) = @_;
    $timeout_s //= 10;
    $node->safe_psql('postgres', "SELECT pg_log_backend_memory_contexts($pid);");
    for (1 .. $timeout_s * 2)
    {
        my $log = PostgreSQL::Test::Utils::slurp_file($node->logfile, $offset);
        if ($log =~ /\[$pid\].*ErrorContext: \d+ total in \d+ blocks; \d+ free \(\d+ chunks\); (\d+) used/)
        {
            return $1;
        }
        usleep(500_000);
    }
    return undef;
}

# Starts pg_recvlogical against $slot_name and blocks until active_pid is set
# to something other than $excluded_pid.  Returns the IPC::Run handle; caller
# must kill_kill it.  Copied from 07_replication_slots.pl's helper of the same
# name rather than shared, to keep this file's injection-point dependency
# isolated from that file's much larger, non-injection-point test set.
sub hold_slot_externally
{
    my ($node, $slot_name, $excluded_pid) = @_;

    my $handle = IPC::Run::start([
        $node->installed_command('pg_recvlogical'),
        '--dbname' => $node->connstr('postgres'),
        '--slot'   => $slot_name,
        '--file'   => '-',
        '--start',
    ]);

    $node->poll_query_until('postgres', qq{
        SELECT active_pid IS NOT NULL AND active_pid <> $excluded_pid
        FROM pg_replication_slots WHERE slot_name = '$slot_name';
    }) or die "slot \"$slot_name\" never became externally active";

    return $handle;
}

# ---------------------------------------------------------------------------
# TryDropSlot: the BUSY switch arm, and the hand-off it gates.
#
# VamanaRetireIndexArtifacts (the DROP INDEX commit-time caller, via
# ApplyPendingSlotDrops) returns early only on DONE; both BUSY and FAILED
# fall through to VamanaWorkerRequestSlotDrop, handing the drop to the worker
# instead of abandoning it.  A test that only forces FAILED still cannot tell
# a correct read from one clobbered to DONE, since that is this path's only
# other outcome and its own zero-initialized default; BUSY is reproducible
# from outside the server without an injection point, so it remains the
# signal this test forces.
#
# Externally holding the slot with pg_recvlogical (rather than racing the
# worker's own transient use, as the non-deterministic test in
# 07_replication_slots.pl does) guarantees TryDropSlot sees ERRCODE_OBJECT_IN_USE
# both times it runs here: once at DROP INDEX commit (the backend's call,
# gating the hand-off) and again when the worker dequeues the handed-off
# request and retries (VamanaWorkerProcessSlotDrops).  The worker's retry
# logs a WARNING naming the index if, and only if, its own read of result is
# BUSY -- so seeing that exact line is proof that both reads survived: the
# backend's (to trigger the hand-off at all) and the worker's (to log this
# specific message instead of the "dropped" LOG line or nothing).  A lost
# write on either read breaks this chain at a different, distinguishable
# point: a clobbered backend-side read never hands off, so the WARNING never
# appears at all; a clobbered worker-side read logs "dropped" instead.
# ---------------------------------------------------------------------------
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_pg_catch_drop_busy');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
    $node->start;

    $node->safe_psql('postgres', "CREATE EXTENSION vector;");
    $node->safe_psql('postgres', "CREATE EXTENSION svs;");
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    my $worker_pid = wait_for_worker($node, 30);

    $node->safe_psql('postgres', qq{
        CREATE TABLE drop_busy_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO drop_busy_tbl (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 5);
        CREATE INDEX drop_busy_idx ON drop_busy_tbl USING vamana (val vector_l2_ops);
    });

    my $dboid = $node->safe_psql('postgres',
        "SELECT oid FROM pg_database WHERE datname = 'postgres';");
    chomp $dboid;
    my $ioid = $node->safe_psql('postgres',
        "SELECT oid FROM pg_class WHERE relname = 'drop_busy_idx';");
    chomp $ioid;
    my $slot_name = "vamana_${dboid}_${ioid}";

    ok(wait_for_slot($node, $slot_name),
        'slot exists before the externally-forced BUSY drop');

    my $held = hold_slot_externally($node, $slot_name, $worker_pid);

    my $log_offset = -s $node->logfile;

    my $ret = $node->psql('postgres', "DROP INDEX drop_busy_idx;");
    is($ret, 0,
        'DROP INDEX commits immediately: TryDropSlot never blocks on a busy slot');

    ok(wait_for_log_line($node,
            qr/replication slot of removed index $ioid is still held/,
            $log_offset, 15),
        'the worker\'s own retry also saw BUSY and logged it: both the backend\'s and '
      . 'the worker\'s reads of result survived their respective PG_CATCH()/PG_END_TRY()');

    ok(!$node->log_contains(
            qr/dropped replication slot of removed index $ioid\b/,
            $log_offset),
        'no caller mistook the busy slot for a completed drop');

    ok(wait_for_worker($node, 10),
        'the worker is still alive after handling the busy drop');

    $held->kill_kill;

    # The worker now keeps retrying a BUSY drop on a throttled cadence rather
    # than giving up after the one hand-off, so once the external holder is
    # gone the next retry succeeds on its own; no manual cleanup needed.
    ok(wait_for_log_line($node,
            qr/dropped replication slot of removed index $ioid\b/,
            $log_offset, 15),
        'once the external holder is gone, the worker\'s own retry succeeds and drops the slot');

    $node->stop;
}

# ---------------------------------------------------------------------------
# VamanaTryCheckpointCachedIndex: the unconditional PG_CATCH() arm.
#
# Both callers (VamanaWorkerCheckpointDueIndexes, VamanaWorkerDrainFinalCheckpoint)
# use succeeded only to decide whether to emit a LOG line; LSN advancement is
# decided entirely inside PerformCheckpoint, before succeeded is ever read, so
# it holds the same value regardless of whether succeeded survives the
# longjmp correctly.  The "will retry" LOG line is the one signal that
# actually depends on the read.
#
# This block also proves a second, independent property of the same catch: it
# must leave the caller's memory context exactly as it found it.  A single
# failure here lands before the checkpoint's own transaction starts, so there
# is no transaction abort to restore the context as a side effect; only a
# second consecutive failure actually frees live data out from under the
# caller, so the injection point is held across two full cycles rather than
# one.  The same worker (not a replacement after a crash) must survive both,
# with no signal termination; and even where no crash occurs, the worker's
# ErrorContext must not keep growing once checkpoints resume succeeding.
# ---------------------------------------------------------------------------
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_pg_catch_checkpoint');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
    $node->append_conf('postgresql.conf', "svs.checkpoint_operations = 0");
    $node->append_conf('postgresql.conf', "svs.checkpoint_min_ops = 1");
    $node->append_conf('postgresql.conf', "svs.checkpoint_debounce_window = 1");
    $node->start;

    $node->safe_psql('postgres', "CREATE EXTENSION vector;");
    $node->safe_psql('postgres', "CREATE EXTENSION svs;");
    $node->safe_psql('postgres', "CREATE EXTENSION injection_points;");
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    my $worker_pid = wait_for_worker($node, 30);
    ok($worker_pid ne '', 'the worker starts for the postgres database');

    $node->safe_psql('postgres', qq{
        CREATE TABLE ckpt_err_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO ckpt_err_tbl (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 5);
        CREATE INDEX ckpt_err_idx ON ckpt_err_tbl USING vamana (val vector_l2_ops);
    });

    my $ioid = $node->safe_psql('postgres',
        "SELECT oid FROM pg_class WHERE relname = 'ckpt_err_idx';");
    chomp $ioid;
    my $dboid = $node->safe_psql('postgres',
        "SELECT oid FROM pg_database WHERE datname = 'postgres';");
    chomp $dboid;
    my $slot_name = "vamana_${dboid}_${ioid}";

    ok(wait_for_slot($node, $slot_name), 'slot exists before the injected checkpoint failure');

    my $baseline = current_lsn($node, $slot_name);
    my $log_offset = -s $node->logfile;

    $node->safe_psql('postgres',
        "SELECT injection_points_attach('vamana-checkpoint-cached-index-error', 'error');");

    $node->safe_psql('postgres',
        "INSERT INTO ckpt_err_tbl (val) VALUES (ARRAY[$array_sql]::vector);");

    ok(wait_for_log_line($node,
            qr/vamana checkpoint: index $ioid not checkpointed this cycle, will retry/,
            $log_offset, 10),
        'succeeded read back false: the worker logged the failure-only "will retry" line');

    # One failure only poisons CurrentMemoryContext; it takes a second failure,
    # with the injection point still attached, to free live loop data out from
    # under the checkpoint sweep and crash an assert build.  Hold the injection
    # point open across both cycles rather than detaching after the first.
    my $second_fail_offset = -s $node->logfile;

    ok(wait_for_log_line($node,
            qr/vamana checkpoint: index $ioid not checkpointed this cycle, will retry/,
            $second_fail_offset, 10),
        'a second consecutive pre-transaction failure also logs the failure-only line');

    $node->safe_psql('postgres',
        "SELECT injection_points_detach('vamana-checkpoint-cached-index-error');");

    # The crash, when it happens, lands within milliseconds of the second
    # failure (about 780 ms observed with core dumps enabled).  Give the
    # worker one full heartbeat past that point before touching the server
    # with SQL: on unfixed code the node is down by then, and any safe_psql
    # call croaks instead of failing a test.  log_contains only reads the
    # file, so it is safe to use even if the server already died.
    usleep(1_500_000);

    ok(!$node->log_contains(
            qr/terminated by signal|server process .* was terminated/,
            $log_offset),
        'the worker was not killed by a signal after two consecutive pre-transaction checkpoint failures');

    is(wait_for_worker($node, 10), $worker_pid,
        'the same worker (not a restart) survives both checkpoint failures');

    $log_offset = -s $node->logfile;

    $node->safe_psql('postgres',
        "INSERT INTO ckpt_err_tbl (val) VALUES (ARRAY[$array_sql]::vector);");

    ok(wait_for_lsn_advance($node, $slot_name, $baseline, 15),
        'once uninjected, the checkpoint actually runs: confirmed_flush_lsn advances');

    ok(!$node->log_contains(
            qr/vamana checkpoint: index $ioid not checkpointed this cycle, will retry/,
            $log_offset),
        'succeeded read back true: no failure-only line for the successful attempt');

    # The crash reproduces reliably only on an assert build (CLOBBER_FREED_MEMORY
    # makes the stale List read garbage).  On a release build the same bug
    # leaves the worker's CurrentMemoryContext stuck on ErrorContext with no
    # crash at all, and the only observable symptom is that ErrorContext keeps
    # growing every heartbeat even once checkpoints are succeeding (nothing
    # should accumulate there with no error in flight).  This is the one check
    # in the file that catches the bug on a release build.
    my $mc_offset1 = -s $node->logfile;
    my $used1 = get_error_context_used($node, $worker_pid, $mc_offset1, 10);
    ok(defined $used1, 'got the worker\'s ErrorContext usage after the recovered checkpoint');

    sleep(4);

    my $mc_offset2 = -s $node->logfile;
    my $used2 = get_error_context_used($node, $worker_pid, $mc_offset2, 10);
    ok(defined $used2, 'got the worker\'s ErrorContext usage a few heartbeats later');

    cmp_ok($used2, '<=', $used1,
        "ErrorContext usage does not grow across heartbeats with no error in flight ($used1 -> $used2)");

    $node->stop;
}

done_testing();
