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

-- A build peak at handoff that does not match what was reserved is capped
-- at zero rather than driving the per-database build counter negative.
SELECT svs_memory_reserve_build(100, 11, (2 * 1024 * 1024)::bigint, (2 * 1024 * 1024)::bigint);
SELECT svs_memory_handoff_build(100, 11, (50 * 1024 * 1024)::bigint, (2 * 1024 * 1024)::bigint);
SELECT * FROM svs_memory_read_stats(100);
SELECT svs_memory_account_unload(100, 11);
SELECT * FROM svs_memory_read_stats(100);

-- Build reserve, then a handoff whose measured bytes fit: build peak
-- releases, residency reconciles from estimate to measured.
SELECT svs_memory_reserve_build(100, 1, (10 * 1024 * 1024)::bigint, (10 * 1024 * 1024)::bigint);
SELECT * FROM svs_memory_read_stats(100);
SELECT svs_memory_handoff_build(100, 1, (10 * 1024 * 1024)::bigint, (9 * 1024 * 1024)::bigint);
SELECT * FROM svs_memory_read_stats(100);

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

-- A handoff whose measured bytes do not fit drops the reservation entirely.
SELECT svs_memory_reserve_build(100, 2, (5 * 1024 * 1024)::bigint, (5 * 1024 * 1024)::bigint);
SELECT svs_memory_handoff_build(100, 2, (5 * 1024 * 1024)::bigint, (35 * 1024 * 1024)::bigint);
SELECT * FROM svs_memory_read_stats(100);

-- Abort releases both the build peak and the residency estimate.
SELECT svs_memory_reserve_build(100, 3, (3 * 1024 * 1024)::bigint, (3 * 1024 * 1024)::bigint);
SELECT svs_memory_abort_build(100, 3);
SELECT * FROM svs_memory_read_stats(100);

-- Reconcile load on a fresh handoff (index 1) is a re-verification: no change.
SELECT svs_memory_reconcile_load(100, 1, (9 * 1024 * 1024)::bigint);
SELECT * FROM svs_memory_read_stats(100);

-- Reconcile load with no pending reservation (reload or restart adopt),
-- fitting the budget.
SELECT svs_memory_reconcile_load(100, 4, (10 * 1024 * 1024)::bigint);
SELECT * FROM svs_memory_read_stats(100);

-- Same, but the measured bytes overflow the budget: nothing is committed.
SELECT svs_memory_reconcile_load(100, 5, (100 * 1024 * 1024)::bigint);
SELECT * FROM svs_memory_read_stats(100);

-- Unload releases index 4's exact committed bytes.
SELECT svs_memory_account_unload(100, 4);
SELECT * FROM svs_memory_read_stats(100);

-- Insert growth: a fitting reservation commits; an overflowing one does not.
SELECT svs_memory_reserve_insert(100, 1, (2 * 1024 * 1024)::bigint);
SELECT * FROM svs_memory_read_stats(100);
SELECT svs_memory_reserve_insert(100, 1, (50 * 1024 * 1024)::bigint);
SELECT * FROM svs_memory_read_stats(100);

-- Reanchoring folds index 1's prior measured size and its one pending
-- insert delta into the worker's single fresh exact measurement.
SELECT svs_memory_reanchor_insert(100, 1, (12 * 1024 * 1024)::bigint);
SELECT * FROM svs_memory_read_stats(100);

-- Reaping while every reservation's owner is this live session is a no-op.
-- A dead-owner reap needs a second, crashed backend to be real, which this
-- single-session driver cannot produce, so it is not exercised here.
SELECT svs_memory_reserve_build(100, 6, (1 * 1024 * 1024)::bigint, (1 * 1024 * 1024)::bigint);
SELECT svs_memory_reap_dead_reservations();
SELECT * FROM svs_memory_read_stats(100);
SELECT svs_memory_abort_build(100, 6);
SELECT svs_memory_account_unload(100, 1);
SELECT * FROM svs_memory_read_stats(100);

-- Global build ceiling: one big reservation, then a second that would push
-- the cluster-wide total over svs.max_build_memory.
SELECT svs_memory_admit_database(200, (40 * 1024 * 1024)::bigint);
SELECT svs_memory_reserve_build(100, 7, :build_ceiling - (10 * 1024 * 1024)::bigint, (1 * 1024 * 1024)::bigint);
SELECT svs_memory_reserve_build(200, 8, (20 * 1024 * 1024)::bigint, (1 * 1024 * 1024)::bigint);
SELECT svs_memory_abort_build(100, 7);

-- Global residency ceiling: admitted budgets already sum to 80MB
-- (databases 100 and 200 at 40MB each); a third database's budget pushes
-- the cluster-wide sum over svs.max_residency_memory.
SELECT svs_memory_admit_database(300, (30 * 1024 * 1024)::bigint);

-- Per-database residency budget, independent of the global ceiling: a
-- single build's residency estimate exceeding this database's own budget.
SELECT svs_memory_reserve_build(200, 9, (1 * 1024 * 1024)::bigint, (41 * 1024 * 1024)::bigint);

-- Every fits-check in this module compares with <= or >, never < or >=.
-- Each one below is exercised exactly at its limit (succeeds) and exactly
-- one byte past it (fails). The two global-ceiling cases capture the live
-- global totals first and run immediately, before anything else in this
-- section changes them.

SELECT svs_memory_test_global_build_committed_bytes() AS build_committed \gset
SELECT svs_memory_test_global_residency_committed_bytes() AS residency_committed \gset

-- Global residency ceiling (a sum of admitted budgets, not live usage):
-- admitting exactly up to the remaining headroom succeeds; one byte more
-- is rejected and the database is never admitted.
SELECT svs_memory_admit_database(520, (:residency_ceiling - :residency_committed)::bigint);
SELECT * FROM svs_memory_read_stats(520);
SELECT svs_memory_admit_database(521, 1::bigint);
SELECT * FROM svs_memory_read_stats(521);

-- Free the headroom the check above just consumed, so every other admit in
-- this section still has room against the shared global ceiling.
SELECT svs_memory_admit_database(520, 1::bigint);

-- Global build ceiling: filling exactly the remaining headroom succeeds;
-- one byte more fails and claims no reservation slot.
SELECT svs_memory_admit_database(522, (1 * 1024 * 1024)::bigint);
SELECT svs_memory_reserve_build(522, 1, (:build_ceiling - :build_committed)::bigint, 1024::bigint);
SELECT svs_memory_abort_build(522, 1);
SELECT svs_memory_reserve_build(522, 2, (:build_ceiling - :build_committed + 1)::bigint, 1024::bigint);

-- Per-database residency budget: a build whose estimate exactly fills a
-- fresh budget succeeds; one byte more fails and commits nothing.
SELECT svs_memory_admit_database(530, (1 * 1024 * 1024)::bigint);
SELECT svs_memory_reserve_build(530, 1, 1024::bigint, (1 * 1024 * 1024)::bigint);
SELECT * FROM svs_memory_read_stats(530);
SELECT svs_memory_abort_build(530, 1);
SELECT svs_memory_reserve_build(530, 2, 1024::bigint, (1 * 1024 * 1024 + 1)::bigint);
SELECT * FROM svs_memory_read_stats(530);

-- Budget-decrease guard: lowering a database's budget to exactly its
-- committed total succeeds; one byte below it is rejected.
SELECT svs_memory_admit_database(531, (1 * 1024 * 1024)::bigint);
SELECT svs_memory_reserve_build(531, 3, 1024::bigint, (1 * 1024 * 1024)::bigint);
SELECT svs_memory_admit_database(531, (1 * 1024 * 1024)::bigint);
SELECT svs_memory_admit_database(531, (1 * 1024 * 1024 - 1)::bigint);
SELECT * FROM svs_memory_read_stats(531);
SELECT svs_memory_abort_build(531, 3);

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

-- ReconcileLoad's no-pending-reservation fits check: exactly at budget
-- succeeds; one byte more fails and commits nothing.
SELECT svs_memory_admit_database(533, (1 * 1024 * 1024)::bigint);
SELECT svs_memory_reconcile_load(533, 6, (1 * 1024 * 1024)::bigint);
SELECT * FROM svs_memory_read_stats(533);
SELECT svs_memory_account_unload(533, 6);
SELECT svs_memory_reconcile_load(533, 7, (1 * 1024 * 1024 + 1)::bigint);
SELECT * FROM svs_memory_read_stats(533);

-- ReserveInsert's fits check: a delta that exactly fills the budget
-- succeeds; one byte more fails and reserves nothing.
SELECT svs_memory_admit_database(534, (1 * 1024 * 1024)::bigint);
SELECT svs_memory_reserve_insert(534, 8, (1 * 1024 * 1024)::bigint);
SELECT * FROM svs_memory_read_stats(534);
SELECT svs_memory_reserve_insert(534, 9, 1::bigint);
SELECT * FROM svs_memory_read_stats(534);
