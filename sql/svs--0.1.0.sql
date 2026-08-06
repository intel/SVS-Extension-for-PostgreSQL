-- Copyright (C) 2026 Intel Corporation
-- SPDX-License-Identifier: PostgreSQL

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION svs" to load this file. \quit

CREATE FUNCTION vamanahandler(internal) RETURNS index_am_handler
	AS 'MODULE_PATHNAME' LANGUAGE C;

CREATE ACCESS METHOD vamana TYPE INDEX HANDLER vamanahandler;

COMMENT ON ACCESS METHOD vamana IS 'vamana index access method';

-- Operator classes for vector type

CREATE OPERATOR CLASS vector_l2_ops
	FOR TYPE vector USING vamana AS
	OPERATOR 1 <-> (vector, vector) FOR ORDER BY float_ops,
	FUNCTION 1 vector_l2_squared_distance(vector, vector);

CREATE OPERATOR CLASS vector_ip_ops
	FOR TYPE vector USING vamana AS
	OPERATOR 1 <#> (vector, vector) FOR ORDER BY float_ops,
	FUNCTION 1 vector_negative_inner_product(vector, vector);

CREATE OPERATOR CLASS vector_cosine_ops
	FOR TYPE vector USING vamana AS
	OPERATOR 1 <=> (vector, vector) FOR ORDER BY float_ops,
	FUNCTION 1 vector_negative_inner_product(vector, vector),
	FUNCTION 2 vector_norm(vector);

-- Operator classes for halfvec type

CREATE OPERATOR CLASS halfvec_l2_ops
	FOR TYPE halfvec USING vamana AS
	OPERATOR 1 <-> (halfvec, halfvec) FOR ORDER BY float_ops,
	FUNCTION 1 halfvec_l2_squared_distance(halfvec, halfvec);

CREATE OPERATOR CLASS halfvec_ip_ops
	FOR TYPE halfvec USING vamana AS
	OPERATOR 1 <#> (halfvec, halfvec) FOR ORDER BY float_ops,
	FUNCTION 1 halfvec_negative_inner_product(halfvec, halfvec);

CREATE OPERATOR CLASS halfvec_cosine_ops
	FOR TYPE halfvec USING vamana AS
	OPERATOR 1 <=> (halfvec, halfvec) FOR ORDER BY float_ops,
	FUNCTION 1 halfvec_negative_inner_product(halfvec, halfvec),
	FUNCTION 2 l2_norm(halfvec);

-- Per-database enablement catalog

CREATE TABLE vamana_databases (
	datname             name    PRIMARY KEY,
	enabled             bool    NOT NULL DEFAULT true,

	-- Placeholders for a future resource-management phase; NULL means
	-- "use the GUC default." Nullable with no default so activating them
	-- later needs no ALTER TABLE.
	graph_memory_mb     int,
	total_memory_mb     int,
	search_num_threads  int
);

CREATE FUNCTION vamana_databases_notify() RETURNS trigger
	LANGUAGE plpgsql AS
$$
BEGIN
	PERFORM pg_notify('vamana_databases_changed', '');
	RETURN NEW;
END;
$$;

CREATE TRIGGER vamana_databases_changed
	AFTER INSERT OR UPDATE OR DELETE ON vamana_databases
	FOR EACH STATEMENT EXECUTE FUNCTION vamana_databases_notify();

CREATE FUNCTION vamana_databases_queue_reservation() RETURNS trigger
	AS 'MODULE_PATHNAME', 'vamana_databases_queue_reservation' LANGUAGE C;

CREATE TRIGGER vamana_databases_queue_reservation
	AFTER INSERT OR UPDATE ON vamana_databases
	FOR EACH ROW EXECUTE FUNCTION vamana_databases_queue_reservation();

-- TRUNCATE bypasses DELETE triggers; block it since no role has a
-- legitimate reason to bulk-wipe this table. The owner retains TRUNCATE
-- regardless of this revoke.
REVOKE TRUNCATE ON vamana_databases FROM PUBLIC;

-- Observability

CREATE FUNCTION pg_stat_vamana_worker()
	RETURNS TABLE (
		worker_pid          int,
		db_oid              oid,
		reload_queue_depth  int,
		active_slot_count   int,
		evict_all           bool,
		heartbeat_ts        timestamptz,
		index_count         int,
		slot_index          int,
		slot_status         text,
		index_relid         oid,
		slot_kind           text,
		error_message       text
	)
	AS 'MODULE_PATHNAME', 'pg_stat_vamana_worker'
	LANGUAGE C STRICT;

CREATE VIEW pg_stat_vamana_worker AS
	SELECT * FROM pg_stat_vamana_worker();

-- Permanent removal

-- Drops every vamana index in the current database, one row per index.
-- Not SECURITY DEFINER: each drop runs with the caller's own privileges.
CREATE FUNCTION svs_teardown_database()
	RETURNS TABLE (index_relid oid, index_name text, dropped bool, reason text)
	AS 'MODULE_PATHNAME', 'svs_teardown_database'
	LANGUAGE C;

-- Reject deleting a row while vamana indexes still exist in that database, so
-- their save directories and replication slots are never orphaned.  TRUNCATE
-- would bypass a DELETE trigger; it is already revoked from PUBLIC above.
CREATE FUNCTION vamana_databases_reject_delete_with_live_indexes()
	RETURNS trigger
	AS 'MODULE_PATHNAME', 'vamana_databases_reject_delete_with_live_indexes'
	LANGUAGE C;

CREATE TRIGGER vamana_databases_reject_delete_with_live_indexes
	BEFORE DELETE ON vamana_databases
	FOR EACH ROW
	EXECUTE FUNCTION vamana_databases_reject_delete_with_live_indexes();
