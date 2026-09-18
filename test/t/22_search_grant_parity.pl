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

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

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

done_testing();
