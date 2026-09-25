# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 38_build_large_vector_buffer.pl — SvsVectorBuffer collects every vector of
# a build into one flat array before handing it to the SVS library. At dim
# 1536, that array crosses MaxAllocSize (1 GiB) at ~174,764 rows, well
# within svs.max_build_memory's default ceiling, so SvsVectorBufferInit and
# SvsVectorBufferAppend allocate and grow through the huge-allocation API
# rather than plain palloc/repalloc.
#
# Case 1 forces the initial allocation over the boundary via reltuples,
# without loading anywhere near 1 GiB of real data. Case 2 crosses the
# boundary through real doubling growth on an unanalyzed table; since the
# build-memory admission gate runs only after the heap scan has filled the
# buffer, its refusal (naming svs.max_build_memory, not an alloc-size error)
# is itself the proof that the scan, and the repalloc inside it, completed.
#
# This file exercises only the vector buffer (SvsVectorBufferInit/Append),
# the one conversion reachable at a testable row count. The huge-allocation
# fix applies the same change to five other row-scaled sites (the TID
# buffer/mapping at four call sites, and the id array in
# VamanaRunSVSBuild), which only cross MaxAllocSize at 130 million or more
# rows. Those five are not exercised by any test here or elsewhere; their
# correctness rests on code reading and on sharing the identical
# MemoryContextAllocHuge/repalloc_huge pattern verified by this file, not on
# an observed failure or a passing test at their own scale.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(time);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

my $node = PostgreSQL::Test::Cluster->new('build_large_vector_buffer');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'vector,svs'");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 10");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "svs.max_build_memory = '4096MB'");
$node->append_conf('postgresql.conf', "svs.max_residency_memory = '16000MB'");
$node->append_conf('postgresql.conf', "svs.default_residency_memory = '16000MB'");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres',
	"INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");
my $worker_pid = wait_for_worker($node);
ok($worker_pid =~ /^\d+$/, 'worker is running before either case');
my $worker_state = $node->safe_psql('postgres',
	"SELECT worker_state FROM pg_stat_vamana_worker WHERE worker_pid = $worker_pid;");
chomp $worker_state;
is($worker_state, 'running', 'worker reached the running state, not stuck starting');

# ---------------------------------------------------------------------------
# Case 1 (Trigger A): SvsVectorBufferInit's initial allocation.
#
# Forcing reltuples to 174763 on a real, ANALYZEd table makes the initial
# request 174763 * 1536 * 4 = 1,073,743,872 bytes, just over MaxAllocSize
# (1,073,741,823). Only the rows actually appended become resident, so
# this is cheap despite the 1 GiB virtual request.
# ---------------------------------------------------------------------------
{
	my $dim              = 1536;
	my $rows             = 500;
	my $forced_reltuples = 174763;

	$node->safe_psql('postgres', qq(
		CREATE TABLE case1_tbl (id serial PRIMARY KEY, embedding vector($dim));
		INSERT INTO case1_tbl (embedding)
			SELECT (SELECT array_agg(random()) FROM generate_series(1, $dim))::vector
			FROM generate_series(1, $rows);
		ANALYZE case1_tbl;
		UPDATE pg_class SET reltuples = $forced_reltuples
			WHERE oid = 'case1_tbl'::regclass;
	));

	my ($ret, $stdout, $stderr) = $node->psql('postgres',
		"CREATE INDEX case1_idx ON case1_tbl USING vamana (embedding vector_l2_ops);");
	is($ret, 0,
		'case1: CREATE INDEX succeeds when the initial allocation request exceeds MaxAllocSize')
	  or diag("stderr: $stderr");

	my $nn_count = $node->safe_psql('postgres', qq(
		SELECT count(*) FROM (
			SELECT id FROM case1_tbl
			ORDER BY embedding <-> (SELECT embedding FROM case1_tbl LIMIT 1)
			LIMIT 5
		) s;
	));
	chomp $nn_count;
	is($nn_count, '5',
		'case1: the index built over the boundary still serves a nearest-neighbour query');

	$node->safe_psql('postgres', "DROP INDEX IF EXISTS case1_idx;");
	$node->safe_psql('postgres', "DROP TABLE case1_tbl;");
}

# ---------------------------------------------------------------------------
# Case 2 (Trigger B): SvsVectorBufferAppend's doubling growth.
#
# At dim 2000 (VAMANA_MAX_DIM), the buffer's capacity doubles from its
# default starting point of 1000 as: 1000, 2000, 4000, 8000, 16000, 32000,
# 64000, 128000, 256000. 128000 * 2000 * 4 = 1,024,000,000 bytes (under
# MaxAllocSize); the next doubling, to 256000, requests 256000 * 2000 * 4 =
# 2,048,000,000 bytes (over). That repalloc fires when count reaches the
# prior capacity, i.e. on the 128,001st appended row.
#
# The table is never ANALYZEd, so reltuples stays -1 and
# SvsMemoryCheckEstimatedBuildSize's pre-scan estimate is skipped; only the
# in-scan repalloc is exercised. Vector content doesn't matter since the
# build itself is refused before it runs, so a near-constant vector per row
# is used: cheap to generate and TOAST-compresses well.
# ---------------------------------------------------------------------------
{
	my $dim  = 2000;
	my $rows = 128001;

	my $t_start = time();
	$node->safe_psql('postgres', qq(
		CREATE TABLE case2_tbl (id serial PRIMARY KEY, embedding vector($dim))
			WITH (autovacuum_enabled = false);
	));
	$node->safe_psql('postgres', qq(
		INSERT INTO case2_tbl (embedding)
			SELECT array_fill(i::real, ARRAY[$dim])::vector
			FROM generate_series(1, $rows) i;
	));
	my $t_loaded = time();

	my $reltuples = $node->safe_psql('postgres',
		"SELECT reltuples FROM pg_class WHERE oid = 'case2_tbl'::regclass;");
	chomp $reltuples;
	cmp_ok($reltuples, '<=', 0,
		'case2: the table is never analyzed, so the pre-scan estimate is skipped')
	  or diag("reltuples: $reltuples");

	# High enough that case1's tiny build above was never at risk; low
	# enough that case2's real buildPeak (rawBuffer alone is ~1.9 GiB at
	# the post-growth capacity of 256000) cannot fit.
	$node->safe_psql('postgres', "ALTER SYSTEM SET svs.max_build_memory = '1024MB';");
	$node->reload;
	my $shown_limit = $node->safe_psql('postgres', "SHOW svs.max_build_memory;");
	chomp $shown_limit;
	is($shown_limit, '1GB', 'case2: the lowered svs.max_build_memory took effect');

	my ($ret, $stdout, $stderr) = $node->psql('postgres',
		"CREATE INDEX case2_idx ON case2_tbl USING vamana (embedding vector_l2_ops);");
	my $t_built = time();
	isnt($ret, 0, 'case2: the build is refused');
	like($stderr, qr/svs\.max_build_memory/,
		'case2: the refusal names svs.max_build_memory, proving the scan and its repalloc completed')
	  or diag("stderr: $stderr");
	unlike($stderr, qr/invalid memory alloc request size/,
		'case2: the refusal is not the plain-allocation-limit error')
	  or diag("stderr: $stderr");

	diag(sprintf(
		'case2 wall time: load %.1fs, build attempt %.1fs, total %.1fs',
		$t_loaded - $t_start, $t_built - $t_loaded, $t_built - $t_start));

	$node->safe_psql('postgres', "ALTER SYSTEM SET svs.max_build_memory = '4096MB';");
	$node->reload;

	my $case2_count = $node->safe_psql('postgres',
		"SELECT count(*) FROM pg_indexes WHERE indexname = 'case2_idx';");
	chomp $case2_count;
	is($case2_count, '0', 'case2: the refused build left no index behind');

	$node->safe_psql('postgres', "DROP TABLE case2_tbl;");
}

$node->stop;

done_testing();
