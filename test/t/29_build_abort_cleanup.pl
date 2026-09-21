# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 29_build_abort_cleanup.pl — PG_ENSURE_ERROR_CLEANUP unwind on a governed
# build failure.
#
# VamanaBuildSVSIndexGoverned's callers (vamanabuild, VamanaRebuildFromTable)
# wrap the call through their own worker hand-off point in
# PG_ENSURE_ERROR_CLEANUP, whose abort-cleanup callback runs on that unwind.
# An injection point sits inside VamanaBuildSVSIndexGoverned, after the SVS
# algorithm/storage/builder triple is created and before the flatten
# allocation -- the same shared code both callers' PG_ENSURE_ERROR_CLEANUP
# spans cover -- so attaching 'error' there forces exactly that unwind
# without needing a real admission failure.  This exercises CREATE INDEX's
# span (vamanabuild); VamanaRebuildFromTable shares the same injection point
# and the same callback, so nothing distinguishes its unwind from this one.

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
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres', "CREATE EXTENSION injection_points;");
$node->safe_psql('postgres',
	"INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

my $worker_pid = wait_for_worker($node);
ok($worker_pid =~ /^\d+$/, 'worker is running before the build-abort test');

$node->safe_psql('postgres', qq(
	CREATE TABLE build_abort_tbl (id serial PRIMARY KEY, c1 vector($dim));
	INSERT INTO build_abort_tbl (c1)
		SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 200) i;
));

$node->safe_psql('postgres',
	"SELECT injection_points_attach('vamana-build-governed-pre-allocation', 'error');");

my ($ret, $stdout, $stderr) = $node->psql('postgres',
	"CREATE INDEX build_abort_idx ON build_abort_tbl USING vamana (c1 vector_l2_ops);");
isnt($ret, 0, 'CREATE INDEX fails when the governed build is injected to error');
like($stderr, qr/error triggered for injection point vamana-build-governed-pre-allocation/,
	'the injected error is what CREATE INDEX reports')
  or diag("stderr: $stderr");

my $live_pid = $node->safe_psql('postgres',
	"SELECT pid FROM pg_stat_activity WHERE backend_type = 'vamana worker';");
chomp $live_pid;
is($live_pid, $worker_pid,
	'worker survives the injected build failure without restarting');

$node->safe_psql('postgres',
	"SELECT injection_points_detach('vamana-build-governed-pre-allocation');");

my ($ret2, $stdout2, $stderr2) = $node->psql('postgres',
	"CREATE INDEX build_abort_idx ON build_abort_tbl USING vamana (c1 vector_l2_ops);");
is($ret2, 0, 'CREATE INDEX succeeds once the injected failure is removed')
  or diag("stderr: $stderr2");

my $index_count = $node->safe_psql('postgres',
	"SELECT count(*) FROM pg_indexes WHERE indexname = 'build_abort_idx';");
chomp $index_count;
is($index_count, '1',
	'exactly one build_abort_idx exists; the aborted build left nothing behind for the retry to collide with');

$node->stop;

done_testing();
