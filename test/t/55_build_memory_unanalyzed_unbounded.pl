# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 55_build_memory_unanalyzed_unbounded.pl — is#187 / T-DoS-3: the build-memory
# admission gate does not bound scan-time buffer growth for a table that has
# never been ANALYZEd.
#
# SvsMemoryCheckEstimatedBuildSize (src/svs_memory.c:567-584) unconditionally
# returns without checking anything when reltuples <= 0 -- the state of any
# table that has never been ANALYZEd. SvsVectorBufferAppend
# (src/svs_vector_buffer.c:19-29) then doubles its backing allocation on
# every overflow with no reference to svs.max_build_memory or any other
# bound. The only real enforcement, SvsMemoryReserveBuild
# (src/vamanabuild.c:600-679), runs on a forecast computed only after
# table_index_build_scan has already returned -- so for an unanalyzed table
# there is no check in effect anywhere while the buffer is actually growing.
#
# This reuses 38_build_large_vector_buffer.pl's case 2 shape (dim 2000,
# 128,001 unanalyzed rows, svs.max_build_memory = 1024MB, the doubling
# crossing from capacity 128000 to 256000) and adds the piece that file does
# not check: the backend's own resident memory (/proc/<pid>/status VmRSS),
# polled while the build is in progress, to directly show the backend's RSS
# climbs well past the configured ceiling before the post-scan gate ever
# gets a chance to refuse.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(time usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

my $node = PostgreSQL::Test::Cluster->new('build_memory_unanalyzed_unbounded');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'vector,svs'");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 10");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "svs.max_build_memory = '1024MB'");
$node->append_conf('postgresql.conf', "svs.max_residency_memory = '16000MB'");
$node->append_conf('postgresql.conf', "svs.default_residency_memory = '16000MB'");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres',
	"INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");
my $worker_pid = wait_for_worker($node);
ok($worker_pid =~ /^\d+$/, 'worker is running before the build');

my $dim  = 2000;
my $rows = 128001;
my $ceiling_bytes = 1024 * 1024 * 1024;	# svs.max_build_memory = 1024MB

my $t_start = time();
$node->safe_psql('postgres', qq(
	CREATE TABLE unanalyzed_tbl (id serial PRIMARY KEY, embedding vector($dim))
		WITH (autovacuum_enabled = false);
));
$node->safe_psql('postgres', qq(
	INSERT INTO unanalyzed_tbl (embedding)
		SELECT array_fill(i::real, ARRAY[$dim])::vector
		FROM generate_series(1, $rows) i;
));
my $t_loaded = time();

my $reltuples = $node->safe_psql('postgres',
	"SELECT reltuples FROM pg_class WHERE oid = 'unanalyzed_tbl'::regclass;");
chomp $reltuples;
cmp_ok($reltuples, '<=', 0,
	'the table is never analyzed, so SvsMemoryCheckEstimatedBuildSize\'s pre-scan check is skipped '
  . '(src/svs_memory.c:571-572)')
  or diag("reltuples: $reltuples");

# Poll /proc/<backend pid>/status VmRSS for the backend running CREATE INDEX
# while it is in progress, recording the peak observed. The build is driven
# through a background session so this script's own connection is free to
# poll concurrently.
my $build = $node->background_psql('postgres', on_error_stop => 0);
$build->query_until(qr/build_started/, qq(
	\\echo build_started
	CREATE INDEX unanalyzed_idx ON unanalyzed_tbl USING vamana (embedding vector_l2_ops);
));

my $backend_pid;
for my $i (1 .. 100)
{
	my $pid_out = $node->safe_psql('postgres',
		"SELECT pid FROM pg_stat_activity WHERE query ILIKE 'CREATE INDEX%unanalyzed_idx%';");
	chomp $pid_out;
	if ($pid_out =~ /^\d+$/)
	{
		$backend_pid = $pid_out;
		last;
	}
	usleep(20_000);
}
ok(defined $backend_pid, 'found the backend pid running the CREATE INDEX')
  or diag('never saw the CREATE INDEX statement in pg_stat_activity');

my $peak_rss_kb = 0;
if (defined $backend_pid)
{
	for my $i (1 .. 300)
	{
		my $status_path = "/proc/$backend_pid/status";
		last unless -e $status_path;
		open(my $fh, '<', $status_path) or last;
		my $vmrss_kb;
		while (my $line = <$fh>)
		{
			if ($line =~ /^VmRSS:\s*(\d+)\s*kB/)
			{
				$vmrss_kb = $1;
				last;
			}
		}
		close $fh;
		$peak_rss_kb = $vmrss_kb if defined $vmrss_kb && $vmrss_kb > $peak_rss_kb;
		usleep(10_000);
	}
}

my $t_build_done = time();

# Flush the background session: this blocks until CREATE INDEX itself has
# finished (successfully or not), then runs this trailing statement.
$build->query('SELECT 1');
my $stderr = $build->{stderr};
$build->quit;

# Informational only. VmRSS includes the whole backend (catalog caches,
# shared-buffer mappings, etc.), not just this buffer, so at this ceiling
# (1024MB) the baseline backend footprint alone can push total VmRSS over
# the nominal threshold even once growth is correctly bounded -- confirmed
# empirically: this number does not reliably distinguish the fixed and
# unfixed code and so is not asserted on. See the two assertions below for
# the actual proof, which key off a deterministic log line instead.
diag(sprintf(
	'wall time: load %.1fs, build+poll %.1fs; peak backend VmRSS observed: %.2f MiB '
  . '(svs.max_build_memory ceiling: %.0f MiB, informational only)',
	$t_loaded - $t_start, $t_build_done - $t_loaded,
	$peak_rss_kb / 1024, $ceiling_bytes / 1024 / 1024));

like($stderr, qr/svs\.max_build_memory/,
	'the build is eventually refused, naming svs.max_build_memory')
  or diag("stderr: $stderr");
unlike($stderr, qr/invalid memory alloc request size/,
	'the refusal is not a plain allocation-size error')
  or diag("stderr: $stderr");

# The deterministic proof: "buffered N vectors for SVS index build" is a
# NOTICE logged (src/vamanabuild.c:760-761) immediately after
# table_index_build_scan returns, i.e. only once the scan -- and every
# repalloc_huge() SvsVectorBufferAppend performed along the way -- has
# finished. If growth is bounded at the point it happens (the fix), the
# scan itself is interrupted by the ERROR and this NOTICE is never reached.
# If it is not (the bug), the scan runs to completion, uninterrupted, and
# this NOTICE appears before the post-scan gate's ERROR ever gets a chance
# to run -- the exact sequence the issue's own reproduction measured.
unlike($stderr, qr/buffered \d+ vectors for SVS index build/,
	'the refusal happens before the scan completes: growth is bounded at the point it happens, '
  . 'not left to a post-scan check that only runs once the damage is already done')
  or diag("stderr: $stderr");

my $case_count = $node->safe_psql('postgres',
	"SELECT count(*) FROM pg_indexes WHERE indexname = 'unanalyzed_idx';");
chomp $case_count;
is($case_count, '0', 'the refused build left no index behind');

$node->safe_psql('postgres', "DROP TABLE unanalyzed_tbl;");

$node->stop;

done_testing();
