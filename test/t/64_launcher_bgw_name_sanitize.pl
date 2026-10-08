# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 064_launcher_bgw_name_sanitize.pl -- a database name with control bytes
# (including a raw newline) must not reach the postmaster's background
# worker lifecycle log lines unsanitized.
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
my $rawname = "is195evil%s${ctrl}db${nl}end";

# pg_clean_ascii()'s escaped form: every byte outside printable ASCII
# (32-126) becomes a literal four-character "\xHH" sequence; '%', 's', 'd',
# 'b', 'e', 'n' are all printable ASCII and pass through unchanged.
my $sanitized = 'is195evil%s\x01db\x0aend';

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

$node->stop;

done_testing();
