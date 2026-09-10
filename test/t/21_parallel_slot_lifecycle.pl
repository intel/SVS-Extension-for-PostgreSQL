# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# 21_parallel_slot_lifecycle.pl - the reap/crash-recovery gate for parked
# BGWORKER_CLASS_PARALLEL search slots (svs_cpu_slots.c).
#
# The svs_cpu_slots_test module's SQL regression test (test/modules/
# svs_cpu_slots_test) already proves launch, pool enforcement, and slot
# return within a single script.  What that script cannot exercise is
# anything needing a postmaster restart or a signal to a live backend:
# repeated register/terminate cycles without leaking, what happens to parked
# slots when their owning backend crashes versus exits cleanly, and pool
# clamp behavior when max_worker_processes itself (not max_parallel_workers)
# is the tight limit.  Those three are this file's job.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(usleep);

my $SLOT_BGW_TYPE = 'vamana search slot';

my $node = PostgreSQL::Test::Cluster->new('parallel_slot_lifecycle');
$node->init;

# Default max_worker_processes (8) leaves almost no headroom once io_workers,
# the vamana launcher, and the logical replication launcher are counted
# against it -- the same shortfall documented in svs_cpu_slots_test's own
# comments.  Case 6 below lowers this again, deliberately, on its own
# restart; this starting value is just enough that cases 4 and 5 are not
# accidentally testing slot-table exhaustion instead of what they mean to.
$node->append_conf('postgresql.conf', "max_worker_processes = 32");

# The TAP harness defaults restart_after_crash to off so that one test file's
# crash cannot leave a dead postmaster for the next.  Case 5's SIGKILL half
# depends on the postmaster actually recovering on its own, so this file
# turns it back on for itself.
$node->append_conf('postgresql.conf', "restart_after_crash = on");

$node->start;

$node->safe_psql('postgres', 'CREATE EXTENSION svs_cpu_slots_test;');

sub slot_count
{
	my $count = $node->safe_psql('postgres',
		"SELECT count(*) FROM pg_stat_activity WHERE backend_type = '$SLOT_BGW_TYPE';"
	);
	chomp $count;
	return $count;
}

# ---------------------------------------------------------------------------
# Case 4: repeated cycles.  Resize 0 -> 6 -> 0 at least 20 times on one
# long-lived backend, since a slot set's whole reason to exist is surviving
# across many statements on the same owner.  This is the case most likely to
# fail: it is the only one that actually exercises "does a parked
# BGWORKER_CLASS_PARALLEL worker with no DSM and no shm_mq get reaped
# cleanly," repeatedly, rather than just once.
# ---------------------------------------------------------------------------

my $pre_cycles_offset = -s $node->logfile;

my $owner = $node->background_psql('postgres');
my $owner_pid = $owner->query_safe('SELECT pg_backend_pid();');
chomp $owner_pid;

my $cycles_ok = 1;
for my $cycle (1 .. 20)
{
	my $held_up = $owner->query_safe('SELECT svs_slot_resize(6);');
	chomp $held_up;
	if ($held_up ne '6')
	{
		diag("cycle $cycle: resize(6) held $held_up, not 6");
		$cycles_ok = 0;
	}

	my $held_down = $owner->query_safe('SELECT svs_slot_resize(0);');
	chomp $held_down;
	if ($held_down ne '0')
	{
		diag("cycle $cycle: resize(0) held $held_down, not 0");
		$cycles_ok = 0;
	}
}
ok($cycles_ok, 'case 4: 20 resize(6)/resize(0) cycles each converge exactly');

my $owner_pid_after = $owner->query_safe('SELECT pg_backend_pid();');
chomp $owner_pid_after;
is($owner_pid_after, $owner_pid,
	'case 4: the owning backend is still the same live process after 20 cycles');

is(slot_count(), '0', 'case 4: no parked slots remain leaked after the cycles');

my $crashed_during_cycles = $node->log_contains(
	qr/Segmentation fault|terminated by signal|was terminated by signal|crashed/,
	$pre_cycles_offset);
ok(!$crashed_during_cycles,
	'case 4: server log has no crashed-worker or segfault line across the cycles');

# AllocateSlotIndex() must keep every live slot's self-reported "X/Y" label
# within 1..slotTotal even after many grow/shrink cycles; an earlier fix that
# assigned indices from a counter that only ever increased passed every
# check above (they never look at application_name) while still producing
# labels like "124/6" once the counter had climbed past the six-slot total.
my $held_final = $owner->query_safe('SELECT svs_slot_resize(6);');
chomp $held_final;
is($held_final, '6', 'case 4: resize(6) after the cycles converges exactly, for the label check below');

my $bad_labels = $node->safe_psql('postgres',
	"SELECT count(*) FROM pg_stat_activity " .
	"WHERE backend_type = '$SLOT_BGW_TYPE' " .
	"AND application_name !~ 'slot [1-6]/6'");
chomp $bad_labels;
is($bad_labels, '0', 'case 4: slot labels stay within total after repeated cycles');

$owner->query_safe('SELECT svs_slot_resize(0);');

# ---------------------------------------------------------------------------
# Case 5: owner death, both kinds.  A crash and a clean exit have genuinely
# different mechanics -- SIGKILL takes the whole cluster down with it and
# depends on crash recovery to clear the slate, while SIGTERM is an ordinary
# backend shutdown that must run its own release path.  Both need to leave
# zero orphaned slots, but for different reasons.
# ---------------------------------------------------------------------------

# --- 5a: SIGKILL is a crash.  The postmaster SIGQUITs every other backend,
# including the parked slots themselves, and (restart_after_crash = on)
# recovers on its own.  No orphan should survive that, because nothing
# survives that.
my $victim_kill = $node->background_psql('postgres');
$victim_kill->query_safe('SELECT svs_slot_resize(4);');
my $victim_kill_pid = $victim_kill->query_safe('SELECT pg_backend_pid();');
chomp $victim_kill_pid;

is(slot_count(), '4', 'case 5a setup: victim backend is holding 4 slots before SIGKILL');

my $pre_kill_offset = -s $node->logfile;

my $killed = kill('KILL', $victim_kill_pid);
ok($killed, "case 5a: SIGKILL delivered to victim backend $victim_kill_pid");

$node->wait_for_log(qr/database system is ready to accept connections/,
	$pre_kill_offset);

is(slot_count(), '0',
	'case 5a: no orphaned slots survive SIGKILL-triggered crash recovery');

# --- 5b: SIGTERM is a clean exit.  The victim's before_shmem_exit hook
# (svs_cpu_slots_test.c's ReleaseTestSlotSetOnExit) must run
# SvsSlotSetReleaseAll() itself; nothing about a plain backend shutdown does
# that automatically.
$node->safe_psql('postgres', 'CREATE EXTENSION IF NOT EXISTS svs_cpu_slots_test;');

my $victim_term = $node->background_psql('postgres');
$victim_term->query_safe('SELECT svs_slot_resize(4);');
my $victim_term_pid = $victim_term->query_safe('SELECT pg_backend_pid();');
chomp $victim_term_pid;

is(slot_count(), '4', 'case 5b setup: victim backend is holding 4 slots before SIGTERM');

my $pre_term_offset = -s $node->logfile;

my $termed = kill('TERM', $victim_term_pid);
ok($termed, "case 5b: SIGTERM delivered to victim backend $victim_term_pid");

# A short poll from a fresh connection each time, not a sleep-and-recheck
# inside one PL/pgSQL call: pg_stat_get_activity() snapshots backend status
# once per transaction, so polling within a single call would see the same
# stale count no matter how long it slept.
my $released_after_term = 0;
for (1 .. 100)
{
	if (slot_count() eq '0')
	{
		$released_after_term = 1;
		last;
	}
	usleep(100_000);
}
ok($released_after_term,
	'case 5b: the release path ran, and slots are gone after a clean SIGTERM exit');

my $crashed_during_term = $node->log_contains(
	qr/Segmentation fault|terminated by signal|was terminated by signal/,
	$pre_term_offset);
ok(!$crashed_during_term, 'case 5b: a clean SIGTERM is not logged as a crash');

# ---------------------------------------------------------------------------
# Case 6: max_worker_processes exhaustion.  PGC_POSTMASTER, so this needs its
# own restart with the setting deliberately low enough to fail on the
# background worker slot table rather than the max_parallel_workers pool --
# the opposite of case 2's shortfall, and the log line distinguishes them.
# ---------------------------------------------------------------------------

$node->append_conf('postgresql.conf', "max_worker_processes = 6");
$node->restart;

$node->safe_psql('postgres', 'CREATE EXTENSION IF NOT EXISTS svs_cpu_slots_test;');

my $pre_exhaust_offset = -s $node->logfile;

# max_worker_processes = 6 total, already spent on io_workers, the vamana
# launcher, and the logical replication launcher before this session even
# connects; whatever is left is deliberately less than the 8 requested here,
# so registration must fail on the slot table itself.
my $held_when_exhausted = $node->safe_psql('postgres', 'SELECT svs_slot_resize(8);');
chomp $held_when_exhausted;

ok($held_when_exhausted =~ /^\d+$/ && $held_when_exhausted < 8,
	"case 6: max_worker_processes exhaustion holds fewer than requested (held $held_when_exhausted)");

# LogShortfallTransition() no longer guesses which limit is binding (see
# svs_cpu_slots.c); it reports only the held/requested counts, which is
# already enough to tell this case apart from case 2's: case 2 holds
# max_parallel_workers (4) of 8 requested, this case holds fewer than that
# because the background worker slot table ran out first.
my $shortfall_line = $node->log_contains(
	qr/svs cpu slots: holding $held_when_exhausted of 8 requested/,
	$pre_exhaust_offset);
ok($shortfall_line,
	"case 6: shortfall is logged holding $held_when_exhausted of 8, fewer than case 2's max_parallel_workers-of-8 shortfall");

$node->safe_psql('postgres', 'SELECT svs_slot_release_all();');

$node->stop;

done_testing();
