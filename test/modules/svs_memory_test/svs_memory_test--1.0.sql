/* test/modules/svs_memory_test/svs_memory_test--1.0.sql */

\echo Use "CREATE EXTENSION svs_memory_test" to load this file. \quit

CREATE FUNCTION svs_memory_test_build_ceiling_bytes() RETURNS bigint
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION svs_memory_test_residency_ceiling_bytes() RETURNS bigint
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION svs_memory_test_global_build_committed_bytes() RETURNS bigint
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION svs_memory_test_global_residency_committed_bytes() RETURNS bigint
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION svs_memory_admit_database(db_oid oid, residency_budget bigint)
RETURNS void
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION svs_memory_reserve_build(db_oid oid, relid oid, build_peak bigint, residency_estimate bigint)
RETURNS void
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION svs_memory_handoff_build(db_oid oid, relid oid, build_peak bigint, measured_residency_bytes bigint)
RETURNS boolean
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION svs_memory_abort_build(db_oid oid, relid oid)
RETURNS void
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION svs_memory_reconcile_load(db_oid oid, relid oid, measured_bytes bigint)
RETURNS boolean
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION svs_memory_account_unload(db_oid oid, relid oid)
RETURNS void
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION svs_memory_reserve_insert(db_oid oid, relid oid, delta_bytes bigint)
RETURNS boolean
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION svs_memory_reanchor_insert(db_oid oid, relid oid, measured_bytes bigint)
RETURNS void
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION svs_memory_reap_dead_reservations()
RETURNS void
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION svs_memory_read_stats(
    db_oid oid,
    OUT residency_budget bigint,
    OUT residency_bytes_committed bigint,
    OUT build_bytes_committed bigint
) RETURNS SETOF record
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;
