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

CREATE FUNCTION svs_memory_test_reservations(
    db_oid oid,
    OUT relid oid,
    OUT state text,
    OUT owner_pid int,
    OUT estimate_bytes bigint,
    OUT measured_bytes bigint,
    OUT build_peak_bytes bigint,
    OUT search_scratch_bytes_per_query bigint,
    OUT prior_resident_bytes bigint
) RETURNS SETOF record
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION svs_memory_test_insert_reservations(
    db_oid oid,
    OUT relid oid,
    OUT owner_pid int,
    OUT delta_bytes bigint
) RETURNS SETOF record
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION svs_memory_test_check_invariants(OUT db_oid oid, OUT violation text)
RETURNS SETOF record
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION svs_memory_test_set_owner_pid(db_oid oid, relid oid, owner_pid int)
RETURNS void
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION svs_memory_test_reset_database_accounting(db_oid oid)
RETURNS void
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION svs_memory_test_set_launcher_database(launcher_database text)
RETURNS void
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION svs_memory_test_resolve_residency_budget(db_oid oid) RETURNS bigint
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION svs_memory_test_resolve_search_work_mem(db_oid oid) RETURNS bigint
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION svs_memory_test_residency_budget(db_oid oid) RETURNS bigint
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION svs_memory_test_search_scratch_bytes_per_query(db_oid oid, relid oid)
RETURNS bigint
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION svs_memory_test_recheck_search_scratch_options(
    db_oid oid, relid oid, search_window_size int, use_search_history boolean
) RETURNS void
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION svs_memory_test_set_search_scratch_bytes_per_query(
    db_oid oid, relid oid, bytes_per_query bigint
) RETURNS void
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION svs_memory_admit_database(db_oid oid, residency_budget bigint, durable_committed_floor bigint DEFAULT 0)
RETURNS void
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION svs_memory_restore_residency_budget(db_oid oid, prior_budget bigint)
RETURNS void
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION svs_memory_reserve_build(db_oid oid, relid oid, build_peak bigint, residency_estimate bigint)
RETURNS void
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION svs_memory_confirm_build(db_oid oid, relid oid, build_peak bigint, measured_residency_bytes bigint)
RETURNS boolean
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION svs_memory_handoff_build(db_oid oid, relid oid)
RETURNS void
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

CREATE FUNCTION svs_memory_close_insert_reservation(db_oid oid, relid oid)
RETURNS void
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION svs_memory_abort_insert(db_oid oid, relid oid)
RETURNS void
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

CREATE FUNCTION svs_memory_test_set_insert_reservation_owner_pid(
    db_oid oid, relid oid, delta_bytes bigint, owner_pid int)
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
