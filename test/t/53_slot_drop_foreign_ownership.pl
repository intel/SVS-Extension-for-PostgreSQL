# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 53_slot_drop_foreign_ownership.pl: TryDropSlot refuses to drop a
# same-named slot it did not create.
#
# Before this fix, TryDropSlot located a slot purely by name
# (SearchNamedReplicationSlot) and dropped it once confirmed inactive, with
# no check of which output plugin created it. A REPLICATION-privileged role
# that pre-creates vamana_<dboid>_<relid> with a different plugin could have
# it silently dropped by DROP INDEX's commit-time cleanup
# (VamanaRetireIndexArtifacts -> VamanaReplicationDropIfExists) or by the
# next VamanaReplicationCreate for that same name.
#
# This test exercises the DROP INDEX path: build a real vamana index, drop
# its own correctly-owned slot out from under it with
# pg_drop_replication_slot(), then occupy the now-free name with a
# test_decoding slot before DROP INDEX ever runs its own cleanup. The fixed
# TryDropSlot must notice the plugin mismatch, warn, and leave the foreign
# slot alone rather than dropping it.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

sub slot_info
{
    my ($node, $slot_name) = @_;
    my $row = $node->safe_psql('postgres', qq{
        SELECT count(*), coalesce(string_agg(plugin, ','), '')
        FROM pg_replication_slots WHERE slot_name = '$slot_name';
    });
    chomp $row;
    return split /\|/, $row;
}

sub wait_for_log_line
{
    my ($node, $regex, $offset, $timeout_s) = @_;
    $timeout_s //= 10;
    for (1 .. $timeout_s * 2)
    {
        return 1 if $node->log_contains($regex, $offset);
        usleep(500_000);
    }
    return 0;
}

my $node = PostgreSQL::Test::Cluster->new('slot_drop_foreign_ownership');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 10");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres',
    "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

my $worker_pid = wait_for_worker($node, 30);
ok($worker_pid ne '', 'the worker starts for the postgres database');

$node->safe_psql('postgres', qq{
    CREATE TABLE foreign_slot_tbl (id serial PRIMARY KEY, val vector($dim));
    INSERT INTO foreign_slot_tbl (val)
        SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 5);
    CREATE INDEX foreign_slot_idx ON foreign_slot_tbl USING vamana (val vector_l2_ops);
});

my $dboid = $node->safe_psql('postgres',
    "SELECT oid FROM pg_database WHERE datname = 'postgres';");
chomp $dboid;
my $ioid = $node->safe_psql('postgres',
    "SELECT oid FROM pg_class WHERE relname = 'foreign_slot_idx';");
chomp $ioid;
my $slot_name = "vamana_${dboid}_${ioid}";

my ($cnt, $plugin) = slot_info($node, $slot_name);
is($cnt, 1, 'the index\'s own slot exists before the swap');
is($plugin, 'svs', 'the index\'s own slot is owned by the svs plugin');

# Swap the real slot out from under the still-catalogued index for a
# same-named foreign one, immediately followed by the DROP INDEX that
# exercises TryDropSlot's ownership check -- the scenario is engineered, but
# the check being tested runs on every call regardless of how the name came
# to collide.
$node->safe_psql('postgres', qq{
    SELECT pg_drop_replication_slot('$slot_name');
    SELECT pg_create_logical_replication_slot('$slot_name', 'test_decoding');
});

($cnt, $plugin) = slot_info($node, $slot_name);
is($cnt, 1, 'a foreign slot now occupies the name');
is($plugin, 'test_decoding', 'the foreign slot is owned by test_decoding, not svs');

my $log_offset = -s $node->logfile;

my $ret = $node->psql('postgres', "DROP INDEX foreign_slot_idx;");
is($ret, 0, 'DROP INDEX still commits even though its slot cleanup is refused');

ok(wait_for_log_line($node,
        qr/replication slot "\Q$slot_name\E" exists but belongs to plugin "test_decoding", not "svs"; skipping drop/,
        $log_offset, 10),
    'TryDropSlot warns about the plugin mismatch instead of dropping the slot');

($cnt, $plugin) = slot_info($node, $slot_name);
is($cnt, 1, 'the foreign slot was not dropped by DROP INDEX cleanup');
is($plugin, 'test_decoding', 'the foreign slot still belongs to test_decoding');

ok(wait_for_worker($node, 10),
    'the worker is still alive after refusing the foreign-owned drop');

# Nothing will ever succeed in dropping this on its own (the name is
# permanently plugin-mismatched), so clean it up directly before shutdown.
$node->safe_psql('postgres',
    "SELECT pg_drop_replication_slot('$slot_name');");

$node->stop;

done_testing();
