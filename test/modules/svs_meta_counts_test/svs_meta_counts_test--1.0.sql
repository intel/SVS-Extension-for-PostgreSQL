\echo Use "CREATE EXTENSION svs_meta_counts_test" to load this file. \quit

CREATE FUNCTION svs_meta_counts_test_validate(relid oid, tid_mapping_capacity bigint,
	num_vectors bigint, num_deleted bigint, next_external_id bigint)
RETURNS bool
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT;
