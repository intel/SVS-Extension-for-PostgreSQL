# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 81_requests_during_save.pl -- requests that reach the worker while its
# main loop is inside an index save wait for the save instead of failing.
#
# The worker serves no request and refreshes no heartbeat while it saves an
# index.  A backend must not count that time against svs.worker_timeout_ms,
# nor read the paused heartbeat as a hung worker.  The save is held open
# here with an injection point on the checkpoint path.
#
# Tests:
#   An insert queued behind a save longer than svs.worker_timeout_ms
#       succeeds once the save ends.
#   An insert and an index scan issued after the save has outlasted the
#       heartbeat staleness threshold also wait and succeed.
#   A save that outlasts svs.worker_startup_timeout_ms still fails the
#       waiting insert, so a hung save cannot block backends forever.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep time);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

if (($ENV{enable_injection_points} // 'no') ne 'yes')
{
	plan skip_all => 'server not built with --enable-injection-points';
}

my $dim = 16;
my $array_sql = join(",", ('random()') x $dim);
my $point = 'vamana-checkpoint-cached-index-error';
my $checkpoint_ops = 50;

my $node = PostgreSQL::Test::Cluster->new('vamana_requests_during_save');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->append_conf('postgresql.conf', "svs.worker_timeout_ms = 1000");
$node->append_conf('postgresql.conf', "svs.checkpoint_operations = $checkpoint_ops");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres', "CREATE EXTENSION injection_points;");
$node->safe_psql('postgres',
	"INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");
wait_for_worker($node, 30);

$node->safe_psql('postgres', qq{
	CREATE TABLE save_tbl (id serial PRIMARY KEY, val vector($dim));
	INSERT INTO save_tbl (val)
		SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 100) i;
	CREATE INDEX save_idx ON save_tbl USING vamana (val vector_l2_ops);
});
wait_for_worker_db($node, 'postgres', 30);

# Write svs.checkpoint_operations rows to a freshly built index: the worker
# answers the last of them, then starts the save on the same main-loop pass
# and parks on the injection point inside it.
sub start_held_save
{
	my ($table) = @_;

	$node->safe_psql('postgres',
		"SELECT injection_points_attach('$point', 'wait');");
	$node->safe_psql('postgres', qq{
		INSERT INTO $table (val)
			SELECT ARRAY[$array_sql]::vector
			FROM generate_series(1, $checkpoint_ops) i;
	});
	$node->wait_for_event('vamana worker', $point);
}

sub release_held_save
{
	$node->safe_psql('postgres', "SELECT injection_points_wakeup('$point');");
	$node->safe_psql('postgres', "SELECT injection_points_detach('$point');");
}

sub start_request
{
	my ($sql) = @_;
	my $h = $node->background_psql('postgres', on_error_stop => 0);

	$h->query_until(qr/request_sent/, qq{
		\\echo request_sent
		$sql
		\\echo request_done
	});
	return $h;
}

# Wait for a request started by start_request to complete; return its stderr.
sub finish_request
{
	my ($h) = @_;

	$h->{stderr} = '';
	$h->query_until(qr/request_done/, "");
	my $err = $h->{stderr};

	$h->quit;
	return $err;
}

sub insert_sql
{
	my ($table) = @_;

	return "INSERT INTO $table (val) VALUES (ARRAY[$array_sql]::vector);";
}

my $search_sql =
  "SET enable_seqscan = off; "
  . "SELECT count(*) FROM (SELECT id FROM save_tbl "
  . "ORDER BY val <-> ARRAY[$array_sql]::vector LIMIT 10) s;";

# ---------------------------------------------------------------------------
# Requests queued behind, and arriving during, a save longer than both
# svs.worker_timeout_ms and the heartbeat staleness threshold.
# ---------------------------------------------------------------------------
start_held_save('save_tbl');

my $early = start_request(insert_sql('save_tbl'));

# Past svs.worker_timeout_ms (1 s) and VAMANA_HEARTBEAT_STALE_MS (3 s).
usleep(3_500_000);

my $late_insert = start_request(insert_sql('save_tbl'));
my $late_search = start_request($search_sql);

usleep(500_000);
release_held_save();

my $early_err = finish_request($early);
my $late_insert_err = finish_request($late_insert);
my $late_search_err = finish_request($late_search);

is($early_err, '',
	"insert queued behind a save longer than svs.worker_timeout_ms succeeds");
is($late_insert_err, '',
	"insert issued after the save outlasted the heartbeat threshold succeeds");
is($late_search_err, '',
	"index scan issued after the save outlasted the heartbeat threshold succeeds");

# ---------------------------------------------------------------------------
# The wait through a save is still bounded, by svs.worker_startup_timeout_ms.
# A second index starts from a known count of writes since its last save.
# ---------------------------------------------------------------------------
$node->append_conf('postgresql.conf', "svs.worker_startup_timeout_ms = 2000");
$node->reload;

$node->safe_psql('postgres', qq{
	CREATE TABLE bound_tbl (id serial PRIMARY KEY, val vector($dim));
	INSERT INTO bound_tbl (val)
		SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 100) i;
	CREATE INDEX bound_idx ON bound_tbl USING vamana (val vector_l2_ops);
});
start_held_save('bound_tbl');

my $t_bounded = time();
my $bounded = start_request(insert_sql('bound_tbl'));
my $bounded_err = finish_request($bounded);
my $bounded_ms = (time() - $t_bounded) * 1000;

like($bounded_err,
	qr/vamana worker insert failed: vamana worker timed out after \d+ ms waiting for an index save to finish/,
	"insert waiting on a save longer than svs.worker_startup_timeout_ms fails");
cmp_ok($bounded_ms, '<', 10_000,
	"and fails within the bound, not when the save ends ($bounded_ms ms)");

release_held_save();

$node->stop;

done_testing();
