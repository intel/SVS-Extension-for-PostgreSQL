# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 09_vamana_standby_replay_faults.pl — standby BGW replay fault handling.
#
# The happy path lives in 08; this file covers the three failure valves.  Each
# fix lives on the standby BGW replay path, so every test drives a primary +
# streaming standby and forces the fault with an injection point (per-record
# apply error, unrecoverable decode error) or by starving the slot past its
# WAL budget.  Kept separate from 08 so the injection-point guard below does
# not gate the injection-free happy path.
#
# Tests:
#   Per-record apply error: skipped with a WARNING; the BGW survives
#       and the remaining rows still replay.
#   Per-record apply error (crash/restart): a skipped record survives a
#       standby crash and restart, not just a live detach.
#   Unrecoverable decode error: drops the slot and rebuilds the index
#       from the heap on the first error; queries return correct results.
#   WAL budget exceeded: a slot that falls past svs.max_slot_wal_size is
#       dropped and rebuilt from the heap instead of drained.

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

# The fault paths above have no deterministic trigger without injection points.
if (($ENV{enable_injection_points} // 'no') ne 'yes')
{
	plan skip_all => 'server not built with --enable-injection-points';
}

# ---------------------------------------------------------------------------
# Build a primary + streaming standby that share one Vamana index and $nrows
# already-replicated rows.  Returns ($primary, $standby).
# ---------------------------------------------------------------------------
sub setup_primary_standby
{
	my ($name, $nrows) = @_;

	my $primary = PostgreSQL::Test::Cluster->new("primary_$name");
	$primary->init(allows_streaming => 1);
	$primary->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
	$primary->append_conf('postgresql.conf', "wal_level = logical");
	$primary->append_conf('postgresql.conf', "max_replication_slots = 10");
	$primary->append_conf('postgresql.conf', "max_wal_senders = 10");
	$primary->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
	$primary->append_conf('postgresql.conf', "svs.checkpoint_min_ops = 999999");
	$primary->start;

	$primary->safe_psql('postgres', "CREATE EXTENSION vector;");
	$primary->safe_psql('postgres', "CREATE EXTENSION svs;");
	$primary->safe_psql('postgres', "CREATE EXTENSION injection_points;");
	$primary->safe_psql('postgres',
		"INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

	$primary->safe_psql('postgres', qq{
		CREATE TABLE rep_tbl (id serial, val vector($dim));
		CREATE INDEX rep_idx ON rep_tbl USING vamana (val vector_l2_ops);
	});
	wait_for_worker($primary, 30);

	for my $i (1 .. $nrows)
	{
		$primary->safe_psql('postgres',
			"INSERT INTO rep_tbl (val) VALUES (ARRAY[$array_sql]::vector);");
	}
	wait_for_worker($primary, 30);

	my $backup = "${name}_backup";
	$primary->backup($backup);

	my $standby = PostgreSQL::Test::Cluster->new("standby_$name");
	$standby->init_from_backup($primary, $backup, has_streaming => 1);
	$standby->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
	$standby->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
	$standby->append_conf('postgresql.conf', "svs.checkpoint_min_ops = 999999");
	$standby->append_conf('postgresql.conf', "log_min_messages = debug1");
	$standby->append_conf('postgresql.conf', "hot_standby = on");
	$standby->start;
	$primary->wait_for_replay_catchup($standby);

	return ($primary, $standby);
}

# Poll the standby until an ANN query sees exactly $want rows, or timeout.
sub standby_ann_count
{
	my ($standby, $want, $attempts) = @_;
	$attempts //= 30;
	my $count = -1;
	for (1 .. $attempts)
	{
		usleep(500_000);
		eval {
			$count = $standby->safe_psql('postgres', qq{
				SELECT count(*) FROM (
					SELECT * FROM rep_tbl
					ORDER BY val <-> ARRAY[$array_sql]::vector LIMIT 100
				) sub;
			});
		};
		chomp $count if defined $count;
		last if defined $count && $count == $want;
	}
	return $count;
}

# ===========================================================================
# Per-record apply error is skipped, not fatal
#
# The subtransaction contains the error to one record: the BGW logs a WARNING,
# stays up, and keeps replaying.  A lone skipped record does not advance the
# slot (opsDecoded stays 0), so a transient fault self-heals: once detached, the
# record is re-delivered and applied on the next sweep.  Permanent recall loss
# only happens when a later successful op advances the slot past the bad record.
# ===========================================================================
{
	my ($primary, $standby) = setup_primary_standby('s1', 5);

	# All 5 pre-backup rows are already replayed on the standby.
	my $before = standby_ann_count($standby, 5);
	is($before, 5, 'per-record apply error: baseline 5 rows searchable on standby');

	# Force the apply of the next insert to throw (fires on every apply until
	# detached).
	$standby->safe_psql('postgres',
		"SELECT injection_points_attach('vamana-replay-apply-insert', 'error');");

	my $log_pos = -s $standby->logfile;

	# Force a RUNNING_XACTS record BEFORE the insert so the standby's decoding
	# snapshot reaches consistency ahead of the change; a snapshot logged after
	# the insert leaves the change without a base snapshot, so decoding delivers
	# an empty transaction (commit but no change) and the injection never fires.
	$primary->safe_psql('postgres', "SELECT pg_log_standby_snapshot();");

	# One new row on the primary; the injection makes its apply throw and skip.
	$primary->safe_psql('postgres',
		"INSERT INTO rep_tbl (val) VALUES (ARRAY[$array_sql]::vector);");
	$primary->wait_for_replay_catchup($standby);

	# The BGW drains autonomously, so poll the log rather than sleeping a fixed
	# interval and racing the drain.  The injection stays attached until the
	# WARNING fires, so a slow drain lengthens the wait instead of missing it.
	$standby->wait_for_log(qr/vamana replay: skipping change at/, $log_pos);
	pass('per-record apply error: injected apply error is skipped with a WARNING');

	my $pid = wait_for_worker($standby, 10);
	ok($pid =~ /^\d+$/, 'per-record apply error: standby BGW survives the skipped record');

	# Detach; the slot never advanced past the skipped record, so it is
	# re-delivered and applied.  A second insert then lands on top: 7 total.
	$standby->safe_psql('postgres',
		"SELECT injection_points_detach('vamana-replay-apply-insert');");
	$primary->safe_psql('postgres',
		"INSERT INTO rep_tbl (val) VALUES (ARRAY[$array_sql]::vector);");
	$primary->wait_for_replay_catchup($standby);

	my $after = standby_ann_count($standby, 7);
	is($after, 7,
		'per-record apply error: replay resumes after the skip (transient fault self-heals)');

	$standby->stop;
	$primary->stop;
}

# ===========================================================================
# Per-record apply error (crash/restart): a skipped record survives a
# standby crash and restart
#
# The per-record apply error test above proves live self-heal: the BGW stays up and a later detach + retry
# re-delivers the record. This proves the stronger claim: the skip never
# advances the slot's restart_lsn (opsDecoded stays 0), so the record
# survives even a full crash and restart, not just a live detach. stop
# ('immediate') sends SIGQUIT with no shutdown checkpoint, forcing crash
# recovery on the next start -- same convention 01/02/07 use to simulate a
# crash.
# ===========================================================================
{
	my ($primary, $standby) = setup_primary_standby('s1b', 5);

	my $before = standby_ann_count($standby, 5);
	is($before, 5, 'per-record apply error (crash/restart): baseline 5 rows searchable on standby');

	# Force the apply of the next insert to throw. The standby crashes before
	# any detach happens, so the injection attachment never gets cleared here.
	$standby->safe_psql('postgres',
		"SELECT injection_points_attach('vamana-replay-apply-insert', 'error');");

	my $log_pos = -s $standby->logfile;

	# As above: log the snapshot BEFORE the insert so the change has a base
	# snapshot and is actually decoded rather than delivered as an empty txn.
	$primary->safe_psql('postgres', "SELECT pg_log_standby_snapshot();");

	$primary->safe_psql('postgres',
		"INSERT INTO rep_tbl (val) VALUES (ARRAY[$array_sql]::vector);");
	$primary->wait_for_replay_catchup($standby);

	# Confirm the skip fired before crashing, else a restart that races ahead
	# of the injected apply would pass trivially.
	$standby->wait_for_log(qr/vamana replay: skipping change at/, $log_pos);
	pass('per-record apply error (crash/restart): injected apply error is skipped with a WARNING before the crash');

	# Crash: the BGW's shared-memory state (including the injection
	# attachment) is gone; only what was durably persisted to disk survives.
	$standby->stop('immediate');
	$standby->start;

	my $post_crash_pid = wait_for_worker($standby, 20);
	ok($post_crash_pid =~ /^\d+$/,
		"per-record apply error (crash/restart): vamana background worker running after crash recovery (pid=$post_crash_pid)");

	# The skip never advanced restart_lsn, so the post-restart pass re-decodes
	# the same record from the slot and applies it cleanly -- no re-injection,
	# no manual detach.
	my $after = standby_ann_count($standby, 6);
	is($after, 6,
		'per-record apply error (crash/restart): skipped record survives standby crash and replays after restart');

	$standby->stop;
	$primary->stop;
}

# ===========================================================================
# Unrecoverable decode error drops the slot and rebuilds from heap
# ===========================================================================
{
	my ($primary, $standby) = setup_primary_standby('s2', 5);

	my $before = standby_ann_count($standby, 5);
	is($before, 5, 'unrecoverable decode error: baseline 5 rows searchable on standby');

	my $log_pos = -s $standby->logfile;

	# Make the decode loop throw — this escapes the per-record subtransaction
	# and reaches VamanaReplicationDrainSlot's recovery handler.
	$standby->safe_psql('postgres',
		"SELECT injection_points_attach('vamana-replay-decode-record', 'error');");

	# As above: log the snapshot BEFORE the insert so the change has a base
	# snapshot and is actually decoded rather than delivered as an empty txn.
	$primary->safe_psql('postgres', "SELECT pg_log_standby_snapshot();");

	# New WAL to decode on the standby.
	$primary->safe_psql('postgres',
		"INSERT INTO rep_tbl (val) VALUES (ARRAY[$array_sql]::vector);");
	$primary->wait_for_replay_catchup($standby);

	# As above: poll the log rather than racing the autonomous drain with a sleep.
	$standby->wait_for_log(qr/vamana replay: unrecoverable decoding error for index/,
		$log_pos);
	pass('unrecoverable decode error: decode error triggers recover-and-rebuild');

	# Detach; the rebuilt-from-heap index must still answer queries correctly.
	$standby->safe_psql('postgres',
		"SELECT injection_points_detach('vamana-replay-decode-record');");

	my $after = standby_ann_count($standby, 6);
	is($after, 6, 'unrecoverable decode error: index rebuilt from heap returns correct results');

	$standby->stop;
	$primary->stop;
}

# ===========================================================================
# WAL budget exceeded: a slot past svs.max_slot_wal_size is dropped and rebuilt, not drained
# ===========================================================================
{
	my ($primary, $standby) = setup_primary_standby('lag', 5);

	# Tighten the WAL budget to its floor on the standby, then reload.
	$standby->append_conf('postgresql.conf', "svs.max_slot_wal_size = 64");
	$standby->reload;

	my $before = standby_ann_count($standby, 5);
	is($before, 5, 'WAL budget exceeded: baseline 5 rows searchable on standby');

	my $log_pos = -s $standby->logfile;

	# Generate > 64 MB of WAL on the primary so restart_lsn falls far behind.
	# Filler goes in its own table so it does not add rep_tbl vectors.
	$primary->safe_psql('postgres', "CREATE TABLE lag_filler (id int, pad text);");
	$primary->safe_psql('postgres', qq{
		INSERT INTO lag_filler
		SELECT g, repeat('x', 1024)
		FROM generate_series(1, 120000) g;
	});
	$primary->safe_psql('postgres', "CHECKPOINT;");
	$primary->wait_for_replay_catchup($standby);

	# As above: poll the log rather than racing the autonomous drain with a sleep.
	$standby->wait_for_log(qr/exceeds max_slot_wal_size .* rebuilding from heap/,
		$log_pos);
	pass('WAL budget exceeded: slot past WAL budget triggers rebuild from heap');

	# Rebuilt-from-heap index still serves the 5 replicated rep_tbl rows.
	my $after = standby_ann_count($standby, 5);
	is($after, 5, 'WAL budget exceeded: index rebuilt from heap after lag valve');

	$standby->stop;
	$primary->stop;
}

done_testing();
