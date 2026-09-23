# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 32_build_memory_gate.pl — the build-memory admission gate refuses a build
# whose estimated peak exceeds svs.max_build_memory, before any large
# allocation, with an error naming the GUC.  Also exercises the
# unmeasured-dimension upper-envelope rule: the test table's vector width
# (VamanaTestUtils' $dim, 16) is not one of the three calibrated dimensions,
# so the refusal below is charged by that fallback, not by an exact-match
# table lookup.
#
# The remaining cases in this file exercise the gate's accounting rather
# than its refusal: that build_bytes_committed is visible for the duration
# of a pending build and returns to its prior value once confirm releases
# it, that residency_bytes_committed never dips across the confirm/hand-off
# boundary, that a residency budget admits exactly one of two competing
# builds rather than both, and that svs.max_build_memory is a single
# cluster-wide ceiling whose refusal never names the database or bytes of
# whichever other build is holding it down.

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

my $node = PostgreSQL::Test::Cluster->new('build_memory_gate');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'vector,svs'");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 20");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "svs.max_build_memory = '1MB'");
$node->append_conf('postgresql.conf', "svs.max_residency_memory = '100000MB'");
$node->append_conf('postgresql.conf', "svs.default_residency_memory = '16000MB'");
$node->append_conf('postgresql.conf', "svs.max_search_work_mem = '800MB'");
$node->append_conf('postgresql.conf', "log_min_messages = 'debug1'");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres', "CREATE EXTENSION injection_points;");
$node->safe_psql('postgres',
	"INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");
wait_for_worker($node);

$node->safe_psql('postgres', qq(
	CREATE TABLE gate_tbl (id serial PRIMARY KEY, c1 vector($dim));
	INSERT INTO gate_tbl (c1)
		SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 100) i;
));

my ($ret, $stdout, $stderr) = $node->psql('postgres',
	"CREATE INDEX gate_idx ON gate_tbl USING vamana (c1 vector_l2_ops);");
isnt($ret, 0, 'CREATE INDEX fails when the estimate exceeds svs.max_build_memory');
like($stderr, qr/svs\.max_build_memory/,
	'the refusal names svs.max_build_memory')
  or diag("stderr: $stderr");

my $index_count = $node->safe_psql('postgres',
	"SELECT count(*) FROM pg_indexes WHERE indexname = 'gate_idx';");
chomp $index_count;
is($index_count, '0',
	'the refused build left no index behind, consistent with failing before the flatten/build ever ran');

# Raising the ceiling high enough for this small, unmeasured-dimension build
# to fit proves the previous failure was the gate, not something else in the
# build path.
$node->safe_psql('postgres', "ALTER SYSTEM SET svs.max_build_memory = '4096MB';");
$node->reload;

($ret, $stdout, $stderr) = $node->psql('postgres',
	"CREATE INDEX gate_idx ON gate_tbl USING vamana (c1 vector_l2_ops);");
is($ret, 0, 'the same build succeeds once svs.max_build_memory is raised')
  or diag("stderr: $stderr");

# committed_totals: a database's own (build_bytes_committed,
# residency_bytes_committed) from the real, running worker's accounting.
sub committed_totals
{
	my ($db) = @_;
	my $row = $node->safe_psql('postgres', qq(
		SELECT build_bytes_committed, residency_bytes_committed
		FROM pg_stat_vamana_worker
		WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = '$db');
	));
	chomp $row;
	return split(/\|/, $row);
}

# park_build: attach 'wait' to $point, start a background CREATE INDEX of
# $idx on $tbl in $db, and return once it is parked there.  The caller is
# responsible for detaching and waking $point.
sub park_build
{
	my ($db, $tbl, $idx, $point) = @_;

	$node->safe_psql('postgres', "SELECT injection_points_attach('$point', 'wait');");

	my $build = $node->background_psql($db, on_error_stop => 0);
	$build->query_until(qr/build_started/, qq(
		\\echo build_started
		CREATE INDEX $idx ON $tbl USING vamana (c1 vector_l2_ops);
	));
	$node->wait_for_event('client backend', $point);

	return $build;
}

# release_point: detach $point (so it does not catch a later arrival) and
# wake whoever is currently parked there.  Does not touch $build itself:
# the session may still be about to park at a second injection point
# further down the same statement, and querying it here would block until
# that statement finishes.
sub release_point
{
	my ($point) = @_;

	$node->safe_psql('postgres', "SELECT injection_points_detach('$point');");
	$node->safe_psql('postgres', "SELECT injection_points_wakeup('$point');");
}

# finish_build: for a session with no further injection point ahead of it,
# confirm it is still usable once its statement completes, then quit it.
sub finish_build
{
	my ($build, $label) = @_;

	my ($stdout) = $build->query('SELECT 1');
	like($stdout, qr/1/, "$label: the parked session stays usable after the build completes")
	  or diag("stdout: $stdout");
	$build->quit;
}

# wake_build: release_point followed immediately by finish_build, for a
# case with only one injection point in play.
sub wake_build
{
	my ($build, $point, $label) = @_;

	release_point($point);
	finish_build($build, $label);
}

# ---------------------------------------------------------------------------
# build_bytes_committed is visible while a build is pending confirm, and it
# is exactly that build's own peak: the DEBUG1 estimate line reports
# buildPeak before ReserveBuild ever commits it, so comparing the two
# confirms the parked figure is not some other value that happens to be
# nonzero.  It returns to its prior value once confirm releases the peak.
# ---------------------------------------------------------------------------
{
	my $tbl = 'committed_visible_tbl';
	my $idx = 'committed_visible_idx';
	my $point = 'vamana-build-governed-pre-confirm';

	$node->safe_psql('postgres', qq(
		CREATE TABLE $tbl (id serial PRIMARY KEY, c1 vector($dim));
		INSERT INTO $tbl (c1)
			SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 200) i;
	));

	my ($prior_build, $prior_residency) = committed_totals('postgres');

	my $log_offset = -s $node->logfile;
	my $build = park_build('postgres', $tbl, $idx, $point);

	$node->wait_for_log(qr/buildPeak \(margined\)/, $log_offset);
	my $log_tail = PostgreSQL::Test::Utils::slurp_file($node->logfile, $log_offset);
	my ($build_peak_from_log) = $log_tail =~ /buildPeak \(margined\) (\d+) bytes/;
	ok(defined $build_peak_from_log && $build_peak_from_log > 0,
		'committed_visible: the DEBUG1 estimate line reports a positive buildPeak');

	my ($parked_build, undef) = committed_totals('postgres');
	is($parked_build, $build_peak_from_log,
		'committed_visible: build_bytes_committed while parked at pre-confirm equals the DEBUG1 buildPeak estimate');

	wake_build($build, $point, 'committed_visible');

	my ($after_build, undef) = committed_totals('postgres');
	is($after_build, $prior_build,
		'committed_visible: build_bytes_committed returns to its prior value once confirm releases the build peak');
}

# ---------------------------------------------------------------------------
# residency_bytes_committed never dips across the confirm/hand-off boundary:
# sampled at pre-confirm (holding the estimate), at pre-handoff (holding the
# measured size), and once the worker has actually loaded the index, all
# three are the identical figure, equal to the prior total plus the index's
# resident_bytes.
# ---------------------------------------------------------------------------
{
	my $tbl = 'residency_no_dip_tbl';
	my $idx = 'residency_no_dip_idx';
	my $confirm_point = 'vamana-build-governed-pre-confirm';
	my $handoff_point = 'vamana-build-governed-pre-handoff';

	$node->safe_psql('postgres', qq(
		CREATE TABLE $tbl (id serial PRIMARY KEY, c1 vector($dim));
		INSERT INTO $tbl (c1)
			SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 200) i;
	));

	my (undef, $prior_residency) = committed_totals('postgres');

	my $build = park_build('postgres', $tbl, $idx, $confirm_point);
	my (undef, $at_confirm) = committed_totals('postgres');

	# Arm pre-handoff before releasing pre-confirm, so the build parks there
	# on its very next step instead of racing straight through.  release_point,
	# not wake_build: this same session still has pre-handoff ahead of it in
	# the same statement, and querying it now would block until that
	# statement finishes.
	$node->safe_psql('postgres', "SELECT injection_points_attach('$handoff_point', 'wait');");
	release_point($confirm_point);

	$node->wait_for_event('client backend', $handoff_point);
	my (undef, $at_handoff) = committed_totals('postgres');

	release_point($handoff_point);

	# The CREATE INDEX statement itself, and the worker's later residency
	# reconcile, are two different commits; a plain psql (not safe_psql) is
	# needed here because the very first few attempts, before that first
	# commit lands, find no such relation at all.
	my $relid;
	for my $i (1 .. 60)
	{
		my (undef, $regclass_out, undef) = $node->psql('postgres', "SELECT '$idx'::regclass::oid;");
		chomp $regclass_out;
		if ($regclass_out =~ /^\d+$/)
		{
			my $has_row = $node->safe_psql('postgres',
				"SELECT count(*) FROM svs_index_residency WHERE index_relid = $regclass_out;");
			chomp $has_row;
			if ($has_row eq '1')
			{
				$relid = $regclass_out;
				last;
			}
		}
		usleep(500_000);
	}
	die "Timed out waiting for $idx to become resident" unless defined $relid;
	finish_build($build, 'residency_no_dip');

	my $resident_bytes = $node->safe_psql('postgres',
		"SELECT resident_bytes FROM svs_index_residency WHERE index_relid = $relid;");
	chomp $resident_bytes;
	cmp_ok($resident_bytes, '>', 0,
		'residency_no_dip: the loaded index reports a positive resident size');

	my (undef, $at_resident) = committed_totals('postgres');

	is($at_confirm, $at_handoff,
		'residency_no_dip: residency_bytes_committed at pre-confirm equals its value at pre-handoff');
	is($at_handoff, $at_resident,
		'residency_no_dip: residency_bytes_committed at pre-handoff equals its value once resident');
	is($at_resident, $prior_residency + $resident_bytes,
		'residency_no_dip: the final committed total is exactly the prior total plus this index\'s resident_bytes');
}

# ---------------------------------------------------------------------------
# A residency budget admits exactly one of two competing builds, not both.
# The budget is sized from a trial build's own measured resident_bytes,
# not a guess: build A is the same shape as the trial, so its own estimate
# and measured size land in the same range, and B (same shape again) is
# refused once A's estimate is already committed.
# ---------------------------------------------------------------------------
{
	$node->safe_psql('postgres', "CREATE DATABASE gate_concurrent;");
	$node->safe_psql('gate_concurrent', "CREATE EXTENSION vector;");
	$node->safe_psql('gate_concurrent', "CREATE EXTENSION svs;");
	$node->safe_psql('postgres',
		"INSERT INTO vamana_databases (datname, enabled) VALUES ('gate_concurrent', true);");
	wait_for_worker_db($node, 'gate_concurrent');

	my $confirm_point = 'vamana-build-governed-pre-confirm';

	$node->safe_psql('gate_concurrent', qq(
		CREATE TABLE trial_tbl (id serial PRIMARY KEY, c1 vector($dim));
		INSERT INTO trial_tbl (c1)
			SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 5000) i;
		CREATE INDEX trial_idx ON trial_tbl USING vamana (c1 vector_l2_ops);
	));
	my $trial_relid = $node->safe_psql('gate_concurrent', "SELECT 'trial_idx'::regclass::oid;");
	chomp $trial_relid;
	my $trial_bytes = $node->safe_psql('gate_concurrent',
		"SELECT resident_bytes FROM svs_index_residency WHERE index_relid = $trial_relid;");
	chomp $trial_bytes;
	cmp_ok($trial_bytes, '>', 0,
		'concurrent_admit: the trial build reports a plausible resident size');
	$node->safe_psql('gate_concurrent', "DROP INDEX trial_idx;");

	# The worker's cache eviction, not the DROP itself, is what calls
	# SvsMemoryAccountUnload, so poll until that has actually happened:
	# SvsMemoryAdmitDatabase refuses to lower the budget below whatever is
	# still committed, and the trial's bytes must be gone before that.
	for my $i (1 .. 60)
	{
		my ($committed, undef) = committed_totals('gate_concurrent');
		last if $committed eq '0';
		usleep(500_000);
	}
	my ($post_drop_committed, undef) = committed_totals('gate_concurrent');
	is($post_drop_committed, '0',
		'concurrent_admit: the dropped trial build\'s bytes are released before the tight budget is set');

	# Room for one build's estimate (which upper-bounds its own measured
	# size) comfortably, never two: 1.4x the trial's measured bytes.
	my $tight_budget_mb = int((1.4 * $trial_bytes + 1024 * 1024 - 1) / (1024 * 1024));
	$tight_budget_mb = 1 if $tight_budget_mb < 1;
	$node->safe_psql('postgres',
		"UPDATE vamana_databases SET residency_memory = $tight_budget_mb WHERE datname = 'gate_concurrent';");

	$node->safe_psql('gate_concurrent', qq(
		CREATE TABLE conc_a_tbl (id serial PRIMARY KEY, c1 vector($dim));
		INSERT INTO conc_a_tbl (c1)
			SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 5000) i;
		CREATE TABLE conc_b_tbl (id serial PRIMARY KEY, c1 vector($dim));
		INSERT INTO conc_b_tbl (c1)
			SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 5000) i;
	));

	my $build_a = park_build('gate_concurrent', 'conc_a_tbl', 'conc_a_idx', $confirm_point);

	my ($ret_b, $stdout_b, $stderr_b) = $node->psql('gate_concurrent',
		"CREATE INDEX conc_b_idx ON conc_b_tbl USING vamana (c1 vector_l2_ops);");
	isnt($ret_b, 0,
		'concurrent_admit: B is refused once A\'s estimate already fills the tight budget');
	like($stderr_b, qr/residency budget/,
		'concurrent_admit: B\'s refusal names the residency budget')
	  or diag("stderr: $stderr_b");
	my $b_count = $node->safe_psql('gate_concurrent',
		"SELECT count(*) FROM pg_indexes WHERE indexname = 'conc_b_idx';");
	chomp $b_count;
	is($b_count, '0', 'concurrent_admit: the refused B build left no index behind');

	wake_build($build_a, $confirm_point, 'concurrent_admit');

	my $a_count = $node->safe_psql('gate_concurrent',
		"SELECT count(*) FROM pg_indexes WHERE indexname = 'conc_a_idx';");
	chomp $a_count;
	is($a_count, '1', 'concurrent_admit: A, admitted first, completes normally');

	$node->safe_psql('postgres',
		"UPDATE vamana_databases SET residency_memory = NULL WHERE datname = 'gate_concurrent';");
}

# ---------------------------------------------------------------------------
# svs.max_build_memory is one cluster-wide ceiling, not a per-database one:
# a build in database Y can be refused by a build in database X that is
# still holding its own peak, and Y's refusal must name the GUC without
# leaking X's identity or committed bytes -- an unprivileged user in Y has
# no business right to either.  SvsMemoryReserveBuild's own message prints
# only the failing relid (Y's own), the bytes Y itself requested, and the
# ceiling -- confirmed by reading it, and by this test's negative
# assertions below.
# ---------------------------------------------------------------------------
{
	$node->safe_psql('postgres', "CREATE DATABASE gate_ceiling_x;");
	$node->safe_psql('postgres', "CREATE DATABASE gate_ceiling_y;");
	for my $db (qw(gate_ceiling_x gate_ceiling_y))
	{
		$node->safe_psql($db, "CREATE EXTENSION vector;");
		$node->safe_psql($db, "CREATE EXTENSION svs;");
	}
	$node->safe_psql('postgres', qq(
		INSERT INTO vamana_databases (datname, enabled, residency_memory)
			VALUES ('gate_ceiling_x', true, 16000), ('gate_ceiling_y', true, 16000);
	));
	wait_for_worker_db($node, 'gate_ceiling_x');
	wait_for_worker_db($node, 'gate_ceiling_y');

	my $confirm_point = 'vamana-build-governed-pre-confirm';

	$node->safe_psql('gate_ceiling_x', qq(
		CREATE TABLE ceiling_x_tbl (id serial PRIMARY KEY, c1 vector($dim));
		INSERT INTO ceiling_x_tbl (c1)
			SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 5000) i;
	));
	# A different row count from X's table, not just a different table: X and
	# Y's buildPeak estimates depend only on shape (rows, dimensions), not on
	# vector content, so two same-shaped tables would coincidentally get the
	# identical buildPeak and the negative assertions below would pass for
	# the wrong reason.
	$node->safe_psql('gate_ceiling_y', qq(
		CREATE TABLE ceiling_y_tbl (id serial PRIMARY KEY, c1 vector($dim));
		INSERT INTO ceiling_y_tbl (c1)
			SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 7000) i;
	));

	my $log_offset = -s $node->logfile;
	my $build_x = park_build('gate_ceiling_x', 'ceiling_x_tbl', 'ceiling_x_idx', $confirm_point);

	$node->wait_for_log(qr/buildPeak \(margined\)/, $log_offset);
	my $log_tail = PostgreSQL::Test::Utils::slurp_file($node->logfile, $log_offset);
	my ($x_relid) = $log_tail =~ /build memory estimate for index (\d+)/;
	my ($x_build_peak) = $log_tail =~ /buildPeak \(margined\) (\d+) bytes/;
	ok(defined $x_relid && defined $x_build_peak,
		'ceiling_hygiene: recovered X\'s relid and buildPeak from its own DEBUG1 estimate line');

	my ($x_committed, undef) = committed_totals('gate_ceiling_x');
	is($x_committed, $x_build_peak,
		'ceiling_hygiene: X\'s committed build bytes while parked equal its own buildPeak');

	# Tight enough that X's already-committed peak plus Y's own leaves no
	# room, generous enough that X alone still fit when it reserved.
	my $ceiling_mb = int(($x_build_peak + 1024 * 1024 - 1) / (1024 * 1024)) + 1;
	$node->safe_psql('postgres', "ALTER SYSTEM SET svs.max_build_memory = '${ceiling_mb}MB';");
	$node->reload;

	my ($ret_y, $stdout_y, $stderr_y) = $node->psql('gate_ceiling_y',
		"CREATE INDEX ceiling_y_idx ON ceiling_y_tbl USING vamana (c1 vector_l2_ops);");
	isnt($ret_y, 0,
		'ceiling_hygiene: Y is refused once X\'s buildPeak already fills the lowered global ceiling');
	like($stderr_y, qr/svs\.max_build_memory/,
		'ceiling_hygiene: Y\'s refusal names svs.max_build_memory')
	  or diag("stderr: $stderr_y");
	unlike($stderr_y, qr/\Q$x_relid\E/,
		'ceiling_hygiene: Y\'s refusal does not mention X\'s relid');
	unlike($stderr_y, qr/\Q$x_build_peak\E/,
		'ceiling_hygiene: Y\'s refusal does not mention X\'s committed bytes');
	unlike($stderr_y, qr/gate_ceiling_x/,
		'ceiling_hygiene: Y\'s refusal does not mention X\'s database name');

	my $y_count = $node->safe_psql('gate_ceiling_y',
		"SELECT count(*) FROM pg_indexes WHERE indexname = 'ceiling_y_idx';");
	chomp $y_count;
	is($y_count, '0', 'ceiling_hygiene: the refused Y build left no index behind');

	$node->safe_psql('postgres', "ALTER SYSTEM SET svs.max_build_memory = '4096MB';");
	$node->reload;

	wake_build($build_x, $confirm_point, 'ceiling_hygiene');

	my $x_count = $node->safe_psql('gate_ceiling_x',
		"SELECT count(*) FROM pg_indexes WHERE indexname = 'ceiling_x_idx';");
	chomp $x_count;
	is($x_count, '1', 'ceiling_hygiene: X, admitted first, completes normally once released');
}

$node->stop;

done_testing();
