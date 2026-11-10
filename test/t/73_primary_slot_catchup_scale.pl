# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 73_primary_slot_catchup_scale.pl -- at-scale verification of the
# fast-forward catch-up step (VamanaReplicationCatchUpSlot) that drains a
# primary's replication-slot lag without a standby or any logical consumer.
#
# A long-open transaction pins the slot's restart point exactly the way core
# logical decoding does for any slot: the running-xacts record it is caught
# under cannot be accepted as a candidate until it commits.  Combined with a
# backlog of real WAL on an unindexed table, this reproduces the condition
# the fix exists for without needing injection points.
#
# Tests:
#   The backlog is real (verified against pg_wal, not just the slot view).
#   Concurrent single-row inserts to the indexed table never time out
#       while the backlog drains.
#   The gap closes to within one running-xacts stride inside a stated
#       slice budget.
#   Per-slice invariants hold throughout, checked against
#       pg_replication_slots: restart_lsn never outruns what a slice
#       actually decoded, and stays monotonic and bounded by confirmed_flush.
#   The durability invariant holds end-to-end: a hard kill, followed by
#       restart, loses nothing durable (search results match the heap).

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep time);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

my $dim = 16;
my $array_sql = join(",", ('random()') x $dim);

my $node = PostgreSQL::Test::Cluster->new('vamana_primary_catchup_scale');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 10");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->append_conf('postgresql.conf', "log_min_messages = debug1");
$node->append_conf('postgresql.conf', "max_wal_size = 4GB");

# Tighten svs.worker_timeout_ms so B = Min(1000, worker_timeout_ms / 5) is a
# small, deterministic 200 ms instead of the 1000 ms default-GUC bound: the
# backlog needed to provoke the pre-fix failure is correspondingly smaller,
# and the per-slice elapsed assertion below is tight enough to catch a
# budget regression instead of only a gross one.
$node->append_conf('postgresql.conf', "svs.worker_timeout_ms = 1000");
$node->append_conf('postgresql.conf', "svs.checkpoint_operations = 50");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres',
	"INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");
wait_for_worker($node, 30);

$node->safe_psql('postgres', qq{
	CREATE TABLE scale_tbl (id serial PRIMARY KEY, val vector($dim));
	INSERT INTO scale_tbl (val)
		SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 100) i;
	CREATE INDEX scale_idx ON scale_tbl USING vamana (val vector_l2_ops);
	CREATE TABLE scale_filler (id bigserial, pad text);
});
my $worker_pid = wait_for_worker_db($node, 'postgres', 30);
ok($worker_pid =~ /^\d+$/, "catchup scale: worker running normally (pid=$worker_pid)");

sub slot_row
{
	my $row = $node->safe_psql('postgres', qq{
		SELECT restart_lsn, confirmed_flush_lsn
		FROM pg_replication_slots WHERE slot_name LIKE 'vamana\\_%';
	});
	chomp $row;
	return split /\|/, $row;
}

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
ok($consistent, "catchup scale: slot reaches its first consistent point");

# ---------------------------------------------------------------------------
# Build the backlog: hold an open transaction so its own xid pins the
# slot's restart point under core semantics, generate real WAL on an
# unindexed table, checkpoint the vamana index so confirmed_flush covers
# the backlog, then commit.  No injection points required.
# ---------------------------------------------------------------------------
my $held_h = $node->background_psql('postgres');
$held_h->query_safe("BEGIN;");
my $held_xid = $held_h->query_safe("SELECT txid_current();");
chomp $held_xid;
ok($held_xid =~ /^\d+$/, "catchup scale: held transaction has an xid ($held_xid)");

my $wal_before = $node->safe_psql('postgres', "SELECT pg_current_wal_lsn();");
chomp $wal_before;

# ~1 GB of filler total, well past svs.max_slot_wal_size / 2 so the lag is
# unmistakably real, and well past one running-xacts stride (64 MB).
# Generated in chunks with an explicit pg_log_standby_snapshot() after each
# one, not as a single bulk statement: a fresh fast-forward decoder is
# re-opened from the same frozen restart_lsn every slice and can only reach
# as far into the backlog as its own budget allows before timing out, a
# small fraction of a gap this size.  A single marker placed only at the
# very end, near confirmed_flush, would sit far past where any one slice
# can reach, so the catch-up step would be stuck on a backlog large enough
# that the worker's own periodic running-xacts emission (which also only
# ever lands near the current end of WAL) cannot help either.  Markers
# spread through the backlog let each slice close one step of the gap and
# start the next slice that much closer to the next marker, the same
# incremental pattern 69_primary_slot_advance.pl's loop uses, just at a
# scale this file is checking specifically.
for (1 .. 10)
{
	$node->safe_psql('postgres', qq{
		INSERT INTO scale_filler (pad)
			SELECT repeat('x', 1024) FROM generate_series(1, 100_000);
	});
	$node->safe_psql('postgres', "SELECT pg_log_standby_snapshot();");
}
$node->safe_psql('postgres', qq{
	INSERT INTO scale_tbl (val)
		SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 60) i;
});

my $wal_after = $node->safe_psql('postgres', "SELECT pg_current_wal_lsn();");
chomp $wal_after;
my $wal_generated = $node->safe_psql('postgres',
	"SELECT pg_wal_lsn_diff('$wal_after', '$wal_before');");
chomp $wal_generated;
ok($wal_generated > 512 * 1024 * 1024,
	"catchup scale: backlog is real on-disk WAL ($wal_generated bytes generated)");

my ($restart0, $confirmed0) = slot_row();
my $gap0 = $node->safe_psql('postgres',
	"SELECT pg_wal_lsn_diff('$confirmed0', '$restart0');");
chomp $gap0;
cmp_ok($gap0, '>', 256 * 1024 * 1024,
	"catchup scale: held transaction kept restart_lsn pinned well behind confirmed_flush ($gap0 bytes)");

$held_h->query_safe("COMMIT;");
$held_h->quit;

# The transaction's own commit does not by itself write a fresh
# RUNNING_XACTS record; without one, every slice re-opens from the same
# restart_lsn and can only make progress as far into the backlog as its
# budget reaches before timing out, which for a backlog this size is a
# small fraction of the whole gap -- nowhere near any marker written
# later, near the current end of WAL.  One explicit snapshot right here,
# at the point restart_lsn is actually stuck, is what a slice can reach
# quickly; without it the catch-up step would be stuck on a backlog large
# enough that the worker's own periodic running-xacts emission (which
# only ever lands near the current end of WAL, just like this one would
# without the explicit call below) cannot help either.
$node->safe_psql('postgres', "SELECT pg_log_standby_snapshot();");

# ---------------------------------------------------------------------------
# Concurrent writes never time out while the drain runs, and invariants
# are checked throughout.  One sequential loop of single-row inserts
# overlaps whatever slice is in progress at any given moment, since the
# worker is single-threaded: a write issued mid-slice either returns
# promptly (the request queue is serviced between slices, per the catch-up
# step's own spacing) or, if the fix regresses, blocks for the slice's
# duration or longer.
# ---------------------------------------------------------------------------
my $max_write_latency = 0;
my $write_errors = 0;
my $seg_bytes = 16 * 1024 * 1024;	# default wal_segment_size
my $stride_bytes = 64 * 1024 * 1024;	# VAMANA_RUNNING_XACTS_STRIDE

my $drained = 0;
my $restart_final = $restart0;
my $prev_restart = $restart0;
my $i1_violations = 0;
my $i3_violations = 0;

for my $iter (1 .. 90)
{
	my $t0 = time();
	my ($out, $err) = ('', '');
	eval {
		($out, $err) = $node->psql('postgres', qq{
			INSERT INTO scale_tbl (val) VALUES (ARRAY[$array_sql]::vector);
		});
	};
	my $elapsed_ms = (time() - $t0) * 1000;
	$max_write_latency = $elapsed_ms if $elapsed_ms > $max_write_latency;
	$write_errors++ if $@ || ($err // '') ne '';

	# confirmed_flush only advances at a checkpoint; keep both moving so
	# there is always fresh ground for a running-xacts record to land on,
	# same as 69_primary_slot_advance.pl's cheap-case loop.  svs.checkpoint_operations
	# is 50, so this crosses the threshold every iteration.
	$node->safe_psql('postgres', qq{
		INSERT INTO scale_tbl (val)
			SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 60) i;
	});
	$node->safe_psql('postgres', "SELECT pg_log_standby_snapshot();");

	my ($restart, $confirmed) = slot_row();

	# restart_lsn must stay monotonic and never pass confirmed_flush.
	my $monotonic = $node->safe_psql('postgres',
		"SELECT pg_lsn('$restart') >= pg_lsn('$prev_restart') AND pg_lsn('$restart') <= pg_lsn('$confirmed');");
	chomp $monotonic;
	$i3_violations++ if $monotonic ne 't';
	$prev_restart = $restart;
	$restart_final = $restart;

	my $gap = $node->safe_psql('postgres',
		"SELECT pg_wal_lsn_diff('$confirmed', '$restart');");
	chomp $gap;
	if ($gap < $stride_bytes)
	{
		$drained = 1;
		last;
	}
	usleep(500_000);
}

is($write_errors, 0, "catchup scale: zero write errors while the backlog drains");
cmp_ok($max_write_latency, '<', 1000,
	"catchup scale: max write latency ($max_write_latency ms) stays under svs.worker_timeout_ms");
is($i3_violations, 0, "catchup scale: restart_lsn stayed monotonic and <= confirmed_flush every sample");
ok($drained,
	"catchup scale: gap closed to within one running-xacts stride (restart_lsn=$restart_final)");

# restart_lsn must never advance past a position a slice actually decoded;
# checked from the DEBUG1 slice log: every slice's end_restart must be
# <= that slice's own exit_recptr.
my $log_content = $node->log_content();
my @slices = ($log_content =~
	/vamana catch-up:.*?exit_recptr=([0-9A-Fa-f]+\/[0-9A-Fa-f]+).*?end_restart=([0-9A-Fa-f]+\/[0-9A-Fa-f]+)/g);
my $slice_count = @slices / 2;
ok($slice_count > 0, "catchup scale: at least one catch-up slice ran ($slice_count observed)");
for (my $s = 0; $s < @slices; $s += 2)
{
	my ($exit_recptr, $end_restart) = @slices[$s, $s + 1];
	my $ok = $node->safe_psql('postgres',
		"SELECT pg_lsn('$end_restart') <= pg_lsn('$exit_recptr');");
	chomp $ok;
	$i1_violations++ if $ok ne 't';
}
is($i1_violations, 0, "catchup scale: restart_lsn never advanced past a decoded position, every slice");

# The slice time budget: B = Min(1000, svs.worker_timeout_ms / 5) = 200 ms
# here.  Each slice's own elapsed_us (measured inside C around the decode
# loop, not inferred from log timestamps) must stay within B plus the
# itemised overshoot margin the budget design allows for (150 ms covers it).
my $budget_ms = 200;
my @elapsed_values = ($log_content =~ /vamana catch-up:.*?elapsed_us=(\d+(?:\.\d+)?)/g);
my $slow_slices = 0;
$slow_slices++ for grep { $_ / 1000 > $budget_ms + 150 } @elapsed_values;
is($slow_slices, 0,
	"catchup scale: every slice's elapsed time stayed within B + 150 ms (" . scalar(@elapsed_values) . " slices checked)");

# ---------------------------------------------------------------------------
# The durability invariant end to end: a hard kill mid-write, then restart,
# must lose nothing durable.  Capture the expected row count first.
# ---------------------------------------------------------------------------
my $expected_count = $node->safe_psql('postgres', "SELECT count(*) FROM scale_tbl;");
chomp $expected_count;

$node->kill9;
unlink($node->data_dir . '/postmaster.pid');
$node->start;

wait_for_worker_db($node, 'postgres', 30);

my $after_count = $node->safe_psql('postgres', qq{
	SET enable_seqscan = off;
	SELECT count(*) FROM (
		SELECT id FROM scale_tbl ORDER BY val <-> ARRAY[$array_sql]::vector LIMIT 100000
	) sub;
});
chomp $after_count;
is($after_count, $expected_count,
	"catchup scale: index search matches the heap after a hard kill ($after_count rows)");

$node->stop;

done_testing();
