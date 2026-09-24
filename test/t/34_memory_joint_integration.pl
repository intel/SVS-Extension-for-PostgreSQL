# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 34_memory_joint_integration.pl -- cross-track scenarios that need both the
# build/residency and search-scratch axes wired together, not owned by
# either track's own file.
#
# Of the joint-integration list, several items already have real coverage
# elsewhere and are not reimplemented here:
#   - Search admission sum test (concurrency guard): 27_search_scratch_
#     accounting.pl Case 0 already races two background_psql sessions near
#     svs.max_search_work_mem.
#   - Build-to-residency handoff, build-confirm rejection, reservation
#     window, rebuild-path closure: 32_build_memory_gate.pl.
#   - Global ceiling: 26_residency_accounting.pl Case 9.
#   - Search-scratch recompute, in-flight: 27_search_scratch_accounting.pl.

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

my $node = PostgreSQL::Test::Cluster->new('memory_joint_integration');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'vector,svs'");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 20");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "svs.max_residency_memory = '16000MB'");
$node->append_conf('postgresql.conf', "svs.default_residency_memory = '16000MB'");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres', "CREATE EXTENSION injection_points;");
$node->safe_psql('postgres',
	"INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");
wait_for_worker($node);

sub committed_bytes
{
	my $bytes = $node->safe_psql('postgres',
		"SELECT residency_bytes_committed FROM pg_stat_vamana_worker "
	  . "WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');");
	chomp $bytes;
	return $bytes;
}

sub build_bytes_committed
{
	my $bytes = $node->safe_psql('postgres',
		"SELECT build_bytes_committed FROM pg_stat_vamana_worker "
	  . "WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');");
	chomp $bytes;
	return $bytes;
}

sub residency_limit_mb
{
	my $mb = $node->safe_psql('postgres',
		"SELECT residency_memory_limit / (1024 * 1024) FROM pg_stat_vamana_worker "
	  . "WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');");
	chomp $mb;
	return $mb;
}

# ---------------------------------------------------------------------------
# Decrease-validation, worker down.
#
# A residency_memory decrease that would undercut a resident index's
# committed bytes must be rejected whether the check reads live shmem or the
# durable svs_index_residency floor. Build a real index large enough that
# its footprint exceeds residency_memory's 1 MB minimum, so a decrease to 1
# is a genuine violation, not merely tiny.
# ---------------------------------------------------------------------------
$node->safe_psql('postgres', qq(
	CREATE TABLE djoint_tbl (id serial PRIMARY KEY, c1 vector($dim));
	INSERT INTO djoint_tbl (c1)
		SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 20000) i;
	CREATE INDEX djoint_idx ON djoint_tbl USING vamana (c1 vector_l2_ops);
));
wait_for_worker($node);
my $resident_bytes = committed_bytes();
cmp_ok($resident_bytes, '>', 1024 * 1024,
	'the built index is resident well above the 1 MB decrease target, so a decrease to 1 MB is a real violation');

# ---------------------------------------------------------------------------
# Window 1: the worker process is killed, but the database row stays
# enabled=true throughout (a plain crash, not a disable). Shared memory for
# this slot is untouched by a worker-process restart (VamanaWorker
# ReconcileResidencyOnStartup preserves it), so the live committed figure
# is still accurate the moment the decrease is attempted.
# ---------------------------------------------------------------------------
{
	my $worker_pid = $node->safe_psql('postgres',
		"SELECT pid FROM pg_stat_activity WHERE backend_type = 'vamana worker';");
	chomp $worker_pid;
	kill('TERM', $worker_pid);
	for (1 .. 100)
	{
		usleep(100_000);
		my $alive = $node->safe_psql('postgres',
			"SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'vamana worker';");
		chomp $alive;
		last if $alive eq '0';
	}

	my ($ret, $stdout, $stderr) = $node->psql('postgres',
		"UPDATE vamana_databases SET residency_memory = 1 WHERE datname = 'postgres';");
	isnt($ret, 0,
		'window 1: a decrease below committed bytes is rejected while the worker process is down');
	like($stderr, qr/cannot be lowered below its already-committed bytes/,
		'window 1: the rejection names the already-committed bytes')
	  or diag("stderr: $stderr");

	my $worker_pid2 = wait_for_worker($node);
	ok($worker_pid2 =~ /^\d+$/ && $worker_pid2 ne $worker_pid,
		'window 1: the worker respawns for the next window');
}

# ---------------------------------------------------------------------------
# Window 2: a full postmaster restart, not just a worker-process kill. This
# is the one event that actually reinitializes shared memory: djoint_idx's
# reservation is gone, and nothing has reloaded it yet -- loading is lazy,
# on first query. The worker seeds its committed total from the durable
# svs_index_residency record at startup, so the live counter is already
# correct the moment it reports running, and the decrease is rejected
# reading that seeded value, not a stale zero.
# ---------------------------------------------------------------------------
{
	$node->restart;

	my $worker_state = '';
	for (1 .. 100)
	{
		usleep(100_000);
		$worker_state = $node->safe_psql('postgres',
			"SELECT worker_state FROM pg_stat_vamana_worker "
		  . "WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');");
		chomp $worker_state;
		last if $worker_state eq 'running';
	}
	is($worker_state, 'running',
		'window 2: the worker reports running again after the postmaster restart');
	is(committed_bytes(), $resident_bytes,
		'window 2: the live counter is already seeded from the durable record, not reading a stale zero');

	my $durable_bytes = $node->safe_psql('postgres',
		"SELECT resident_bytes FROM svs_index_residency WHERE index_relid = 'djoint_idx'::regclass;");
	chomp $durable_bytes;
	is($durable_bytes, $resident_bytes,
		'window 2: the durable record still holds the pre-restart measured size');

	my ($ret, $stdout, $stderr) = $node->psql('postgres',
		"UPDATE vamana_databases SET residency_memory = 1 WHERE datname = 'postgres';");
	isnt($ret, 0,
		'window 2: the decrease is still rejected after the restart');
	like($stderr, qr/cannot be lowered below its already-committed bytes/,
		'window 2: the rejection names the already-committed bytes')
	  or diag("stderr: $stderr");

	is(residency_limit_mb($node), '16000',
		'window 2: the resolved budget is untouched by the rejected decrease');
}

# ---------------------------------------------------------------------------
# Crash/leak matrix: the one sub-scenario not already covered elsewhere.
#
# Build error (29_build_abort_cleanup.pl), DROP INDEX (26_/31_), worker
# restart (26_/27_/13_), and insert-crash-before-apply (26_ Case 5) are all
# already exercised through the reaper or PG_ENSURE_ERROR_CLEANUP. What
# is not: a backend hard-killed mid-build, parked deep enough that its own
# error cleanup never runs, leaving a build reservation only the worker's
# SvsMemoryReapDeadReservations can reclaim -- the build-axis counterpart to
# 26_'s insert-reservation reaper case.
# ---------------------------------------------------------------------------
{
	my $tbl = 'crashbuild_tbl';
	my $idx = 'crashbuild_idx';
	my $point = 'vamana-build-governed-pre-confirm';

	$node->safe_psql('postgres', qq(
		CREATE TABLE $tbl (id serial PRIMARY KEY, c1 vector($dim));
		INSERT INTO $tbl (c1)
			SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 300) i;
	));

	my $build_before = build_bytes_committed();
	my $residency_before = committed_bytes();

	$node->safe_psql('postgres', "SELECT injection_points_attach('$point', 'wait');");

	my $victim = $node->background_psql('postgres', on_error_stop => 0);
	my $victim_pid_out = $victim->query('SELECT pg_backend_pid();');
	my ($victim_pid) = $victim_pid_out =~ /(\d+)/;
	$victim->query_until(qr/crashbuild_started/, qq(
		\\echo crashbuild_started
		CREATE INDEX $idx ON $tbl USING vamana (c1 vector_l2_ops);
	));
	$node->wait_for_event('client backend', $point);

	cmp_ok(build_bytes_committed(), '>', $build_before,
		'crash-mid-build: the build peak is committed while the backend is parked');

	kill('TERM', $victim_pid);

	my $reaped = '';
	for (1 .. 100)
	{
		$node->safe_psql('postgres',
			"UPDATE vamana_databases SET enabled = enabled WHERE datname = 'postgres';");
		usleep(100_000);
		if (build_bytes_committed() eq $build_before && committed_bytes() eq $residency_before)
		{
			$reaped = 1;
			last;
		}
	}
	ok($reaped,
		"a hard-killed backend's build reservation is reclaimed by the reaper");

	$node->safe_psql('postgres', "SELECT injection_points_detach('$point');");

	my $index_count = $node->safe_psql('postgres',
		"SELECT count(*) FROM pg_indexes WHERE indexname = '$idx';");
	chomp $index_count;
	is($index_count, '0', 'crash-mid-build: the killed build left no index behind');

	my $worker_pid = $node->safe_psql('postgres',
		"SELECT pid FROM pg_stat_activity WHERE backend_type = 'vamana worker';");
	chomp $worker_pid;
	ok($worker_pid =~ /^\d+$/, 'crash-mid-build: the worker survives reaping the killed backend');
}

$node->stop;

# ---------------------------------------------------------------------------
# DBA sizing walkthrough: the design doc's own worked example (50 GB index,
# 100 GB machine, Section 10) run against a real cluster at the exact GUC
# values it specifies, as an acceptance check rather than a doc example.
# shared_buffers/work_mem are core GUCs outside SVS's own accounting and
# are not under test here; only the five SVS memory GUCs are.
# ---------------------------------------------------------------------------
{
	my $sizing_node = PostgreSQL::Test::Cluster->new('memory_dba_sizing');
	$sizing_node->init;
	$sizing_node->append_conf('postgresql.conf', "shared_preload_libraries = 'vector,svs'");
	$sizing_node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
	$sizing_node->append_conf('postgresql.conf', "wal_level = logical");
	$sizing_node->append_conf('postgresql.conf', "max_replication_slots = 20");
	$sizing_node->append_conf('postgresql.conf', "max_wal_senders = 10");
	$sizing_node->append_conf('postgresql.conf', "svs.max_residency_memory = '50GB'");
	$sizing_node->append_conf('postgresql.conf', "svs.max_build_memory = '55GB'");
	$sizing_node->append_conf('postgresql.conf', "svs.max_search_work_mem = '2GB'");
	$sizing_node->append_conf('postgresql.conf', "svs.default_residency_memory = '1GB'");
	$sizing_node->append_conf('postgresql.conf', "svs.default_search_work_mem = '100MB'");
	$sizing_node->start;

	$sizing_node->safe_psql('postgres', "CREATE EXTENSION vector;");
	$sizing_node->safe_psql('postgres', "CREATE EXTENSION svs;");
	$sizing_node->safe_psql('postgres', "CREATE DATABASE sizing_b;");

	$sizing_node->safe_psql('postgres',
		"INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");
	my $pid_a = wait_for_worker_db($sizing_node, 'postgres');
	ok($pid_a =~ /^\d+$/, 'sizing: postgres admits under the worked-example GUCs');

	is($sizing_node->safe_psql('postgres', qq(
			SELECT residency_memory_limit, search_work_mem_limit
			FROM pg_stat_vamana_worker
			WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');
		)),
		(1024 * 1024 * 1024) . '|' . (100 * 1024 * 1024),
		'sizing: an unconfigured database resolves to the small defaults (1GB/100MB), not the ceilings');

	$sizing_node->safe_psql('postgres',
		"INSERT INTO vamana_databases (datname, enabled) VALUES ('sizing_b', true);");
	my $pid_b = wait_for_worker_db($sizing_node, 'sizing_b');
	ok($pid_b =~ /^\d+$/,
		'sizing: a second unconfigured database coexists, proving the default is not the whole ceiling at this scale');

	is($sizing_node->safe_psql('postgres', qq(
			SELECT residency_memory_limit, search_work_mem_limit
			FROM pg_stat_vamana_worker
			WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'sizing_b');
		)),
		(1024 * 1024 * 1024) . '|' . (100 * 1024 * 1024),
		'sizing: the second database resolves to the same defaults as the first');

	$sizing_node->safe_psql('postgres', qq(
		CREATE TABLE sizing_tbl (id serial PRIMARY KEY, c1 vector($dim));
		INSERT INTO sizing_tbl (c1)
			SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 300) i;
		CREATE INDEX sizing_idx ON sizing_tbl USING vamana (c1 vector_l2_ops);
	));
	wait_for_worker_db($sizing_node, 'postgres');

	my $sizing_relid = $sizing_node->safe_psql('postgres', "SELECT 'sizing_idx'::regclass::oid;");
	chomp $sizing_relid;
	my $sizing_resident = $sizing_node->safe_psql('postgres',
		"SELECT resident_bytes FROM svs_index_residency WHERE index_relid = $sizing_relid;");
	chomp $sizing_resident;
	cmp_ok($sizing_resident, '>', 0,
		'sizing: a real build and load succeed under the GB-scale ceilings, with a plausible measured size');

	my ($max_residency_bytes, $max_build_bytes, $max_search_bytes) = split(/\|/, $sizing_node->safe_psql('postgres', qq(
		SELECT
			(SELECT setting::bigint * 1024 * 1024 FROM pg_settings WHERE name = 'svs.max_residency_memory'),
			(SELECT setting::bigint * 1024 * 1024 FROM pg_settings WHERE name = 'svs.max_build_memory'),
			(SELECT setting::bigint * 1024 * 1024 FROM pg_settings WHERE name = 'svs.max_search_work_mem');
	)));
	is($max_residency_bytes, 50 * 1024 * 1024 * 1024, 'sizing: svs.max_residency_memory reads back as exactly 50GB, no truncation at GB scale');
	is($max_build_bytes, 55 * 1024 * 1024 * 1024, 'sizing: svs.max_build_memory reads back as exactly 55GB');
	is($max_search_bytes, 2 * 1024 * 1024 * 1024, 'sizing: svs.max_search_work_mem reads back as exactly 2GB');

	my $peak_svs_memory = $max_residency_bytes + $max_build_bytes + $max_search_bytes;
	is($peak_svs_memory, 107 * 1024 * 1024 * 1024,
		'sizing: the three ceilings sum to the worked example\'s 107GB peak_svs_memory');

	$sizing_node->stop;
}

done_testing();
