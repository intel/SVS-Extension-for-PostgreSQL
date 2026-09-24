/* test/modules/svs_capacity_search_test/svs_capacity_search_test--1.0.sql */

\echo Use "CREATE EXTENSION svs_capacity_search_test" to load this file. \quit

CREATE FUNCTION svs_capacity_search_test_headroom(
    num_vectors bigint, block_size_vectors bigint, max_search_vectors bigint
) RETURNS bigint
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;
