\echo Use "CREATE EXTENSION svs_cache_load_test" to load this file. \quit

CREATE FUNCTION svs_cache_load_test_fake_load(relid oid, measured_bytes bigint)
RETURNS void
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT;

CREATE FUNCTION svs_cache_load_test_committed_bytes(relid oid)
RETURNS bigint
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT;

CREATE FUNCTION svs_cache_load_test_reservation_exists(relid oid)
RETURNS bool
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT;
