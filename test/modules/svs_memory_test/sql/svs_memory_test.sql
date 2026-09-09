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

-- Build reserve, then a handoff whose measured bytes fit: build peak
-- releases, residency reconciles from estimate to measured.
SELECT svs_memory_reserve_build(100, 1, (10 * 1024 * 1024)::bigint, (10 * 1024 * 1024)::bigint);
SELECT * FROM svs_memory_read_stats(100);
SELECT svs_memory_handoff_build(100, 1, (10 * 1024 * 1024)::bigint, (9 * 1024 * 1024)::bigint);
SELECT * FROM svs_memory_read_stats(100);

-- A handoff whose measured bytes do not fit drops the reservation entirely.
SELECT svs_memory_reserve_build(100, 2, (5 * 1024 * 1024)::bigint, (5 * 1024 * 1024)::bigint);
SELECT svs_memory_handoff_build(100, 2, (5 * 1024 * 1024)::bigint, (35 * 1024 * 1024)::bigint);
SELECT * FROM svs_memory_read_stats(100);

-- Abort releases both the build peak and the residency estimate.
SELECT svs_memory_reserve_build(100, 3, (3 * 1024 * 1024)::bigint, (3 * 1024 * 1024)::bigint);
SELECT svs_memory_abort_build(100, 3, (3 * 1024 * 1024)::bigint);
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
-- single-session driver cannot produce; that case is a TAP test instead.
SELECT svs_memory_reserve_build(100, 6, (1 * 1024 * 1024)::bigint, (1 * 1024 * 1024)::bigint);
SELECT svs_memory_reap_dead_reservations();
SELECT * FROM svs_memory_read_stats(100);
SELECT svs_memory_abort_build(100, 6, (1 * 1024 * 1024)::bigint);
SELECT svs_memory_account_unload(100, 1);
SELECT * FROM svs_memory_read_stats(100);

-- Global build ceiling: one big reservation, then a second that would push
-- the cluster-wide total over svs.max_build_memory.
SELECT svs_memory_admit_database(200, (40 * 1024 * 1024)::bigint);
SELECT svs_memory_reserve_build(100, 7, :build_ceiling - (10 * 1024 * 1024)::bigint, (1 * 1024 * 1024)::bigint);
SELECT svs_memory_reserve_build(200, 8, (20 * 1024 * 1024)::bigint, (1 * 1024 * 1024)::bigint);
SELECT svs_memory_abort_build(100, 7, :build_ceiling - (10 * 1024 * 1024)::bigint);

-- Global residency ceiling: admitted budgets already sum to 80MB
-- (databases 100 and 200 at 40MB each); a third database's budget pushes
-- the cluster-wide sum over svs.max_residency_memory.
SELECT svs_memory_admit_database(300, (30 * 1024 * 1024)::bigint);

-- Per-database residency budget, independent of the global ceiling: a
-- single build's residency estimate exceeding this database's own budget.
SELECT svs_memory_reserve_build(200, 9, (1 * 1024 * 1024)::bigint, (41 * 1024 * 1024)::bigint);
