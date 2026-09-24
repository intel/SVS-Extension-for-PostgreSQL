/* test/modules/svs_vector_buffer_test/svs_vector_buffer_test--1.0.sql */

\echo Use "CREATE EXTENSION svs_vector_buffer_test" to load this file. \quit

CREATE FUNCTION svs_vector_buffer_test_run(
    estimated_rows bigint,
    dimensions int,
    flat_input float8[],
    OUT flat_output float8[],
    OUT final_count bigint,
    OUT final_capacity bigint
) RETURNS record
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;
