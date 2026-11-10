# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 69_primary_slot_advance.pl -- a primary's own replication slot advances on
# its own, without a standby or any other logical consumer ever decoding it.
#
# The checkpoint path records the slot's durable point directly, with no
# decoding of its own; a separate, budgeted fast-forward decode step run
# from the worker's main loop is what actually advances restart_lsn, bounded
# to never decode past the slot's own confirmed_flush.  A lag under one WAL
# segment retains nothing extra on disk, so the catch-up step is a no-op
# below that; this file's cheap cases generate enough WAL to cross that
# floor instead of asserting restart_lsn moves every single write cycle.
#
# Tests:
#   The catch-up step drains restart_lsn toward confirmed_flush once lag
#       exceeds one WAL segment, on its own cadence, without the checkpoint
#       path ever decoding (the primary pass/fail signal).
#   pg_wal usage stays bounded rather than tracking total WAL written.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

my $dim = 16;
my $array_sql = join(",", ('random()') x $dim);

my $node = PostgreSQL::Test::Cluster->new('vamana_primary_slot_advance');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 10");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->append_conf('postgresql.conf', "log_min_messages = debug1");

# Debounce the per-index checkpoint on a small, deterministic op count
# instead of the default (10000 ops / 300s quiet window), so the one write
# batch below reliably triggers a checkpoint instead of waiting on either
# default threshold.
$node->append_conf('postgresql.conf', "svs.checkpoint_operations = 50");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres',
	"INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");
wait_for_worker($node, 30);

$node->safe_psql('postgres', qq{
	CREATE TABLE advance_tbl (id serial PRIMARY KEY, val vector($dim));
	INSERT INTO advance_tbl (val)
		SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 100) i;
	CREATE INDEX advance_idx ON advance_tbl USING vamana (val vector_l2_ops);
});
my $worker_pid = wait_for_worker_db($node, 'postgres', 30);
ok($worker_pid =~ /^\d+$/,
	"primary slot advance: worker running normally (pid=$worker_pid)");

sub slot_lsns
{
	my $row = $node->safe_psql('postgres', qq{
		SELECT restart_lsn, confirmed_flush_lsn
		FROM pg_replication_slots WHERE slot_name LIKE 'vamana\\_%';
	});
	chomp $row;
	return split /\|/, $row;
}

my ($restart0, $confirmed0) = slot_lsns();
ok(defined $restart0 && length $restart0,
	'primary slot advance: slot exists with a restart_lsn after index creation');

# CREATE INDEX's own catch-up decode to the slot's first consistent point runs
# in the worker asynchronously; writing before it finishes can block on the
# worker's write-IPC path.  Poll confirmed_flush_lsn rather than sleeping a
# fixed amount.
my $consistent = 0;
for (1 .. 60)
{
	my $cf = $node->safe_psql('postgres', qq{
		SELECT confirmed_flush_lsn IS NOT NULL
		FROM pg_replication_slots WHERE slot_name LIKE 'vamana\\_%';
	});
	chomp $cf;
	if ($cf eq 't')
	{
		$consistent = 1;
		last;
	}
	usleep(500_000);
}
ok($consistent, 'primary slot advance: slot reaches its first consistent point');

my $wal_segment_size_str = $node->safe_psql('postgres', "SHOW wal_segment_size;");
chomp $wal_segment_size_str;
my ($seg_num, $seg_unit) = $wal_segment_size_str =~ /^(\d+)\s*([A-Za-z]*)$/;
my %unit_bytes = ('' => 1, 'kB' => 1024, 'MB' => 1024 * 1024, 'GB' => 1024 * 1024 * 1024);
my $seg_bytes = $seg_num * ($unit_bytes{$seg_unit} // 1);

$node->safe_psql('postgres', "CREATE TABLE advance_filler (id bigserial, pad text);");

# Generate well past one WAL segment of filler on an unrelated table, call
# pg_log_standby_snapshot() explicitly (what the worker's own periodic
# running-xacts emission would eventually do on its own, but deterministically,
# before confirmed_flush is captured rather than racing with it:
# GetXLogInsertRecPtr, which that emission reads, leads the flush pointer
# checkpoint_lsn is captured from, so a record emitted around a checkpoint
# typically lands at or just past that same checkpoint's own confirmed_flush --
# too late to help it, only a later one), then one small checkpoint-worthy
# write to advance_tbl so confirmed_flush is captured only slightly past the
# explicit snapshot and covers it.  Without a fresh running-xacts record
# inside [restart_lsn, confirmed_flush], the catch-up step would be stuck:
# nothing else writes one on a timescale this short, so the only candidate
# restart_lsn can accept is whatever running-xacts record already existed
# before the filler, and it stays stuck there.
$node->safe_psql('postgres', qq{
	INSERT INTO advance_filler (pad)
		SELECT repeat('x', 1024) FROM generate_series(1, 30000);
});
$node->safe_psql('postgres', "SELECT pg_log_standby_snapshot();");
$node->safe_psql('postgres', qq{
	INSERT INTO advance_tbl (val)
		SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 60) i;
});

my ($restart1, $confirmed1) = slot_lsns();
my $lag_after_filler = $node->safe_psql('postgres',
	"SELECT pg_wal_lsn_diff('$confirmed1', '$restart1');");
chomp $lag_after_filler;
cmp_ok($lag_after_filler, '>=', $seg_bytes,
	"primary slot advance: filler plus checkpoints produced at least one WAL segment of lag ($lag_after_filler bytes)");

# confirmed_flush only moves at a checkpoint, so a one-shot snapshot call
# before a single checkpoint is a race against exactly where that one call
# lands relative to the confirmed_flush that same checkpoint captures (this
# flaked in practice).  Instead, keep both moving together: a small write
# to advance_tbl each iteration both raises confirmed_flush a bit further
# (so there is always fresh ground for a running-xacts record to land on)
# and calls pg_log_standby_snapshot() right after, standing in for the
# worker's own ongoing running-xacts emission in a real deployment.
# Frequent checkpoints like this are exactly what the catch-up step's
# save-defer counter exists to tolerate without starving the step outright;
# this is also a live check that the defer counter actually bounds the
# starvation rather than being unbounded.
my $drained = 0;
my $restart_final = $restart1;
for (1 .. 60)
{
	$node->safe_psql('postgres', qq{
		INSERT INTO advance_tbl (val)
			SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 60) i;
	});
	$node->safe_psql('postgres', "SELECT pg_log_standby_snapshot();");

	my ($restart, $confirmed) = slot_lsns();
	my $lag = $node->safe_psql('postgres',
		"SELECT pg_wal_lsn_diff('$confirmed', '$restart');");
	chomp $lag;
	$restart_final = $restart;
	if ($lag < $seg_bytes)
	{
		$drained = 1;
		last;
	}
	usleep(500_000);
}
ok($drained,
	'primary slot advance: catch-up step drains restart_lsn toward confirmed_flush below one WAL segment');

my $wal_now = $node->safe_psql('postgres', "SELECT pg_current_wal_lsn();");
chomp $wal_now;

my $lag_final = $node->safe_psql('postgres',
	"SELECT pg_wal_lsn_diff('$wal_now', '$restart_final');");
chomp $lag_final;

cmp_ok($lag_final, '<', 2 * $seg_bytes,
	"primary slot advance: restart_lsn lag ($lag_final bytes) stays bounded instead of tracking total WAL written");

$node->stop;

done_testing();
