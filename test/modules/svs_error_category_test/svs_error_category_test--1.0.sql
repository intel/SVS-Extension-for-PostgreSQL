\echo Use "CREATE EXTENSION svs_error_category_test" to load this file. \quit

CREATE FUNCTION svs_error_category_test_unsupported_hw_round_trips()
RETURNS bool
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT;

CREATE FUNCTION svs_error_category_test_existing_categories_unchanged()
RETURNS bool
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT;
