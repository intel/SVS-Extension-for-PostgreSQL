\echo Use "CREATE EXTENSION svs_multi_insert_bounds_test" to load this file. \quit

CREATE FUNCTION svs_multi_insert_bounds_test_validate(ntuples int, isinit bool, data_len bigint)
RETURNS bool
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT;
