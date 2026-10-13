/* test/modules/svs_umask_test/svs_umask_test--1.0.sql */

\echo Use "CREATE EXTENSION svs_umask_test" to load this file. \quit

CREATE FUNCTION svs_test_set_umask(mode int)
RETURNS int
AS 'MODULE_PATHNAME' LANGUAGE C STRICT;

REVOKE ALL ON FUNCTION svs_test_set_umask(int) FROM PUBLIC;
