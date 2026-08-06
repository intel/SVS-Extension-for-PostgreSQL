# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 13_vamana_f2_permissions.pl -- SDL 211 TC-02: F2 directory permission posture.
#
# Validates that the on-disk index directory created by VamanaEnsureSaveDir
# (src/vamanaio.c:63-80) inherits the postmaster's 0700 permission posture.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

{
    my $node = PostgreSQL::Test::Cluster->new('vamana_f2_perms');
    $node->init;
    $node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
    $node->append_conf('postgresql.conf', "wal_level = logical");
    $node->append_conf('postgresql.conf', "max_replication_slots = 10");
    $node->append_conf('postgresql.conf', "max_wal_senders = 10");
    $node->start;

    my $pgdata = $node->data_dir;

    $node->safe_psql("postgres", "CREATE EXTENSION vector;");
    $node->safe_psql("postgres", "CREATE EXTENSION svs;");

    $node->safe_psql("postgres", qq(
        CREATE TABLE f2_tbl (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO f2_tbl (val)
            SELECT ARRAY[$array_sql]::vector
            FROM generate_series(1, 50) i;
        CREATE INDEX f2_idx ON f2_tbl USING vamana (val vector_l2_ops);
    ));

    my $index_oid = $node->safe_psql("postgres",
        "SELECT oid FROM pg_class WHERE relname = 'f2_idx';");
    chomp $index_oid;

    my $parent_dir = "$pgdata/vamana_indexes";
    my $index_dir  = "$parent_dir/$index_oid";

    # TC-02 bullet 1: directory existence
    ok(-d $parent_dir,
        'vamana_indexes/ parent directory exists after CREATE INDEX');
    ok(-d $index_dir,
        'vamana_indexes/<oid>/ per-index directory exists after CREATE INDEX');

    # TC-02 bullet 1: permission posture (0700 or 0750 if postgres group)
    my @parent_stat = stat($parent_dir);
    my $parent_mode = $parent_stat[2] & 07777;
    ok($parent_mode == 0700 || $parent_mode == 0750,
        sprintf('vamana_indexes/ permissions are %04o (expect 0700 or 0750)',
                $parent_mode));

    my @index_stat = stat($index_dir);
    my $index_mode = $index_stat[2] & 07777;
    ok($index_mode == 0700 || $index_mode == 0750,
        sprintf('vamana_indexes/<oid>/ permissions are %04o (expect 0700 or 0750)',
                $index_mode));

    # TC-02 bullet 1: ownership matches the postgres OS user
    my $pg_uid = (stat($pgdata))[4];
    is($parent_stat[4], $pg_uid,
        'vamana_indexes/ owned by postgres OS user');
    is($index_stat[4], $pg_uid,
        'vamana_indexes/<oid>/ owned by postgres OS user');

    # TC-02 bullets 2-3: operator documentation content verification.
    # Confirm USER_GUIDE.md contains the required security notes so that a
    # packaging change that strips docs is caught by CI.
    # Enforcement: docs/USER_GUIDE.md lines 620-622 (verified 2026-08-06).
    my $guide_path = "$Bin/../../docs/USER_GUIDE.md";

    ok(-f $guide_path,
        'USER_GUIDE.md exists at expected path (packaging regression gate)');

    open my $fh, '<', $guide_path or die "open $guide_path: $!";
    my $guide_content = do { local $/; <$fh> };
    close $fh;

    # TC-02 bullet 2a: F2 inherits $PGDATA permission posture
    like($guide_content,
        qr/\$PGDATA.*permission posture|postmaster.*umask.*0700/s,
        'USER_GUIDE.md documents F2 inherits PGDATA permission posture');

    # TC-02 bullet 2b: separately-encrypted tablespace does NOT protect F2
    like($guide_content,
        qr/separately-encrypted tablespace.*does \*\*not\*\* protect/si,
        'USER_GUIDE.md documents encrypted tablespace does not protect F2');

    # TC-02 bullet 3: ALTER INDEX SET TABLESPACE is a silent no-op
    like($guide_content,
        qr/ALTER INDEX.*SET TABLESPACE.*silent no-op/si,
        'USER_GUIDE.md documents ALTER INDEX SET TABLESPACE is a silent no-op');

    $node->stop;
}

done_testing();
