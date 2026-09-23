# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 32_build_memory_gate.pl — the build-memory admission gate refuses a build
# whose estimated peak exceeds svs.max_build_memory, before any large
# allocation, with an error naming the GUC.  Also exercises the
# unmeasured-dimension upper-envelope rule: the test table's vector width
# (VamanaTestUtils' $dim, 16) is not one of the three calibrated dimensions,
# so the refusal below is charged by that fallback, not by an exact-match
# table lookup.

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

$node->stop;

done_testing();
