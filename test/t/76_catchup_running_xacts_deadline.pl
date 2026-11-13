# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 76_catchup_running_xacts_deadline.pl -- a catch-up slice checks its
# deadline right after decoding a RUNNING_XACTS record.
#
# Decoding a RUNNING_XACTS record can write a snapshot file and save the
# slot, and no budget check can interrupt that I/O.  The slice therefore
# checks the deadline immediately after each such record instead of waiting
# for the next 32-record stride, so at most that one decode runs past the
# deadline.  An injection point parks the worker inside the first
# RUNNING_XACTS decode of a slice for longer than the slice budget, which
# stands in for slow storage.
#
# Tests:
#   The slice that was parked stops at the end of that RUNNING_XACTS record,
#       checked against the WAL with pg_waldump, not at a later record.
#   Its running_xacts_decode_us covers the parked time.
#   Its elapsed time less running_xacts_decode_us stays within the budget.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

if (($ENV{enable_injection_points} // 'no') ne 'yes')
{
	plan skip_all => 'server not built with --enable-injection-points';
}

my $dim = 16;
my $array_sql = join(",", ('random()') x $dim);
my $point = 'vamana-catchup-running-xacts-decoded';

# svs.worker_timeout_ms = 1000 makes the slice budget
# Min(1000, svs.worker_timeout_ms / 5) = 200 ms.
my $budget_ms = 200;
my $park_ms = 600;

my $node = PostgreSQL::Test::Cluster->new('vamana_catchup_rx_deadline');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 10");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->append_conf('postgresql.conf', "log_min_messages = debug1");
$node->append_conf('postgresql.conf', "svs.worker_timeout_ms = 1000");
$node->append_conf('postgresql.conf', "svs.checkpoint_operations = 50");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres', "CREATE EXTENSION injection_points;");
$node->safe_psql('postgres',
	"INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");
wait_for_worker($node, 30);

$node->safe_psql('postgres', qq{
	CREATE TABLE rx_tbl (id serial PRIMARY KEY, val vector($dim));
	CREATE TABLE rx_filler (id bigserial, pad text);
	INSERT INTO rx_tbl (val)
		SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 100) i;
	CREATE INDEX rx_idx ON rx_tbl USING vamana (val vector_l2_ops);
});
wait_for_worker_db($node, 'postgres', 30);

# The first catch-up decode to the slot's consistent point runs in the worker
# asynchronously; wait for it before building any lag.
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
ok($consistent, "catchup rx deadline: slot reaches its first consistent point");

# Park the worker in the first RUNNING_XACTS decode of the next slice that
# has anything to decode, then build more than one WAL segment of lag with a
# running-xacts record inside it.
$node->safe_psql('postgres',
	"SELECT injection_points_attach('$point', 'wait');");

$node->safe_psql('postgres', qq{
	INSERT INTO rx_filler (pad)
		SELECT repeat('x', 1024) FROM generate_series(1, 30000);
});
$node->safe_psql('postgres', "SELECT pg_log_standby_snapshot();");
$node->safe_psql('postgres', qq{
	INSERT INTO rx_tbl (val)
		SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 60) i;
});
$node->safe_psql('postgres', "SELECT pg_log_standby_snapshot();");

$node->wait_for_event('vamana worker', $point);

usleep($park_ms * 1000);
my $log_offset = -s $node->logfile;
$node->safe_psql('postgres', "SELECT injection_points_detach('$point');");
$node->safe_psql('postgres', "SELECT injection_points_wakeup('$point');");

$node->wait_for_log(qr/vamana catch-up:.*budget_exhausted=1/, $log_offset);
my $log_content = slurp_file($node->logfile, $log_offset);
my ($slice) = $log_content =~ /(vamana catch-up:.*budget_exhausted=1.*)$/m;
ok(defined $slice, "catchup rx deadline: the parked slice exhausted its budget");

my ($start_restart, $exit_recptr, $elapsed_us, $decode_us) = $slice =~
  /start_restart=([0-9A-Fa-f]+\/[0-9A-Fa-f]+) exit_recptr=([0-9A-Fa-f]+\/[0-9A-Fa-f]+).*elapsed_us=(\d+).*running_xacts_decode_us=(\d+)/;

# The last record the slice decoded ends at exit_recptr, so it is the last
# record pg_waldump prints for [start_restart, exit_recptr].
my ($waldump, $waldump_err) = run_command(
	[
		'pg_waldump', '--path', $node->data_dir . '/pg_wal',
		'--start', $start_restart, '--end', $exit_recptr
	]);
my @records = split /\n/, $waldump;
like($records[-1], qr/Standby\s+.*RUNNING_XACTS/,
	"catchup rx deadline: the slice stopped at the end of the RUNNING_XACTS record it was parked in");

cmp_ok($decode_us, '>=', ($park_ms - 100) * 1000,
	"catchup rx deadline: running_xacts_decode_us ($decode_us) covers the parked time");
cmp_ok(($elapsed_us - $decode_us) / 1000, '<=', $budget_ms + 150,
	"catchup rx deadline: elapsed time less running_xacts_decode_us stayed within B + 150 ms");

$node->stop;

done_testing();
