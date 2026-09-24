use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

my $node = PostgreSQL::Test::Cluster->new('zz_scratch_decrease_probe');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'vector,svs'");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 20");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "svs.max_residency_memory = '16000MB'");
$node->append_conf('postgresql.conf', "svs.default_residency_memory = '16000MB'");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres',
	"INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");
my $pid1 = wait_for_worker($node);
diag("pid1=$pid1");

$node->safe_psql('postgres', qq(
	CREATE TABLE probe_tbl (id serial PRIMARY KEY, c1 vector($dim));
	INSERT INTO probe_tbl (c1)
		SELECT ARRAY[$array_sql]::vector FROM generate_series(1, 20000) i;
	CREATE INDEX probe_idx ON probe_tbl USING vamana (c1 vector_l2_ops);
));
wait_for_worker($node);

my $committed_before = $node->safe_psql('postgres',
	"SELECT residency_bytes_committed FROM pg_stat_vamana_worker "
  . "WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');");
chomp $committed_before;
diag("committed_before=$committed_before");

# Raw kill, WITHOUT disabling: the row stays enabled=true throughout.
kill('TERM', $pid1);
for (1 .. 100)
{
	usleep(100_000);
	my $alive = $node->safe_psql('postgres',
		"SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'vamana worker';");
	chomp $alive;
	last if $alive eq '0';
}
diag("worker process is down now (enabled stays true)");

my ($ret1, $stdout1, $stderr1) = $node->psql('postgres',
	"UPDATE vamana_databases SET residency_memory = 1 WHERE datname = 'postgres';");
diag("attempt while down: ret=$ret1 stderr=[$stderr1]");

my $limit_while_down = $node->safe_psql('postgres',
	"SELECT residency_memory_limit FROM pg_stat_vamana_worker "
  . "WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');");
chomp $limit_while_down;
diag("limit_while_down=$limit_while_down");

# Wait for the launcher's own crash-backoff respawn (enabled stays true throughout).
my $pid2 = '';
for (1 .. 200)
{
	usleep(100_000);
	$pid2 = $node->safe_psql('postgres',
		"SELECT pid FROM pg_stat_activity WHERE backend_type = 'vamana worker' LIMIT 1;");
	chomp $pid2;
	last if $pid2 =~ /^\d+$/ && $pid2 ne $pid1;
}
diag("pid2=$pid2 (respawned)");

my $committed_right_after_respawn = $node->safe_psql('postgres',
	"SELECT residency_bytes_committed FROM pg_stat_vamana_worker "
  . "WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');");
chomp $committed_right_after_respawn;
diag("committed_right_after_respawn=$committed_right_after_respawn");

my ($ret2, $stdout2, $stderr2) = $node->psql('postgres',
	"UPDATE vamana_databases SET residency_memory = 1 WHERE datname = 'postgres';");
diag("attempt right after respawn: ret=$ret2 stderr=[$stderr2]");

my $limit_after_respawn = $node->safe_psql('postgres',
	"SELECT residency_memory_limit FROM pg_stat_vamana_worker "
  . "WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');");
chomp $limit_after_respawn;
diag("limit_after_respawn=$limit_after_respawn");

# ---------------------------------------------------------------------------
# Scenario B: disable + kill (slot released), attempt the decrease while
# fully down, then re-enable and immediately attempt it again, before
# anything reloads.
# ---------------------------------------------------------------------------
$node->safe_psql('postgres',
	"UPDATE vamana_databases SET residency_memory = NULL WHERE datname = 'postgres';");

my $worker_pid = $node->safe_psql('postgres',
	"SELECT pid FROM pg_stat_activity WHERE backend_type = 'vamana worker';");
chomp $worker_pid;
$node->safe_psql('postgres',
	"UPDATE vamana_databases SET enabled = false WHERE datname = 'postgres';");
kill('TERM', $worker_pid);
for (1 .. 100)
{
	usleep(100_000);
	my $alive = $node->safe_psql('postgres',
		"SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'vamana worker';");
	chomp $alive;
	last if $alive eq '0';
}
diag("disabled and killed (scenario B)");

my $row_exists_while_disabled = $node->safe_psql('postgres',
	"SELECT count(*) FROM pg_stat_vamana_worker "
  . "WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');");
chomp $row_exists_while_disabled;
diag("row_exists_while_disabled=$row_exists_while_disabled");

my ($ret3, $stdout3, $stderr3) = $node->psql('postgres',
	"UPDATE vamana_databases SET residency_memory = 1 WHERE datname = 'postgres';");
diag("attempt while disabled: ret=$ret3 stderr=[$stderr3]");

my $column_value_while_disabled = $node->safe_psql('postgres',
	"SELECT residency_memory FROM vamana_databases WHERE datname = 'postgres';");
chomp $column_value_while_disabled;
diag("column_value_while_disabled=$column_value_while_disabled");

my ($ret_reenable, $stdout_reenable, $stderr_reenable) = $node->psql('postgres',
	"UPDATE vamana_databases SET enabled = true WHERE datname = 'postgres';");
diag("re-enable with residency_memory still at $column_value_while_disabled MB: "
   . "ret=$ret_reenable stderr=[$stderr_reenable]");

my $committed_right_after_reenable = $node->safe_psql('postgres',
	"SELECT residency_bytes_committed FROM pg_stat_vamana_worker "
  . "WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');");
chomp $committed_right_after_reenable;
diag("committed_right_after_reenable=$committed_right_after_reenable (column was already $column_value_while_disabled MB)");

my ($ret4, $stdout4, $stderr4) = $node->psql('postgres',
	"UPDATE vamana_databases SET residency_memory = 1 WHERE datname = 'postgres';");
diag("attempt right after re-enable (still 1MB, no-op update): ret=$ret4 stderr=[$stderr4]");

# The rejected re-enable above rolled back its whole transaction, so
# 'postgres' is still disabled. Fix the override and re-enable together, in
# one statement, so enabled only flips true once residency_memory already
# resolves to something valid -- avoids re-creating the same chicken-and-egg
# rejection just to get back to a clean baseline.
$node->safe_psql('postgres',
	"UPDATE vamana_databases SET residency_memory = NULL, enabled = true WHERE datname = 'postgres';");
my $enabled_after_fix = $node->safe_psql('postgres',
	"SELECT enabled FROM vamana_databases WHERE datname = 'postgres';");
chomp $enabled_after_fix;
diag("enabled_after_fix=$enabled_after_fix");
wait_for_worker($node);

# ---------------------------------------------------------------------------
# Scenario C: full postmaster restart (shared memory genuinely reinitializes,
# unlike a plain worker-process kill). Attempt the decrease as the very
# first action post-restart, racing the launcher's own respawn. 'postgres'
# is genuinely enabled=true going in, unlike scenario B.
# ---------------------------------------------------------------------------
$node->restart;

my $post_restart_worker_state = $node->safe_psql('postgres',
	"SELECT worker_state FROM pg_stat_vamana_worker "
  . "WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');");
chomp $post_restart_worker_state;
my $post_restart_committed = $node->safe_psql('postgres',
	"SELECT residency_bytes_committed FROM pg_stat_vamana_worker "
  . "WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');");
chomp $post_restart_committed;
diag("immediately after postmaster restart: worker_state=$post_restart_worker_state "
   . "committed=$post_restart_committed");

my $durable_row_survives = $node->safe_psql('postgres',
	"SELECT resident_bytes FROM svs_index_residency WHERE index_relid = "
  . "(SELECT 'probe_idx'::regclass::oid);");
chomp $durable_row_survives;
diag("durable row after postmaster restart: resident_bytes=$durable_row_survives");

my ($ret5, $stdout5, $stderr5) = $node->psql('postgres',
	"UPDATE vamana_databases SET residency_memory = 1 WHERE datname = 'postgres';");
diag("attempt immediately after postmaster restart: ret=$ret5 stderr=[$stderr5]");

my $post_attempt_row = $node->safe_psql('postgres', qq(
	SELECT w.residency_bytes_committed, w.residency_memory_limit, w.worker_state
	FROM pg_stat_vamana_worker w
	WHERE w.db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');
));
diag("post_attempt_row=[$post_attempt_row]");
my $post_attempt_column = $node->safe_psql('postgres',
	"SELECT residency_memory FROM vamana_databases WHERE datname = 'postgres';");
diag("post_attempt_column=[$post_attempt_column]");

ok(1, 'probe ran');
$node->stop;
done_testing();
