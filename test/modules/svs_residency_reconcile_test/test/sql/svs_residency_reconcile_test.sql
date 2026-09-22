CREATE EXTENSION vector;
CREATE EXTENSION svs;
CREATE EXTENSION svs_residency_reconcile_test;

-- svs_index_residency's own DML is revoked from PUBLIC; this session is the
-- regression superuser, which bypasses that. The relids below are
-- fabricated: SvsIndexResidencyReconcileOrphans only ever compares OIDs, it
-- never opens the relation they name.
INSERT INTO svs_index_residency (index_relid, db_oid, resident_bytes)
VALUES (999901, (SELECT oid FROM pg_database WHERE datname = current_database()), 12345),
       (999902, (SELECT oid FROM pg_database WHERE datname = current_database()), 67890);

-- An empty live set must be refused outright: both rows survive untouched,
-- because an empty enumeration is indistinguishable from a failed one.
SELECT svs_residency_reconcile_test_call(
    (SELECT oid FROM pg_database WHERE datname = current_database()),
    ARRAY[]::oid[]);

SELECT count(*) AS rows_after_empty_live_set
FROM svs_index_residency WHERE index_relid IN (999901, 999902);

-- A non-empty live set that excludes both fabricated relids sweeps them,
-- proving the empty-set result above was the refusal, not a DELETE that
-- silently matches nothing.
SELECT svs_residency_reconcile_test_call(
    (SELECT oid FROM pg_database WHERE datname = current_database()),
    ARRAY[424242]::oid[]);

SELECT count(*) AS rows_after_nonempty_sweep
FROM svs_index_residency WHERE index_relid IN (999901, 999902);

-- A row named in the live set survives a nonempty sweep alongside an
-- orphan being removed, so the guard is not merely "run or don't run" but
-- "delete exactly what isn't live".
INSERT INTO svs_index_residency (index_relid, db_oid, resident_bytes)
VALUES (999903, (SELECT oid FROM pg_database WHERE datname = current_database()), 111),
       (999904, (SELECT oid FROM pg_database WHERE datname = current_database()), 222);

SELECT svs_residency_reconcile_test_call(
    (SELECT oid FROM pg_database WHERE datname = current_database()),
    ARRAY[999903]);

SELECT index_relid FROM svs_index_residency
WHERE index_relid IN (999903, 999904) ORDER BY index_relid;
