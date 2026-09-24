# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 32_build_memory_gate.pl — the build-memory admission gate refuses a build
# whose estimated peak exceeds svs.max_build_memory, before any large
# allocation, with an error naming the GUC.  Also exercises the
# unmeasured-dimension upper-envelope rule: the test table's vector width
# (VamanaTestUtils' $dim, 16) is not one of the three calibrated dimensions,
# so the refusal below is charged by that fallback, not by an exact-match
# table lookup.
#
# Also covers the cheaper pre-scan tripwire ahead of that gate: a build
# refused on reltuples alone, before the heap scan runs.  And covers the
# estimate no longer including a separate scan-buffer term now that
# BuildCallback writes directly into the same flat buffer the build uses.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

my $node = PostgreSQL::Test::Cluster->new('build_memory_gate');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'vector,svs'");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 20");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "svs.max_build_memory = '1MB'");
$node->append_conf('postgresql.conf', "svs.max_residency_memory = '16000MB'");
$node->append_conf('postgresql.conf', "svs.default_residency_memory = '16000MB'");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres',
	"INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");
wait_for_worker($node);

$node->safe_psql('postgres', qq(
	CREATE TABLE gate_tbl (id serial PRIMARY KEY, c1 vector($dim));
	INSERT INTO gate_tbl (c1)
		SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 100) i;
));

my ($ret, $stdout, $stderr) = $node->psql('postgres',
	"CREATE INDEX gate_idx ON gate_tbl USING vamana (c1 vector_l2_ops);");
isnt($ret, 0, 'CREATE INDEX fails when the estimate exceeds svs.max_build_memory');
like($stderr, qr/svs\.max_build_memory/,
	'the refusal names svs.max_build_memory')
  or diag("stderr: $stderr");

my $index_count = $node->safe_psql('postgres',
	"SELECT count(*) FROM pg_indexes WHERE indexname = 'gate_idx';");
chomp $index_count;
is($index_count, '0',
	'the refused build left no index behind, consistent with failing before the flatten/build ever ran');

# Raising the ceiling high enough for this small, unmeasured-dimension build
# to fit proves the previous failure was the gate, not something else in the
# build path.
$node->safe_psql('postgres', "ALTER SYSTEM SET svs.max_build_memory = '4096MB';");
$node->reload;

($ret, $stdout, $stderr) = $node->psql('postgres',
	"CREATE INDEX gate_idx ON gate_tbl USING vamana (c1 vector_l2_ops);");
is($ret, 0, 'the same build succeeds once svs.max_build_memory is raised')
  or diag("stderr: $stderr");
$node->safe_psql('postgres', "DROP INDEX gate_idx;");

# The estimate no longer prices a second, scan-side copy of the vectors:
# BuildCallback writes straight into the same flat buffer the build itself
# uses, so the log's own breakdown of the estimate must not mention a
# scanBuffer term at all.
my $log_pos = length($node->log_content());
$node->safe_psql('postgres', qq(
	SET log_min_messages = debug1;
	CREATE INDEX gate_idx ON gate_tbl USING vamana (c1 vector_l2_ops);
));
my $log = substr($node->log_content(), $log_pos);
unlike($log, qr/scanBuffer/,
	'the double-buffered scan copy no longer contributes to the build memory estimate')
  or diag("log: $log");
$node->safe_psql('postgres', "DROP INDEX gate_idx;");

# The pre-scan estimate uses reltuples, not the real row count, so it can be
# exercised without actually scanning a huge table: inflate reltuples on a
# small table past what its raw vector data alone would need to exceed the
# ceiling.
$node->safe_psql('postgres', qq(
	CREATE TABLE estimate_tbl (id serial PRIMARY KEY, c1 vector($dim));
	INSERT INTO estimate_tbl (c1)
		SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 10) i;
	ANALYZE estimate_tbl;
));

($ret, $stdout, $stderr) = $node->psql('postgres',
	"CREATE INDEX estimate_idx ON estimate_tbl USING vamana (c1 vector_l2_ops);");
is($ret, 0, 'a real small build succeeds under a ceiling large enough for it')
  or diag("stderr: $stderr");
$node->safe_psql('postgres', "DROP INDEX estimate_idx;");

$node->safe_psql('postgres',
	"UPDATE pg_class SET reltuples = 100000000 WHERE relname = 'estimate_tbl';");

($ret, $stdout, $stderr) = $node->psql('postgres',
	"CREATE INDEX estimate_idx ON estimate_tbl USING vamana (c1 vector_l2_ops);");
isnt($ret, 0, 'an inflated reltuples estimate blocks the build before the scan runs');
like($stderr, qr/svs\.max_build_memory/,
	'the pre-scan refusal names svs.max_build_memory too')
  or diag("stderr: $stderr");

my $estimate_index_count = $node->safe_psql('postgres',
	"SELECT count(*) FROM pg_indexes WHERE indexname = 'estimate_idx';");
chomp $estimate_index_count;
is($estimate_index_count, '0',
	'the pre-scan refusal left no index behind either');

$node->stop;

done_testing();
