# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 28_build_memory_calibration.pl — regression guard for the resident-bytes
# measurement path. For each storage type (no compression, LeanVec, LVQ), a
# built-and-loaded index must report a plausible non-zero resident_bytes, and
# that figure must grow with row count in the expected direction. This does
# not assert anything about a memory estimate: nothing in the extension
# computes one yet.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

my $node = PostgreSQL::Test::Cluster->new('build_memory_calibration');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 10");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "svs.max_residency_memory = '800MB'");
$node->append_conf('postgresql.conf', "svs.default_residency_memory = '800MB'");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres',
    "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");
wait_for_worker($node);

my $test_dim = 32;

# resident_bytes for a built-and-loaded index of the given storage type and
# row count. random() vectors are sufficient: the resident footprint depends
# on count, dimensions, graph degree and storage type, not vector content.
sub resident_bytes_for
{
    my ($compression_type, $rows, $suffix) = @_;
    my $table = "calib_tbl_$suffix";
    my $index = "calib_idx_$suffix";

    $node->safe_psql('postgres', qq(
        CREATE TABLE $table (id serial PRIMARY KEY, val vector($test_dim));
        INSERT INTO $table (val)
            SELECT ARRAY(SELECT random() FROM generate_series(1, $test_dim))::vector
            FROM generate_series(1, $rows);
        CREATE INDEX $index ON $table USING vamana (val vector_l2_ops)
            WITH (graph_degree = 32, compression_type = $compression_type);
    ));
    $node->safe_psql('postgres', "SELECT svs_warmup_index('$index');");

    my $bytes = $node->safe_psql('postgres',
        "SELECT resident_bytes FROM svs_index_residency "
      . "WHERE index_relid = '$index'::regclass;");
    chomp $bytes;
    return $bytes;
}

# Storage type 0 (no compression): a plausible non-zero footprint at small
# scale, and growth with row count in the expected direction.
{
    my $small = resident_bytes_for(0, 500, 'none_small');
    my $large = resident_bytes_for(0, 2000, 'none_large');

    ok($small > 0, 'compression_type=0: small build reports non-zero resident_bytes');
    ok($large > $small,
        'compression_type=0: resident_bytes grows with row count');
}

# Storage type 1 (LeanVec): trips the recall WARNING at this scale, which is
# expected and not a failure; the build must still succeed and report a
# plausible non-zero, growing resident_bytes.
{
    my $small = resident_bytes_for(1, 500, 'leanvec_small');
    my $large = resident_bytes_for(1, 2000, 'leanvec_large');

    ok($small > 0, 'compression_type=1 (LeanVec): small build reports non-zero resident_bytes');
    ok($large > $small,
        'compression_type=1 (LeanVec): resident_bytes grows with row count');
}

# Storage type 2 (LVQ): also trips its own recall WARNING at this scale.
{
    my $small = resident_bytes_for(2, 500, 'lvq_small');
    my $large = resident_bytes_for(2, 2000, 'lvq_large');

    ok($small > 0, 'compression_type=2 (LVQ): small build reports non-zero resident_bytes');
    ok($large > $small,
        'compression_type=2 (LVQ): resident_bytes grows with row count');
}

$node->stop;

done_testing();
