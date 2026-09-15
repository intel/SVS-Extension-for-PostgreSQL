-- Copyright (C) 2026 Intel Corporation
-- SPDX-License-Identifier: PostgreSQL

CREATE EXTENSION svs_memory_test;

SELECT svs_memory_test_build_ceiling_bytes() AS build_ceiling \gset
SELECT svs_memory_test_residency_ceiling_bytes() AS residency_ceiling \gset

-- Admission: budget in, stats out; re-admitting updates the budget in place.
SELECT svs_memory_admit_database(100, (40 * 1024 * 1024)::bigint);
SELECT * FROM svs_memory_read_stats(100);
SELECT svs_memory_admit_database(100, (30 * 1024 * 1024)::bigint);
SELECT * FROM svs_memory_read_stats(100);
SELECT svs_memory_admit_database(100, (40 * 1024 * 1024)::bigint);
SELECT * FROM svs_memory_test_check_invariants();

-- A build peak at handoff that does not match what was reserved is capped
-- at zero rather than driving the per-database build counter negative.
SELECT svs_memory_reserve_build(100, 11, (2 * 1024 * 1024)::bigint, (2 * 1024 * 1024)::bigint);
SELECT svs_memory_handoff_build(100, 11, (50 * 1024 * 1024)::bigint, (2 * 1024 * 1024)::bigint);
SELECT * FROM svs_memory_read_stats(100);
SELECT svs_memory_account_unload(100, 11);
SELECT * FROM svs_memory_read_stats(100);
SELECT * FROM svs_memory_test_check_invariants();

-- Build reserve, then a handoff whose measured bytes fit: build peak
-- releases, residency reconciles from estimate to measured.
SELECT svs_memory_reserve_build(100, 1, (10 * 1024 * 1024)::bigint, (10 * 1024 * 1024)::bigint);
SELECT * FROM svs_memory_read_stats(100);
SELECT svs_memory_handoff_build(100, 1, (10 * 1024 * 1024)::bigint, (9 * 1024 * 1024)::bigint);
SELECT * FROM svs_memory_read_stats(100);
SELECT * FROM svs_memory_test_check_invariants();

-- A worker's own measurement at load can differ from what the backend
-- recorded at handoff; the committed counter tracks the new figure
-- exactly, not the old one.
SELECT svs_memory_reserve_build(100, 10, (2 * 1024 * 1024)::bigint, (8 * 1024 * 1024)::bigint);
SELECT svs_memory_handoff_build(100, 10, (2 * 1024 * 1024)::bigint, (8 * 1024 * 1024)::bigint);
SELECT * FROM svs_memory_read_stats(100);
SELECT svs_memory_reconcile_load(100, 10, (9 * 1024 * 1024)::bigint);
SELECT * FROM svs_memory_read_stats(100);
SELECT svs_memory_account_unload(100, 10);
SELECT * FROM svs_memory_read_stats(100);
SELECT * FROM svs_memory_test_check_invariants();

-- A handoff whose measured bytes do not fit drops the reservation entirely.
SELECT svs_memory_reserve_build(100, 2, (5 * 1024 * 1024)::bigint, (5 * 1024 * 1024)::bigint);
SELECT svs_memory_handoff_build(100, 2, (5 * 1024 * 1024)::bigint, (35 * 1024 * 1024)::bigint);
SELECT * FROM svs_memory_read_stats(100);
SELECT * FROM svs_memory_test_check_invariants();

-- Abort releases both the build peak and the residency estimate.
SELECT svs_memory_reserve_build(100, 3, (3 * 1024 * 1024)::bigint, (3 * 1024 * 1024)::bigint);
SELECT svs_memory_abort_build(100, 3);
SELECT * FROM svs_memory_read_stats(100);
SELECT * FROM svs_memory_test_check_invariants();

-- Reconcile load on a fresh handoff (index 1) is a re-verification: no change.
SELECT svs_memory_reconcile_load(100, 1, (9 * 1024 * 1024)::bigint);
SELECT * FROM svs_memory_read_stats(100);
SELECT * FROM svs_memory_test_check_invariants();

-- Reconcile load with no pending reservation (reload or restart adopt),
-- fitting the budget.
SELECT svs_memory_reconcile_load(100, 4, (10 * 1024 * 1024)::bigint);
SELECT * FROM svs_memory_read_stats(100);
SELECT * FROM svs_memory_test_check_invariants();

-- Same, but the measured bytes overflow the budget: nothing is committed.
SELECT svs_memory_reconcile_load(100, 5, (100 * 1024 * 1024)::bigint);
SELECT * FROM svs_memory_read_stats(100);
SELECT * FROM svs_memory_test_check_invariants();

-- Unload releases index 4's exact committed bytes.
SELECT svs_memory_account_unload(100, 4);
SELECT * FROM svs_memory_read_stats(100);
SELECT * FROM svs_memory_test_check_invariants();

-- Insert growth: a fitting reservation commits; an overflowing one does not.
SELECT svs_memory_reserve_insert(100, 1, (2 * 1024 * 1024)::bigint);
SELECT * FROM svs_memory_read_stats(100);
SELECT svs_memory_reserve_insert(100, 1, (50 * 1024 * 1024)::bigint);
SELECT * FROM svs_memory_read_stats(100);
SELECT * FROM svs_memory_test_check_invariants();

-- Reanchoring folds index 1's prior measured size and its one pending
-- insert delta into the worker's single fresh exact measurement.
SELECT svs_memory_reanchor_insert(100, 1, (12 * 1024 * 1024)::bigint);
SELECT * FROM svs_memory_read_stats(100);
SELECT * FROM svs_memory_test_check_invariants();

-- Reaping while every reservation's owner is this live session is a no-op.
-- A dead-owner reap needs a second, crashed backend to be real, which this
-- single-session driver cannot produce, so it is not exercised here.
SELECT svs_memory_reserve_build(100, 6, (1 * 1024 * 1024)::bigint, (1 * 1024 * 1024)::bigint);
SELECT svs_memory_reap_dead_reservations();
SELECT * FROM svs_memory_read_stats(100);
SELECT svs_memory_abort_build(100, 6);
SELECT svs_memory_account_unload(100, 1);
SELECT * FROM svs_memory_read_stats(100);
SELECT * FROM svs_memory_test_check_invariants();

-- Global build ceiling: one big reservation, then a second that would push
-- the cluster-wide total over svs.max_build_memory.
SELECT svs_memory_admit_database(200, (40 * 1024 * 1024)::bigint);
SELECT svs_memory_reserve_build(100, 7, :build_ceiling - (10 * 1024 * 1024)::bigint, (1 * 1024 * 1024)::bigint);
SELECT svs_memory_reserve_build(200, 8, (20 * 1024 * 1024)::bigint, (1 * 1024 * 1024)::bigint);
SELECT svs_memory_abort_build(100, 7);
SELECT * FROM svs_memory_test_check_invariants();

-- Global residency ceiling: admitted budgets already sum to 80MB
-- (databases 100 and 200 at 40MB each); a third database's budget pushes
-- the cluster-wide sum over svs.max_residency_memory.
SELECT svs_memory_admit_database(300, (30 * 1024 * 1024)::bigint);

-- Per-database residency budget, independent of the global ceiling: a
-- single build's residency estimate exceeding this database's own budget.
SELECT svs_memory_reserve_build(200, 9, (1 * 1024 * 1024)::bigint, (41 * 1024 * 1024)::bigint);
SELECT * FROM svs_memory_test_check_invariants();

-- Every fits-check in this module compares with <= or >, except the
-- budget-decrease guard in SvsMemoryAdmitDatabase, which uses <. Each one
-- below is exercised exactly at its limit (succeeds) and exactly one byte
-- past it (fails). The two global-ceiling cases capture the live global
-- totals first and run immediately, before anything else in this section
-- changes them.

SELECT svs_memory_test_global_build_committed_bytes() AS build_committed \gset
SELECT svs_memory_test_global_residency_committed_bytes() AS residency_committed \gset

-- Global residency ceiling (a sum of admitted budgets, not live usage):
-- admitting exactly up to the remaining headroom succeeds; one byte more
-- is rejected and the database is never admitted.
SELECT svs_memory_admit_database(520, (:residency_ceiling - :residency_committed)::bigint);
SELECT * FROM svs_memory_read_stats(520);
SELECT svs_memory_admit_database(521, 1::bigint);
SELECT * FROM svs_memory_read_stats(521);
SELECT * FROM svs_memory_test_check_invariants();

-- Free the headroom the check above just consumed, so every other admit in
-- this section still has room against the shared global ceiling.
SELECT svs_memory_admit_database(520, 1::bigint);

-- Global build ceiling: filling exactly the remaining headroom succeeds;
-- one byte more fails and claims no reservation slot.
SELECT svs_memory_admit_database(522, (1 * 1024 * 1024)::bigint);
SELECT svs_memory_reserve_build(522, 1, (:build_ceiling - :build_committed)::bigint, 1024::bigint);
SELECT svs_memory_abort_build(522, 1);
SELECT svs_memory_reserve_build(522, 2, (:build_ceiling - :build_committed + 1)::bigint, 1024::bigint);
SELECT * FROM svs_memory_test_check_invariants();

-- Per-database residency budget: a build whose estimate exactly fills a
-- fresh budget succeeds; one byte more fails and commits nothing.
SELECT svs_memory_admit_database(530, (1 * 1024 * 1024)::bigint);
SELECT svs_memory_reserve_build(530, 1, 1024::bigint, (1 * 1024 * 1024)::bigint);
SELECT * FROM svs_memory_read_stats(530);
SELECT svs_memory_abort_build(530, 1);
SELECT svs_memory_reserve_build(530, 2, 1024::bigint, (1 * 1024 * 1024 + 1)::bigint);
SELECT * FROM svs_memory_read_stats(530);
SELECT * FROM svs_memory_test_check_invariants();

-- Budget-decrease guard: lowering a database's budget to exactly its
-- committed total succeeds; one byte below it is rejected.
SELECT svs_memory_admit_database(531, (1 * 1024 * 1024)::bigint);
SELECT svs_memory_reserve_build(531, 3, 1024::bigint, (1 * 1024 * 1024)::bigint);
SELECT svs_memory_admit_database(531, (1 * 1024 * 1024)::bigint);
SELECT svs_memory_admit_database(531, (1 * 1024 * 1024 - 1)::bigint);
SELECT * FROM svs_memory_read_stats(531);
SELECT svs_memory_abort_build(531, 3);
SELECT * FROM svs_memory_test_check_invariants();

-- HandoffBuild's own fits check: measured bytes exactly at budget succeed;
-- one byte more drops the reservation entirely.
SELECT svs_memory_admit_database(532, (1 * 1024 * 1024)::bigint);
SELECT svs_memory_reserve_build(532, 4, 1024::bigint, (512 * 1024)::bigint);
SELECT svs_memory_handoff_build(532, 4, 1024::bigint, (1 * 1024 * 1024)::bigint);
SELECT * FROM svs_memory_read_stats(532);
SELECT svs_memory_account_unload(532, 4);
SELECT svs_memory_reserve_build(532, 5, 1024::bigint, (512 * 1024)::bigint);
SELECT svs_memory_handoff_build(532, 5, 1024::bigint, (1 * 1024 * 1024 + 1)::bigint);
SELECT * FROM svs_memory_read_stats(532);
SELECT * FROM svs_memory_test_check_invariants();

-- ReconcileLoad's no-pending-reservation fits check: exactly at budget
-- succeeds; one byte more fails and commits nothing.
SELECT svs_memory_admit_database(533, (1 * 1024 * 1024)::bigint);
SELECT svs_memory_reconcile_load(533, 6, (1 * 1024 * 1024)::bigint);
SELECT * FROM svs_memory_read_stats(533);
SELECT svs_memory_account_unload(533, 6);
SELECT svs_memory_reconcile_load(533, 7, (1 * 1024 * 1024 + 1)::bigint);
SELECT * FROM svs_memory_read_stats(533);
SELECT * FROM svs_memory_test_check_invariants();

-- ReconcileLoad's existing-reservation fits check, and which field it folds
-- out of the running total for a RESERVED record: the estimate, not a
-- measured value it has never taken. A measured load landing exactly on
-- budget fits, and the reservation reconciles to RESIDENT with no owner.
SELECT svs_memory_admit_database(535, (10 * 1024 * 1024)::bigint);
SELECT svs_memory_reserve_build(535, 1, 0::bigint, (4 * 1024 * 1024)::bigint);
SELECT svs_memory_reconcile_load(535, 1, (10 * 1024 * 1024)::bigint) AS fits;
SELECT residency_bytes_committed = (10 * 1024 * 1024) AS committed_equals_measured
  FROM svs_memory_read_stats(535);
SELECT relid, state, owner_pid FROM svs_memory_test_reservations(535);
SELECT * FROM svs_memory_test_check_invariants();

-- Free 535's budget back to the shared global ceiling; later boundary
-- tests in this section need the headroom, same as db 520 below.
SELECT svs_memory_account_unload(535, 1);
SELECT svs_memory_admit_database(535, 1::bigint);

-- ReanchorInsert's over-budget warning: a reanchor landing exactly on the
-- budget stays silent; one byte more warns.
SELECT svs_memory_admit_database(536, (1 * 1024 * 1024)::bigint);
SELECT svs_memory_reconcile_load(536, 1, (900 * 1024)::bigint);
SELECT svs_memory_reanchor_insert(536, 1, (1 * 1024 * 1024)::bigint);
SELECT residency_bytes_committed = (1 * 1024 * 1024) AS exactly_at_budget_no_warning
  FROM svs_memory_read_stats(536);
SELECT svs_memory_reanchor_insert(536, 1, (1 * 1024 * 1024 + 1)::bigint);
SELECT * FROM svs_memory_test_check_invariants();

-- Unwind 536's deliberate overage: both the invariant violation and its
-- budget must not leak into the rest of the file, the same as db 542
-- later in this file.
SELECT svs_memory_account_unload(536, 1);
SELECT svs_memory_admit_database(536, 1::bigint);
SELECT * FROM svs_memory_test_check_invariants();

-- ReserveInsert's fits check: a delta that exactly fills the budget
-- succeeds; one byte more fails and reserves nothing.
SELECT svs_memory_admit_database(534, (1 * 1024 * 1024)::bigint);
SELECT svs_memory_reserve_insert(534, 8, (1 * 1024 * 1024)::bigint);
SELECT * FROM svs_memory_read_stats(534);
SELECT svs_memory_reserve_insert(534, 9, 1::bigint);
SELECT * FROM svs_memory_read_stats(534);
SELECT * FROM svs_memory_test_check_invariants();

-- With two pending inserts on the same relid, reanchoring folds out only
-- the older one's delta and leaves the newer one still pending. Its delta
-- differs from the older one's, so folding the wrong one would land the
-- committed total on a different number than the one asserted below.
SELECT svs_memory_admit_database(560, (20 * 1024)::bigint);
SELECT svs_memory_reconcile_load(560, 1, (10 * 1024)::bigint);
SELECT svs_memory_reserve_insert(560, 1, (1 * 1024)::bigint);
SELECT svs_memory_reserve_insert(560, 1, (3 * 1024)::bigint);
SELECT svs_memory_reanchor_insert(560, 1, (11 * 1024)::bigint);
SELECT residency_bytes_committed = (14 * 1024) AS older_deltas_folded_newer_still_pending
  FROM svs_memory_read_stats(560);
SELECT delta_bytes = (3 * 1024) AS newer_pending_insert_survives
  FROM svs_memory_test_insert_reservations(560);
SELECT * FROM svs_memory_test_check_invariants();

-- Abort on a RESIDENT record releases its measured bytes, the amount the
-- committed counter actually holds by that point -- not its stale estimate.
SELECT svs_memory_admit_database(540, (10 * 1024 * 1024)::bigint);
SELECT svs_memory_reserve_build(540, 1, 1024::bigint, (5 * 1024 * 1024)::bigint);
SELECT svs_memory_handoff_build(540, 1, 1024::bigint, (7 * 1024 * 1024)::bigint);
SELECT svs_memory_reconcile_load(540, 1, (7 * 1024 * 1024)::bigint);
SELECT residency_bytes_committed = (7 * 1024 * 1024) AS committed_equals_measured
  FROM svs_memory_read_stats(540);
SELECT svs_memory_abort_build(540, 1);
SELECT residency_bytes_committed = 0 AS committed_back_to_zero_after_abort
  FROM svs_memory_read_stats(540);
SELECT * FROM svs_memory_test_check_invariants();

-- ReconcileLoad's existing-reservation branch can still refuse with no
-- budget change involved: a RESERVED estimate that undershoots the real
-- measured size fails on its own, leaving the reservation and the counter
-- exactly as they were.
SELECT svs_memory_admit_database(541, (1 * 1024 * 1024)::bigint);
SELECT svs_memory_reserve_build(541, 1, 1024::bigint, (512 * 1024)::bigint);
SELECT svs_memory_reconcile_load(541, 1, (2 * 1024 * 1024)::bigint) AS fits;
SELECT residency_bytes_committed = (512 * 1024) AS estimate_untouched_by_failed_reconcile
  FROM svs_memory_read_stats(541);
SELECT * FROM svs_memory_test_check_invariants();

-- ReanchorInsert only warns on overage, it never refuses, so ordinary
-- insert growth can push a database's committed bytes over its budget in
-- normal operation; the next load on that same database then refuses too,
-- with no budget ever having changed.
SELECT svs_memory_admit_database(542, (1 * 1024 * 1024)::bigint);
SELECT svs_memory_reconcile_load(542, 1, (800 * 1024)::bigint);
SELECT svs_memory_reserve_insert(542, 1, (100 * 1024)::bigint);
SELECT svs_memory_reanchor_insert(542, 1, (1200 * 1024)::bigint);
SELECT residency_bytes_committed > residency_budget AS over_budget_after_reanchor
  FROM svs_memory_read_stats(542);
SELECT svs_memory_reconcile_load(542, 2, (100 * 1024)::bigint) AS fits;
SELECT residency_bytes_committed = (1200 * 1024) AS committed_unchanged_by_failed_load
  FROM svs_memory_read_stats(542);
SELECT * FROM svs_memory_test_check_invariants();

-- Unload the deliberate overage above so it does not leak into every
-- check_invariants() call for the rest of this file.
SELECT svs_memory_account_unload(542, 1);
SELECT * FROM svs_memory_test_check_invariants();

-- Guard: a database cannot have two live reservations for the same relid.
SELECT svs_memory_admit_database(600, (1 * 1024)::bigint);
SELECT svs_memory_reserve_build(600, 1, 0::bigint, 100::bigint);
SELECT svs_memory_reserve_build(600, 1, 0::bigint, 100::bigint);
SELECT count(*) = 1 AS exactly_one_reservation_survives FROM svs_memory_test_reservations(600);
SELECT * FROM svs_memory_test_check_invariants();

-- Guard: a database cannot be admitted at a zero residency budget.
SELECT svs_memory_admit_database(601, 0::bigint);

-- Guard: a handoff with no matching build reservation errors instead of
-- silently accounting bytes no reservation ever claimed.
SELECT svs_memory_admit_database(602, (1 * 1024)::bigint);
SELECT svs_memory_handoff_build(602, 1, 0::bigint, 100::bigint);
SELECT * FROM svs_memory_test_check_invariants();

-- HandoffBuild zeros buildPeakBytes once released, so nothing later
-- re-releases it; a later abort on the same (now-confirmed) reservation
-- then leaves the global build counter untouched.
SELECT svs_memory_admit_database(603, (1 * 1024)::bigint);
SELECT svs_memory_reserve_build(603, 1, 500::bigint, 100::bigint);
SELECT svs_memory_handoff_build(603, 1, 500::bigint, 100::bigint);
SELECT build_peak_bytes = 0 AS build_peak_zeroed_after_handoff
  FROM svs_memory_test_reservations(603);
SELECT svs_memory_test_global_build_committed_bytes() AS build_committed_before_603 \gset
SELECT svs_memory_abort_build(603, 1);
SELECT svs_memory_test_global_build_committed_bytes() AS build_committed_after_603 \gset
SELECT :build_committed_before_603 = :build_committed_after_603 AS build_peak_not_double_released;
SELECT * FROM svs_memory_test_check_invariants();

-- The reaper reclaims only RESERVED reservations; a dead owner on a
-- CONFIRMED record is never treated as an abandoned build.
SELECT svs_memory_admit_database(604, (10 * 1024)::bigint);
SELECT svs_memory_reserve_build(604, 1, 0::bigint, (1 * 1024)::bigint);
SELECT svs_memory_reserve_build(604, 2, 0::bigint, (1 * 1024)::bigint);
SELECT svs_memory_handoff_build(604, 2, 0::bigint, (1 * 1024)::bigint);
SELECT svs_memory_test_set_owner_pid(604, 1, 2147483647);
SELECT svs_memory_test_set_owner_pid(604, 2, 2147483647);
SELECT svs_memory_reap_dead_reservations();
SELECT relid, state FROM svs_memory_test_reservations(604) ORDER BY relid;
SELECT * FROM svs_memory_test_check_invariants();

-- RequireAdmitted's error: any accounting call on a database that was
-- never admitted refuses cleanly.
SELECT svs_memory_reserve_build(605, 1, 0::bigint, 100::bigint);

-- The reservation table is finite: a 65th distinct index for one database
-- is refused outright, and the 64 already tracked stay tracked.
SELECT svs_memory_admit_database(606, 1000::bigint);
DO $$
BEGIN
	FOR i IN 1..64 LOOP
		PERFORM svs_memory_reserve_build(606, i, 0::bigint, 1::bigint);
	END LOOP;
END $$;
SELECT svs_memory_reserve_build(606, 65, 0::bigint, 1::bigint);
SELECT count(*) = 64 AS all_64_slots_still_tracked FROM svs_memory_test_reservations(606);
SELECT * FROM svs_memory_test_check_invariants();

-- Unloading an index with no reservation warns instead of erroring.
SELECT svs_memory_admit_database(607, (1 * 1024)::bigint);
SELECT svs_memory_account_unload(607, 1);
SELECT * FROM svs_memory_test_check_invariants();

-- The pending-insert table is finite too: a 65th distinct pending batch
-- for one database is refused, and the 64 already queued stay queued.
SELECT svs_memory_admit_database(608, 100000::bigint);
DO $$
BEGIN
	FOR i IN 1..64 LOOP
		PERFORM svs_memory_reserve_insert(608, 1, 1::bigint);
	END LOOP;
END $$;
SELECT svs_memory_reserve_insert(608, 1, 1::bigint);
SELECT count(*) = 64 AS all_64_pending_inserts_still_queued
  FROM svs_memory_test_insert_reservations(608);
SELECT * FROM svs_memory_test_check_invariants();

-- Reanchor refuses when relid has no resident reservation to fold into.
SELECT svs_memory_admit_database(609, (1 * 1024)::bigint);
SELECT svs_memory_reanchor_insert(609, 1, 100::bigint);
SELECT * FROM svs_memory_test_check_invariants();

-- Abort on a relid with no reservation at all is a safe no-op, not an
-- error: the "safe to call more than once" promise extends to a relid
-- that was never reserved in the first place.
SELECT svs_memory_admit_database(610, (1 * 1024)::bigint);
SELECT residency_bytes_committed = 0 AND build_bytes_committed = 0 AS clean_before_noop_abort
  FROM svs_memory_read_stats(610);
SELECT svs_memory_abort_build(610, 1);
SELECT residency_bytes_committed = 0 AND build_bytes_committed = 0 AS unchanged_after_noop_abort
  FROM svs_memory_read_stats(610);
SELECT * FROM svs_memory_test_check_invariants();

-- Reanchor with no pending insert waiting still folds cleanly: the
-- steady-state re-measure case, with nothing pending to fold in.
SELECT svs_memory_admit_database(611, (1 * 1024)::bigint);
SELECT svs_memory_reconcile_load(611, 1, 100::bigint);
SELECT svs_memory_reanchor_insert(611, 1, 150::bigint);
SELECT residency_bytes_committed = 150 AS reanchored_to_new_measurement_exactly
  FROM svs_memory_read_stats(611);
SELECT * FROM svs_memory_test_check_invariants();

-- ReserveBuild's rollback on a global-ceiling failure leaves every counter
-- untouched and the relid reusable, not consumed by the failed attempt.
SELECT svs_memory_admit_database(612, (1 * 1024 * 1024)::bigint);
SELECT svs_memory_test_global_build_committed_bytes() AS build_committed_612 \gset
SELECT svs_memory_reserve_build(612, 1, (:build_ceiling - :build_committed_612 + 1)::bigint, 1::bigint);
SELECT residency_bytes_committed = 0 AND build_bytes_committed = 0 AS counters_untouched_by_failed_reserve
  FROM svs_memory_read_stats(612);
SELECT count(*) = 0 AS failed_reserve_consumed_no_slot FROM svs_memory_test_reservations(612);
SELECT svs_memory_reserve_build(612, 1, 1024::bigint, 1::bigint);
SELECT relid, state, owner_pid = pg_backend_pid() AS owned_by_this_backend,
       estimate_bytes, measured_bytes, build_peak_bytes
  FROM svs_memory_test_reservations(612);
SELECT * FROM svs_memory_test_check_invariants();

-- SvsMemoryResetDatabaseAccounting, run on a slot release: rolling one
-- database's contribution out of the global totals must not touch another
-- database's. It also erases the reset database's own reservations, so a
-- reload starts clean rather than inheriting a recycled slot's tenant.
SELECT svs_memory_admit_database(620, (5 * 1024)::bigint);
SELECT svs_memory_reserve_build(620, 1, (1 * 1024)::bigint, (1 * 1024)::bigint);
SELECT svs_memory_admit_database(621, (5 * 1024)::bigint);
SELECT svs_memory_reserve_build(621, 1, (2 * 1024)::bigint, (2 * 1024)::bigint);
SELECT * FROM svs_memory_read_stats(621) \gset before_621_
SELECT svs_memory_test_reset_database_accounting(620);
SELECT count(*) = 0 AS reset_database_no_longer_admitted
  FROM svs_memory_read_stats(620);
SELECT count(*) = 0 AS reset_database_lost_its_reservations
  FROM svs_memory_test_reservations(620);
SELECT residency_bytes_committed = :before_621_residency_bytes_committed
   AND build_bytes_committed = :before_621_build_bytes_committed AS other_database_untouched
  FROM svs_memory_read_stats(621);
SELECT * FROM svs_memory_test_check_invariants();

-- durable_committed_floor: the fallback SvsMemoryAdmitDatabase's caller
-- passes in place of the live counter when a worker cannot yet be trusted
-- to answer from shared memory (svs_index_residency.h). A freshly
-- constructed entry's committed bytes read 0 (no reconcile has ever run
-- against it), exactly as they do on a real server restart before the
-- worker reloads anything; the floor is the only thing standing between
-- that 0 and a budget lowered out from under bytes a durable row still
-- remembers. Byte-scale, not MB-scale, values throughout this section: the
-- shared global residency ceiling is nearly exhausted by every admit
-- earlier in this file.
--
-- A floor above the (here, zero) live counter blocks a decrease the live
-- counter alone would allow.
SELECT svs_memory_admit_database(650, (10 * 1024)::bigint);
SELECT svs_memory_admit_database(650, (2 * 1024)::bigint, (5 * 1024)::bigint);
SELECT residency_budget = (10 * 1024) AS budget_unchanged_by_rejected_decrease
  FROM svs_memory_read_stats(650);
SELECT * FROM svs_memory_test_check_invariants();

-- Exactly at the floor succeeds; one byte under it fails, symmetric with
-- every other fits-check boundary in this file.
SELECT svs_memory_admit_database(650, (5 * 1024)::bigint, (5 * 1024)::bigint);
SELECT svs_memory_admit_database(650, (5 * 1024 - 1)::bigint, (5 * 1024)::bigint);
SELECT residency_budget = (5 * 1024) AS budget_holds_at_the_floor
  FROM svs_memory_read_stats(650);
SELECT * FROM svs_memory_test_check_invariants();

-- The floor never lowers the bar below what the live counter already
-- requires: a floor under the live committed total is not a license to
-- shrink past it.
SELECT svs_memory_admit_database(651, (10 * 1024)::bigint);
SELECT svs_memory_reconcile_load(651, 1, (4 * 1024)::bigint);
SELECT svs_memory_admit_database(651, (3 * 1024)::bigint, (1 * 1024)::bigint);
SELECT residency_budget = (10 * 1024) AS live_counter_still_governs_over_a_lower_floor
  FROM svs_memory_read_stats(651);
SELECT svs_memory_admit_database(651, (4 * 1024)::bigint, (1 * 1024)::bigint);
SELECT * FROM svs_memory_test_check_invariants();
SELECT svs_memory_account_unload(651, 1);
SELECT svs_memory_admit_database(651, 1::bigint);

-- A floor at or below a fresh entry's zero committed bytes admits normally:
-- durable_committed_floor is a floor, not a mandatory minimum budget.
SELECT svs_memory_admit_database(652, (1 * 1024)::bigint, 0::bigint);
SELECT * FROM svs_memory_test_check_invariants();

-- AbortInsert releases only the calling backend's own pending reservation.
-- Two reservations share relid 1, one faked to a different owner pid; abort
-- must free the one owned by this session and leave the other's delta
-- committed.
SELECT svs_memory_admit_database(660, (10 * 1024)::bigint);
SELECT svs_memory_reserve_insert(660, 1, (2 * 1024)::bigint);
SELECT svs_memory_reserve_insert(660, 1, (3 * 1024)::bigint);
SELECT svs_memory_test_set_insert_reservation_owner_pid(660, 1, (3 * 1024)::bigint, -1);
SELECT svs_memory_abort_insert(660, 1);
SELECT delta_bytes = (3 * 1024) AS only_the_other_owners_reservation_remains
  FROM svs_memory_test_insert_reservations(660);
SELECT residency_bytes_committed = (3 * 1024) AS only_the_other_owners_delta_still_committed
  FROM svs_memory_read_stats(660);
SELECT * FROM svs_memory_test_check_invariants();

-- Abort finding a reservation for relid, but none owned by this session, is
-- a safe no-op: the ownership match above must not degrade to "free
-- whatever exists for this relid" when nothing matches.
SELECT svs_memory_admit_database(661, (10 * 1024)::bigint);
SELECT svs_memory_reserve_insert(661, 1, (4 * 1024)::bigint);
SELECT svs_memory_test_set_insert_reservation_owner_pid(661, 1, (4 * 1024)::bigint, -1);
SELECT svs_memory_abort_insert(661, 1);
SELECT count(*) = 1 AS foreign_owned_reservation_survives_the_noop_abort
  FROM svs_memory_test_insert_reservations(661);
SELECT * FROM svs_memory_test_check_invariants();

-- Abort with no reservation at all for relid is a safe no-op too, the same
-- "safe to call more than once" contract AbortBuild already documents.
SELECT svs_memory_admit_database(662, (1 * 1024)::bigint);
SELECT svs_memory_abort_insert(662, 1);
SELECT residency_bytes_committed = 0 AS unchanged_after_noop_abort
  FROM svs_memory_read_stats(662);
SELECT * FROM svs_memory_test_check_invariants();
