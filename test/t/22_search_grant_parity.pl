# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 22_search_grant_parity.pl — the search-thread grant the launcher publishes
# to pg_stat_vamana_worker actually reaches SVS at search dispatch and at
# index load, not just the shared-memory control block.
#
# pg_stat_vamana_worker.search_threads_granted (added in #19) proves the
# value was *published*; the DEBUG1 lines added alongside SVSSetIndexSearchThreads
# and in SVSLoadDynamicIndex prove it was *applied*.  Every case below checks
# both, deliberately kept separate.
#
# Also covers the search-scratch/thread-grant gate collision at their shared
# call site, VamanaWorkerDispatchBatch: a batch the search-scratch check
# refuses must never reach the thread-grant apply, and a batch it admits
# must still get the grant applied normally.

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

# ---------------------------------------------------------------------------
# Poll pg_stat_vamana_worker.search_threads_granted for a specific database
# until it reaches $expected, or give up.  Separate from wait_for_worker: this
# waits on the launcher's reconcile pass, not on worker startup.
# ---------------------------------------------------------------------------
sub wait_for_granted
{
	my ($node, $db, $expected, $attempts) = @_;
	$attempts //= 30;
	my $granted = '';
	for my $i (1 .. $attempts)
	{
		$granted = $node->safe_psql('postgres',
			"SELECT search_threads_granted FROM pg_stat_vamana_worker "
		  . "WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = '$db');");
		chomp $granted;
		return $granted if $granted eq "$expected";
		usleep(500_000);
	}
	return $granted;
}

my $node = PostgreSQL::Test::Cluster->new('search_grant_applied');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 10");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "log_min_messages = 'debug1'");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres', "CREATE EXTENSION injection_points;");
$node->safe_psql('postgres',
	"INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");
wait_for_worker($node);

$node->safe_psql('postgres', qq(
	CREATE TABLE sga_tbl (id serial PRIMARY KEY, val vector($dim));
	INSERT INTO sga_tbl (val)
		SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 300) i;
	CREATE INDEX sga_idx ON sga_tbl USING vamana (val vector_l2_ops);
));

my $relid = $node->safe_psql('postgres', "SELECT 'sga_idx'::regclass::oid;");

sub run_search
{
	return $node->safe_psql('postgres', qq(
		SET enable_seqscan = off;
		SELECT id FROM sga_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
	));
}

# ---------------------------------------------------------------------------
# 1. Published then applied: the value in pg_stat_vamana_worker actually
# reaches SVS at dispatch time, proven via the DEBUG1 dispatch log line.
# ---------------------------------------------------------------------------
{
	$node->safe_psql('postgres',
		"UPDATE vamana_databases SET search_num_threads = 4 WHERE datname = 'postgres';"
	);
	my $granted = wait_for_granted($node, 'postgres', 4);
	is($granted, '4', 'search_threads_granted reaches 4 after catalog update');

	my $log_pos = length($node->log_content());
	my $r = run_search();
	isnt($r, '', 'search returns results with search_num_threads=4');

	my $log = substr($node->log_content(), $log_pos);
	like($log,
		qr/vamana worker: dispatching batch on index $relid with 4 search threads/,
		'dispatch log confirms 4 search threads reached SVS');
}

# ---------------------------------------------------------------------------
# 2. Reapplied every dispatch, not cached at load time: changing the catalog
# value takes effect on the very next search, with no index reload.
# ---------------------------------------------------------------------------
{
	$node->safe_psql('postgres',
		"UPDATE vamana_databases SET search_num_threads = 7 WHERE datname = 'postgres';"
	);
	my $granted = wait_for_granted($node, 'postgres', 7);
	is($granted, '7', 'search_threads_granted reaches 7 after catalog update');

	my $log_pos = length($node->log_content());
	my $r = run_search();
	isnt($r, '', 'search returns results with search_num_threads=7');

	my $log = substr($node->log_content(), $log_pos);
	like($log,
		qr/vamana worker: dispatching batch on index $relid with 7 search threads/,
		'dispatch log confirms the revised grant (7) reached SVS on the very next dispatch');
	unlike($log, qr/loading vamana index $relid/,
		'no index reload occurred: the new grant took effect on the already-cached handle');
}

# ---------------------------------------------------------------------------
# 3. One number per database: two different indexes dispatched in the same
# cycle both get the same count.
# ---------------------------------------------------------------------------
{
	$node->safe_psql('postgres', qq(
		CREATE TABLE sga_tbl2 (id serial PRIMARY KEY, val vector($dim));
		INSERT INTO sga_tbl2 (val)
			SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 300) i;
		CREATE INDEX sga_idx2 ON sga_tbl2 USING vamana (val vector_l2_ops);
	));
	my $relid2 = $node->safe_psql('postgres', "SELECT 'sga_idx2'::regclass::oid;");

	$node->safe_psql('postgres',
		"UPDATE vamana_databases SET search_num_threads = 3 WHERE datname = 'postgres';"
	);
	my $granted = wait_for_granted($node, 'postgres', 3);
	is($granted, '3', 'search_threads_granted reaches 3 after catalog update');

	my $log_pos = length($node->log_content());
	isnt(run_search(), '', 'search on first index returns results with search_num_threads=3');
	my $r2 = $node->safe_psql('postgres', qq(
		SET enable_seqscan = off;
		SELECT id FROM sga_tbl2 ORDER BY val <-> '[$query_sql]' LIMIT 5;
	));
	isnt($r2, '', 'search on second index returns results with search_num_threads=3');

	my $log = substr($node->log_content(), $log_pos);
	like($log,
		qr/vamana worker: dispatching batch on index $relid with 3 search threads/,
		'first index dispatched with the database-wide grant (3)');
	like($log,
		qr/vamana worker: dispatching batch on index $relid2 with 3 search threads/,
		'second index dispatched with the same database-wide grant (3), not a per-index value');
}

# ---------------------------------------------------------------------------
# 4. Unconfigured default is 1, not nproc-1: this is the behavior the bug
# report names explicitly.
# ---------------------------------------------------------------------------
{
	$node->safe_psql('postgres',
		"UPDATE vamana_databases SET search_num_threads = NULL WHERE datname = 'postgres';"
	);
	my $granted = wait_for_granted($node, 'postgres', 1);
	is($granted, '1',
		'search_threads_granted resolves to 1, not nproc-1, with nothing configured');

	my $log_pos = length($node->log_content());
	isnt(run_search(), '', 'search returns results with search_num_threads unconfigured');

	my $log = substr($node->log_content(), $log_pos);
	like($log,
		qr/vamana worker: dispatching batch on index $relid with 1 search threads/,
		'dispatch log confirms search ran at 1 thread, not nproc-1, when unconfigured');
}

# ---------------------------------------------------------------------------
# 5. The load path: a freshly loaded index (from a cold worker cache) picks
# up the current grant.
# ---------------------------------------------------------------------------
{
	$node->safe_psql('postgres',
		"UPDATE vamana_databases SET search_num_threads = 5 WHERE datname = 'postgres';"
	);
	my $granted = wait_for_granted($node, 'postgres', 5);
	is($granted, '5', 'search_threads_granted reaches 5 before the reload test');

	# A restart leaves the worker cache cold; nothing preloads eagerly.  It
	# also leaves the launcher's freshly restarted worker not yet "live" on
	# the launcher's very first post-restart reconcile pass, so that pass
	# floors this database's grant at 0; nothing then wakes a second pass
	# for up to the 180s naptime.  A no-op catalog write (re-asserting the
	# same value) fires the vamana_databases_changed NOTIFY and forces a
	# prompt reconcile once the worker is live, exactly as a real config
	# change would.
	$node->restart;
	wait_for_worker($node);
	$node->safe_psql('postgres',
		"UPDATE vamana_databases SET search_num_threads = 5 WHERE datname = 'postgres';"
	);
	$granted = wait_for_granted($node, 'postgres', 5);
	is($granted, '5', 'search_threads_granted reaches 5 again after the worker restart');

	my $log_pos = length($node->log_content());
	$node->safe_psql('postgres', "SELECT svs_warmup_index('sga_idx');");

	my $log = substr($node->log_content(), $log_pos);
	like($log, qr/loading vamana index $relid/,
		'svs_warmup_index forces a load from disk (cache was cold after restart)');
	like($log, qr/loading SVS index with 5 search threads/,
		"the freshly loaded handle's thread count matches the grant (5), not nproc-1");
}

# ---------------------------------------------------------------------------
# 6. Skipped when unchanged: SVSSetIndexSearchThreads runs (and logs) on the
# first dispatch that applies a given thread count, then is skipped on a
# later dispatch for the same index as long as the grant has not moved.
# ---------------------------------------------------------------------------
{
	my $log_pos = length($node->log_content());
	isnt(run_search(), '', 'first search after the reload returns results');

	my $log = substr($node->log_content(), $log_pos);
	like($log,
		qr/vamana worker: dispatching batch on index $relid with 5 search threads/,
		'first dispatch after the reload logs the applied thread count');

	$log_pos = length($node->log_content());
	isnt(run_search(), '', 'second search with the same grant returns results');

	$log = substr($node->log_content(), $log_pos);
	unlike($log,
		qr/vamana worker: dispatching batch on index $relid with \d+ search threads/,
		'second dispatch with an unchanged grant does not repeat the apply');
}

# ---------------------------------------------------------------------------
# Search-scratch gate collision: the search-scratch admission check and the
# thread-grant apply share VamanaWorkerDispatchBatch. A batch the
# search-scratch check refuses must never reach the thread-grant apply; a
# batch it admits must still get the grant applied normally.
# ---------------------------------------------------------------------------
{
	# The default svs.search_window_size makes one query's real cost too
	# small for any plausible batch to exceed the 1 MB minimum
	# search_work_mem; inflate it, matching how 27_search_scratch_
	# accounting.pl sizes the same probe.
	$node->safe_psql('postgres', "ALTER SYSTEM SET svs.search_window_size = 10000;");
	$node->safe_psql('postgres', "SELECT pg_reload_conf();");

	my ($probe_session, $probe_client_pid, $probe_worker_pid) =
		park_search_scratch_reservation($node, 'postgres', qq(
			SET enable_seqscan = off;
			SELECT id FROM sga_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;
		));
	isnt($probe_worker_pid, '', 'collision: a probe search parks with its cost admitted');

	my $cost_bytes = search_scratch_cost_for_relid($node, 'postgres', $relid);
	cmp_ok($cost_bytes, '>', 0, 'collision: the probe reports a positive per-query cost');

	release_search_scratch_reservation($node, 'postgres', $probe_session);
	is(wait_for_search_scratch_in_flight($node, 'postgres', '0'), '0',
		'collision: nothing left in flight after the probe');

	my $cost_mb = int(($cost_bytes + 1024 * 1024 - 1) / (1024 * 1024));
	$cost_mb = 1 if $cost_mb < 1;

	my $collision_batch_n = 60;
	my @collision_query_vecs =
		map { join(",", map { sprintf("%.6f", rand()) } 1 .. $dim) } 1 .. $collision_batch_n;
	my $collision_search_sql = sub {
		my ($i) = @_;
		return "SELECT id FROM sga_tbl ORDER BY val <-> '[$collision_query_vecs[$i]]' LIMIT 5;\n";
	};

	# Rejection side: a budget that admits one query but not $collision_batch_n
	# of them together. The refusal must come from the search-scratch gate,
	# and no refused dispatch may reach the thread-grant apply.
	$node->safe_psql('postgres',
		"UPDATE vamana_databases SET search_work_mem = $cost_mb WHERE datname = 'postgres';");

	my $log_pos = length($node->log_content());
	my @refused_results = run_synchronized(
		$node, 'postgres', $collision_batch_n,
		sub { return "SET enable_seqscan = off;\n"; },
		$collision_search_sql);
	ok((grep { $_ eq '' } @refused_results),
		"collision: at least one of $collision_batch_n synchronized queries is refused "
	  . "once their combined cost exceeds the search-scratch budget");

	my $refusal_log = substr($node->log_content(), $log_pos);
	like($refusal_log, qr/exceeds this database's search-scratch budget/,
		'collision: the refusal names the search-scratch budget');
	unlike($refusal_log, qr/vamana worker: dispatching batch on index $relid with \d+ search threads/,
		'collision: a refused dispatch never reaches the thread-grant apply');

	is(wait_for_search_scratch_in_flight($node, 'postgres', '0'), '0',
		'collision: nothing left in flight after the refused batch');

	# Admission side: raise the budget comfortably and change the thread
	# grant, so the apply log is guaranteed to fire fresh on this dispatch
	# (Case 6: it is skipped when the grant is unchanged from a prior one).
	$node->safe_psql('postgres',
		"UPDATE vamana_databases SET search_work_mem = " . ($cost_mb * ($collision_batch_n + 1)) .
		", search_num_threads = 3 WHERE datname = 'postgres';");
	is(wait_for_granted($node, 'postgres', 3), '3', 'collision: search_threads_granted reaches 3');

	$log_pos = length($node->log_content());
	my @admitted_results = run_synchronized(
		$node, 'postgres', $collision_batch_n,
		sub { return "SET enable_seqscan = off;\n"; },
		$collision_search_sql);
	ok(!(grep { $_ eq '' } @admitted_results),
		"collision: the same $collision_batch_n-way batch succeeds once the budget comfortably covers it");

	my $admit_log = substr($node->log_content(), $log_pos);
	like($admit_log, qr/vamana worker: dispatching batch on index $relid with 3 search threads/,
		'collision: the thread grant is applied once the scratch gate admits the batch');

	is(wait_for_search_scratch_in_flight($node, 'postgres', '0'), '0',
		'collision: nothing left in flight once the admitted batch completes');

	$node->safe_psql('postgres',
		"UPDATE vamana_databases SET search_work_mem = NULL WHERE datname = 'postgres';");
}

$node->stop;

# ---------------------------------------------------------------------------
# 7. Role parity: SvsComputeCpuGrants is pure, so reconcile must produce
# identical desired/granted/reserved search-thread grants on a standby as on
# a primary for the same enabled-database row.
# ---------------------------------------------------------------------------
{
	my $primary = PostgreSQL::Test::Cluster->new('search_grant_parity_primary');
	$primary->init(allows_streaming => 1);
	$primary->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
	$primary->append_conf('postgresql.conf', "wal_level = logical");
	$primary->append_conf('postgresql.conf', "max_replication_slots = 10");
	$primary->append_conf('postgresql.conf', "max_wal_senders = 10");
	$primary->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
	$primary->start;

	$primary->safe_psql('postgres', "CREATE EXTENSION vector;");
	$primary->safe_psql('postgres', "CREATE EXTENSION svs;");
	$primary->safe_psql('postgres', qq(
		INSERT INTO vamana_databases (datname, enabled, search_num_threads, search_threads_reserved)
			VALUES ('postgres', true, 5, 2);
	));
	wait_for_worker($primary);
	is(wait_for_granted($primary, 'postgres', 5), '5',
		'primary reaches the expected grant before comparing to the standby');

	$primary->safe_psql('postgres',
		"SELECT pg_create_physical_replication_slot('parity_phys');");

	my $backup_name = 'parity_backup';
	$primary->backup($backup_name);

	my $standby = PostgreSQL::Test::Cluster->new('search_grant_parity_standby');
	$standby->init_from_backup($primary, $backup_name, has_streaming => 1);
	$standby->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
	$standby->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
	$standby->append_conf('postgresql.conf', "hot_standby = on");
	$standby->append_conf('postgresql.conf', "hot_standby_feedback = on");
	$standby->append_conf('postgresql.conf', "primary_slot_name = 'parity_phys'");
	$standby->start;

	$primary->wait_for_replay_catchup($standby);
	is(wait_for_granted($standby, 'postgres', 5), '5',
		'standby reaches the same grant as the primary');

	my $primary_row = $primary->safe_psql('postgres',
		"SELECT search_threads_desired, search_threads_granted, search_threads_reserved "
	  . "FROM pg_stat_vamana_worker "
	  . "WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');");
	my $standby_row = $standby->safe_psql('postgres',
		"SELECT search_threads_desired, search_threads_granted, search_threads_reserved "
	  . "FROM pg_stat_vamana_worker "
	  . "WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');");

	is($standby_row, $primary_row,
		'reconcile gives identical desired/granted/reserved grants on standby and primary');

	$standby->stop;
	$primary->stop;
}

# ---------------------------------------------------------------------------
# 8. Multi-database grant identity: each database gets its own grant, not a
# sibling's.
# ---------------------------------------------------------------------------
{
	my $node2 = PostgreSQL::Test::Cluster->new('search_grant_identity');
	$node2->init;
	$node2->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
	$node2->append_conf('postgresql.conf', "wal_level = logical");
	$node2->append_conf('postgresql.conf', "max_replication_slots = 10");
	$node2->append_conf('postgresql.conf', "max_wal_senders = 10");
	$node2->append_conf('postgresql.conf', "max_parallel_workers = 32");
	$node2->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
	$node2->append_conf('postgresql.conf', "svs.max_residency_memory = '400MB'");
	$node2->append_conf('postgresql.conf', "svs.max_search_work_mem = '400MB'");
	$node2->start;

	$node2->safe_psql('postgres', "CREATE EXTENSION vector;");
	$node2->safe_psql('postgres', "CREATE EXTENSION svs;");
	$node2->safe_psql('postgres', "CREATE DATABASE sgi_a;");
	$node2->safe_psql('postgres', "CREATE DATABASE sgi_b;");
	$node2->safe_psql('sgi_a', "CREATE EXTENSION vector;");
	$node2->safe_psql('sgi_a', "CREATE EXTENSION svs;");
	$node2->safe_psql('sgi_b', "CREATE EXTENSION vector;");
	$node2->safe_psql('sgi_b', "CREATE EXTENSION svs;");

	$node2->safe_psql('postgres', qq(
		INSERT INTO vamana_databases (datname, enabled, search_num_threads) VALUES
			('sgi_a', true, 3),
			('sgi_b', true, 7);
	));

	wait_for_worker_db($node2, 'sgi_a', 30);
	wait_for_worker_db($node2, 'sgi_b', 30);

	is(wait_for_granted($node2, 'sgi_a', 3), '3',
		'sgi_a gets its own grant (3), not its sibling\'s');
	is(wait_for_granted($node2, 'sgi_b', 7), '7',
		'sgi_b gets its own grant (7), not its sibling\'s');

	$node2->stop;
}

done_testing();
