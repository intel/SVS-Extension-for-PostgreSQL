# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 041_launcher_orphaned_slot_release.pl — pausing a database and later
# deleting its row releases the shared-memory slot instead of leaking it.
#
# ReconcileLedgerLiveness() classifies a stopped ledger worker with
# ClassifyWorkerStop().  A row that is still present but disabled classifies
# as STOP_DISABLED, which drops the ledger entry but keeps the slot (correct:
# a paused database keeps its slot while its row exists).  A row that is
# already gone classifies as STOP_REMOVED, which releases the slot -- but
# only a ledger entry that is *still present* when its row disappears can
# ever be classified that way.  Disable-then-delete drops the ledger entry at
# the disable step, so the later DELETE has nothing left to classify, and
# nothing else in the launcher ever releases that slot.  Two such cycles
# exhaust svs.max_databases, and the resulting error blames a limit that no
# enabled database is actually using.
#
# svs.max_databases is set to 2 so exhaustion is reached in two iterations
# instead of eight.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

my $MAX_DATABASES = 2;

my $node = PostgreSQL::Test::Cluster->new('launcher_orphan_slot');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 20");
$node->append_conf('postgresql.conf', "max_wal_senders = 20");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->append_conf('postgresql.conf', "svs.max_databases = $MAX_DATABASES");
# A row's ceiling check sums every row in vamana_databases, paused ones
# included, and residency admission sums every currently-reserved slot;
# several coexist briefly across this test's enable/pause/delete cycles, so
# the default ceilings (sized for one) are raised.
$node->append_conf('postgresql.conf', "svs.max_search_work_mem = '400MB'");
$node->append_conf('postgresql.conf', "svs.max_residency_memory = '400MB'");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");

for my $db (qw(orphan_a orphan_b orphan_c))
{
    $node->safe_psql('postgres', "CREATE DATABASE $db;");
}

sub db_oid
{
    my ($node, $db) = @_;
    my $oid = $node->safe_psql('postgres',
        "SELECT oid FROM pg_database WHERE datname = '$db';");
    chomp $oid;
    return $oid;
}

# Superuser, so pg_stat_vamana_worker shows every reserved slot cluster-wide.
sub reserved_slots
{
    my ($node) = @_;
    my $n = $node->safe_psql('postgres', "SELECT count(*) FROM pg_stat_vamana_worker;");
    chomp $n;
    return $n;
}

sub worker_gone
{
    my ($node, $db) = @_;
    for (1 .. 80)          # 40 s
    {
        my $n = $node->safe_psql('postgres',
            "SELECT count(*) FROM pg_stat_activity "
          . "WHERE backend_type = 'vamana worker' AND datname = '$db';");
        chomp $n;
        return 1 if $n eq '0';
        usleep(500_000);
    }
    return 0;
}

is(reserved_slots($node), '0', 'no slots reserved before any database is enabled');

# ---------------------------------------------------------------------------
# Pause-then-remove, twice. Each iteration should leave the cluster exactly as
# it started: no row, no worker, no reserved slot -- once the release's grace
# period (VAMANA_ORPHAN_SLOT_GRACE_MS) has passed.
# ---------------------------------------------------------------------------
my @released_oids;

for my $db (qw(orphan_a orphan_b))
{
    my $oid = db_oid($node, $db);
    push @released_oids, $oid;

    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('$db', true);");
    my $pid = wait_for_worker_db($node, $db, 40);
    ok($pid =~ /^\d+$/, "$db: worker started (pid=$pid)");

    # Step 1: pause it.
    $node->safe_psql('postgres',
        "UPDATE vamana_databases SET enabled = false WHERE datname = '$db';");
    ok(worker_gone($node, $db), "$db: worker stopped after the pause");

    # The slot is intentionally retained while paused -- that part is by
    # design and must not regress.
    my $while_paused = $node->safe_psql('postgres',
        "SELECT count(*) FROM pg_stat_vamana_worker WHERE db_oid = $oid;");
    chomp $while_paused;
    is($while_paused, '1', "$db: slot retained while paused (by design)");

    # Step 2: now remove the row. No vamana indexes exist, so the BEFORE
    # DELETE guard permits it.
    my ($rc, undef, $err) = $node->psql('postgres',
        "DELETE FROM vamana_databases WHERE datname = '$db';");
    is($rc, 0, "$db: row removed") or diag($err);

    my $rows = $node->safe_psql('postgres',
        "SELECT count(*) FROM vamana_databases WHERE datname = '$db';");
    chomp $rows;
    is($rows, '0', "$db: catalog row is gone");

    # Step 3: the slot is released, once the orphan grace period elapses.
    # wait_for_slot_release polls up to 60 x 0.5s = 30s, comfortably above
    # VAMANA_ORPHAN_SLOT_GRACE_MS (5s).
    ok(wait_for_slot_release($node, 'postgres', $oid, 60),
        "$db: the shmem slot is released after its row is removed, "
      . "even though STOP_DISABLED already dropped the ledger entry")
      or diag("slot for $db (oid=$oid) still reserved 30 s after the DELETE");
}

# ---------------------------------------------------------------------------
# No orphaned slot outlives its database in the observability view.
# ---------------------------------------------------------------------------
{
    is(reserved_slots($node), '0',
        'both slots were released; none are stranded for a database with no row');

    for my $db (qw(orphan_a orphan_b))
    {
        $node->safe_psql('postgres', "DROP DATABASE $db;");
    }

    my $orphans = $node->safe_psql('postgres',
        "SELECT count(*) FROM pg_stat_vamana_worker s "
      . "WHERE NOT EXISTS (SELECT 1 FROM pg_database d WHERE d.oid = s.db_oid);");
    chomp $orphans;
    is($orphans, '0',
        'pg_stat_vamana_worker reports no slot for a database OID that no longer exists')
      or diag("$orphans slot(s) point at dropped databases (oids: "
            . join(', ', @released_oids) . ")");
}

# ---------------------------------------------------------------------------
# The consequence the leak used to cause: enabling a further database at the
# svs.max_databases ceiling now succeeds, because the released slots are
# actually free again.
# ---------------------------------------------------------------------------
{
    my ($rc, undef, $err) = $node->psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('orphan_c', true);");

    diag("enabling orphan_c: rc=$rc stderr:\n$err") if $rc != 0;

    is($rc, 0,
        'enabling a third database succeeds -- the released slots are available again');
}

# ---------------------------------------------------------------------------
# The DROP DATABASE variant, with no preceding disable: releasing a slot for
# a database that was simply dropped while enabled behaves the same way.
# ---------------------------------------------------------------------------
{
    $node->safe_psql('postgres', "CREATE DATABASE orphan_d;");
    my $oid = db_oid($node, 'orphan_d');

    $node->safe_psql('postgres',
        "INSERT INTO vamana_databases (datname, enabled) VALUES ('orphan_d', true);");
    my $pid = wait_for_worker_db($node, 'orphan_d', 40);
    ok($pid =~ /^\d+$/, "orphan_d: worker started (pid=$pid)");

    $node->safe_psql('postgres',
        "UPDATE vamana_databases SET enabled = false WHERE datname = 'orphan_d';");
    ok(worker_gone($node, 'orphan_d'), 'orphan_d: worker stopped after the pause');

    $node->safe_psql('postgres',
        "DELETE FROM vamana_databases WHERE datname = 'orphan_d';");
    $node->safe_psql('postgres', "DROP DATABASE orphan_d;");

    ok(wait_for_slot_release($node, 'postgres', $oid, 60),
        'orphan_d: the slot is released after DROP DATABASE with no row left behind')
      or diag("slot for orphan_d (oid=$oid) still reserved 30 s after DROP DATABASE");
}

# ---------------------------------------------------------------------------
# The race the release pass must not lose: a slot reserved by an enrollment
# whose transaction has not yet committed must not be released, even though
# it looks identical -- no matching row -- to a genuinely orphaned slot for
# as long as the injection point below holds the enrolling transaction open.
#
# Reservation happens at that transaction's PRE_COMMIT, a moment before its
# row becomes visible to any other backend's snapshot, so parking there and
# forcing several reconcile passes across more than the release pass's grace
# period is what actually exercises the race, not just its absence.
# ---------------------------------------------------------------------------
if (($ENV{enable_injection_points} // 'no') eq 'yes')
{
    $node->safe_psql('postgres', "CREATE EXTENSION injection_points;");
    $node->safe_psql('postgres', "CREATE DATABASE orphan_e;");
    my $oid = db_oid($node, 'orphan_e');

    my $point = 'vamana-databases-reserved-precommit';
    $node->safe_psql('postgres', "SELECT injection_points_attach('$point', 'wait');");

    my $enroll = $node->background_psql('postgres');
    $enroll->query_until(qr/enroll_started/, qq(
        \\echo enroll_started
        INSERT INTO vamana_databases (datname, enabled) VALUES ('orphan_e', true);
    ));
    $node->wait_for_event('client backend', $point);

    my $row_visible = $node->safe_psql('postgres',
        "SELECT count(*) FROM vamana_databases WHERE datname = 'orphan_e';");
    chomp $row_visible;
    is($row_visible, '0',
        '(confirming) the enrolling row is not yet visible while parked at PRE_COMMIT');

    my $reserved_while_parked = $node->safe_psql('postgres',
        "SELECT count(*) FROM pg_stat_vamana_worker WHERE db_oid = $oid;");
    chomp $reserved_while_parked;
    is($reserved_while_parked, '1',
        '(confirming) the slot is already reserved in shared memory while parked');

    # Force several reconcile passes, spanning longer than the orphan grace
    # period, while the enrollment is still uncommitted.  A direct NOTIFY,
    # not a write to vamana_databases: the parked transaction is still
    # holding its ShareRowExclusiveLock on that relation from its own
    # PRE_COMMIT trigger, so any DML against it here would simply queue
    # behind that lock until this test calls injection_points_wakeup below.
    for (1 .. 12)
    {
        $node->safe_psql('postgres', "SELECT pg_notify('vamana_databases_changed', '');");
        usleep(500_000);
    }

    my $still_reserved = $node->safe_psql('postgres',
        "SELECT count(*) FROM pg_stat_vamana_worker WHERE db_oid = $oid;");
    chomp $still_reserved;
    is($still_reserved, '1',
        'the slot for an enrollment whose transaction has not committed is not released, '
      . 'even after the orphan grace period elapses while its row is still invisible');

    $node->safe_psql('postgres', "SELECT injection_points_wakeup('$point');");
    $node->safe_psql('postgres', "SELECT injection_points_detach('$point');");

    $enroll->query('SELECT 1');
    $enroll->quit;

    my $committed = $node->safe_psql('postgres',
        "SELECT count(*) FROM vamana_databases WHERE datname = 'orphan_e';");
    chomp $committed;
    is($committed, '1', 'the enrollment commits normally once released');

    my $pid = wait_for_worker_db($node, 'orphan_e', 40);
    ok($pid =~ /^\d+$/,
        "orphan_e: worker starts normally once the parked commit completes (pid=$pid)");

    $node->safe_psql('postgres',
        "UPDATE vamana_databases SET enabled = false WHERE datname = 'orphan_e';");
    ok(worker_gone($node, 'orphan_e'), 'orphan_e: worker stopped for cleanup');
    $node->safe_psql('postgres', "DELETE FROM vamana_databases WHERE datname = 'orphan_e';");
    $node->safe_psql('postgres', "DROP DATABASE orphan_e;");
    ok(wait_for_slot_release($node, 'postgres', $oid, 60),
        'orphan_e: slot released during cleanup');
}
else
{
    diag('skipping in-flight-enrollment race check: server not built with '
       . '--enable-injection-points');
}

$node->stop;

done_testing();
