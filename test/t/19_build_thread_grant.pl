# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 19_build_thread_grant.pl — CPU-governed build-thread grants (Stage 2, Group A).
#
# Before building, CREATE INDEX asks the already-running launcher for a
# build-thread grant, reserves that many parked ParallelContext workers so
# PostgreSQL's own pool accounting sees them, builds, then releases both.
# These tests drive that round trip against the real launcher: the
# reservation's visibility in pg_stat_activity during the build and its
# cleanup afterward, that repeated builds never exhaust the fixed
# pending-request slots, and the zero-default fix (Task 8) at the full-stack
# level rather than the isolated function tested elsewhere.

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

my $node = PostgreSQL::Test::Cluster->new('build_thread_grant');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres', "CREATE EXTENSION injection_points;");
$node->safe_psql('postgres',
	"INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

my $worker_pid = wait_for_worker($node);
ok($worker_pid =~ /^\d+$/, 'worker is running before any build');

# ---------------------------------------------------------------------------
# Every parked worker for a build self-describes via application_name (its
# bgw_type is fixed to "parallel worker" by core and cannot be changed --
# see svs_slot_naming.c), each with its own distinct slot index.  Checked
# from this session, a connection separate from the build itself: that
# separation matters, not just style -- pg_stat_activity.application_name
# for another backend's parallel workers is only reliably observable from
# outside that backend's own connection.
# ---------------------------------------------------------------------------
sub check_build_slot_appnames
{
	my ($node, $build_pid, $expected_total, $test_name) = @_;

	my $appnames_out = $node->safe_psql('postgres',
		"SELECT application_name FROM pg_stat_activity "
	  . "WHERE backend_type = 'parallel worker' AND leader_pid = $build_pid "
	  . "ORDER BY application_name;");
	my @appnames = split /\n/, $appnames_out;

	my @slot_indexes;
	my $pattern = "^vamana: build slot (\\d+)/$expected_total "
	  . "\\(requested $expected_total, granted $expected_total\\) db=postgres\$";
	for my $name (@appnames)
	{
		push @slot_indexes, $1 if $name =~ /$pattern/;
	}
	is(scalar(@slot_indexes), $expected_total,
		"$test_name: application_name format matches for all $expected_total workers");

	my @sorted = sort { $a <=> $b } @slot_indexes;
	is_deeply(\@sorted, [1 .. $expected_total],
		"$test_name: slot indexes are a permutation of 1..$expected_total, not all the same");
}

# ---------------------------------------------------------------------------
# A build reserves exactly its granted thread count as parked parallel
# workers for the build's duration, and releases them once it finishes.
# ---------------------------------------------------------------------------
{
	$node->safe_psql('postgres',
		"UPDATE vamana_databases SET maintenance_num_threads = 2 WHERE datname = 'postgres';"
	);
	$node->safe_psql('postgres',
		"SELECT injection_points_attach('svs-build-thread-grant-acquired', 'wait');"
	);

	my $build = $node->background_psql('postgres', on_error_stop => 1);
	my $pid_out = $build->query('SELECT pg_backend_pid()');
	my ($build_pid) = $pid_out =~ /(\d+)/;

	$build->query_until(qr/build_started/, qq(
		\\echo build_started
		CREATE TABLE btg_tbl (id serial PRIMARY KEY, val vector(8));
		INSERT INTO btg_tbl (val)
			SELECT ARRAY[random(),random(),random(),random(),
						 random(),random(),random(),random()]::vector(8)
			FROM generate_series(1, 50);
		CREATE INDEX btg_idx ON btg_tbl USING vamana (val vector_l2_ops);
	));

	$node->wait_for_event('client backend', 'svs-build-thread-grant-acquired');

	my $parked = $node->safe_psql('postgres',
		"SELECT count(*) FROM pg_stat_activity "
	  . "WHERE backend_type = 'parallel worker' AND leader_pid = $build_pid;");
	is($parked, '2',
		'build reserves exactly its granted thread count as parked parallel workers');

	check_build_slot_appnames($node, $build_pid, 2, 'maintenance_num_threads = 2');

	$node->safe_psql('postgres',
		"SELECT injection_points_wakeup('svs-build-thread-grant-acquired');");
	$build->query('SELECT 1');
	$build->quit;

	my $parked_after = $node->safe_psql('postgres',
		"SELECT count(*) FROM pg_stat_activity "
	  . "WHERE backend_type = 'parallel worker' AND leader_pid = $build_pid;");
	is($parked_after, '0', 'parked workers are released once the build completes');

	$node->safe_psql('postgres',
		"SELECT injection_points_detach('svs-build-thread-grant-acquired');");
}

# ---------------------------------------------------------------------------
# The build-slot application_name formatter (SvsFormatBuildSlotAppName)
# shares its counts-first ordering and ASCII-sanitizing with the
# search-slot formatter, but has its own caller (svs_parallel_build.c) and
# its own truncation math, so it gets its own adversarial datname coverage
# rather than relying on the search-slot cases in
# test/t/25_slot_self_description.pl.  Drives a single-threaded build to
# completion on a database with the given name, paused via the same
# injection point as the case above, and checks the one parked worker's
# application_name.
# ---------------------------------------------------------------------------
sub check_adversarial_build_appname
{
	my ($node, $dbname, $expect_appname_qr, $test_name) = @_;

	$node->safe_psql('postgres', qq(CREATE DATABASE "$dbname";));
	$node->safe_psql('postgres',
		"INSERT INTO vamana_databases (datname, enabled) VALUES ('$dbname', true);");
	wait_for_worker_db($node, $dbname);

	# SvsDatabasesGetMyMaintenanceNumThreads() resolves maintenance_num_threads
	# via SPI with "WHERE datname = current_database()", against whichever
	# database the build itself runs in -- a separate, local copy of
	# vamana_databases from the launcher's own copy in 'postgres' above,
	# which only registers the database with the launcher.
	$node->safe_psql($dbname, qq(
		CREATE EXTENSION vector;
		CREATE EXTENSION svs;
		INSERT INTO vamana_databases (datname, enabled, maintenance_num_threads)
			VALUES ('$dbname', true, 1);
	));
	$node->safe_psql('postgres',
		"SELECT injection_points_attach('svs-build-thread-grant-acquired', 'wait');"
	);

	# Connects directly to $dbname rather than to 'postgres' and then \c-ing
	# over: \c is a line-oriented meta-command, and a datname containing a
	# raw newline (case below) splits its quoted argument across what psql
	# sees as two separate input lines, breaking the reconnect. Passing
	# $dbname as the connection parameter instead goes through libpq's
	# connection handling, which raises no such problem for any of this
	# file's adversarial names (proven already by the plain SQL statements
	# and the $dbname-as-parameter safe_psql call above).
	my $build = $node->background_psql($dbname, on_error_stop => 1);
	my $pid_out = $build->query('SELECT pg_backend_pid()');
	my ($build_pid) = $pid_out =~ /(\d+)/;

	$build->query_until(qr/build_started/, qq(
		\\echo build_started
		CREATE TABLE btg_tbl (id serial PRIMARY KEY, val vector(8));
		INSERT INTO btg_tbl (val)
			SELECT ARRAY[random(),random(),random(),random(),
						 random(),random(),random(),random()]::vector(8)
			FROM generate_series(1, 50);
		CREATE INDEX btg_idx ON btg_tbl USING vamana (val vector_l2_ops);
	));

	$node->wait_for_event('client backend', 'svs-build-thread-grant-acquired');

	my $appname = $node->safe_psql('postgres',
		"SELECT application_name FROM pg_stat_activity "
	  . "WHERE backend_type = 'parallel worker' AND leader_pid = $build_pid;");
	chomp $appname;
	like($appname, qr/^vamana: build slot 1\/1 \(requested 1, granted 1\)/,
		"$test_name: build slot counts are intact");
	like($appname, $expect_appname_qr,
		"$test_name: build slot application_name matches expected sanitized db name");

	$node->safe_psql('postgres',
		"SELECT injection_points_wakeup('svs-build-thread-grant-acquired');");
	$build->query('SELECT 1');
	$build->quit;

	$node->safe_psql('postgres',
		"SELECT injection_points_detach('svs-build-thread-grant-acquired');");

	# Disable and wait for the per-database worker to exit before dropping:
	# DROP DATABASE fails while any other backend, including that worker,
	# still holds a connection to it.
	$node->safe_psql('postgres',
		"UPDATE vamana_databases SET enabled = false WHERE datname = '$dbname';");
	my $alive = '?';
	for (1 .. 60)    # up to 30s for the graceful drain to finish
	{
		usleep(500_000);
		$alive = $node->safe_psql('postgres',
			"SELECT count(*) FROM pg_stat_activity "
		  . "WHERE backend_type = 'vamana worker' AND datname = '$dbname';");
		chomp $alive;
		last if $alive eq '0';
	}

	# The worker's own replication slot outlives the worker; core refuses to
	# drop a database that still has one attached, so it has to go first
	# (matching test_svs_ext_regression.sh's own teardown of
	# contrib_regression's slot before dropping that database).
	$node->safe_psql('postgres',
		"SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots "
	  . "WHERE database = '$dbname';");

	# DROP DATABASE, not just DELETE the catalog row: vamana_databases has a
	# reject-delete-with-live-indexes trigger, and this database's build
	# just created one (btg_idx), so deleting the row first would be
	# rejected. Dropping the database removes the index along with it,
	# leaving nothing for a later DELETE of the now-unreferenced row to
	# reject.
	$node->safe_psql('postgres', qq(DROP DATABASE "$dbname";));
	$node->safe_psql('postgres',
		"DELETE FROM vamana_databases WHERE datname = '$dbname';");
}

# Numbers survive a long database name in a build slot's application_name,
# the same truncation guard proven for search slots in
# test/t/25_slot_self_description.pl.
{
	my $longdb = "longbuilddb_" . ("x" x 51);    # 63 chars, NAMEDATALEN - 1
	my $prefix = substr($longdb, 0, 10);
	check_adversarial_build_appname($node, $longdb, qr/db=\Q$prefix\E/,
		'long datname');
}

# A control character in datname reaches a build slot's application_name
# only in pg_clean_ascii's escaped \xXX form, never as a raw control byte.
{
	# Short on purpose: the build-slot prefix ("vamana: build slot 1/1
	# (requested 1, granted 1) db=") leaves less room before NAMEDATALEN
	# truncation than the search-slot prefix does, and truncation of a
	# long datname is already covered by the case above; this case is
	# only about sanitizing, so it must fit well inside that room intact.
	my $nldb = "nl\ndb";
	check_adversarial_build_appname($node, $nldb, qr/db=nl\\x0adb/,
		'newline datname');
}

# A literal '%' in datname is preserved as-is in a build slot's
# application_name, proving no format confusion was introduced.
{
	my $pctdb = "pct100%db";
	check_adversarial_build_appname($node, $pctdb, qr/db=pct100%db/,
		'percent datname');
}

# ---------------------------------------------------------------------------
# The pending-build-request list has a fixed 8 slots per database
# (SVS_MAX_PENDING_BUILDS).  A build's slot must be released once it
# completes, not just once it is granted -- otherwise the ninth sequential
# build in the same database would find every slot still occupied.
# ---------------------------------------------------------------------------
{
	my $exhausted_at;
	for my $i (1 .. 9)
	{
		my ($ret, $stdout, $stderr) = $node->psql('postgres', qq(
			DROP TABLE IF EXISTS btg_loop_t;
			CREATE TABLE btg_loop_t (id serial PRIMARY KEY, val vector(3));
			INSERT INTO btg_loop_t (val) VALUES ('[0,0,0]'), ('[1,1,1]'), ('[2,2,2]');
			CREATE INDEX ON btg_loop_t USING vamana (val vector_l2_ops);
		));
		if ($stderr =~ /no free build-thread request slot/)
		{
			$exhausted_at = $i;
			last;
		}
	}
	ok(!defined($exhausted_at),
		'9 sequential builds (one more than the 8 fixed slots) never exhaust them'
	) or diag("slots exhausted on iteration $exhausted_at");
}

# ---------------------------------------------------------------------------
# maintenance_num_threads = 0 means serial (1 thread), not nproc-1 (Task 8),
# verified here at the full request/grant/reservation round trip rather than
# just the isolated SVSDefaultBuildThreads() function.
# ---------------------------------------------------------------------------
{
	$node->safe_psql('postgres',
		"UPDATE vamana_databases SET maintenance_num_threads = 0 WHERE datname = 'postgres';"
	);
	$node->safe_psql('postgres',
		"SELECT injection_points_attach('svs-build-thread-grant-acquired', 'wait');"
	);

	my $build = $node->background_psql('postgres', on_error_stop => 1);
	my $pid_out = $build->query('SELECT pg_backend_pid()');
	my ($build_pid) = $pid_out =~ /(\d+)/;

	$build->query_until(qr/build_started/, qq(
		\\echo build_started
		CREATE TABLE btg_zero_tbl (id serial PRIMARY KEY, val vector(3));
		INSERT INTO btg_zero_tbl (val) VALUES ('[0,0,0]'), ('[1,1,1]');
		CREATE INDEX btg_zero_idx ON btg_zero_tbl USING vamana (val vector_l2_ops);
	));

	$node->wait_for_event('client backend', 'svs-build-thread-grant-acquired');

	my $parked = $node->safe_psql('postgres',
		"SELECT count(*) FROM pg_stat_activity "
	  . "WHERE backend_type = 'parallel worker' AND leader_pid = $build_pid;");
	is($parked, '1',
		'maintenance_num_threads = 0 resolves to exactly 1 reserved thread, not nproc-1');

	check_build_slot_appnames($node, $build_pid, 1, 'maintenance_num_threads = 0');

	$node->safe_psql('postgres',
		"SELECT injection_points_wakeup('svs-build-thread-grant-acquired');");
	$build->query('SELECT 1');
	$build->quit;

	$node->safe_psql('postgres',
		"SELECT injection_points_detach('svs-build-thread-grant-acquired');");
}

# ---------------------------------------------------------------------------
# If the launcher never gets to publish a grant, the waiting backend must
# time out rather than hang.  Stalling PublishCpuGrants itself -- the
# launcher's one and only path to a grant -- makes that deterministic instead
# of racing a real launcher hang.
# ---------------------------------------------------------------------------
{
	$node->safe_psql('postgres', "ALTER SYSTEM SET svs.worker_timeout_ms = 100;");
	$node->safe_psql('postgres', "SELECT pg_reload_conf();");
	$node->safe_psql('postgres',
		"SELECT injection_points_attach('svs-build-thread-grant-publish', 'wait');"
	);

	my ($ret, $stdout, $stderr) = $node->psql('postgres', qq(
		CREATE TABLE btg_timeout_tbl (id serial PRIMARY KEY, val vector(3));
		INSERT INTO btg_timeout_tbl (val) VALUES ('[0,0,0]'), ('[1,1,1]');
		CREATE INDEX ON btg_timeout_tbl USING vamana (val vector_l2_ops);
	));
	like($stderr, qr/no build-thread grant from the launcher within \d+ ms/,
		'CREATE INDEX times out when the launcher never publishes a grant');

	$node->safe_psql('postgres',
		"SELECT injection_points_wakeup('svs-build-thread-grant-publish');");
	$node->safe_psql('postgres',
		"SELECT injection_points_detach('svs-build-thread-grant-publish');");
	$node->safe_psql('postgres', "ALTER SYSTEM RESET svs.worker_timeout_ms;");
	$node->safe_psql('postgres', "SELECT pg_reload_conf();");
}

$node->stop;

done_testing();
