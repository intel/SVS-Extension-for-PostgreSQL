\echo Use "CREATE EXTENSION svs_unsupported_hw_test" to load this file. \quit

CREATE FUNCTION svs_unsupported_hw_test_report(message text, compression_name text)
RETURNS void
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT;
