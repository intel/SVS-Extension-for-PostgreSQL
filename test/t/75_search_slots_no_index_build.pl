# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 75_search_slots_no_index_build.pl -- parked search slots and the first build.
#
# A database with no vamana index holds no search claim, so its first
# CREATE INDEX gets the whole pool rather than competing with parked search
# slots that have nothing to search.  Committing the first index (or dropping
# the last) must wake the launcher at once instead of waiting out its naptime.
# A build that starts fewer parallel workers than it was granted says so.

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

my $node = PostgreSQL::Test::Cluster->new('search_slots_no_index_build');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->append_conf('postgresql.conf', "svs.max_residency_memory = '800MB'");
$node->append_conf('postgresql.conf', "svs.max_search_work_mem = '800MB'");
$node->append_conf('postgresql.conf', "svs.search_num_threads = 4");
$node->append_conf('postgresql.conf', "max_parallel_workers = 16");
$node->append_conf('postgresql.conf', "max_worker_processes = 32");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres', "CREATE EXTENSION injection_points;");
$node->safe_psql('postgres',
	"INSERT INTO vamana_databases (datname, enabled, maintenance_num_threads) "
  . "VALUES ('postgres', true, 4);");

ok(wait_for_worker($node) =~ /^\d+$/, 'worker is running');

my $worker_state_sql =
	"SELECT search_threads_granted || ',' || search_slots_registered "
  . "FROM pg_stat_vamana_worker "
  . "WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');";

# Poll until (granted,registered) reads $want, for up to $secs seconds.
sub wait_for_worker_state
{
	my ($want, $secs) = @_;
	my $got = '';

	for (1 .. $secs * 2)
	{
		$got = $node->safe_psql('postgres', $worker_state_sql);
		chomp $got;
		last if $got eq $want;
		usleep(500_000);
	}
	return $got;
}

# Count of "started N of M" warnings in the server log past $offset.
sub shortfall_warnings_since
{
	my ($offset) = @_;
	my $log = PostgreSQL::Test::Utils::slurp_file($node->logfile, $offset);
	my @hits = $log =~ /vamana index build started \d+ of \d+ granted parallel workers/g;

	return scalar(@hits);
}

# ---------------------------------------------------------------------------
# 1. A freshly enrolled database with no index holds no search claim.
# ---------------------------------------------------------------------------
{
	# Let a few launcher cycles pass so a zero is not just "not reconciled yet".
	sleep 3;
	is(wait_for_worker_state('0,0', 10), '0,0',
		'no-index database is granted no search threads and parks no slots');
}

# ---------------------------------------------------------------------------
# 2. The first build under a tight session limit gets its full grant.
# ---------------------------------------------------------------------------
{
	$node->safe_psql('postgres',
		"SELECT injection_points_attach('svs-build-thread-grant-acquired', 'wait');");

	my $log_offset = -s $node->logfile;
	my $build = $node->background_psql('postgres', on_error_stop => 1);
	my ($build_pid) = $build->query('SELECT pg_backend_pid()') =~ /(\d+)/;

	$build->query_until(qr/build_started/, q(
		\echo build_started
		SET max_parallel_workers = 4;
		CREATE TABLE nib_tbl (id serial PRIMARY KEY, val vector(8));
		INSERT INTO nib_tbl (val)
			SELECT ARRAY[random(),random(),random(),random(),
						 random(),random(),random(),random()]::vector(8)
			FROM generate_series(1, 50);
		CREATE INDEX nib_idx ON nib_tbl USING vamana (val vector_l2_ops);
	));

	$node->wait_for_event('client backend', 'svs-build-thread-grant-acquired');

	is( $node->safe_psql('postgres',
			"SELECT count(*) FROM pg_stat_activity "
		  . "WHERE backend_type = 'parallel worker' AND leader_pid = $build_pid;"),
		'4',
		'first build holds its full grant of parked workers');

	$node->safe_psql('postgres',
		"SELECT injection_points_wakeup('svs-build-thread-grant-acquired');");
	$build->query('SELECT 1');
	$build->quit;
	$node->safe_psql('postgres',
		"SELECT injection_points_detach('svs-build-thread-grant-acquired');");

	is(shortfall_warnings_since($log_offset), 0,
		'first build emits no shortfall warning');
}

# ---------------------------------------------------------------------------
# 3. Committing the first index wakes the launcher well inside its naptime.
# ---------------------------------------------------------------------------
is(wait_for_worker_state('4,4', 30), '4,4',
	'search slots are parked within 30s of the first index committing');

# ---------------------------------------------------------------------------
# 4. With the slots parked, a second build under a tight session limit starts
# fewer workers than granted and says so; with room, it is silent.
# ---------------------------------------------------------------------------
{
	my ($ret, $stdout, $stderr) = $node->psql(
		'postgres', q(
		SET max_parallel_workers = 4;
		CREATE INDEX nib_idx2 ON nib_tbl USING vamana (val vector_l2_ops);
	));
	is($ret, 0, 'second build succeeds under a tight session limit');
	like($stderr,
		qr/WARNING:  vamana index build started 0 of 4 granted parallel workers/,
		'shortfall warning reports the started and granted counts');
	like($stderr,
		qr/DETAIL:  The build will use 1 thread; max_parallel_workers is 4\./,
		'shortfall warning reports the thread count and session limit');
	like($stderr, qr/HINT:  .*max_worker_processes/,
		'shortfall warning carries the hint');

	($ret, $stdout, $stderr) = $node->psql(
		'postgres', q(
		SET max_parallel_workers = 16;
		CREATE INDEX nib_idx3 ON nib_tbl USING vamana (val vector_l2_ops);
	));
	is($ret, 0, 'third build succeeds with room in the pool');
	unlike($stderr, qr/granted parallel workers/,
		'no shortfall warning when every granted worker starts');
}

# ---------------------------------------------------------------------------
# 5. Dropping the last index releases the slots promptly.
# ---------------------------------------------------------------------------
{
	$node->safe_psql('postgres', "DROP INDEX nib_idx, nib_idx2, nib_idx3;");
	is(wait_for_worker_state('0,0', 30), '0,0',
		'search slots are released within 30s of the last index dropping');
}

$node->stop;

done_testing();
