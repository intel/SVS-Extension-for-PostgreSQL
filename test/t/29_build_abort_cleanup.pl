# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 29_build_abort_cleanup.pl — PG_ENSURE_ERROR_CLEANUP unwind on a governed
# build failure, at both ends of the guarded span, now that the span
# actually holds accounting: reserve, confirm, and hand-off.
#
# VamanaBuildSVSIndexGoverned's callers (vamanabuild, VamanaRebuildFromTable)
# wrap the call through their own worker hand-off point in
# PG_ENSURE_ERROR_CLEANUP, whose abort-cleanup callback (SvsMemoryAbortBuild)
# runs on that unwind. Three injection points sit inside that span:
#
#   - vamana-build-governed-pre-allocation, inside
#     VamanaBuildSVSIndexGoverned, after the SVS algorithm/storage/builder
#     triple is created and before the flatten allocation -- the start of
#     the span, before the admission gate has reserved anything at all.
#   - vamana-build-governed-pre-confirm, in each caller, immediately before
#     SvsMemoryConfirmBuild -- after SVSBuildDynamicIndex has already
#     succeeded, but before the reservation's estimate is reconciled to a
#     measured size.
#   - vamana-build-governed-pre-handoff, in each caller, immediately before
#     the worker hand-off call (VamanaWorkerSubmitLoad in vamanabuild,
#     VamanaCacheIndex in VamanaRebuildFromTable) -- after confirm and
#     hand-off have both already run.
#
# Both callers share all three injection points, so attaching 'error' to any
# of them forces the same PG_CATCH -> cleanup -> PG_RE_THROW unwind. This
# file exercises CREATE INDEX's span (vamanabuild); VamanaRebuildFromTable
# shares the same injection points and the same callback, so nothing
# distinguishes its unwind from these.
#
# What pre_allocation actually proves: it fires before the gate has reserved
# anything, so SvsMemoryAbortBuild finds no reservation for this relid and
# is a safe no-op. What pre_confirm and pre_handoff prove is different: by
# the time either fires, this build's estimate is already committed (and,
# for pre_handoff, already reconciled to a measured size and hand off to
# HANDOFF); the injected error still rolls the whole CREATE INDEX
# transaction back (nothing was ever durably serialized), so
# SvsMemoryAbortBuild must release real committed bytes, not merely find
# nothing to do. Comparing committed totals before and after each case is
# what actually tells them apart.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

if (($ENV{enable_injection_points} // 'no') ne 'yes')
{
	plan skip_all => 'server not built with --enable-injection-points';
}

my $node = PostgreSQL::Test::Cluster->new('build_abort_cleanup');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->append_conf('postgresql.conf', "svs.max_residency_memory = '16000MB'");
$node->append_conf('postgresql.conf', "svs.default_residency_memory = '16000MB'");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres', "CREATE EXTENSION injection_points;");
$node->safe_psql('postgres',
	"INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

my $worker_pid = wait_for_worker($node);
ok($worker_pid =~ /^\d+$/, 'worker is running before the build-abort tests');

# committed_totals: this database's own (build_bytes_committed,
# residency_bytes_committed) from the real, running worker's accounting.
# Both must return to the same value across any build attempt, whether it
# succeeds, fails before confirm, or fails after hand-off -- that round trip
# is the whole point of the reservation lifecycle this file exercises.
sub committed_totals
{
	my $row = $node->safe_psql('postgres', qq(
		SELECT build_bytes_committed, residency_bytes_committed
		FROM pg_stat_vamana_worker
		WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');
	));
	chomp $row;
	return split(/\|/, $row);
}

# ---------------------------------------------------------------------------
# poll_until_committed_totals_baseline: poll committed_totals() and the
# durable residency row count for $relid, up to $bound_seconds, until both
# match $before's totals and the row count reaches zero. Returns the final
# observed (\@totals, $residency_rows) rather than asserting anything itself;
# assertions stay in the caller, matching this file's other polling helpers.
#
# The poll itself runs server-side, inside a single psql script (one DO
# block, one connection), rather than as a Perl-level loop of separate
# safe_psql round trips: a fresh connection per poll attempt is needless
# round-trip overhead once the abort has already happened, and this file's
# other in-transaction checks already establish that a single script is the
# reliable shape for talking to this worker.
# ---------------------------------------------------------------------------
sub poll_until_committed_totals_baseline
{
	my ($before, $relid, $bound_seconds) = @_;
	my $attempts = int($bound_seconds / 0.2);
	my ($before_build, $before_resid) = @$before;

	my $row = $node->safe_psql('postgres', qq(
		DO \$poll\$
		DECLARE
			v_build bigint;
			v_resid bigint;
			v_rows  bigint;
		BEGIN
			FOR i IN 1..$attempts LOOP
				SELECT build_bytes_committed, residency_bytes_committed
				INTO v_build, v_resid
				FROM pg_stat_vamana_worker
				WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');
				SELECT count(*) INTO v_rows
				FROM svs_index_residency WHERE index_relid = $relid;
				EXIT WHEN v_build = $before_build AND v_resid = $before_resid AND v_rows = 0;
				PERFORM pg_sleep(0.2);
			END LOOP;
			CREATE TEMP TABLE poll_result (build_v bigint, resid_v bigint, rows_v bigint);
			INSERT INTO poll_result VALUES (v_build, v_resid, v_rows);
		END
		\$poll\$;
		SELECT build_v, resid_v, rows_v FROM poll_result;
	));
	chomp $row;
	my ($build_v, $resid_v, $rows_v) = split(/\|/, $row);
	return ([$build_v, $resid_v], $rows_v);
}

# ---------------------------------------------------------------------------
# check_abort_at: attach 'error' to $injection_point, run CREATE INDEX on a
# fresh table, confirm it fails with exactly that injected error and the
# worker survives, detach, then confirm a retry succeeds cleanly with no
# residue from the aborted build -- neither in pg_indexes nor in the
# accounting counters this build touched.
# ---------------------------------------------------------------------------
sub check_abort_at
{
	my ($injection_point, $label) = @_;
	my $tbl = "${label}_tbl";
	my $idx = "${label}_idx";

	$node->safe_psql('postgres', qq(
		CREATE TABLE $tbl (id serial PRIMARY KEY, c1 vector($dim));
		INSERT INTO $tbl (c1)
			SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 200) i;
	));

	my @before = committed_totals();

	$node->safe_psql('postgres',
		"SELECT injection_points_attach('$injection_point', 'error');");

	my ($ret, $stdout, $stderr) = $node->psql('postgres',
		"CREATE INDEX $idx ON $tbl USING vamana (c1 vector_l2_ops);");
	isnt($ret, 0, "$label: CREATE INDEX fails when $injection_point is injected to error");
	like($stderr, qr/error triggered for injection point \Q$injection_point\E/,
		"$label: the injected error is what CREATE INDEX reports")
	  or diag("stderr: $stderr");

	my @after = committed_totals();
	is_deeply(\@after, \@before,
		"$label: the injected failure leaves this database's build and residency "
	  . "committed bytes exactly where they started");

	my $live_pid = $node->safe_psql('postgres',
		"SELECT pid FROM pg_stat_activity WHERE backend_type = 'vamana worker';");
	chomp $live_pid;
	is($live_pid, $worker_pid,
		"$label: worker survives the injected build failure without restarting");

	$node->safe_psql('postgres',
		"SELECT injection_points_detach('$injection_point');");

	my ($ret2, $stdout2, $stderr2) = $node->psql('postgres',
		"CREATE INDEX $idx ON $tbl USING vamana (c1 vector_l2_ops);");
	is($ret2, 0, "$label: CREATE INDEX succeeds once the injected failure is removed")
	  or diag("stderr: $stderr2");

	my $index_count = $node->safe_psql('postgres',
		"SELECT count(*) FROM pg_indexes WHERE indexname = '$idx';");
	chomp $index_count;
	is($index_count, '1',
		"$label: exactly one $idx exists; the aborted build left nothing behind for the retry to collide with");
}

check_abort_at('vamana-build-governed-pre-allocation', 'pre_allocation');
check_abort_at('vamana-build-governed-pre-confirm', 'pre_confirm');
check_abort_at('vamana-build-governed-pre-handoff', 'pre_handoff');

# ---------------------------------------------------------------------------
# check_rollback_after_warmup: unlike check_abort_at, no injection point is
# involved here -- the build itself succeeds and reaches RESIDENT inside an
# open transaction, and only then does $abort_sql abort it (an explicit
# ROLLBACK, or a statement error followed by the ROLLBACK a client must still
# send to close the aborted block). The whole transaction, including the
# in-transaction check that residency_bytes_committed already grew, is sent
# as a single psql script in one round trip: driving the same open
# transaction interactively over several background_psql query() calls hangs
# indefinitely on this server.
# ---------------------------------------------------------------------------
sub check_rollback_after_warmup
{
	my ($label, $abort_sql) = @_;
	my $tbl = "${label}_tbl";
	my $idx = "${label}_idx";

	$node->safe_psql('postgres', qq(
		CREATE TABLE $tbl (id serial PRIMARY KEY, c1 vector($dim));
		INSERT INTO $tbl (c1)
			SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 2000) i;
	));

	my @before = committed_totals();

	# The follow-up SELECT reading residency_bytes_committed's growth must run
	# immediately after CREATE INDEX, in the same script and the same still-
	# open transaction: the worker's own reload sweep evicts this relid's
	# residency unconditionally before it can re-load it (see
	# VamanaWorkerProcessReloads), and re-loading fails for as long as this
	# transaction still holds the index's lock -- so any extra round trip or
	# in-transaction delay between CREATE INDEX and this SELECT risks
	# observing that eviction instead of the warm-up's own growth.
	my ($ret, $stdout, $stderr) = $node->psql('postgres', qq(
		BEGIN;
		CREATE INDEX $idx ON $tbl USING vamana (c1 vector_l2_ops);
		SELECT '$idx'::regclass::oid AS relid_v \\gset
		SELECT build_bytes_committed AS build_v, residency_bytes_committed AS resid_v
		FROM pg_stat_vamana_worker
		WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');
		\\gset
		\\echo PARSED_RELID=:relid_v
		\\echo PARSED_BUILD=:build_v
		\\echo PARSED_RESID=:resid_v
		$abort_sql
		ROLLBACK;
	));

	my ($relid) = $stdout =~ /PARSED_RELID=(\d+)/;
	my ($warmed_resid) = $stdout =~ /PARSED_RESID=(\d+)/;
	ok(defined $relid && defined $warmed_resid,
		"$label: the built index's relid and warm-up residency bytes were captured before the abort")
	  or diag("stdout: $stdout\nstderr: $stderr");
	cmp_ok($warmed_resid, '>', $before[1],
		"$label: residency_bytes_committed already grew before the abort, proving the warm-up reached RESIDENT");

	my ($after, $residency_rows) =
	  poll_until_committed_totals_baseline(\@before, $relid, 10);

	is_deeply($after, \@before,
		"$label: build and residency committed bytes return to baseline after the abort, residency_rows=$residency_rows");
	is($residency_rows, '0',
		"$label: no durable residency row remains for the aborted build");

	my $live_pid = $node->safe_psql('postgres',
		"SELECT pid FROM pg_stat_activity WHERE backend_type = 'vamana worker';");
	chomp $live_pid;
	is($live_pid, $worker_pid,
		"$label: worker survives the abort without restarting");
}

check_rollback_after_warmup('rollback_after_warmup', '');
check_rollback_after_warmup('error_after_warmup', 'SELECT 1/0;');

# ---------------------------------------------------------------------------
# Confirm rejection: a rebuild (REINDEX of an already-RESIDENT index) whose
# measured size genuinely grows past what its reservation can still fit,
# because something else claims the rest of the budget in between. This
# window exists only for a rebuild: ReserveBuild folds a rebuild's own prior
# measured bytes out of the fits check instead of pre-committing its new
# estimate (see the comment on that branch in svs_memory.c), so nothing
# pins down the room its eventual confirm will actually need. A fresh
# build's estimate is pre-committed immediately at reserve time and always
# upper-bounds its own eventual measured size, so the same construction
# cannot be made to fail confirm for a fresh build -- confirmed by working
# through the arithmetic, not by trying every combination by hand.
#
# The "something else" here is a second, real, ordinary CREATE INDEX,
# built to completion while the rebuild is parked at pre-confirm: after it
# settles, this database's residency budget is lowered to just above what
# is now committed (legal for a rebuild's own reservation, whose prior
# measured bytes are the only floor that matters while it is pending), and
# only then is the parked rebuild woken -- so there is no race between the
# rebuild's own confirm and the second build's, unlike attaching 'wait' to
# both and hoping the parked one resumes first.
# ---------------------------------------------------------------------------
{
	my $confirm_tbl = 'confirm_reject_tbl';
	my $confirm_idx = 'confirm_reject_idx';
	my $helper_tbl = 'confirm_reject_helper_tbl';
	my $helper_idx = 'confirm_reject_helper_idx';
	my $point = 'vamana-build-governed-pre-confirm';

	$node->safe_psql('postgres',
		"UPDATE vamana_databases SET residency_memory = 200 WHERE datname = 'postgres';");

	$node->safe_psql('postgres', qq(
		CREATE TABLE $confirm_tbl (id serial PRIMARY KEY, c1 vector($dim));
		INSERT INTO $confirm_tbl (c1)
			SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 5000) i;
		CREATE INDEX $confirm_idx ON $confirm_tbl USING vamana (c1 vector_l2_ops)
			WITH (graph_degree = 16);
	));

	my $confirm_relid = $node->safe_psql('postgres', "SELECT '$confirm_idx'::regclass::oid;");
	chomp $confirm_relid;

	my $prior_resident_bytes = $node->safe_psql('postgres',
		"SELECT resident_bytes FROM svs_index_residency WHERE index_relid = $confirm_relid;");
	chomp $prior_resident_bytes;
	cmp_ok($prior_resident_bytes, '>', 0,
		'confirm_reject: the original degree=16 build reports a plausible resident size');

	# A larger graph_degree does not itself trigger a rebuild; REINDEX below
	# does, and rebuilds under the new option -- a materially denser graph
	# over the same 5000 rows, so its measured size is not a coin flip
	# against the original's.
	$node->safe_psql('postgres', "ALTER INDEX $confirm_idx SET (graph_degree = 256);");

	$node->safe_psql('postgres', "SELECT injection_points_attach('$point', 'wait');");

	my $rebuild = $node->background_psql('postgres', on_error_stop => 0);
	$rebuild->query_until(qr/reindex_started/, qq(
		\\echo reindex_started
		REINDEX INDEX $confirm_idx;
	));
	$node->wait_for_event('client backend', $point);

	# Detaching does not disturb the rebuild session already asleep inside
	# injection_wait(): only injection_points_wakeup() does that. It does
	# mean the helper build below passes straight through this same
	# injection point rather than parking behind the rebuild, so there is
	# exactly one waiter left to wake.
	$node->safe_psql('postgres', "SELECT injection_points_detach('$point');");

	$node->safe_psql('postgres', qq(
		CREATE TABLE $helper_tbl (id serial PRIMARY KEY, c1 vector(1536));
		INSERT INTO $helper_tbl (c1)
			SELECT ARRAY(SELECT random() FROM generate_series(1, 1536))::vector
			FROM generate_series(1, 500) i;
		CREATE INDEX $helper_idx ON $helper_tbl USING vamana (c1 vector_l2_ops);
	));

	my ($budget, $committed) = split(/\|/, $node->safe_psql('postgres', qq(
		SELECT residency_memory_limit, residency_bytes_committed
		FROM pg_stat_vamana_worker
		WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');
	)));
	cmp_ok($committed, '<', $budget,
		'confirm_reject: the helper build left this database under its residency budget');

	# The tightest budget a rebuild's own reservation permits is whatever is
	# already committed (its own prior measured bytes plus the helper's,
	# neither foldable out for this relid); one extra megabyte of slack is
	# comfortably below the megabytes-scale gap a degree=16 -> degree=256
	# rebuild of 5000 rows should produce, and comfortably above whatever
	# sub-megabyte rounding the residency_memory column's whole-MB unit
	# forces.
	my $tight_budget_mb = int(($committed + 1024 * 1024 - 1) / (1024 * 1024)) + 1;
	$node->safe_psql('postgres',
		"UPDATE vamana_databases SET residency_memory = $tight_budget_mb WHERE datname = 'postgres';");

	$node->safe_psql('postgres', "SELECT injection_points_wakeup('$point');");

	# The parked REINDEX is still mid-statement in this session; psql will
	# not read the "SELECT 1" below until it finishes, so the REINDEX's own
	# error text is still sitting in this session's stderr buffer by the
	# time query() returns, ahead of "SELECT 1"'s own output.
	my ($stdout, $ret) = $rebuild->query('SELECT 1');
	my $reindex_stderr = $rebuild->{stderr};
	like($stdout, qr/1/, 'confirm_reject: the rebuilding session stays usable after REINDEX fails')
	  or diag("stdout: $stdout");
	like($reindex_stderr, qr/cannot be confirmed.*residency budget/,
		'confirm_reject: REINDEX fails with the confirm-rejection error, naming the residency budget')
	  or diag("stderr: $reindex_stderr");
	like($reindex_stderr, qr/Measured \d+ bytes/,
		'confirm_reject: the error reports the exact measured bytes that did not fit')
	  or diag("stderr: $reindex_stderr");
	$rebuild->quit;

	my $index_count = $node->safe_psql('postgres',
		"SELECT count(*) FROM pg_indexes WHERE indexname = '$confirm_idx';");
	chomp $index_count;
	is($index_count, '1',
		'confirm_reject: the original index still exists; a failed REINDEX does not drop it');

	my $post_resident_bytes = $node->safe_psql('postgres',
		"SELECT resident_bytes FROM svs_index_residency WHERE index_relid = $confirm_relid;");
	chomp $post_resident_bytes;
	is($post_resident_bytes, $prior_resident_bytes,
		'confirm_reject: the durable residency record still shows the pre-rebuild '
	  . 'measured size; a failed confirm never re-records it');

	$node->safe_psql('postgres',
		"UPDATE vamana_databases SET residency_memory = NULL WHERE datname = 'postgres';");

	# Confirms the index is still genuinely queryable, not merely present in
	# pg_indexes as a catalog artifact of a half-finished rebuild.
	my $query_count = $node->safe_psql('postgres', qq(
		SET enable_seqscan = off;
		SELECT count(*) FROM (
			SELECT id FROM $confirm_tbl ORDER BY c1 <-> '[$query_sql]' LIMIT 5
		) sub;
	));
	chomp $query_count;
	is($query_count, '5',
		'confirm_reject: the original index still serves queries after the failed rebuild');
}

$node->stop;

done_testing();
