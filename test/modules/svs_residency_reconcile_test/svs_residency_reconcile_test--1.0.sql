\echo Use "CREATE EXTENSION svs_residency_reconcile_test" to load this file. \quit

CREATE FUNCTION svs_residency_reconcile_test_call(db_oid oid, live_relids oid[])
RETURNS void
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT;
