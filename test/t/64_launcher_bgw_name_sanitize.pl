# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 064_launcher_bgw_name_sanitize.pl -- a database name with control bytes
# (including a raw newline) must not reach the postmaster's background
# worker lifecycle log lines, or the launcher's own capacity-exceeded log
# line, unsanitized.
#
# RegisterDatabaseWorker() (src/vamanalauncher.c) formats bgw.bgw_name
# directly from db->datname.  Any role with CREATEDB can create a database
# whose name contains control characters, and once a database owner enrolls
# it in vamana_databases, every launcher cycle calls RegisterDatabaseWorker()
# for it.  The postmaster logs "registering background worker \"<bgw_name>\""
# and "unregistering background worker \"<bgw_name>\"" at DEBUG1 for every
# dynamic worker (src/backend/postmaster/bgworker.c); those lines are
# line-oriented and consumed by log parsers, so a raw newline in bgw_name is
# a log/line injection, not merely cosmetic.
#
# Core's own ascii_safe_strlcpy() (used when the postmaster copies bgw_name
# out of shared memory) explicitly passes '\n', '\r', and '\t' through
# unchanged -- it only replaces non-whitespace control/non-ASCII bytes with
# '?' -- so core provides no safety net for this byte.  The fix reuses
# CopySanitizedDatname() (src/svs_slot_naming.c), which runs datname through
# core's pg_clean_ascii() first; that function escapes every byte outside
# 32-126 (including '\n') to a literal "\xHH" sequence, so the sanitized
# name can never split a log line.
#
# log_min_messages is raised to debug1 so the register/unregister lines are
# actually emitted.
#
# VamanaWorkerReserveSlotOrLog() (src/vamanalauncher.c) has the identical
# bug on its own LOG line: it formats the "could not reserve a slot for
# database" message directly from datname.  Its two callers,
# RegisterDatabaseWorker() and MaterializeInitialConfig(), only reach that
# LOG line when a reservation genuinely fails, which does not happen through
# ordinary enrollment -- enabling a database reserves its slot inline and
# raises an ERROR of its own (a separate, already-sanitized call site) if
# svs.max_databases is already exhausted at that moment.  The reachable path
# is lowering svs.max_databases below the number of already-enabled rows and
# restarting: MaterializeInitialConfig() then reserves slots for the enabled
# rows in scan order, and whichever rows no longer fit hit the unsanitized
# LOG line.  The second half of this test reproduces exactly that.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

my $node = PostgreSQL::Test::Cluster->new('launcher_bgw_name_sanitize');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node->append_conf('postgresql.conf', "log_min_messages = 'debug1'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_wal_senders = 4");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");

# ---------------------------------------------------------------------------
# A database name carrying a raw newline, a non-whitespace control byte, and
# a literal '%s' (to rule out a format-string-adjacent bug, though snprintf
# already makes that class of bug impossible). Short enough to stay well
# under NAMEDATALEN with room to spare.
# ---------------------------------------------------------------------------
my $ctrl    = "\x01";
my $nl      = "\n";
my $rawname = "evilname%s${ctrl}db${nl}end";

# pg_clean_ascii()'s escaped form: every byte outside printable ASCII
# (32-126) becomes a literal four-character "\xHH" sequence; '%', 's', 'd',
# 'b', 'e', 'n' are all printable ASCII and pass through unchanged.
my $sanitized = 'evilname%s\x01db\x0aend';

sub wait_for_worker_oid
{
    my ($node, $oid, $attempts) = @_;
    $attempts //= 60;
    for (1 .. $attempts)
    {
        my $pid = $node->safe_psql('postgres',
            "SELECT pid FROM pg_stat_activity "
          . "WHERE backend_type = 'vamana worker' AND datid = $oid LIMIT 1;");
        chomp $pid;
        return $pid if $pid =~ /^\d+$/;
        usleep(500_000);
    }
    return '';
}

sub wait_for_worker_oid_gone
{
    my ($node, $oid, $attempts) = @_;
    $attempts //= 60;
    for (1 .. $attempts)
    {
        my $n = $node->safe_psql('postgres',
            "SELECT count(*) FROM pg_stat_activity "
          . "WHERE backend_type = 'vamana worker' AND datid = $oid;");
        chomp $n;
        return 1 if $n eq '0';
        usleep(500_000);
    }
    return 0;
}

$node->safe_psql('postgres', qq(CREATE DATABASE "$rawname";));

my $oid = $node->safe_psql('postgres',
    "SELECT oid FROM pg_database WHERE datname = '$rawname';");
chomp $oid;
ok($oid =~ /^\d+$/, "evil-named database created (oid=$oid)");

$node->safe_psql('postgres',
    "INSERT INTO vamana_databases (datname, enabled) VALUES ('$rawname', true);");

my $pid = wait_for_worker_oid($node, $oid, 60);
ok($pid =~ /^\d+$/, "worker started for the evil-named database (pid=$pid)");

$node->safe_psql('postgres',
    "UPDATE vamana_databases SET enabled = false WHERE datname = '$rawname';");
ok(wait_for_worker_oid_gone($node, $oid, 60),
    'worker stopped after the database was disabled');

$node->safe_psql('postgres',
    "DELETE FROM vamana_databases WHERE datname = '$rawname';");
$node->safe_psql('postgres', qq(DROP DATABASE "$rawname";));

my $log = slurp_file($node->logfile);

like($log,
    qr/\Qregistering background worker "vamana worker: $sanitized"\E/,
    'the worker start log line carries the sanitized, single-line datname');

like($log,
    qr/\Qunregistering background worker "vamana worker: $sanitized"\E/,
    'the worker stop log line carries the sanitized, single-line datname');

like($log,
    qr/\Qvamana background worker started for database "$sanitized"\E/,
    'the worker-started log line (VamanaWorkerRunStartupTransaction) carries '
  . 'the sanitized, single-line datname');

$node->stop;

# ---------------------------------------------------------------------------
# VamanaWorkerReserveSlotOrLog()'s own capacity-exceeded LOG line, hit via
# MaterializeInitialConfig() at startup: two databases are enabled while
# svs.max_databases = 2, then the server is restarted with svs.max_databases
# lowered to 1, so the second enabled row (the evil-named one) can no longer
# get a slot.
# ---------------------------------------------------------------------------
my $node2 = PostgreSQL::Test::Cluster->new('launcher_bgw_name_sanitize_cap');
$node2->init;
$node2->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node2->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node2->append_conf('postgresql.conf', "log_min_messages = 'debug1'");
$node2->append_conf('postgresql.conf', "wal_level = logical");
$node2->append_conf('postgresql.conf', "max_wal_senders = 4");
$node2->append_conf('postgresql.conf', "svs.max_databases = 2");
# Two enabled databases must fit under the default search/residency memory
# ceilings (sized for one).
$node2->append_conf('postgresql.conf', "svs.max_search_work_mem = '400MB'");
$node2->append_conf('postgresql.conf', "svs.max_residency_memory = '400MB'");
$node2->start;

$node2->safe_psql('postgres', "CREATE EXTENSION vector;");
$node2->safe_psql('postgres', "CREATE EXTENSION svs;");

$node2->safe_psql('postgres', "CREATE DATABASE filler;");
$node2->safe_psql('postgres',
    "INSERT INTO vamana_databases (datname, enabled) VALUES ('filler', true);");

$node2->safe_psql('postgres', qq(CREATE DATABASE "$rawname";));
$node2->safe_psql('postgres',
    "INSERT INTO vamana_databases (datname, enabled) VALUES ('$rawname', true);");

my $enabled_count = $node2->safe_psql('postgres',
    "SELECT count(*) FROM vamana_databases WHERE enabled;");
chomp $enabled_count;
is($enabled_count, '2', 'both databases enrolled and enabled under svs.max_databases = 2');

$node2->stop;
$node2->append_conf('postgresql.conf', "svs.max_databases = 1");
$node2->start;

# Give the launcher's initial scan time to run and log the capacity failure.
my $capacity_log = '';
for (1 .. 60)
{
    $capacity_log = slurp_file($node2->logfile);
    last if $capacity_log =~ /could not reserve a slot/;
    usleep(500_000);
}

like($capacity_log,
    qr/\Qcould not reserve a slot for database "$sanitized"\E/,
    'the capacity-exceeded log line carries the sanitized, single-line datname');

$node2->stop;

# ---------------------------------------------------------------------------
# Two more sinks of the same bug, both reached without any resource
# exhaustion or restart:
#
# vamana_databases_reject_delete_with_live_indexes() (src/vamana_databases.c)
# rejects an ordinary DELETE FROM vamana_databases while the database still
# has a live vamana index, and its ERROR message interpolates datname twice.
#
# ReadDatabaseRows() (src/vamanalauncher.c) logs "database ... does not
# exist; skipping" on every reconcile cycle for a row whose database has
# been dropped out from under it. DROP DATABASE requires no live
# connections, so the row is disabled (stopping the worker) before the drop.
# ---------------------------------------------------------------------------
my $node3 = PostgreSQL::Test::Cluster->new('launcher_bgw_name_sanitize_misc');
$node3->init;
$node3->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node3->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node3->append_conf('postgresql.conf', "log_min_messages = 'debug1'");
$node3->append_conf('postgresql.conf', "wal_level = logical");
$node3->append_conf('postgresql.conf', "max_wal_senders = 4");
$node3->start;

$node3->safe_psql('postgres', "CREATE EXTENSION vector;");
$node3->safe_psql('postgres', "CREATE EXTENSION svs;");

$node3->safe_psql('postgres', qq(CREATE DATABASE "$rawname";));
$node3->safe_psql('postgres',
    "INSERT INTO vamana_databases (datname, enabled) VALUES ('$rawname', true);");

my $oid3 = $node3->safe_psql('postgres',
    "SELECT oid FROM pg_database WHERE datname = '$rawname';");
chomp $oid3;
my $pid3 = wait_for_worker_oid($node3, $oid3, 60);
ok($pid3 =~ /^\d+$/, "worker started for the evil-named database on node3 (pid=$pid3)");

$node3->safe_psql($rawname, "CREATE EXTENSION vector;");
$node3->safe_psql($rawname, "CREATE EXTENSION svs;");
$node3->safe_psql($rawname, "CREATE TABLE t (id bigint, v vector(4));");
$node3->safe_psql($rawname,
    "INSERT INTO t SELECT g, ARRAY[random(), random(), random(), random()]::vector(4) "
  . "FROM generate_series(1, 10) g;");
$node3->safe_psql($rawname, "CREATE INDEX t_idx ON t USING vamana (v vector_l2_ops);");

my ($delete_rc, undef, $delete_stderr) = $node3->psql('postgres',
    "DELETE FROM vamana_databases WHERE datname = '$rawname';");
isnt($delete_rc, 0, 'deleting the row while a live vamana index exists is rejected');

like($delete_stderr,
    qr/\Qcannot remove "$sanitized" from vamana_databases:\E/,
    'the delete-rejection error carries the sanitized, single-line datname');
like($delete_stderr,
    qr/\Qrun svs_teardown_database() in "$sanitized" first\E/,
    'the delete-rejection errhint carries the sanitized, single-line datname');

$node3->safe_psql('postgres',
    "UPDATE vamana_databases SET enabled = false WHERE datname = '$rawname';");
ok(wait_for_worker_oid_gone($node3, $oid3, 60),
    'node3: worker stopped after the database was disabled');

$node3->safe_psql('postgres', qq(DROP DATABASE "$rawname";));

my $skip_log = '';
for (1 .. 60)
{
    $skip_log = slurp_file($node3->logfile);
    last if $skip_log =~ /does not exist; skipping/;
    $node3->safe_psql('postgres', "SELECT pg_notify('vamana_databases_changed', '');");
    usleep(500_000);
}

like($skip_log,
    qr/\Qdatabase "$sanitized" does not exist; skipping\E/,
    'the dropped-database skip log line carries the sanitized, single-line datname');

$node3->safe_psql('postgres',
    "DELETE FROM vamana_databases WHERE datname = '$rawname';");

$node3->stop;

# ---------------------------------------------------------------------------
# ReserveSlotsForEnabledEntries() (src/vamana_databases.c) raises its
# "cannot enable database" error, with datname interpolated, in the
# enrolling transaction's own pre-commit trigger -- no restart needed, just
# an ordinary INSERT once svs.max_databases is already exhausted by an
# earlier enabled row.
# ---------------------------------------------------------------------------
my $node4 = PostgreSQL::Test::Cluster->new('launcher_bgw_name_sanitize_ceiling');
$node4->init;
$node4->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node4->append_conf('postgresql.conf', "svs.launcher_database = 'postgres'");
$node4->append_conf('postgresql.conf', "wal_level = logical");
$node4->append_conf('postgresql.conf', "max_wal_senders = 4");
$node4->append_conf('postgresql.conf', "svs.max_databases = 1");
# The filler database alone must not trip the (unrelated) memory ceiling
# before the max_databases ceiling this scenario is actually testing.
$node4->append_conf('postgresql.conf', "svs.max_search_work_mem = '400MB'");
$node4->append_conf('postgresql.conf', "svs.max_residency_memory = '400MB'");
$node4->start;

$node4->safe_psql('postgres', "CREATE EXTENSION vector;");
$node4->safe_psql('postgres', "CREATE EXTENSION svs;");

$node4->safe_psql('postgres', "CREATE DATABASE filler;");
$node4->safe_psql('postgres',
    "INSERT INTO vamana_databases (datname, enabled) VALUES ('filler', true);");

$node4->safe_psql('postgres', qq(CREATE DATABASE "$rawname";));
my ($enable_rc, undef, $enable_stderr) = $node4->psql('postgres',
    "INSERT INTO vamana_databases (datname, enabled) VALUES ('$rawname', true);");
isnt($enable_rc, 0,
    'enabling a second database once svs.max_databases = 1 is already spent is rejected');

like($enable_stderr,
    qr/\Qcannot enable database "$sanitized": svs.max_databases (1) already reached\E/,
    'the enable-time ceiling error carries the sanitized, single-line datname');

$node4->stop;

# ---------------------------------------------------------------------------
# LogShortfallTransition() (src/svs_cpu_slots.c) logs set->datname, which
# comes from get_database_name() of whichever database is connected -- the
# same attacker-settable value as every other sink, just reached through
# the standalone svs_cpu_slots_test module (test/modules/svs_cpu_slots_test)
# rather than through a live vamana worker, so neither the launcher nor the
# svs extension itself is needed here. max_parallel_workers is PGC_USERSET,
# so the shortfall is forced within one session with no restart.
# ---------------------------------------------------------------------------
my $node5 = PostgreSQL::Test::Cluster->new('launcher_bgw_name_sanitize_shortfall');
$node5->init;
$node5->start;

$node5->safe_psql('postgres', qq(CREATE DATABASE "$rawname";));
$node5->safe_psql($rawname, "CREATE EXTENSION svs_cpu_slots_test;");

my $shortfall_offset = -s $node5->logfile;
$node5->safe_psql($rawname,
    "SET max_parallel_workers = 1; SELECT svs_slot_resize(4);");

like(slurp_file($node5->logfile),
    qr/\Qsvs cpu slots: holding 1 of 4 requested vamana search slot slots for database "$sanitized"\E/,
    'the shortfall-entered log line carries the sanitized, single-line datname')
  or diag(substr(slurp_file($node5->logfile), $shortfall_offset));

$node5->safe_psql($rawname, "SELECT svs_slot_resize(0);");

like(slurp_file($node5->logfile),
    qr/\Qsvs cpu slots: shortfall cleared, holding 0 of 0 requested vamana search slot slots for database "$sanitized"\E/,
    'the shortfall-cleared log line carries the sanitized, single-line datname');

$node5->stop;

done_testing();
