# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 32_eviction_guard_scope.pl — vamana_active_load_relid must bracket the
# whole transaction, at every call site that sets it.
#
# A relcache invalidation for an unrelated, untouched cached index can be
# delivered as soon as StartTransactionCommand runs. The guard must already
# be set at that point, or VamanaRelcacheCallback evicts the bystander and
# forces a needless cold reload on its next query. Driven by injection
# points so the delivery is deterministic instead of racing real timing.

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

my $node = PostgreSQL::Test::Cluster->new('vamana_guard_scope');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 10");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->append_conf('postgresql.conf', "log_min_messages = debug1");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres', "CREATE EXTENSION injection_points;");
$node->safe_psql('postgres',
    "INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);");

sub make_table
{
    my ($name) = @_;
    $node->safe_psql('postgres', qq{
        CREATE TABLE $name (id serial PRIMARY KEY, val vector($dim));
        INSERT INTO $name (val)
            SELECT ARRAY[$array_sql]::vector
            FROM generate_series(1, 20);
    });
}

sub relid_of
{
    my ($idx) = @_;
    my $r = $node->safe_psql('postgres', "SELECT '$idx'::regclass::oid;");
    chomp $r;
    return $r;
}

my $worker_pid = wait_for_worker($node, 30);
ok($worker_pid =~ /^\d+$/, "worker running (pid=$worker_pid)");

# Bystander, shared across all three blocks: created once, queried once to
# cache it, then left untouched except for the ALTER that manufactures a
# pure relcache invalidation with no reload-queue side effect.
make_table('bystand');
$node->safe_psql('postgres', qq{
    CREATE INDEX bystand_idx ON bystand USING vamana (val vector_l2_ops);
    SET enable_seqscan = off;
    SELECT id FROM bystand ORDER BY val <-> '[$query_sql]' LIMIT 1;
});
my $bystand_relid = relid_of('bystand_idx');

sub assert_bystander_untouched
{
    my ($label, $log_offset) = @_;

    my $delta = substr(slurp_file($node->logfile), $log_offset);
    ok($delta !~ /evicting vamana cache entry for relation $bystand_relid\b/,
        "$label: bystander was NOT evicted");

    my $offset2 = -s $node->logfile;
    $node->safe_psql('postgres', qq{
        SET enable_seqscan = off;
        SELECT id FROM bystand ORDER BY val <-> '[$query_sql]' LIMIT 1;
    });
    my $delta2 = substr(slurp_file($node->logfile), $offset2);
    unlike($delta2, qr/loading vamana index $bystand_relid\b/,
        "$label: bystander stayed cached (no cold reload)");
}

sub jab_bystander
{
    $node->safe_psql('postgres',
        "ALTER INDEX bystand_idx SET (search_window_size = 77);");
}

# ---------------------------------------------------------------------------
# Reload path: vamanaworker.c, VamanaWorkerProcessReloads
# ---------------------------------------------------------------------------
{
    make_table('reload_tgt');
    $node->safe_psql('postgres', qq{
        CREATE INDEX reload_tgt_idx ON reload_tgt USING vamana (val vector_l2_ops);
        SET enable_seqscan = off;
        SELECT id FROM reload_tgt ORDER BY val <-> '[$query_sql]' LIMIT 1;
    });

    $node->safe_psql('postgres',
        "SELECT injection_points_attach('vamana-reload-before-txn-start', 'wait');");

    my $offset = -s $node->logfile;
    $node->safe_psql('postgres', "TRUNCATE reload_tgt;");

    $node->wait_for_event('vamana worker', 'vamana-reload-before-txn-start');

    jab_bystander();

    $node->safe_psql('postgres',
        "SELECT injection_points_wakeup('vamana-reload-before-txn-start');");
    $node->safe_psql('postgres',
        "SELECT injection_points_detach('vamana-reload-before-txn-start');");

    usleep(200_000) for (1 .. 10);

    assert_bystander_untouched('reload', $offset);
}

# ---------------------------------------------------------------------------
# Load-slot path: vamanaworkerwrite.c, VamanaWorkerProcessLoadSlot
# ---------------------------------------------------------------------------
{
    make_table('load_tgt');

    $node->safe_psql('postgres',
        "SELECT injection_points_attach('vamana-load-before-txn-start', 'wait');");

    my $offset = -s $node->logfile;

    my $build = $node->background_psql('postgres', on_error_stop => 1);
    $build->query_until(qr/build_started/, qq(
        \\echo build_started
        CREATE INDEX load_tgt_idx ON load_tgt USING vamana (val vector_l2_ops);
    ));

    $node->wait_for_event('vamana worker', 'vamana-load-before-txn-start');

    jab_bystander();

    $node->safe_psql('postgres',
        "SELECT injection_points_wakeup('vamana-load-before-txn-start');");
    $node->safe_psql('postgres',
        "SELECT injection_points_detach('vamana-load-before-txn-start');");

    $build->query('SELECT 1');
    $build->quit;

    assert_bystander_untouched('load-slot', $offset);
}

# ---------------------------------------------------------------------------
# Warmup path: vamanaworkerwrite.c, VamanaWorkerProcessWarmupSlot
# ---------------------------------------------------------------------------
{
    make_table('warmup_tgt');
    $node->safe_psql('postgres',
        "CREATE INDEX warmup_tgt_idx ON warmup_tgt USING vamana (val vector_l2_ops);");

    $node->safe_psql('postgres',
        "SELECT injection_points_attach('vamana-warmup-before-txn-start', 'wait');");

    my $offset = -s $node->logfile;

    my $warmup = $node->background_psql('postgres', on_error_stop => 1);
    $warmup->query_until(qr/warmup_started/, qq(
        \\echo warmup_started
        SELECT svs_warmup_index('warmup_tgt_idx');
    ));

    $node->wait_for_event('vamana worker', 'vamana-warmup-before-txn-start');

    jab_bystander();

    $node->safe_psql('postgres',
        "SELECT injection_points_wakeup('vamana-warmup-before-txn-start');");
    $node->safe_psql('postgres',
        "SELECT injection_points_detach('vamana-warmup-before-txn-start');");

    $warmup->query('SELECT 1');
    $warmup->quit;

    assert_bystander_untouched('warmup', $offset);
}

$node->stop;

done_testing();
