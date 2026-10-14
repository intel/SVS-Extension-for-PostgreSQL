# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 72_metapage_count_bounds.pl: a tampered metapage slot count must fail the
# one affected index cleanly, not allocate against it or crash the worker.
#
# VamanaValidateMetaCounts (src/vamanautils.c) checks tidMappingCapacity,
# numVectors, numDeleted, and nextExternalId before LoadIndexFromPages
# allocates a TID map sized by them. This file edits the on-disk metapage
# directly, byte for byte, to simulate the counts a tampered or corrupted
# page could carry, and confirms the worker rejects each one with a clean
# ERROR, keeps serving every other index, and recovers via REINDEX.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);
use Fcntl qw(:seek);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

$| = 1;

# Byte offset of tidMappingCapacity within the metapage: the page header
# (MAXALIGN(SizeOfPageHeaderData) = 24) plus offsetof(VamanaMetaPageData,
# tidMappingCapacity), pinned at 60 by the StaticAssertDecl next to that
# struct's definition (src/vamana.h).
my $CAPACITY_OFFSET = 24 + 60;
my $ROW_COUNT       = 50;

# ---------------------------------------------------------------------------
# read_capacity / write_capacity: raw 4-byte little-endian access to the
# tidMappingCapacity field of an index's metapage (block 0), with the
# server stopped.
# ---------------------------------------------------------------------------
sub read_capacity
{
	my ($path) = @_;
	open(my $fh, '<:raw', $path) or die "open $path for read: $!";
	seek($fh, $CAPACITY_OFFSET, SEEK_SET) or die "seek $path: $!";
	read($fh, my $bytes, 4) == 4 or die "short read on $path";
	close($fh);
	return unpack('V', $bytes);
}

sub write_capacity
{
	my ($path, $value) = @_;
	open(my $fh, '+<:raw', $path) or die "open $path for write: $!";
	seek($fh, $CAPACITY_OFFSET, SEEK_SET) or die "seek $path: $!";
	print $fh pack('V', $value) or die "write $path: $!";
	close($fh);
}

sub postmaster_pid
{
	my ($node) = @_;
	open(my $fh, '<', $node->data_dir . "/postmaster.pid")
	  or die "open postmaster.pid: $!";
	my $pid = <$fh>;
	close($fh);
	chomp $pid;
	return $pid;
}

sub metapage_path
{
	my ($node, $index) = @_;
	my $relpath = $node->safe_psql('postgres',
		"SELECT pg_relation_filepath('$index');");
	chomp $relpath;
	return $node->data_dir . "/$relpath";
}

my $node = PostgreSQL::Test::Cluster->new('vamana_metapage_bounds');
$node->init(no_data_checksums => 1);
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 10");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->append_conf('postgresql.conf', "svs.checkpoint_min_ops = 1");
$node->append_conf('postgresql.conf', "svs.checkpoint_debounce_window = 1");
$node->append_conf('postgresql.conf', "svs.default_residency_memory = 1MB");
$node->append_conf('postgresql.conf', "svs.max_residency_memory = 16MB");
$node->append_conf('postgresql.conf', "log_min_messages = 'notice'");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres',
	"INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

$node->safe_psql('postgres', qq{
	CREATE TABLE victim_tbl (id serial PRIMARY KEY, val vector($dim));
	INSERT INTO victim_tbl (val)
		SELECT ARRAY[$array_sql]::vector FROM generate_series(1, $ROW_COUNT);
	CREATE INDEX victim_idx ON victim_tbl USING vamana (val vector_l2_ops);

	CREATE TABLE bystander_tbl (id serial PRIMARY KEY, val vector($dim));
	INSERT INTO bystander_tbl (val)
		SELECT ARRAY[$array_sql]::vector FROM generate_series(1, $ROW_COUNT);
	CREATE INDEX bystander_idx ON bystander_tbl USING vamana (val vector_l2_ops);
});
my $worker_pid = wait_for_worker($node, 30);
ok($worker_pid =~ /^\d+$/, 'worker is running after both indexes build');

# ---------------------------------------------------------------------------
# force_saved_copy: one more insert triggers a checkpoint (min_ops = 1),
# which persists the metapage and tidmap.bin for $index.
# ---------------------------------------------------------------------------
sub force_saved_copy
{
	my ($node, $table, $index, $db) = @_;
	$node->safe_psql('postgres',
		"INSERT INTO $table (val) VALUES (ARRAY[$array_sql]::vector);");
	my $ioid = $node->safe_psql('postgres',
		"SELECT oid FROM pg_class WHERE relname = '$index';");
	chomp $ioid;
	my $tidmap = vamana_save_dir($node, $db, $ioid) . "/tidmap.bin";
	for (1 .. 20)
	{
		last if -f $tidmap;
		usleep(500_000);
	}
	ok(-f $tidmap, "$index: tidmap.bin written before tampering");
}

force_saved_copy($node, 'victim_tbl', 'victim_idx', 'postgres');
force_saved_copy($node, 'bystander_tbl', 'bystander_idx', 'postgres');

# ---------------------------------------------------------------------------
# run_case: checkpoint, stop, tamper tidMappingCapacity in victim_idx's
# metapage, restart, and check the required TC-14 outcomes.
# ---------------------------------------------------------------------------
sub run_case
{
	my ($name, $tamper_value, $expected_error, $expected_capacity) = @_;

	my $path = metapage_path($node, 'victim_idx');
	$node->safe_psql('postgres', "CHECKPOINT;");
	$node->stop;

	my $before = read_capacity($path);
	is($before, $expected_capacity,
		"$name: pre-tamper capacity matches the known value")
	  or die "metapage layout drifted, refusing to tamper the wrong field";

	write_capacity($path, $tamper_value);

	$node->start;
	my $postmaster_pid = postmaster_pid($node);
	my $pid = wait_for_worker($node, 30);
	ok($pid =~ /^\d+$/, "$name: worker is running after restart");

	my $log_offset = -s $node->logfile;

	# A search's load failure is swallowed by VamanaRunInSubXact (the
	# worker treats it the same as "no saved copy, fall back"): the client
	# only sees a generic "index not loaded" error, but the actual check
	# that failed is logged as a WARNING with the real message as detail
	# (src/vamanaworkerindex.c), which is where this test asserts on it.
	my ($rc, $stdout, $stderr) = $node->psql('postgres',
		"SET enable_seqscan = off; "
	  . "SELECT id FROM victim_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;");
	isnt($rc, 0, "$name: victim query fails");

	my $logged = $node->log_contains($expected_error, $log_offset);
	ok($logged, "$name: the real check failure is logged for the victim");

	my $crashed = $node->log_contains(
		qr/terminated by signal|server closed the connection unexpectedly/,
		$log_offset);
	ok(!$crashed, "$name: no crash restart logged for the victim's failure");

	my $pid_after = $node->safe_psql('postgres',
		"SELECT pid FROM pg_stat_activity WHERE backend_type = 'vamana worker' LIMIT 1;");
	chomp $pid_after;
	is($pid_after, $pid, "$name: worker PID unchanged across the failing request");

	my $postmaster_pid_after = postmaster_pid($node);
	is($postmaster_pid_after, $postmaster_pid, "$name: postmaster PID unchanged");

	my $stuck = $node->safe_psql('postgres',
		"SELECT count(*) FROM pg_stat_vamana_worker_slot "
	  . "WHERE slot_status IN ('pending', 'processing');");
	chomp $stuck;
	is($stuck, '0', "$name: no slot left mid-flight after the victim's failure");

	my $bystander_result = $node->safe_psql('postgres',
		"SET enable_seqscan = off; "
	  . "SELECT id FROM bystander_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;");
	isnt($bystander_result, '',
		"$name: bystander answers correctly after the victim's failure");

	$node->safe_psql('postgres', "REINDEX INDEX victim_idx;");
	my $recovered = $node->safe_psql('postgres',
		"SET enable_seqscan = off; "
	  . "SELECT id FROM victim_tbl ORDER BY val <-> '[$query_sql]' LIMIT 5;");
	isnt($recovered, '', "$name: REINDEX recovers the victim");

	# REINDEX serializes a fresh metapage synchronously as part of the
	# build (tidMappingCapacity = numVectors = row count, no growth
	# doubling), independent of svs.checkpoint_min_ops; no extra wait
	# needed before the next case's checkpoint + stop.
}

# force_saved_copy's extra insert makes nextExternalId (= $ROW_COUNT) reach
# the build's own capacity ($ROW_COUNT), which doubles it: this is the
# capacity on disk for the first case below. Every later case runs after the
# previous one's REINDEX, which rebuilds with no growth, so capacity
# collapses back to the exact row count ($ROW_COUNT + 1, from the one extra
# insert) for every case after the first.
my $capacity_after_growth  = $ROW_COUNT * 2;
my $capacity_after_reindex = $ROW_COUNT + 1;

# (a) Type ceiling: a count past what any downstream int cast can hold.
run_case('type ceiling', 0xFFFFFFFF,
	qr/metapage slot count exceeds the supported maximum/,
	$capacity_after_growth);

# (b) Residency anchor: in-range, internally consistent, but a TID map this
# size (capacity * 6 bytes) exceeds the configured 1MB residency budget by a
# safe margin while staying small in absolute terms (~1.14MB touched if the
# pre-fix allocator ran, safe on any CI host).
run_case('residency anchor', 200_000,
	qr/metapage TID-map capacity exceeds this database's residency budget/,
	$capacity_after_reindex);

# (c) Internal consistency: capacity patched down below the real numVectors.
run_case('internal consistency', 10,
	qr/metapage slot counts are inconsistent/,
	$capacity_after_reindex);

$node->stop;
done_testing();
