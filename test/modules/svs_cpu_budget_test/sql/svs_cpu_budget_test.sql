-- Copyright (C) 2026 Intel Corporation
-- SPDX-License-Identifier: PostgreSQL

CREATE EXTENSION svs_cpu_budget_test;

-- No configuration: everyone gets 1 search thread, builds run serial.
SELECT * FROM svs_cpu_budget_test(
    8, 0, 0, 2, 0,
    ARRAY[100,200]::oid[], ARRAY[true,true], ARRAY[-1,-1], ARRAY[0,0],
    ARRAY[]::oid[], ARRAY[]::int4[], ARRAY[]::int4[])
ORDER BY kind, db_oid;

-- Demand fits the pool: everyone gets their full ask, no arbitration needed.
SELECT * FROM svs_cpu_budget_test(
    8, 0, 0, 2, 0,
    ARRAY[100,200]::oid[], ARRAY[true,true], ARRAY[3,1], ARRAY[0,0],
    ARRAY[]::oid[], ARRAY[]::int4[], ARRAY[]::int4[])
ORDER BY kind, db_oid;

-- Contention: hot_db's floor is honored in full, the remainder is split,
-- and hot_db's own build absorbs the squeeze.
SELECT * FROM svs_cpu_budget_test(
    8, 0, 0, 2, 0,
    ARRAY[100,200]::oid[], ARRAY[true,true], ARRAY[6,1], ARRAY[4,0],
    ARRAY[100]::oid[], ARRAY[555], ARRAY[4])
ORDER BY kind, db_oid;

-- Proportional split of the elastic remainder between two unequal floors,
-- with no builds competing.
SELECT * FROM svs_cpu_budget_test(
    9, 0, 0, 2, 0,
    ARRAY[100,200]::oid[], ARRAY[true,true], ARRAY[8,4], ARRAY[4,2],
    ARRAY[]::oid[], ARRAY[]::int4[], ARRAY[]::int4[])
ORDER BY kind, db_oid;

-- Configured floors sum past the pool: the clamp lands on the lowest dbOid
-- first, and the flag comes back set.
SELECT * FROM svs_cpu_budget_test(
    8, 0, 0, 2, 0,
    ARRAY[10,20,30]::oid[], ARRAY[true,true,true], ARRAY[4,4,4], ARRAY[4,4,4],
    ARRAY[]::oid[], ARRAY[]::int4[], ARRAY[]::int4[])
ORDER BY kind, db_oid;

-- No databases, no builds: no rows.
SELECT * FROM svs_cpu_budget_test(
    8, 0, 0, 2, 0,
    ARRAY[]::oid[], ARRAY[]::boolean[], ARRAY[]::int4[], ARRAY[]::int4[],
    ARRAY[]::oid[], ARRAY[]::int4[], ARRAY[]::int4[])
ORDER BY kind, db_oid;

-- A dead/backing-off database contributes nothing, floor or otherwise.
SELECT * FROM svs_cpu_budget_test(
    8, 0, 0, 2, 0,
    ARRAY[100,200]::oid[], ARRAY[false,true], ARRAY[6,1], ARRAY[4,0],
    ARRAY[]::oid[], ARRAY[]::int4[], ARRAY[]::int4[])
ORDER BY kind, db_oid;
