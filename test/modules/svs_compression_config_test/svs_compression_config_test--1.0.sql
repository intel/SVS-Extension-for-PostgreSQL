\echo Use "CREATE EXTENSION svs_compression_config_test" to load this file. \quit

CREATE FUNCTION svs_compression_config_test_is_valid(
    compression_type int,
    compression_primary int,
    compression_secondary int)
RETURNS bool
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT;
