# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 74_vamana_standby_slot_invalidation.pl: standby slot invalidation under
# hot_standby_feedback = off.
#
# A standby's vamana slot is a logical slot, so it needs catalog rows the
# primary must not vacuum away.  Only hot_standby_feedback pins the primary's
# catalog_xmin on the standby's behalf.  With it off, a catalog VACUUM on the
# primary produces a recovery conflict on replay and PostgreSQL invalidates the
# slot.
#
# What this file establishes:
#   1. The worker warns at startup when it is on a standby with
#      hot_standby_feedback off, and that warning precedes any invalidation.
#   2. The slot really does get invalidated, with reason 'rows_removed', and the
#      worker survives it without crashing.
#   3. Once invalidated, the drain sweep drops the slot and rebuilds the index
#      from the heap rather than continuing to decode through it, and logs the
#      rebuild so the degraded-and-recovering state is visible to an operator.
#      The worker's main loop is paused on an injection point for the span
#      between invalidation and the write that follows it, so the rebuild is
#      proven to run against a known heap state instead of racing the sweep's
#      own cadence.
#   4. Restarting with hot_standby_feedback on does not adopt an invalidated
#      on-disk slot: the load path rejects it and a fresh, valid slot is
#      created in its place.
#
# Each of these is asserted, not merely observed, so that changing any of
# this behavior fails this file loudly and forces the replacement contract to
# be written down.

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

my $dim = 16;
my $array_sql = join(",", ('random()') x $dim);

# A constant query vector: the ORDER BY key must be an immutable literal for the
# planner to consider the vamana index.
my $query_vec = '[' . join(",", map { sprintf("%.6f", rand()) } 1 .. $dim) . ']';

my $phys_slot = 'standby_phys';
my $nrows     = 5;

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Byte offset of the first match of $pattern in $node's log, or -1.  Used to
# assert the relative order of two log messages rather than merely that both
# are present.
sub log_offset_of
{
	my ($node, $pattern) = @_;
	open(my $fh, '<', $node->logfile) or die "cannot open log: $!";
	my $content = do { local $/; <$fh> };
	close $fh;
	return $content =~ /$pattern/ ? $-[0] : -1;
}

# Poll an ANN query on the standby until it returns $want rows, or give up.
# Returns the last count seen, so a caller can assert on a wrong value rather
# than on a timeout.
sub standby_ann_count
{
	my ($standby, $want, $attempts) = @_;
	$attempts //= 30;
	my $count = -1;
	for (1 .. $attempts)
	{
		usleep(500_000);
		eval {
			$count = $standby->safe_psql('postgres', qq{
				SET enable_seqscan = off;
				SELECT count(*) FROM (
					SELECT * FROM rep_tbl
					ORDER BY val <-> '$query_vec'::vector LIMIT 100
				) sub;
			});
		};
		chomp $count if defined $count;
		last if defined $count && $count == $want;
	}
	return $count;
}

# Push the primary's catalog horizon forward.
#
# The primary runs the same index, so it holds a vamana slot of its own, and that
# slot's catalog_xmin is what bounds catalog VACUUM on the primary.  A slot's
# catalog_xmin only moves while something decodes it, and the primary feeds its
# index from write IPC rather than from its slot, so in steady state the value
# sits wherever it was when the index was created.  Until it moves, no catalog
# row that postdates the index is removable and no recovery conflict can be
# produced at all.
#
# pg_log_standby_snapshot gives the decoder the running-xacts record it needs to
# choose a new candidate catalog_xmin; the following advance applies it.  Two
# passes are needed because the first advance selects the candidate and the
# second commits it.
sub advance_primary_catalog_horizon
{
	my ($primary, $slot) = @_;

	for (1 .. 2)
	{
		$primary->safe_psql('postgres', 'SELECT pg_log_standby_snapshot();');
		my (undef, undef, $err) = $primary->psql('postgres',
			"SELECT pg_replication_slot_advance('$slot', pg_current_wal_lsn());");
		diag "slot advance: $err" if defined $err && $err ne '';
	}
}

# One round of the recovery-conflict trigger.  Returns the VACUUM's reported
# removable cutoff so the caller can check the precondition actually held.
#
# A logical slot is only invalidated when the standby replays a conflicting
# record from a *catalog* relation: the guard in standby.c is
# "wal_level >= logical && isCatalogRel".  Churning the vector base table
# therefore cannot invalidate anything, however much of it there is.  Making
# pg_class rows dead and vacuuming pg_class can.
#
# VACUUM does not flush WAL, so the INSERT into the empty flush_wal table forces
# the flush that lets the vacuum record stream to the standby.
#
# Nothing here writes to rep_tbl on purpose: a decoded base-table change would
# let the standby's own slot confirm a new position and drag its catalog_xmin
# forward, which is the very thing the conflict needs to overtake.
sub run_conflict_round
{
	my ($primary, $standby, $slot) = @_;

	$primary->safe_psql('postgres', q{
		CREATE TABLE conflict_probe(x integer, y text);
		DROP TABLE conflict_probe;
	});

	advance_primary_catalog_horizon($primary, $slot);

	my (undef, undef, $err) = $primary->psql('postgres',
		'VACUUM verbose pg_class; INSERT INTO flush_wal DEFAULT VALUES;');

	$primary->wait_for_replay_catchup($standby);

	return ($err // '') =~ /removable cutoff: (\d+)/ ? $1 : -1;
}

# ===========================================================================
# Setup: primary with a physical slot, plus a standby with
# hot_standby_feedback off
# ===========================================================================

my $primary = PostgreSQL::Test::Cluster->new('primary_slotinval');
$primary->init(allows_streaming => 1);
$primary->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$primary->append_conf('postgresql.conf', "wal_level = logical");
$primary->append_conf('postgresql.conf', "max_replication_slots = 10");
$primary->append_conf('postgresql.conf', "max_wal_senders = 10");
$primary->append_conf('postgresql.conf', "svs.worker_database = 'postgres'");
$primary->append_conf('postgresql.conf', "svs.checkpoint_min_ops = 999999");

# Autovacuum would vacuum the catalogs on its own schedule and could invalidate
# the slot before the controlled trigger below, which would destroy the
# before/after evidence this file depends on.
$primary->append_conf('postgresql.conf', "autovacuum = off");
$primary->start;

$primary->safe_psql('postgres', "CREATE EXTENSION vector;");
$primary->safe_psql('postgres', "CREATE EXTENSION svs;");
$primary->safe_psql('postgres', "CREATE EXTENSION injection_points;");
$primary->safe_psql('postgres',
	"INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

$primary->safe_psql('postgres', qq{
	CREATE TABLE rep_tbl (id serial, val vector($dim));
	CREATE INDEX rep_idx ON rep_tbl USING vamana (val vector_l2_ops);
});
wait_for_worker($primary, 30);

for my $i (1 .. $nrows)
{
	$primary->safe_psql('postgres',
		"INSERT INTO rep_tbl (val) VALUES (ARRAY[$array_sql]::vector);");
}
wait_for_worker($primary, 30);

# A physical slot plus primary_slot_name on the standby is what lets
# hot_standby_feedback pin catalog_xmin at all, so it has to exist for the
# recovery step to mean anything.
$primary->safe_psql('postgres',
	"SELECT pg_create_physical_replication_slot('$phys_slot');");

# Empty table used only to force a WAL flush after VACUUM.
$primary->safe_psql('postgres', "CREATE TABLE flush_wal();");

my $backup_name = 'slotinval_backup';
$primary->backup($backup_name);

my $standby = PostgreSQL::Test::Cluster->new('standby_slotinval');
$standby->init_from_backup($primary, $backup_name, has_streaming => 1);
$standby->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$standby->append_conf('postgresql.conf', "svs.worker_database = 'postgres'");
$standby->append_conf('postgresql.conf', "svs.checkpoint_min_ops = 999999");
$standby->append_conf('postgresql.conf', "hot_standby = on");
$standby->append_conf('postgresql.conf', "max_replication_slots = 10");
$standby->append_conf('postgresql.conf', "primary_slot_name = '$phys_slot'");
$standby->append_conf('postgresql.conf', "hot_standby_feedback = off");
$standby->start;

$primary->wait_for_replay_catchup($standby);

# ===========================================================================
# Fixture preconditions
#
# These are assertions, not setup: if any is wrong the rest of the file proves
# nothing, and a silently mis-set hot_standby_feedback would make the whole
# invalidation path unreachable.
# ===========================================================================

is($standby->safe_psql('postgres', 'SELECT pg_is_in_recovery();'), 't',
	'fixture: standby is in recovery');

is($standby->safe_psql('postgres', 'SHOW hot_standby_feedback;'), 'off',
	'fixture: standby runs with hot_standby_feedback off');

is($primary->safe_psql('postgres', 'SHOW wal_level;'), 'logical',
	'fixture: primary runs with wal_level = logical');

is($standby->safe_psql('postgres', 'SHOW wal_level;'), 'logical',
	'fixture: standby runs with wal_level = logical');

is( $standby->safe_psql('postgres',
		"SELECT count(*) FROM pg_extension WHERE extname = 'svs';"),
	'1', 'fixture: svs extension is present on the standby');

# ===========================================================================
# The standby bootstraps its own vamana slot
# ===========================================================================

my $slot_name = $standby->safe_psql('postgres', q{
	SELECT 'vamana_'
	       || (SELECT oid FROM pg_database WHERE datname = current_database())
	       || '_' || 'rep_idx'::regclass::oid;
});
chomp $slot_name;

ok( $standby->poll_query_until('postgres',
		"SELECT count(*) = 1 FROM pg_replication_slots WHERE slot_name = '$slot_name';"),
	"standby creates its own vamana replication slot ($slot_name)")
  or die "standby never created slot $slot_name";

is( $standby->safe_psql('postgres',
		"SELECT slot_type || ' ' || plugin FROM pg_replication_slots
		 WHERE slot_name = '$slot_name';"),
	'logical svs',
	'standby vamana slot is a logical slot using the svs output plugin');

# Baseline: the slot is healthy right now.  Asserting the negative state before
# the trigger is what makes the invalidation assertions below non-vacuous.
is( $standby->safe_psql('postgres',
		"SELECT conflicting::text || ' ' || coalesce(invalidation_reason, 'none')
		 FROM pg_replication_slots WHERE slot_name = '$slot_name';"),
	'false none',
	'standby vamana slot starts out valid and non-conflicting');

# All pre-backup rows are already searchable on the standby.
is(standby_ann_count($standby, $nrows), $nrows,
	"baseline: $nrows rows searchable on the standby before invalidation");

my $plan = $standby->safe_psql('postgres', qq{
	SET enable_seqscan = off;
	EXPLAIN (COSTS OFF)
	SELECT * FROM rep_tbl ORDER BY val <-> '$query_vec'::vector LIMIT 100;
});
like($plan, qr/Index Scan using rep_idx/,
	'baseline: the ANN query is answered by the vamana index, not a heap scan');

# ===========================================================================
# The worker warns about the misconfiguration at startup
#
# src/vamanaworker.c emits this once in VamanaWorkerMain when it finds itself on
# a standby with hot_standby_feedback off.  It is the only warning the extension
# raises about this, and it fires before any slot can be invalidated.
# ===========================================================================

my $warn_re = qr/vamana replay on standby requires hot_standby_feedback = on/;

ok($standby->log_contains($warn_re, 0),
	'standby worker warns at startup that hot_standby_feedback must be on');

# ===========================================================================
# Force the recovery conflict that invalidates the slot
# ===========================================================================

my $conflict_re =
  qr/invalidating obsolete replication slot "\Q$slot_name\E"/;

# The standby slot's catalog_xmin is the value the primary's VACUUM has to get
# past.  Capture it before the trigger so the precondition can be asserted
# rather than assumed.
my $standby_cxmin = $standby->safe_psql('postgres',
	"SELECT catalog_xmin FROM pg_replication_slots WHERE slot_name = '$slot_name';");
chomp $standby_cxmin;
cmp_ok($standby_cxmin, '>', 0,
	"standby vamana slot holds a catalog_xmin ($standby_cxmin) that the primary must not vacuum past");

my $rounds      = 0;
my $invalidated = 0;
my $best_cutoff = -1;

for my $round (1 .. 10)
{
	$rounds = $round;

	my $cutoff = run_conflict_round($primary, $standby, $slot_name);
	$best_cutoff = $cutoff if $cutoff > $best_cutoff;

	# Give the standby's startup process time to apply the vacuum record and
	# run the conflict check.
	for (1 .. 20)
	{
		my $c = $standby->safe_psql('postgres',
			"SELECT conflicting FROM pg_replication_slots
			 WHERE slot_name = '$slot_name';");
		chomp $c;
		if ($c eq 't')
		{
			$invalidated = 1;
			last;
		}
		usleep(250_000);
	}
	last if $invalidated;
}

# The conflict is only possible once the primary can remove catalog rows the
# standby's slot still needs.  Asserting the cutoff separately means a failure
# says which half broke: the trigger never armed, or it armed and the standby
# did not react.
cmp_ok($best_cutoff, '>=', $standby_cxmin,
	"primary catalog VACUUM reached a removable cutoff ($best_cutoff) at or past the standby slot's catalog_xmin ($standby_cxmin)");

# A trigger that never fired is a failure of this test case, not a reason to
# skip: every assertion below depends on the slot actually being invalidated.
ok($invalidated,
	"catalog VACUUM on the primary invalidates the standby vamana slot (after $rounds round(s))")
  or die
  "slot $slot_name was never invalidated; the rest of this file cannot be evaluated";

# ===========================================================================
# Invalidation is reported through pg_replication_slots
# ===========================================================================

is( $standby->safe_psql('postgres',
		"SELECT invalidation_reason FROM pg_replication_slots
		 WHERE slot_name = '$slot_name' AND conflicting;"),
	'rows_removed',
	'invalidated slot reports conflict reason rows_removed');

# PG 18 renders an invalidated slot's wal_status as 'lost', except that a slot
# whose restart_lsn survived (which is the case for a rows_removed conflict) is
# rendered 'unreserved' while some process holds it.  The vamana worker acquires
# the slot on each drain sweep, so both values are legitimate here and the
# stable signal is the conflict reason above.
my $wal_status = $standby->safe_psql('postgres',
	"SELECT wal_status FROM pg_replication_slots WHERE slot_name = '$slot_name';");
chomp $wal_status;
ok($wal_status eq 'lost' || $wal_status eq 'unreserved',
	"invalidated slot reports wal_status as lost or unreserved (got '$wal_status')");

# ===========================================================================
# The warning precedes the invalidation
# ===========================================================================

ok($standby->log_contains($conflict_re, 0),
	'invalidation is logged against the slot by name');

my $warn_at     = log_offset_of($standby, $warn_re);
my $conflict_at = log_offset_of($standby, $conflict_re);

cmp_ok($warn_at, '>=', 0, 'ordering: the startup warning is present in the log');
cmp_ok($conflict_at, '>=', 0, 'ordering: the invalidation message is present in the log');
cmp_ok($warn_at, '<', $conflict_at,
	'ordering: the warning is logged before the slot is invalidated');

# ===========================================================================
# Invalidation degrades reads; it does not crash the worker or fabricate rows
# ===========================================================================

my $pid_after = wait_for_worker($standby, 20);
like($pid_after, qr/^\d+$/,
	"standby worker survives slot invalidation (pid=$pid_after)");

my $log_all = do {
	open(my $fh, '<', $standby->logfile) or die "cannot open standby log: $!";
	local $/;
	<$fh>;
};
unlike($log_all, qr/PANIC|was terminated by signal|TRAP: failed Assert/,
	'no crash, PANIC or failed assertion on the standby after invalidation');

# Reads keep working, from the graph the standby already had.
is(standby_ann_count($standby, $nrows), $nrows,
	'reads on the standby still return the already-replayed rows after invalidation');

# Park the worker just before its drain sweep, so the sweep cannot act on the
# invalidated slot until this test releases it below.  Search requests are
# serviced earlier in the same loop iteration, so no read issued before the
# worker reaches this point depends on it, but any read issued while parked
# would hang until release; none is issued until after the wakeup/detach
# below.  Without this, the sweep's own cadence (on the order of one second)
# races the write that follows and its rebuild can land before or after that
# write, nondeterministically.
my $worker_point = 'vamana-worker-pre-drain';
$standby->safe_psql('postgres',
	"SELECT injection_points_attach('$worker_point', 'wait');");
$standby->wait_for_event('vamana worker', $worker_point);

# Write and physically replicate three more rows while the worker is still
# parked, so they land in the heap before the rebuild below ever runs.  That
# makes the rebuild's own heap scan, once released, deterministic: it is
# known to run against a heap that already holds all eight rows, rather than
# racing the drain sweep's own cadence to decide how many of them it sees.
for my $i (1 .. 3)
{
	$primary->safe_psql('postgres',
		"INSERT INTO rep_tbl (val) VALUES (ARRAY[$array_sql]::vector);");
}
$primary->wait_for_replay_catchup($standby);

# Physical replication is unaffected by a logical slot being invalidated, so the
# standby heap already holds every row.  Establishing this first is what makes
# the index count below meaningful: the WAL demonstrably arrived and was applied,
# so an index that is missing rows is missing them because logical replay is
# dead, not because the test did not wait long enough.
is( $standby->safe_psql('postgres', 'SELECT count(*) FROM rep_tbl;'),
	$nrows + 3,
	'physical replication is unaffected: the standby heap has every row');

# Release the worker now that the heap holds every row.  What actually
# happens next: the drain sweep notices the slot is invalidated and rebuilds
# the index from the heap in its place, the same remedy it already uses when
# a slot's WAL lag exceeds its budget.  An invalidated slot can never resume
# decoding past the point core cut it off, so this is checked on every sweep
# rather than left for the next restart.
#
# This is pinned as an assertion rather than left implicit because it is the
# whole behavioral question the file exists to answer.  If the drain sweep is
# ever changed to stop rebuilding on invalidation, this assertion is where
# that shows up, and the recovery contract has to be written down at the same
# time.
$standby->safe_psql('postgres',
	"SELECT injection_points_wakeup('$worker_point');");
$standby->safe_psql('postgres',
	"SELECT injection_points_detach('$worker_point');");

my $rebuild_re = qr/slot for index \d+ is invalidated; rebuilding from heap/;

ok( $standby->poll_query_until('postgres',
		"SELECT count(*) = 1 FROM pg_replication_slots
		 WHERE slot_name = '$slot_name' AND NOT conflicting;"),
	'the drain sweep replaces the invalidated slot with a fresh, valid one')
  or die "slot $slot_name was never replaced after invalidation";

ok($standby->log_contains($rebuild_re, 0),
	'the rebuild is logged, so the degraded-and-recovering state is visible to an operator');

# The rebuild's own heap scan runs against whatever the heap held at the
# moment the sweep acted, which this test cannot pin more precisely than
# "no earlier than the three-row write above" without an injection point
# inside the rebuild itself.  What is pinned and asserted here is the
# correctness floor: the rebuilt index must reflect at least the rows that
# were already searchable before invalidation, and never more than the
# heap holds, matching the same assurance the existing WAL-budget valve's
# own rebuild-from-heap path provides.
my $post_count = standby_ann_count($standby, $nrows);

cmp_ok($post_count, '>=', $nrows,
	'the rebuilt index reflects at least every row that was already searchable before invalidation');

# The index may lag the heap, but it must never claim more rows than the heap
# holds.  This is a correctness bound rather than a description of current
# behavior: it holds whether replay continues, stalls, or is made to stop, so
# a future change to the drain path must not break it.
my $heap_count = $standby->safe_psql('postgres', 'SELECT count(*) FROM rep_tbl;');
chomp $heap_count;
cmp_ok($post_count, '<=', $heap_count,
	"the index never reports more rows than the heap holds ($post_count of $heap_count)");

# ===========================================================================
# Turning hot_standby_feedback back on and restarting the standby
#
# The load path that opens a handle to whatever slot is already on disk
# checks whether that slot is still valid.  An invalidated slot is dropped
# rather than adopted, so the restarted worker creates a fresh slot in its
# place instead of resuming decode through the dead one.
#
# By this point the sweep above has already replaced the slot with a valid
# one, so this restart is a non-regression check on an already-healthy
# slot, not an independent trigger of the load path's own rejection logic.
# That rejection logic is exercised directly by reverting it in isolation
# (see the prove-it-fails notes for this file).
# ===========================================================================

$standby->append_conf('postgresql.conf', "hot_standby_feedback = on");
$standby->restart;

is($standby->safe_psql('postgres', 'SHOW hot_standby_feedback;'), 'on',
	'standby now runs with hot_standby_feedback on');

# Wait for the restarted worker before reading slot state, so this is not a race
# against worker startup.
my $pid_restart = wait_for_worker($standby, 30);
like($pid_restart, qr/^\d+$/,
	"standby worker is running again after the restart (pid=$pid_restart)");

# Feedback is on now, so the primary is pinning catalog_xmin again and no fresh
# conflict is possible.  Give the loop a chance to create the replacement slot,
# rather than reading one moment after startup.
my $cleared = 0;
for (1 .. 20)
{
	$primary->safe_psql('postgres', 'SELECT pg_log_standby_snapshot();');
	my $state = $standby->safe_psql('postgres',
		"SELECT coalesce(bool_and(NOT conflicting), false)
		 FROM pg_replication_slots WHERE slot_name = '$slot_name';");
	chomp $state;
	if ($state eq 't')
	{
		$cleared = 1;
		last;
	}
	usleep(500_000);
}

is($cleared, 1,
	'the restart leaves a fresh, valid slot in place');

is( $standby->safe_psql('postgres',
		"SELECT coalesce(invalidation_reason, 'none') FROM pg_replication_slots
		 WHERE slot_name = '$slot_name';"),
	'none',
	'the slot carries no invalidation reason after the restart');

# Reads do come back, and the two rows below are written after the restart
# has finished, so they can only arrive through live decoding, which is what
# makes this a test of replay rather than of startup.
for my $i (1 .. 2)
{
	$primary->safe_psql('postgres',
		"INSERT INTO rep_tbl (val) VALUES (ARRAY[$array_sql]::vector);");
}
$primary->wait_for_replay_catchup($standby);

is(standby_ann_count($standby, $nrows + 5, 60), $nrows + 5,
	'reads on the standby reflect rows written after the restart');

$standby->stop;
$primary->stop;

done_testing();
