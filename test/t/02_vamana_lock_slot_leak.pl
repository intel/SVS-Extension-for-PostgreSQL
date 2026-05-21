# Tests that index lock slots are freed when an index is dropped.
#
# VamanaWorkerShmem.indexLocks[] has VAMANA_MAX_INDEXES (64) slots.
# If DROP INDEX does not zero the slot, the array fills after 64 cumulative
# creations and VamanaGetIndexLock emits a WARNING and returns NULL, causing
# subsequent searches and writes to run without concurrency control.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

srand(42);
my $dim       = 16;
my $array_sql = join(",", ('random()') x $dim);
my $query_sql = join(",", map { rand() } 1 .. $dim);

my $node = PostgreSQL::Test::Cluster->new('vamana_lock_leak');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "vamana.worker_database = 'postgres'");
$node->append_conf('postgresql.conf', "log_min_messages = 'warning'");
$node->start;

$node->safe_psql("postgres", "CREATE EXTENSION vector;");
$node->safe_psql("postgres", "CREATE EXTENSION svs;");

$node->safe_psql("postgres", qq(
    CREATE TABLE lock_leak_tbl (id serial PRIMARY KEY, val vector($dim));
    INSERT INTO lock_leak_tbl (val)
        SELECT ARRAY[$array_sql]::vector
        FROM generate_series(1, 10);
));

# Test 1: worker is running so searches go through VamanaGetIndexLock.
my $worker_pid = '';
for my $attempt (1 .. 20)
{
    usleep(500_000);
    $worker_pid = $node->safe_psql("postgres",
        "SELECT pid FROM pg_stat_activity "
      . "WHERE backend_type = 'vamana background worker' LIMIT 1;");
    chomp $worker_pid;
    last if $worker_pid =~ /^\d+$/;
}
ok($worker_pid =~ /^\d+$/, "vamana background worker is running (pid=$worker_pid)");

# Cycle through all 64 slots: each CREATE claims a slot, the query confirms
# the worker has claimed it (safe_psql blocks until the worker responds),
# and each DROP should free it.
for my $i (1 .. 64)
{
    $node->safe_psql("postgres",
        "CREATE INDEX lock_leak_idx ON lock_leak_tbl "
      . "USING vamana (val vector_l2_ops);");

    $node->safe_psql("postgres", qq(
        SET enable_seqscan = off;
        SELECT id FROM lock_leak_tbl ORDER BY val <-> '[$query_sql]' LIMIT 1;
    ));

    $node->safe_psql("postgres", "DROP INDEX lock_leak_idx;");
}

# Test 2: a 65th index must not trigger the lock-table-full WARNING.
# If DROP INDEX leaked slots, all 64 are still occupied and this WARNING fires.
my $log_pos = length($node->log_content());

$node->safe_psql("postgres",
    "CREATE INDEX lock_leak_idx ON lock_leak_tbl "
  . "USING vamana (val vector_l2_ops);");

$node->safe_psql("postgres", qq(
    SET enable_seqscan = off;
    SELECT id FROM lock_leak_tbl ORDER BY val <-> '[$query_sql]' LIMIT 1;
));

my $leak_log = substr($node->log_content(), $log_pos);

unlike(
    $leak_log,
    qr/vamana worker: index lock table full \(VAMANA_MAX_INDEXES=64\)/,
    'no lock slot exhaustion after 64 CREATE+DROP cycles'
) or diag(
    "WARNING found — DROP INDEX does not release the indexLocks[] slot.\n"
  . "Fix: make VamanaReleaseIndexLock non-static, declare it in vamanaworker.h,\n"
  . "and call it from VamanaObjectAccessHook when access == OAT_DROP.\n"
  . "Log excerpt:\n",
    substr($leak_log, 0, 2000)
);

$node->stop;
done_testing();
