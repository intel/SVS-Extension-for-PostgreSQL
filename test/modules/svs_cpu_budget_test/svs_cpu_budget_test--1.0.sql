/* test/modules/svs_cpu_budget_test/svs_cpu_budget_test--1.0.sql */

\echo Use "CREATE EXTENSION svs_cpu_budget_test" to load this file. \quit

CREATE FUNCTION svs_cpu_budget_test(
    max_parallel_workers int4,
    max_search_threads_per_db int4,
    max_total_search_threads int4,
    max_parallel_maintenance_workers int4,
    search_num_threads_default int4,
    db_oid oid[],
    db_live boolean[],
    db_search_num_threads int4[],
    db_search_threads_reserved int4[],
    build_db_oid oid[],
    build_request_pid int4[],
    build_maintenance_num_threads int4[]
) RETURNS TABLE (
    kind text,
    db_oid oid,
    request_pid int4,
    desired int4,
    granted int4,
    reserved int4,
    reserved_floors_exceed_pool boolean
)
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;
