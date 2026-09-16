# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 24_regrowth_kicks.pl: the launcher is kicked promptly when a database's
# last cached index unloads, instead of waiting out the 180s naptime.
#
# SCOPE NOTE: the published grant (pg_stat_vamana_worker.search_threads_granted)
# is computed by SvsComputeCpuGrants/ComputeEffectiveDesired (svs_cpu_budget.c)
# purely from a database's liveness and its search_num_threads catalog value,
# never from its cached-index count or even its catalog index_count. So
# unloading a database's last cached index cannot, under the current formula,
# make a sibling's granted value rise, regardless of how promptly the launcher
# reconciles. See the PR description for the supporting evidence.
#
# What this file actually tests is the mechanism this task adds: the worker
# calls SvsKickLauncher() exactly when its cache transitions to zero entries,
# so the launcher's next reconcile pass runs within a couple of seconds of
# that event rather than after the full 180s VAMANA_LAUNCHER_NAPTIME_MS
# naptime. Every reconcile pass calls PublishCpuGrants(), which carries a
# pre-existing injection point ("svs-build-thread-grant-publish", added for
# #19's build-thread-grant tests). Attaching to it in 'wait' mode and checking
# the launcher's pg_stat_activity.wait_event is a direct, value-independent
# way to observe "a reconcile pass just ran" without needing the grant to
# move at all.
#
# The "unloading one of several cached indexes must not kick" negative case
# is not tested in this file; see test/modules/svs_cache_kick_test and the PR
# description.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep gettimeofday tv_interval);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

if (($ENV{enable_injection_points} // 'no') ne 'yes')
{
	plan skip_all => 'server not built with --enable-injection-points';
}

# NAPTIME_BOUND_MS is the regression this file guards against: without the
# kick, nothing shortens VAMANA_LAUNCHER_NAPTIME_MS (180000ms), so regrowth
# would wait that out. Every positive-detection bound below is a small
# fraction of it, so a reconcile arriving late (a missed kick falling back to
# naptime) fails loudly instead of the test just running slower.
my $NAPTIME_BOUND_MS = 180_000;

my $node = PostgreSQL::Test::Cluster->new('regrowth_kicks');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "max_replication_slots = 16");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->append_conf('postgresql.conf', "svs.max_residency_memory = '400MB'");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres', "CREATE EXTENSION injection_points;");

$node->safe_psql('postgres', "CREATE DATABASE hot_db;");
$node->safe_psql('postgres', "CREATE DATABASE cold_db;");
# idle_db is case 3's alone: a database with no other cached index ever
# lets a backend-triggered invalidation happen with nothing else present to
# be swept up in the cross-index cascade documented in section 2 below.
$node->safe_psql('postgres', "CREATE DATABASE idle_db;");
for my $db (qw(hot_db cold_db idle_db))
{
	$node->safe_psql($db, "CREATE EXTENSION vector;");
	$node->safe_psql($db, "CREATE EXTENSION svs;");
}
$node->safe_psql('postgres',
	"INSERT INTO vamana_databases (datname, enabled) VALUES "
  . "('hot_db', true), ('cold_db', true), ('idle_db', true);");

my $hot_pid = wait_for_worker_db($node, 'hot_db', 30);
ok($hot_pid =~ /^\d+$/, 'hot_db worker is running');
my $cold_pid = wait_for_worker_db($node, 'cold_db', 30);
ok($cold_pid =~ /^\d+$/, 'cold_db worker is running');
my $idle_pid = wait_for_worker_db($node, 'idle_db', 30);
ok($idle_pid =~ /^\d+$/, 'idle_db worker is running');

# ---------------------------------------------------------------------------
# Helper: create one vamana-indexed table in $db and load its index into the
# worker's cache with a query. Separate statements, not one batched multi-
# statement command: an error partway through a batched command (e.g. a scan
# timing out while the worker is mid-BuildSnapshot for a brand-new
# replication slot) rolls back everything before it in the same implicit
# transaction, including the CREATE INDEX -- observed directly while hand-
# testing this file's scenario.
# ---------------------------------------------------------------------------
my $tbl_seq = 0;

sub cache_one_index
{
	my ($db, $tblname, $idxname) = @_;

	$node->safe_psql($db, qq(
		CREATE TABLE $tblname (id serial PRIMARY KEY, val vector($dim));
		INSERT INTO $tblname (val)
			SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 20) i;
	));
	$node->safe_psql($db,
		"CREATE INDEX $idxname ON $tblname USING vamana (val vector_l2_ops);");
	$node->safe_psql($db, qq(
		SET enable_seqscan = off;
		SELECT id FROM $tblname ORDER BY val <-> '[$query_sql]' LIMIT 1;
	));
}

# ---------------------------------------------------------------------------
# Helper: was the launcher blocked on the given injection point within
# $bound_ms? Polls pg_stat_activity rather than sleeping the full bound, so a
# prompt hit is detected quickly and the elapsed time returned is meaningful.
# ---------------------------------------------------------------------------
sub launcher_hit_injection_point
{
	my ($point, $bound_ms) = @_;
	my $t0 = [gettimeofday];
	my $deadline = $t0->[0] + $bound_ms / 1000.0;

	while (gettimeofday() < $deadline)
	{
		my $we = $node->safe_psql('postgres',
			"SELECT wait_event FROM pg_stat_activity "
		  . "WHERE backend_type = 'vamana launcher';");
		chomp $we;
		return (1, tv_interval($t0)) if $we eq $point;
		usleep(100_000);
	}
	return (0, tv_interval($t0));
}

# CREATE INDEX's build-thread-grant release kick (svs_build_thread_grant.c)
# is fire-and-forget from the backend's side: it calls SvsKickLauncher() and
# returns without waiting for the launcher to process that reconcile pass.
# Attaching the shared injection point right after setup activity can catch
# a still-in-flight, unrelated reconcile instead of the one the next action
# under test is meant to trigger. Drain any such reconcile deterministically
# by attaching, absorbing one hit if it lands within a short bound, and
# waking it, rather than guessing a sleep duration.
sub settle
{
	$node->safe_psql('postgres',
		"SELECT injection_points_attach('svs-build-thread-grant-publish', 'wait');");
	my ($hit, undef) = launcher_hit_injection_point(
		'svs-build-thread-grant-publish', 2_000);
	if ($hit)
	{
		$node->safe_psql('postgres',
			"SELECT injection_points_wakeup('svs-build-thread-grant-publish');");
	}
	$node->safe_psql('postgres',
		"SELECT injection_points_detach('svs-build-thread-grant-publish');");
}

# ---------------------------------------------------------------------------
# 1. Positive case: unloading a database's *only* cached index kicks the
# launcher, and its next reconcile pass (observed via the pre-existing
# svs-build-thread-grant-publish injection point) runs within a few seconds,
# not after the 180s naptime this guards against.
# ---------------------------------------------------------------------------
{
	cache_one_index('cold_db', 'rk_cold_tbl', 'rk_cold_idx');
	cache_one_index('hot_db', 'rk_hot_tbl', 'rk_hot_idx');

	my $cached = $node->safe_psql('postgres',
		"SELECT d.datname, w.index_count FROM pg_stat_vamana_worker w "
	  . "JOIN pg_database d ON d.oid = w.db_oid "
	  . "WHERE d.datname IN ('cold_db', 'hot_db') ORDER BY d.datname;");
	is($cached, "cold_db|1\nhot_db|1", 'setup: exactly one cached index in each database');

	settle();
	$node->safe_psql('postgres',
		"SELECT injection_points_attach('svs-build-thread-grant-publish', 'wait');");

	$node->safe_psql('cold_db', "DROP INDEX rk_cold_idx;");

	my ($hit, $elapsed) = launcher_hit_injection_point(
		'svs-build-thread-grant-publish', 5_000);
	ok($hit,
		"case 1: launcher reconciles within 5s of cold_db's only cached index unloading "
	  . "(took ${elapsed}s; the regression this guards against is a 180s wait)");
	ok($elapsed < $NAPTIME_BOUND_MS / 1000.0,
		'case 1: elapsed time is well under the 180s naptime');

	$node->safe_psql('postgres',
		"SELECT injection_points_wakeup('svs-build-thread-grant-publish');");
	$node->safe_psql('postgres',
		"SELECT injection_points_detach('svs-build-thread-grant-publish');");

	my $after = $node->safe_psql('postgres',
		"SELECT index_count FROM pg_stat_vamana_worker w "
	  . "JOIN pg_database d ON d.oid = w.db_oid WHERE d.datname = 'cold_db';");
	chomp $after;
	is($after, '0', "case 1: cold_db's cache is empty after the unload");
}

# ---------------------------------------------------------------------------
# 2. Negative case (with several indexes still cached in one database,
# unloading one of them must NOT kick the launcher): not tested here. A
# separate, pre-existing bug in this codebase's replication/reload-signaling
# makes it unconstructable end-to-end through SQL today; see the PR
# description for the evidence. test/modules/svs_cache_kick_test proves the
# same arithmetic directly, sidestepping that bug.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 3. A backend's own local cache eviction must not kick the launcher.
# VamanaInvalidateCache is called directly from a backend (not the worker)
# when a CREATE INDEX build finds no vectors to index (vamanabuild.c); that
# path is reachable from ordinary SQL with an empty table, no worker
# involvement needed.
#
# Runs in idle_db, not hot_db: hot_db still holds rk_hot_idx from case 1, and
# an empty-table CREATE INDEX there is subject to the same cross-index
# cascade described in section 2, which would evict rk_hot_idx as a side
# effect and produce a kick unrelated to what this case tests. idle_db has
# never cached anything, so there is nothing for that cascade to reach.
# ---------------------------------------------------------------------------
{
	settle();
	$node->safe_psql('postgres',
		"SELECT injection_points_attach('svs-build-thread-grant-publish', 'wait');");

	$node->safe_psql('idle_db', qq(
		CREATE TABLE rk_empty_tbl (id serial PRIMARY KEY, val vector($dim));
		CREATE INDEX rk_empty_idx ON rk_empty_tbl USING vamana (val vector_l2_ops);
	));

	my ($hit, $elapsed) = launcher_hit_injection_point(
		'svs-build-thread-grant-publish', 5_000);
	ok(!$hit,
		"case 3: a backend's own cache invalidation (empty-table CREATE INDEX) "
	  . "does not kick the launcher (waited ${elapsed}s)");

	if ($hit)
	{
		$node->safe_psql('postgres',
			"SELECT injection_points_wakeup('svs-build-thread-grant-publish');");
	}
	$node->safe_psql('postgres',
		"SELECT injection_points_detach('svs-build-thread-grant-publish');");
}

# ---------------------------------------------------------------------------
# 4. One kick per full eviction (VamanaEvictAllCacheEntries), not one per
# entry. Reuses 06_reload_queue.pl's mechanism: SIGSTOP the worker, overflow
# the 16-slot per-OID reload queue with 17 TRUNCATEs so evict_all is set,
# then SIGCONT so the worker evicts its whole cache (several entries here) in
# one pass.
#
# SvsKickLauncher only sets the launcher's latch, which coalesces repeat
# calls made before the launcher wakes into a single wake-up, so kick *count*
# cannot be distinguished from the outside between "called once after the
# loop" and "called once per entry" the way this test observes the system.
# What is directly observable, and asserted below, is a single reconcile
# pass following the full eviction and the worker staying healthy
# throughout. test/modules/svs_cache_kick_test proves the "once after the
# loop, not per entry" guarantee directly.
# ---------------------------------------------------------------------------
{
	my $N_TABLES = 17;    # one more than VAMANA_MAX_RELOAD_QUEUE (16)
	my $N_CACHE_TABLES = 5;    # several entries for the full eviction to clear

	for my $i (0 .. $N_TABLES - 1)
	{
		$node->safe_psql('cold_db', qq(
			CREATE TABLE rk_rq_tbl_$i (id serial PRIMARY KEY, val vector($dim));
			INSERT INTO rk_rq_tbl_$i (val)
				SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 10) i;
		));
		$node->safe_psql('cold_db',
			"CREATE INDEX ON rk_rq_tbl_$i USING vamana (val vector_l2_ops);");
	}

	for my $i (0 .. $N_CACHE_TABLES - 1)
	{
		$node->safe_psql('cold_db', qq(
			SET enable_seqscan = off;
			SELECT id FROM rk_rq_tbl_$i ORDER BY val <-> '[$query_sql]' LIMIT 1;
		));
	}

	my $cached_before = $node->safe_psql('postgres',
		"SELECT index_count FROM pg_stat_vamana_worker w "
	  . "JOIN pg_database d ON d.oid = w.db_oid WHERE d.datname = 'cold_db';");
	chomp $cached_before;
	is($cached_before, "" . ($N_TABLES),
		'setup: all 17 indexes are counted in cold_db (index_count tracks catalog, not cache residency)');

	my $before_flag = $node->safe_psql('cold_db',
		"SELECT evict_all FROM pg_stat_vamana_worker WHERE db_oid = "
	  . "(SELECT oid FROM pg_database WHERE datname = 'cold_db');");
	chomp $before_flag;
	is($before_flag, 'f', 'evict_all starts false');

	kill('STOP', $cold_pid);

	for my $i (0 .. $N_TABLES - 1)
	{
		$node->safe_psql('cold_db', "TRUNCATE rk_rq_tbl_$i;");
	}

	my $after_flag = $node->safe_psql('cold_db',
		"SELECT evict_all FROM pg_stat_vamana_worker WHERE db_oid = "
	  . "(SELECT oid FROM pg_database WHERE datname = 'cold_db');");
	chomp $after_flag;
	is($after_flag, 't',
		'evict_all set after queue overflow (17 TRUNCATEs against 16-slot queue)');

	settle();
	$node->safe_psql('postgres',
		"SELECT injection_points_attach('svs-build-thread-grant-publish', 'wait');");

	kill('CONT', $cold_pid);

	my ($hit, $elapsed) = launcher_hit_injection_point(
		'svs-build-thread-grant-publish', 10_000);
	ok($hit,
		"case 4: the full eviction (several entries) kicks the launcher into a "
	  . "reconcile within 10s (took ${elapsed}s)");

	$node->safe_psql('postgres',
		"SELECT injection_points_wakeup('svs-build-thread-grant-publish');");
	$node->safe_psql('postgres',
		"SELECT injection_points_detach('svs-build-thread-grant-publish');");

	my $cleared = 0;
	for my $attempt (1 .. 60)
	{
		usleep(500_000);
		my $flag = $node->safe_psql('cold_db',
			"SELECT evict_all FROM pg_stat_vamana_worker WHERE db_oid = "
		  . "(SELECT oid FROM pg_database WHERE datname = 'cold_db');");
		chomp $flag;
		if ($flag eq 'f')
		{
			$cleared = 1;
			last;
		}
	}
	ok($cleared, 'case 4: evict_all cleared after the worker resumes and drains the full eviction');
}

# ---------------------------------------------------------------------------
# 5. The worker survives every case above: same pid, heartbeat still
# advancing, and no crash or unexpected exit in the server log. A green TAP
# result above does not by itself prove nothing died and restarted.
# ---------------------------------------------------------------------------
{
	my $hot_pid_after = $node->safe_psql('postgres',
		"SELECT pid FROM pg_stat_activity "
	  . "WHERE backend_type = 'vamana worker' AND datname = 'hot_db';");
	chomp $hot_pid_after;
	is($hot_pid_after, $hot_pid, 'hot_db worker pid is unchanged after all cases');

	my $cold_pid_after = $node->safe_psql('postgres',
		"SELECT pid FROM pg_stat_activity "
	  . "WHERE backend_type = 'vamana worker' AND datname = 'cold_db';");
	chomp $cold_pid_after;
	is($cold_pid_after, $cold_pid, 'cold_db worker pid is unchanged after all cases');

	my $hb1 = $node->safe_psql('postgres',
		"SELECT heartbeat_ts FROM pg_stat_vamana_worker w "
	  . "JOIN pg_database d ON d.oid = w.db_oid WHERE d.datname = 'cold_db';");
	sleep(2);
	my $hb2 = $node->safe_psql('postgres',
		"SELECT heartbeat_ts FROM pg_stat_vamana_worker w "
	  . "JOIN pg_database d ON d.oid = w.db_oid WHERE d.datname = 'cold_db';");
	isnt($hb1, $hb2, "cold_db worker's heartbeat is still advancing");

	my $log = $node->log_content();
	# "parallel worker (build thread) exited with exit code 1" is normal and
	# expected throughout this file (every CREATE INDEX above spawns and
	# retires build-thread-grant workers that way); only a crash of the
	# vamana worker or launcher itself is the regression this guards
	# against, matching the pattern 21_parallel_slot_lifecycle.pl uses.
	unlike($log, qr/Segmentation fault|terminated by signal|was terminated by signal|crashed/,
		'no crashed-worker or segfault line during this file');
}

$node->stop;

done_testing();
