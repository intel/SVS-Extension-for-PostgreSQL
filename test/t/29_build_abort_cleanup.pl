# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 29_build_abort_cleanup.pl — PG_ENSURE_ERROR_CLEANUP unwind on a governed
# build failure, at both ends of the guarded span.
#
# VamanaBuildSVSIndexGoverned's callers (vamanabuild, VamanaRebuildFromTable)
# wrap the call through their own worker hand-off point in
# PG_ENSURE_ERROR_CLEANUP, whose abort-cleanup callback runs on that unwind.
# Two injection points sit inside that span:
#
#   - vamana-build-governed-pre-allocation, inside
#     VamanaBuildSVSIndexGoverned, after the SVS algorithm/storage/builder
#     triple is created and before the flatten allocation -- the start of
#     the span, before SVSBuildDynamicIndex has run at all.
#   - vamana-build-governed-pre-handoff, in each caller, immediately before
#     the worker hand-off call (VamanaWorkerSubmitLoad in vamanabuild,
#     VamanaCacheIndex in VamanaRebuildFromTable) -- the end of the span,
#     after SVSBuildDynamicIndex has already succeeded.
#
# Both callers share both injection points, so attaching 'error' to either
# forces the same PG_CATCH -> cleanup -> PG_RE_THROW unwind without needing
# a real admission failure or a real build failure.  This file exercises
# CREATE INDEX's span (vamanabuild); VamanaRebuildFromTable shares the same
# two injection points and the same callback, so nothing distinguishes its
# unwind from these.
#
# What this file does not claim: SvsBuildAbortCleanup is a no-op today
# because VamanaBuildSVSIndexGoverned reserves nothing.  A real
# SvsMemoryAbortBuild will need to tell "nothing built yet" (the
# pre-allocation point) apart from "already built, not yet handed off"
# (the pre-handoff point) -- for example, whether the in-process SVS index
# handle itself needs freeing on that second path.  That distinction is the
# real gate's job.  This file only proves the unwind mechanism itself fires
# cleanly, with no crash and no stuck worker, at both points.

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
ok($worker_pid =~ /^\d+$/, 'worker is running before the build-abort tests');

# ---------------------------------------------------------------------------
# check_abort_at: attach 'error' to $injection_point, run CREATE INDEX on a
# fresh table, confirm it fails with exactly that injected error and the
# worker survives, detach, then confirm a retry succeeds cleanly with no
# residue from the aborted build.
# ---------------------------------------------------------------------------
sub check_abort_at
{
	my ($injection_point, $label) = @_;
	my $tbl = "${label}_tbl";
	my $idx = "${label}_idx";

	$node->safe_psql('postgres', qq(
		CREATE TABLE $tbl (id serial PRIMARY KEY, c1 vector($dim));
		INSERT INTO $tbl (c1)
			SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 200) i;
	));

	$node->safe_psql('postgres',
		"SELECT injection_points_attach('$injection_point', 'error');");

	my ($ret, $stdout, $stderr) = $node->psql('postgres',
		"CREATE INDEX $idx ON $tbl USING vamana (c1 vector_l2_ops);");
	isnt($ret, 0, "$label: CREATE INDEX fails when $injection_point is injected to error");
	like($stderr, qr/error triggered for injection point \Q$injection_point\E/,
		"$label: the injected error is what CREATE INDEX reports")
	  or diag("stderr: $stderr");

	my $live_pid = $node->safe_psql('postgres',
		"SELECT pid FROM pg_stat_activity WHERE backend_type = 'vamana worker';");
	chomp $live_pid;
	is($live_pid, $worker_pid,
		"$label: worker survives the injected build failure without restarting");

	$node->safe_psql('postgres',
		"SELECT injection_points_detach('$injection_point');");

	my ($ret2, $stdout2, $stderr2) = $node->psql('postgres',
		"CREATE INDEX $idx ON $tbl USING vamana (c1 vector_l2_ops);");
	is($ret2, 0, "$label: CREATE INDEX succeeds once the injected failure is removed")
	  or diag("stderr: $stderr2");

	my $index_count = $node->safe_psql('postgres',
		"SELECT count(*) FROM pg_indexes WHERE indexname = '$idx';");
	chomp $index_count;
	is($index_count, '1',
		"$label: exactly one $idx exists; the aborted build left nothing behind for the retry to collide with");
}

check_abort_at('vamana-build-governed-pre-allocation', 'pre_allocation');
check_abort_at('vamana-build-governed-pre-handoff', 'pre_handoff');

$node->stop;

done_testing();
