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
# assert on the caller-visible outcome that only holds if the assigned
# value survived to the read.  A regression that dropped the volatile
# qualifier and got unlucky with register allocation would show up here as
# a slot that vanishes despite a reported failure, or a checkpoint that is
# credited despite never running.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

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

# ---------------------------------------------------------------------------
# TryDropSlot: the default/FAILED switch arm.
#
# ReplicationSlotDrop() throws inside PG_TRY(); the default arm of
# PG_CATCH()'s switch sets result = VAMANA_SLOT_DROP_FAILED and re-reports
# the error at WARNING without re-throwing, so control falls through
# PG_END_TRY() normally.  If that write were lost, a caller could see a
# stale VAMANA_SLOT_DROP_DONE and treat a slot that is still there as gone.
# ---------------------------------------------------------------------------
{
    my $node = PostgreSQL::Test::Cluster->new('vamana_pg_catch_drop');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
    $node->start;

    $node->safe_psql('postgres', "CREATE EXTENSION vector;");
    $node->safe_psql('postgres', "CREATE EXTENSION svs;");
    $node->safe_psql('postgres', "CREATE EXTENSION injection_points;");
    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

    wait_for_worker($node, 30);

    $node->safe_psql('postgres', qq{
        CREATE TABLE drop_err_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO drop_err_tbl (val)
            SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 5);
        CREATE INDEX drop_err_idx ON drop_err_tbl USING vamana (val vector_l2_ops);
    });

    my $dboid = $node->safe_psql('postgres',
        "SELECT oid FROM pg_database WHERE datname = 'postgres';");
    chomp $dboid;
    my $ioid = $node->safe_psql('postgres',
        "SELECT oid FROM pg_class WHERE relname = 'drop_err_idx';");
    chomp $ioid;
    my $slot_name = "vamana_${dboid}_${ioid}";

    ok(wait_for_slot($node, $slot_name),
        'slot exists before the injected drop failure');

    my $log_offset = -s $node->logfile;

    $node->safe_psql('postgres',
        "SELECT injection_points_attach('vamana-drop-slot-error', 'error');");

    my $ret = $node->psql('postgres', "DROP TABLE drop_err_tbl;");
    is($ret, 0, 'DROP TABLE commits even though the slot drop it triggers fails');

    $node->safe_psql('postgres',
        "SELECT injection_points_detach('vamana-drop-slot-error');");

    ok($node->log_contains(
            qr/error triggered for injection point vamana-drop-slot-error/,
            $log_offset),
        'TryDropSlot reported the injected failure instead of silently succeeding');

    is($node->safe_psql('postgres', qq{
            SELECT count(*) FROM pg_replication_slots WHERE slot_name = '$slot_name';
        }), '1',
        'the slot is still there: a lost result write could have made this look done');

    ok(wait_for_worker($node, 10),
        'the worker is still alive after the failed drop');

    $node->safe_psql('postgres',
        "SELECT pg_drop_replication_slot('$slot_name');");

    $node->stop;
}

# ---------------------------------------------------------------------------
# VamanaTryCheckpointCachedIndex: the unconditional PG_CATCH() arm.
#
# VamanaCheckpointCachedIndex() throws inside PG_TRY(); PG_CATCH() always
# sets succeeded = false and never re-throws, regardless of the error's
# errcode, so control falls through PG_END_TRY() normally.  If that write
# were lost, a caller could see a stale "true" and treat a checkpoint that
# never ran as flushed.
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

    my $dboid = $node->safe_psql('postgres',
        "SELECT oid FROM pg_database WHERE datname = 'postgres';");
    chomp $dboid;
    my $ioid = $node->safe_psql('postgres',
        "SELECT oid FROM pg_class WHERE relname = 'ckpt_err_idx';");
    chomp $ioid;
    my $slot_name = "vamana_${dboid}_${ioid}";

    ok(wait_for_slot($node, $slot_name), 'slot exists before the injected checkpoint failure');

    my $baseline = current_lsn($node, $slot_name);

    $node->safe_psql('postgres',
        "SELECT injection_points_attach('vamana-checkpoint-cached-index-error', 'error');");

    $node->safe_psql('postgres',
        "INSERT INTO ckpt_err_tbl (val) VALUES (ARRAY[$array_sql]::vector);");

    # Give the debounced checkpoint sweep a few ticks to attempt and fail.
    ok(!wait_for_lsn_advance($node, $slot_name, $baseline, 3),
        'the checkpoint never actually ran while the injection point was armed');

    ok(wait_for_worker($node, 10),
        'the worker survives a checkpoint that fails inside PG_TRY()');

    $node->safe_psql('postgres',
        "SELECT injection_points_detach('vamana-checkpoint-cached-index-error');");

    $node->safe_psql('postgres',
        "INSERT INTO ckpt_err_tbl (val) VALUES (ARRAY[$array_sql]::vector);");

    ok(wait_for_lsn_advance($node, $slot_name, $baseline, 15),
        'once uninjected, the same index checkpoints normally: the failed attempt left nothing corrupted');

    $node->stop;
}

done_testing();
