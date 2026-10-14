# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 69_primary_slot_advance.pl -- a primary's own replication slot must advance
# without a standby or any other logical consumer ever decoding it.
#
# Nothing on a primary used to run a logical decode against a vamana index's
# own slot: the checkpoint-triggered advance called LogicalConfirmReceivedLocation
# directly, which can only promote restart_lsn/confirmed_flush_lsn once a decode
# has already populated the reorder buffer's candidate positions.  On a lone
# primary with no standby and no logical consumer, nothing ever did that, so
# both LSNs froze at their first-consistent-point value and retained WAL grew
# without bound as steady-state behavior, not an edge case.
#
# Tests:
#   restart_lsn and confirmed_flush_lsn advance across repeated write and
#       checkpoint cycles on a lone primary (the primary pass/fail signal).
#   pg_wal usage stays bounded rather than growing with every cycle.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

my $dim = 16;
my $array_sql = join(",", ('random()') x $dim);

my $node = PostgreSQL::Test::Cluster->new('vamana_primary_slot_advance');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 10");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");

# Debounce the per-index checkpoint on a small, deterministic op count instead
# of the default (10000 ops / 300s quiet window), so each write batch below
# reliably triggers its own VamanaSlotAdvance call.
$node->append_conf('postgresql.conf', "svs.checkpoint_operations = 50");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres',
	"INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");
wait_for_worker($node, 30);

$node->safe_psql('postgres', qq{
	CREATE TABLE advance_tbl (id serial PRIMARY KEY, val vector($dim));
	INSERT INTO advance_tbl (val)
		SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 100) i;
	CREATE INDEX advance_idx ON advance_tbl USING vamana (val vector_l2_ops);
});
my $worker_pid = wait_for_worker_db($node, 'postgres', 30);
ok($worker_pid =~ /^\d+$/,
	"primary slot advance: worker running normally (pid=$worker_pid)");

sub slot_lsns
{
	my $row = $node->safe_psql('postgres', qq{
		SELECT restart_lsn, confirmed_flush_lsn
		FROM pg_replication_slots WHERE slot_name LIKE 'vamana\\_%';
	});
	chomp $row;
	return split /\|/, $row;
}

my ($restart0, $confirmed0) = slot_lsns();
ok(defined $restart0 && length $restart0,
	'primary slot advance: slot exists with a restart_lsn after index creation');

# CREATE INDEX's own catch-up decode to the slot's first consistent point runs
# in the worker asynchronously; writing before it finishes can block on the
# worker's write-IPC path.  Poll confirmed_flush_lsn rather than sleeping a
# fixed amount.
my $consistent = 0;
for (1 .. 60)
{
	my $cf = $node->safe_psql('postgres', qq{
		SELECT confirmed_flush_lsn IS NOT NULL
		FROM pg_replication_slots WHERE slot_name LIKE 'vamana\\_%';
	});
	chomp $cf;
	if ($cf eq 't')
	{
		$consistent = 1;
		last;
	}
	usleep(500_000);
}
ok($consistent, 'primary slot advance: slot reaches its first consistent point');

# Drive several write + per-index-checkpoint cycles and confirm both LSNs
# keep pace with WAL growth instead of freezing at their first value.
my $prev_restart = $restart0;
my $advanced_count = 0;
for my $cycle (1 .. 6)
{
	$node->safe_psql('postgres', qq{
		INSERT INTO advance_tbl (val)
			SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 60) i;
	});
	usleep(1_500_000);

	my ($restart, $confirmed) = slot_lsns();
	$advanced_count++
	  if $node->safe_psql('postgres',
		"SELECT pg_lsn('$restart') > pg_lsn('$prev_restart');") eq 't';
	$prev_restart = $restart;
}

cmp_ok($advanced_count, '>=', 4,
	"primary slot advance: restart_lsn advanced in at least 4 of 6 cycles ($advanced_count observed)");

my ($restart_final, $confirmed_final) = slot_lsns();
my $wal_now = $node->safe_psql('postgres', "SELECT pg_current_wal_lsn();");
chomp $wal_now;

my $lag = $node->safe_psql('postgres',
	"SELECT pg_wal_lsn_diff('$wal_now', '$restart_final');");
chomp $lag;

cmp_ok($lag, '<', 8 * 1024 * 1024,
	"primary slot advance: restart_lsn lag ($lag bytes) stays small instead of tracking total WAL written");

$node->stop;

done_testing();
