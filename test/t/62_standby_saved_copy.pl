# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 62_standby_saved_copy.pl: a standby built from a basebackup that already
# holds an index's saved copy.
#
# The backup carries the primary's save directory, but the standby creates
# its own replication slot only once it loads the index, so that slot starts
# out short of CONSISTENT and the saved copy lacks every row committed after
# the save.  The standby must not trust that copy and must not try to write
# WAL while discarding it.
#
# Tests:
#   1. The saved copy is present in the standby's data directory before it
#      starts, so the load really goes through it.
#   2. The standby worker starts and the vamana index answers a query.
#   3. Rows committed after the save, both before the backup and after the
#      standby starts, are found through the standby's index.
#   4. The worker survives: same pid, and nothing in the log shows a crash or
#      an attempted WAL write.
#   5. Standby WAL replay of CREATE DATABASE, which waits for every backend
#      to absorb a ProcSignalBarrier, still completes.
#   6. The worker honours pg_terminate_backend and comes back serving.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

# Contents of a generation marker as hex, or 'absent'.
sub marker_hex
{
    my ($path) = @_;
    return 'absent' unless -f $path;
    open(my $fh, '<:raw', $path) or die "open $path: $!";
    my $data = do { local $/; <$fh> };
    close($fh);
    return unpack('H*', $data);
}

my $dim = 8;
my $near_sql = join(",", ('random()') x $dim);
my $far_sql = join(",", ('100 + random()') x $dim);
my $far_query = '[' . join(",", ('100.5') x $dim) . ']';

# Returns the query's output, or undef if it fails: a standby that has
# crashed must fail the remaining checks rather than abort the file.
sub try_psql
{
    my ($node, $sql) = @_;
    my ($ret, $out, $err);
    eval { ($ret, $out, $err) = $node->psql('postgres', $sql); 1 } or return undef;
    return $ret == 0 ? $out : undef;
}

sub standby_worker_pid
{
    my ($node) = @_;
    return try_psql($node,
        "SELECT worker_pid FROM pg_stat_vamana_worker "
      . "WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');");
}

sub wait_for_standby_worker
{
    my ($node, $old_pid) = @_;
    for (1 .. 150)
    {
        my $pid = standby_worker_pid($node);
        return $pid
          if defined $pid && $pid =~ /^\d+$/
          && (!defined $old_pid || $pid ne $old_pid);
        usleep(200_000);
    }
    return '';
}

# Number of far rows among the index's nearest $limit to the far query.
sub far_rows_via_index
{
    my ($node, $limit) = @_;
    return try_psql($node, qq{
        SET enable_seqscan = off;
        SELECT count(*) FROM (
            SELECT val FROM t ORDER BY val <-> '$far_query' LIMIT $limit) s
        WHERE val <-> '$far_query' < 50;
    });
}

sub wait_for_far_rows
{
    my ($node, $want) = @_;
    my $got;
    for (1 .. 150)
    {
        $got = far_rows_via_index($node, $want);
        return $got if defined $got && $got eq $want;
        usleep(200_000);
    }
    return $got // 'query failed';
}

my $primary = PostgreSQL::Test::Cluster->new('standby_saved_primary');
$primary->init(allows_streaming => 1);
$primary->append_conf('postgresql.conf', qq{
shared_preload_libraries = 'svs'
wal_level = logical
max_replication_slots = 10
max_wal_senders = 10
svs.launcher_database = 'postgres'
svs.checkpoint_min_ops = 999999
});
$primary->start;

$primary->safe_psql('postgres', "CREATE EXTENSION vector;");
$primary->safe_psql('postgres', "CREATE EXTENSION svs;");
$primary->safe_psql('postgres',
    "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");
$primary->safe_psql('postgres',
    "SELECT pg_create_physical_replication_slot('standby_saved_phys');");

$primary->safe_psql('postgres', qq{
    CREATE TABLE t (id serial PRIMARY KEY, val vector($dim));
    INSERT INTO t (val) SELECT ARRAY[$near_sql]::vector FROM generate_series(1, 200);
    CREATE INDEX t_idx ON t USING vamana (val vector_l2_ops);
});
wait_for_worker($primary, 30);

# A clean shutdown saves the index to disk.
$primary->restart;
wait_for_worker($primary, 30);

my $relid = $primary->safe_psql('postgres', "SELECT 't_idx'::regclass::oid;");
ok(-d vamana_save_dir($primary, 'postgres', $relid),
    'the primary holds a saved copy of the index');

# Committed after the save, so absent from the saved copy.
$primary->safe_psql('postgres',
    "INSERT INTO t (val) SELECT ARRAY[$far_sql]::vector FROM generate_series(1, 20);");

$primary->backup('standby_saved_backup');

my $standby = PostgreSQL::Test::Cluster->new('standby_saved_standby');
$standby->init_from_backup($primary, 'standby_saved_backup', has_streaming => 1);
$standby->append_conf('postgresql.conf', qq{
shared_preload_libraries = 'svs'
svs.launcher_database = 'postgres'
svs.checkpoint_min_ops = 999999
hot_standby = on
hot_standby_feedback = on
primary_slot_name = 'standby_saved_phys'
});

my $dboid = $primary->safe_psql('postgres',
    "SELECT oid FROM pg_database WHERE datname = 'postgres';");
ok(-d $standby->data_dir . "/vamana_indexes/$dboid/$relid",
    'the basebackup carried the saved copy to the standby');

# A worker crash at first load takes the standby down before start returns.
my $started = $standby->start(fail_ok => 1);
ok($started, 'the standby starts');
eval { $primary->wait_for_replay_catchup($standby) } if $started;
$primary->safe_psql('postgres', "SELECT pg_log_standby_snapshot();");

my $worker_pid = wait_for_standby_worker($standby, undef);
like($worker_pid, qr/^\d+$/, 'the standby worker starts');

is(wait_for_far_rows($standby, 20), '20',
    'rows committed after the save are found through the standby index');

# Committed after the standby is up.
$primary->safe_psql('postgres',
    "INSERT INTO t (val) SELECT ARRAY[$far_sql]::vector FROM generate_series(1, 20);");
$primary->safe_psql('postgres', "SELECT pg_log_standby_snapshot();");
is(wait_for_far_rows($standby, 40), '40',
    'rows committed after the standby started are found through its index');

is(standby_worker_pid($standby) // 'standby down', $worker_pid,
    'the standby worker never restarted');

my $log = slurp_file($standby->logfile);
unlike($log, qr/TRAP:|terminated by signal|cannot make new WAL entries/,
    'no crash and no attempted WAL write on the standby');

# Replaying CREATE DATABASE waits on a ProcSignalBarrier, which a worker left
# holding interrupts would never absorb.
$primary->safe_psql('postgres',
    "CREATE DATABASE barrier_db STRATEGY file_copy;");
my $replayed = 0;
for (1 .. 150)
{
    my $n = try_psql($standby,
        "SELECT count(*) FROM pg_database WHERE datname = 'barrier_db';");
    if (defined $n && $n eq '1') { $replayed = 1; last; }
    usleep(200_000);
}
ok($replayed, 'standby replay of CREATE DATABASE is not held up by the worker');

is(try_psql($standby, "SELECT pg_terminate_backend($worker_pid);") // 'query failed',
    't', 'pg_terminate_backend is accepted for the standby worker');
my $new_pid = wait_for_standby_worker($standby, $worker_pid);
like($new_pid, qr/^\d+$/, 'the terminated standby worker is replaced');
is(wait_for_far_rows($standby, 40), '40',
    'the replacement worker serves the full index');

$standby->stop;
$primary->stop;

# ---------------------------------------------------------------------------
# A standby's first load happening after replay has passed a newer primary
# save.
#
# The save directory's generation marker and TID map are plain files that
# never replicate, while the metapage's save generation does.  A standby whose
# first load comes after replay has applied a primary save made since the
# backup therefore sees stamps that differ although nothing tore.  Nothing on
# a standby ever saves, so that difference is expected there and must not be
# reported as a torn save.
#
# The database is disabled when the backup is taken and replay is paused on
# the standby, so the primary can re-enable it and save before the standby's
# launcher starts a worker for the database.
# ---------------------------------------------------------------------------
{
    my $p = PostgreSQL::Test::Cluster->new('standby_late_primary');
    $p->init(allows_streaming => 1);
    $p->append_conf('postgresql.conf', qq{
shared_preload_libraries = 'svs'
wal_level = logical
max_replication_slots = 10
max_wal_senders = 10
svs.launcher_database = 'postgres'
svs.checkpoint_min_ops = 1
svs.checkpoint_debounce_window = 1
});
    $p->start;
    $p->safe_psql('postgres', "CREATE EXTENSION vector;");
    $p->safe_psql('postgres', "CREATE EXTENSION svs;");
    $p->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");
    $p->safe_psql('postgres',
        "SELECT pg_create_physical_replication_slot('standby_late_phys');");
    $p->safe_psql('postgres', qq{
        CREATE TABLE t (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO t (val) SELECT ARRAY[$near_sql]::vector FROM generate_series(1, 200);
        CREATE INDEX t_idx ON t USING vamana (val vector_l2_ops);
    });
    wait_for_worker($p, 30);
    $p->restart;
    wait_for_worker($p, 30);

    my $late_relid = $p->safe_psql('postgres', "SELECT 't_idx'::regclass::oid;");
    my $late_dboid = $p->safe_psql('postgres',
        "SELECT oid FROM pg_database WHERE datname = 'postgres';");
    my $late_dir = vamana_save_dir($p, 'postgres', $late_relid);

    # Disabled for the backup, so a standby cloned from it starts no worker.
    $p->safe_psql('postgres',
        "UPDATE vamana_databases SET enabled = false WHERE datname = 'postgres';");
    for (1 .. 60)
    {
        last if $p->safe_psql('postgres',
            "SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'vamana worker';") eq '0';
        usleep(500_000);
    }
    $p->backup('standby_late_backup');

    my $backup_marker = marker_hex($p->backup_dir
          . "/standby_late_backup/vamana_indexes/$late_dboid/$late_relid/generation.bin");
    isnt($backup_marker, 'absent', 'the backup carries the saved copy');

    my $s = PostgreSQL::Test::Cluster->new('standby_late_standby');
    $s->init_from_backup($p, 'standby_late_backup', has_streaming => 1);
    $s->append_conf('postgresql.conf', qq{
shared_preload_libraries = 'svs'
svs.launcher_database = 'postgres'
svs.checkpoint_min_ops = 1
svs.checkpoint_debounce_window = 1
hot_standby = on
hot_standby_feedback = on
primary_slot_name = 'standby_late_phys'
});
    ok($s->start(fail_ok => 1), 'the standby starts');

    my $paused;
    for (1 .. 60)
    {
        $paused = try_psql($s, "SELECT pg_wal_replay_pause();");
        last if defined $paused;
        usleep(500_000);
    }
    is(try_psql($s, "SELECT pg_get_wal_replay_pause_state();") // 'query failed',
        'paused', 'standby replay is paused before the primary saves again');

    # Re-enable and save on the primary while the standby is not replaying.
    $p->safe_psql('postgres',
        "UPDATE vamana_databases SET enabled = true WHERE datname = 'postgres';");
    wait_for_worker($p, 60);
    $p->safe_psql('postgres',
        "INSERT INTO t (val) SELECT ARRAY[$far_sql]::vector FROM generate_series(1, 20);");
    my $now = $backup_marker;
    for (1 .. 60)
    {
        $now = marker_hex("$late_dir/generation.bin");
        last if $now ne $backup_marker;
        usleep(500_000);
    }
    isnt($now, $backup_marker,
        'the primary saved again, so its stamp is newer than the one in the standby copy');

    # Replay the enable and the newer save, then have the standby launcher
    # notice the enabled database now rather than at its next scheduled pass.
    my $log_pos = length(slurp_file($s->logfile));
    try_psql($s, "SELECT pg_wal_replay_resume();");
    eval { $p->wait_for_replay_catchup($s) };
    $p->safe_psql('postgres', "SELECT pg_log_standby_snapshot();");
    try_psql($s, "SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
          . "WHERE backend_type = 'vamana launcher';");

    my $pid = wait_for_standby_worker($s, undef);
    like($pid, qr/^\d+$/, 'the standby worker starts once the database is enabled');
    is(wait_for_far_rows($s, 20), '20',
        'the standby serves the rows saved after its copy was taken');

    my $late_log = substr(slurp_file($s->logfile), $log_pos);
    like($late_log, qr/loaded from disk/,
        'the standby loaded the copy from disk, so the generation check ran');
    unlike($late_log, qr/torn save detected/,
        'differing stamps on a standby are not reported as a torn save');

    $s->stop;
    $p->stop;
}

done_testing();
