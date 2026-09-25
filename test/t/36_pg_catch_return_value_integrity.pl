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
# specifically: TryDropSlot's other non-BUSY outcomes (DONE, FAILED) are
# indistinguishable to every caller in this codebase (VAMANA_SLOT_DROP_FAILED
# is written but never read anywhere), so only a genuinely-busy slot exercises
# a caller branch that depends on the value.  For VamanaTryCheckpointCachedIndex,
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
# ApplyPendingSlotDrops (the DROP INDEX commit-time caller) branches only on
# result != VAMANA_SLOT_DROP_BUSY: DONE and FAILED both just "continue" with
# no further action, so a test that only forces FAILED cannot tell a correct
# read from a clobbered one -- every value that isn't BUSY looks identical to
# every caller.  BUSY is the one value with a caller-visible, value-dependent
# effect: it alone drives VamanaWorkerRequestSlotDrop, handing the drop to the
# worker instead of abandoning it.
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

    # Both the backend's and the worker's single retry are now spent (neither
    # queues another attempt), so nothing will drop this slot on its own; drop
    # it directly so the cluster doesn't shut down holding a slot open.
    $node->safe_psql('postgres',
        "SELECT pg_drop_replication_slot('$slot_name');");

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

    wait_for_worker($node, 30);

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

    ok(wait_for_worker($node, 10),
        'the worker survives a checkpoint that fails inside PG_TRY()');

    $node->safe_psql('postgres',
        "SELECT injection_points_detach('vamana-checkpoint-cached-index-error');");

    $log_offset = -s $node->logfile;

    $node->safe_psql('postgres',
        "INSERT INTO ckpt_err_tbl (val) VALUES (ARRAY[$array_sql]::vector);");

    ok(wait_for_lsn_advance($node, $slot_name, $baseline, 15),
        'once uninjected, the checkpoint actually runs: confirmed_flush_lsn advances');

    ok(!$node->log_contains(
            qr/vamana checkpoint: index $ioid not checkpointed this cycle, will retry/,
            $log_offset),
        'succeeded read back true: no failure-only line for the successful attempt');

    $node->stop;
}

done_testing();
