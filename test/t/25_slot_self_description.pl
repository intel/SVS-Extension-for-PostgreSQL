# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 25_slot_self_description.pl -- a parked search slot must be identifiable
# and readable from pg_stat_activity alone, including under an adversarial
# database name.
#
# Checked here:
#   - backend_type still reads "vamana search slot" (regression guard)
#   - wait_event_type/wait_event name the park loop's wait as
#     Extension/VamanaSearchSlot instead of the generic extension wait
#   - the slot's counts in application_name survive truncation for a
#     datname near NAMEDATALEN - 1
#   - a control character (newline) in datname does not reach
#     application_name
#   - a literal '%' in datname is preserved, not stripped or doubled
#   - the worker serving all of this stays up throughout (no crash)
#
# Slot creation is driven through the real worker path (catalog DML on
# vamana_databases), not the test/modules/svs_cpu_slots_test harness: these
# assertions are about what a DBA observes from pg_stat_activity once a
# database is actually onboarded, which is exactly what the real path
# produces, and the module harness would only add an extra layer between
# the assertion and the thing being proven.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

use FindBin qw($Bin);
use lib "$Bin/../perl";
use VamanaTestUtils qw(:all);

# ---------------------------------------------------------------------------
# Local helpers
# ---------------------------------------------------------------------------

sub db_oid
{
	my ($node, $db) = @_;
	my $oid = $node->safe_psql('postgres',
		"SELECT oid FROM pg_database WHERE datname = '$db';");
	chomp $oid;
	return $oid;
}

sub wait_for_granted
{
	my ($node, $dboid, $want, $attempts) = @_;
	$attempts //= 40;
	my $g = '';
	for (1 .. $attempts)
	{
		$g = $node->safe_psql('postgres',
			"SELECT search_threads_granted FROM pg_stat_vamana_worker "
		  . "WHERE db_oid = $dboid;");
		chomp $g;
		return $g if defined($g) && $g ne '' && $g == $want;
		usleep(500_000);
	}
	return $g;
}

# All parked search slots' application_name values, one per line.  A plain
# list rather than a per-database filter: several of the cases below use a
# datname containing characters ('%', a newline) that are unsafe or
# meaningless inside a SQL LIKE pattern, so filtering happens on the Perl
# side against the exact (post-sanitizing) expected text instead.
sub search_slot_appnames
{
	my ($node) = @_;
	my $out = $node->safe_psql('postgres',
		"SELECT application_name FROM pg_stat_activity "
	  . "WHERE backend_type = 'vamana search slot' ORDER BY application_name;");
	return split /\n/, $out;
}

sub wait_for_appname_containing
{
	my ($node, $needle, $attempts) = @_;
	$attempts //= 40;
	for (1 .. $attempts)
	{
		for my $name (search_slot_appnames($node))
		{
			return $name if index($name, $needle) >= 0;
		}
		usleep(500_000);
	}
	return undef;
}

my $node = PostgreSQL::Test::Cluster->new('slot_self_description');
$node->init;
$node->append_conf('postgresql.conf', "shared_preload_libraries = 'svs'");
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_replication_slots = 10");
$node->append_conf('postgresql.conf', "max_wal_senders = 10");
$node->append_conf('postgresql.conf', "max_worker_processes = 24");
$node->append_conf('postgresql.conf', "max_parallel_workers = 8");
$node->start;

$node->safe_psql('postgres', "CREATE EXTENSION vector;");
$node->safe_psql('postgres', "CREATE EXTENSION svs;");
$node->safe_psql('postgres',
	"INSERT INTO vamana_databases (datname, enabled, search_num_threads) "
  . "VALUES ('postgres', true, 1);");
my $worker_pid = wait_for_worker($node);
ok($worker_pid =~ /^\d+$/, 'worker is running before the checks below');

my $pg_oid = db_oid($node, 'postgres');
my $pg_granted = wait_for_granted($node, $pg_oid, 1, 40);
is($pg_granted, '1', "postgres's search_threads_granted reaches 1");

# ---------------------------------------------------------------------------
# Case 1: backend_type.  Already true on main; asserted anyway so a
# regression here is caught alongside the new checks in this file.
# ---------------------------------------------------------------------------
{
	my $count = $node->safe_psql('postgres',
		"SELECT count(*) FROM pg_stat_activity "
	  . "WHERE backend_type = 'vamana search slot' "
	  . "AND application_name LIKE '%db=postgres%';");
	chomp $count;
	is($count, '1', 'exactly one parked slot self-describes as vamana search slot for postgres');
}

# ---------------------------------------------------------------------------
# Case 2: named wait event.  Must fail against unpatched main, where the
# park loop waits on the generic PG_WAIT_EXTENSION.
# ---------------------------------------------------------------------------
{
	my $wait = $node->safe_psql('postgres',
		"SELECT wait_event_type || ':' || wait_event FROM pg_stat_activity "
	  . "WHERE backend_type = 'vamana search slot' "
	  . "AND application_name LIKE '%db=postgres%';");
	chomp $wait;
	is($wait, 'Extension:VamanaSearchSlot',
		'parked search slot waits on the named VamanaSearchSlot event');
}

# ---------------------------------------------------------------------------
# Case 3: numbers survive a long database name.  Must fail against
# unpatched main, where "db=" comes first and truncation eats the counts.
# ---------------------------------------------------------------------------
{
	my $longdb = "longname_" . ("x" x 54);    # 63 chars, NAMEDATALEN - 1
	is(length($longdb), 63, 'test setup: long datname is exactly NAMEDATALEN - 1');

	$node->safe_psql('postgres', qq(CREATE DATABASE "$longdb";));
	$node->safe_psql('postgres',
		"INSERT INTO vamana_databases (datname, enabled, search_num_threads) "
	  . "VALUES ('$longdb', true, 1);");
	wait_for_worker_db($node, $longdb);
	my $long_oid = db_oid($node, $longdb);
	my $granted = wait_for_granted($node, $long_oid, 1, 40);
	is($granted, '1', "${longdb}'s search_threads_granted reaches 1");

	# 23 characters of room remain after "vamana: search slot 1/1
	# (reserved 0) db=" before NAMEDATALEN - 1 is reached; the first 10
	# characters of the datname are well within that margin, so their
	# presence proves truncation cost the tail of datname, not the counts.
	my $prefix = substr($longdb, 0, 10);
	my $appname = wait_for_appname_containing($node, "db=$prefix", 40);
	ok(defined($appname), 'a parked slot self-describes with the long datname prefix');
	like($appname, qr/search slot 1\/1 \(reserved \d+\)/,
		'the slot counts are intact despite a datname near NAMEDATALEN - 1');
}

# ---------------------------------------------------------------------------
# Case 4: a control character in datname does not reach application_name.
# Must fail against unpatched main, which has no sanitizing at all.
# ---------------------------------------------------------------------------
{
	my $nl_raw = "nldb_before\nafter";        # real newline, for CREATE DATABASE
	my $nl_lit = 'nldb_before\nafter';         # literal backslash-n, for E''

	$node->safe_psql('postgres', qq(CREATE DATABASE "$nl_raw";));
	$node->safe_psql('postgres',
		"INSERT INTO vamana_databases (datname, enabled, search_num_threads) "
	  . "VALUES (E'$nl_lit', true, 1);");
	wait_for_worker_db($node, $nl_raw);
	my $nl_oid = db_oid($node, $nl_raw);
	my $granted = wait_for_granted($node, $nl_oid, 1, 40);
	is($granted, '1', "the newline-named database's search_threads_granted reaches 1");

	my $appname = wait_for_appname_containing($node, "nldb_before after", 40);
	ok(defined($appname),
		'a parked slot self-describes with the newline replaced by a space');
	unlike($appname, qr/\n/,
		'the published application_name carries no newline from datname');
}

# ---------------------------------------------------------------------------
# Case 5: a literal '%' in datname is preserved, proving no format
# confusion was introduced.  Expected to already pass against unpatched
# main: datname is a %s argument to a literal format string, never a
# format string itself.
# ---------------------------------------------------------------------------
{
	my $pctdb = "pct100%db";

	$node->safe_psql('postgres', qq(CREATE DATABASE "$pctdb";));
	$node->safe_psql('postgres',
		"INSERT INTO vamana_databases (datname, enabled, search_num_threads) "
	  . "VALUES ('$pctdb', true, 1);");
	wait_for_worker_db($node, $pctdb);
	my $pct_oid = db_oid($node, $pctdb);
	my $granted = wait_for_granted($node, $pct_oid, 1, 40);
	is($granted, '1', "${pctdb}'s search_threads_granted reaches 1");

	my $appname = wait_for_appname_containing($node, "db=$pctdb", 40);
	ok(defined($appname), 'a parked slot self-describes with the literal % intact');
}

# ---------------------------------------------------------------------------
# Case 6: the worker serving postgres survived everything above: same pid,
# heartbeat still advancing, no crash in the log.
# ---------------------------------------------------------------------------
{
	my $pid_now = $node->safe_psql('postgres',
		"SELECT pid FROM pg_stat_activity "
	  . "WHERE backend_type = 'vamana worker' AND datname = 'postgres';");
	chomp $pid_now;
	is($pid_now, $worker_pid, "postgres's worker pid is unchanged throughout the test");

	my $hb1 = $node->safe_psql('postgres',
		"SELECT heartbeat_ts FROM pg_stat_vamana_worker WHERE db_oid = $pg_oid;");
	chomp $hb1;
	usleep(1_500_000);
	my $hb2 = $node->safe_psql('postgres',
		"SELECT heartbeat_ts FROM pg_stat_vamana_worker WHERE db_oid = $pg_oid;");
	chomp $hb2;
	isnt($hb1, $hb2, "postgres's worker heartbeat is still advancing");

	my $log = $node->log_content();
	unlike($log, qr/Segmentation fault/, 'no segfault in the server log');
	unlike($log, qr/\(PID $worker_pid\) exited with exit code/,
		"the postgres worker's pid never exited");
}

$node->stop;

done_testing();
