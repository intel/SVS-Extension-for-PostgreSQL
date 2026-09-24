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
# Also covers three joint-integration scenarios that need both the build and
# residency axes wired together: the counter staying correct across the
# reserve-confirm-handoff-reconcile window, a reservation window between two
# concurrent builds, and VamanaRebuildFromTable sharing the same build gate
# as a fresh CREATE INDEX.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use File::Path qw(remove_tree);

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
$node->append_conf('postgresql.conf', "svs.max_residency_memory = '16000MB'");
$node->append_conf('postgresql.conf', "svs.default_residency_memory = '16000MB'");
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

sub committed_bytes
{
	my $bytes = $node->safe_psql('postgres',
		"SELECT residency_bytes_committed FROM pg_stat_vamana_worker "
	  . "WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');");
	chomp $bytes;
	return $bytes;
}

sub relid_of
{
	my ($ident) = @_;
	my $relid = $node->safe_psql('postgres', "SELECT '$ident'::regclass::oid;");
	chomp $relid;
	return $relid;
}

sub resident_bytes_of
{
	my ($relid) = @_;
	my $bytes = $node->safe_psql('postgres',
		"SELECT resident_bytes FROM svs_index_residency WHERE index_relid = $relid;");
	chomp $bytes;
	return $bytes;
}

# ---------------------------------------------------------------------------
# Build-to-residency handoff: the committed counter must already hold this
# build's confirmed bytes before handoff runs, and handoff plus the worker's
# own load reconcile must not add to it again.
# ---------------------------------------------------------------------------
{
	my $point = 'vamana-build-governed-pre-handoff';

	$node->safe_psql('postgres', qq(
		CREATE TABLE handoff_tbl (id serial PRIMARY KEY, c1 vector($dim));
		INSERT INTO handoff_tbl (c1)
			SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 500) i;
	));

	my $before = committed_bytes();

	$node->safe_psql('postgres', "SELECT injection_points_attach('$point', 'wait');");

	my $build = $node->background_psql('postgres', on_error_stop => 0);
	$build->query_until(qr/handoff_build_started/, qq(
		\\echo handoff_build_started
		CREATE INDEX handoff_idx ON handoff_tbl USING vamana (c1 vector_l2_ops);
	));
	$node->wait_for_event('client backend', $point);

	my $mid = committed_bytes();
	cmp_ok($mid, '>', $before,
		'handoff: confirm already committed this build\'s bytes before handoff runs');

	$node->safe_psql('postgres', "SELECT injection_points_detach('$point');");
	$node->safe_psql('postgres', "SELECT injection_points_wakeup('$point');");
	$build->query('SELECT 1');
	$build->quit;

	my $after = committed_bytes();
	is($after, $mid,
		'handoff: handoff and the worker\'s load reconcile do not add to the counter again');

	my $relid = relid_of('handoff_idx');
	my $measured = resident_bytes_of($relid);
	cmp_ok($measured, '>', 0, 'handoff: the durable record holds a real measured size');
	is($after - $before, $measured,
		'handoff: the counter\'s total growth equals exactly this index\'s measured bytes');

	$node->safe_psql('postgres', "DROP TABLE handoff_tbl;");
}

# ---------------------------------------------------------------------------
# Reservation window: a budget that fits one build but not two. The second
# build's gate must see the first's already-committed bytes, not a stale
# snapshot, and the counter must equal exactly the survivor's bytes.
# ---------------------------------------------------------------------------
{
	my $point = 'vamana-build-governed-pre-allocation';
	my $rows = 20000;

	$node->safe_psql('postgres', qq(
		CREATE TABLE resa_tbl (id serial PRIMARY KEY, c1 vector($dim));
		INSERT INTO resa_tbl (c1)
			SELECT ARRAY[$array_sql]::vector FROM generate_series(1, $rows) i;
		CREATE TABLE resb_tbl (id serial PRIMARY KEY, c1 vector($dim));
		INSERT INTO resb_tbl (c1)
			SELECT ARRAY[$array_sql]::vector FROM generate_series(1, $rows) i;
	));

	# Learn one build's real footprint first, at a generous budget, then drop
	# it and re-admit at a budget between 1x and 2x that footprint.
	$node->safe_psql('postgres',
		"CREATE INDEX resa_probe_idx ON resa_tbl USING vamana (c1 vector_l2_ops);");
	my $probe_relid = relid_of('resa_probe_idx');
	my $unit_bytes = resident_bytes_of($probe_relid);
	cmp_ok($unit_bytes, '>', 0, 'reservation-window: probe build reports a real size');
	$node->safe_psql('postgres', "DROP INDEX resa_probe_idx;");

	my $tight_mb = int(($unit_bytes * 1.4 + 1024 * 1024 - 1) / (1024 * 1024));
	$node->safe_psql('postgres',
		"UPDATE vamana_databases SET residency_memory = $tight_mb WHERE datname = 'postgres';");

	$node->safe_psql('postgres', "SELECT injection_points_attach('$point', 'wait');");

	my $buildA = $node->background_psql('postgres', on_error_stop => 0);
	$buildA->query_until(qr/resa_build_started/, qq(
		\\echo resa_build_started
		CREATE INDEX resa_idx ON resa_tbl USING vamana (c1 vector_l2_ops);
	));
	$node->wait_for_event('client backend', $point);

	# A is parked before it has reserved anything; detach so B does not also
	# park here, then let B run to completion while A still waits.
	$node->safe_psql('postgres', "SELECT injection_points_detach('$point');");

	my ($retB, $stdoutB, $stderrB) = $node->psql('postgres',
		"CREATE INDEX resb_idx ON resb_tbl USING vamana (c1 vector_l2_ops);");
	is($retB, 0, 'reservation-window: the first build to actually reserve succeeds')
	  or diag("stderr: $stderrB");

	my $after_b = committed_bytes();

	$node->safe_psql('postgres', "SELECT injection_points_wakeup('$point');");
	$buildA->query('SELECT 1');
	my $stderrA = $buildA->{stderr};
	$buildA->quit;

	like($stderrA, qr/would exceed database \d+'s residency budget/,
		'reservation-window: the parked build\'s own gate sees B\'s bytes already committed, not a stale snapshot')
	  or diag("stderr: $stderrA");

	my $index_count = $node->safe_psql('postgres',
		"SELECT count(*) FROM pg_indexes WHERE indexname = 'resa_idx';");
	chomp $index_count;
	is($index_count, '0', 'reservation-window: the refused build left no index behind');

	my $final = committed_bytes();
	is($final, $after_b,
		'reservation-window: the counter never overshoots past the survivor\'s own bytes');

	$node->safe_psql('postgres',
		"UPDATE vamana_databases SET residency_memory = NULL WHERE datname = 'postgres';");
	$node->safe_psql('postgres', "DROP TABLE resa_tbl; DROP TABLE resb_tbl;");
}

# ---------------------------------------------------------------------------
# Rebuild-path closure: VamanaRebuildFromTable shares vamanabuild's gate. A
# demand-driven rebuild whose estimate alone exceeds svs.max_build_memory is
# refused before allocation, the same as a fresh CREATE INDEX, and the
# refusal reaches the querying client rather than killing the worker.
# ---------------------------------------------------------------------------
{
	$node->safe_psql('postgres', qq(
		CREATE TABLE rebuild_tbl (id serial PRIMARY KEY, c1 vector($dim));
		INSERT INTO rebuild_tbl (c1)
			SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 500) i;
		CREATE INDEX rebuild_idx ON rebuild_tbl USING vamana (c1 vector_l2_ops);
	));

	my $relid = relid_of('rebuild_idx');
	my $save_dir = vamana_save_dir($node, 'postgres', $relid);
	ok(-d $save_dir, 'rebuild-path: the on-disk save directory exists before the test');

	$node->safe_psql('postgres', "ALTER SYSTEM SET svs.max_build_memory = '1MB';");
	$node->stop;
	remove_tree($save_dir);
	$node->start;

	wait_for_worker($node);

	my ($ret3, $stdout3, $stderr3) = $node->psql('postgres', qq(
		SET enable_seqscan = off;
		SELECT id FROM rebuild_tbl ORDER BY c1 <-> '[$query_sql]' LIMIT 1;
	));
	isnt($ret3, 0, 'rebuild-path: the query fails when the demand rebuild exceeds svs.max_build_memory');
	like($stderr3, qr/would exceed svs\.max_build_memory/,
		'rebuild-path: the refusal names svs.max_build_memory, same as a fresh build\'s gate')
	  or diag("stderr: $stderr3");

	my $live_pid = $node->safe_psql('postgres',
		"SELECT pid FROM pg_stat_activity WHERE backend_type = 'vamana worker';");
	chomp $live_pid;
	ok($live_pid =~ /^\d+$/, 'rebuild-path: the worker survives the refused rebuild');

	$node->safe_psql('postgres', "ALTER SYSTEM SET svs.max_build_memory = '4096MB';");
	$node->reload;

	my ($ret4, $stdout4, $stderr4) = $node->psql('postgres', qq(
		SET enable_seqscan = off;
		SELECT id FROM rebuild_tbl ORDER BY c1 <-> '[$query_sql]' LIMIT 1;
	));
	is($ret4, 0, 'rebuild-path: the same rebuild succeeds once svs.max_build_memory is raised')
	  or diag("stderr: $stderr4");
}

$node->stop;

done_testing();
