\echo Use "CREATE EXTENSION svs_parallel_build_test" to load this file. \quit

CREATE FUNCTION svs_parallel_build_test_run(nworkers int4)
RETURNS int4
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT;
