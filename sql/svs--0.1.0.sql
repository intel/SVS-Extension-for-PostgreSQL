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
	restart_generation  bigint  NOT NULL DEFAULT 0,

	-- Placeholders for a future resource-management phase; NULL means
	-- "use the GUC default." Nullable with no default so activating them
	-- later needs no ALTER TABLE.
	graph_memory_mb          int CHECK (graph_memory_mb > 0),
	total_memory_mb          int CHECK (total_memory_mb > 0),
	search_num_threads       int CHECK (search_num_threads BETWEEN 1 AND 1024),

	-- NULL means "no floor" (pure best-effort against the shared pool).
	search_threads_reserved int CHECK (search_threads_reserved BETWEEN 0 AND 1024),

	-- NULL means "follow the cluster-wide build-thread default." 0 means
	-- serial, matching core's max_parallel_maintenance_workers = 0 semantics.
	maintenance_num_threads int CHECK (maintenance_num_threads BETWEEN 0 AND 1024)
);

SELECT pg_catalog.pg_extension_config_dump('vamana_databases', '');

CREATE FUNCTION vamana_databases_notify() RETURNS trigger
	LANGUAGE plpgsql AS
$$
BEGIN
	PERFORM pg_notify('vamana_databases_changed', '');
	RETURN NULL;
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

-- Not granted to PUBLIC by default, but explicit so the invariant survives a
-- future default-privileges change and is grep-able here.
REVOKE INSERT, UPDATE, DELETE ON vamana_databases FROM PUBLIC;

-- Observability
--
-- Two grains, mirroring pg_stat_replication / pg_replication_slots in core:
-- pg_stat_vamana_worker is one row per reserved database (worker grain);
-- pg_stat_vamana_worker_slot is one row per work-request slot (slot grain).
--
-- Cross-database visibility is enforced C-side, per row: an unprivileged
-- caller sees only its own database's row, a pg_read_all_stats member sees all.
-- The views must still be readable for that gate to run, so SELECT is granted
-- to PUBLIC below.  Do not REVOKE it or narrow it: that would hide the self-row
-- from ordinary users, which the C-side filter is designed to expose.
--
-- The function and view intentionally share a name (function returns the set,
-- view is the queryable relation over it), mirroring the existing idiom.

CREATE FUNCTION pg_stat_vamana_worker()
	RETURNS TABLE (
		db_oid              oid,
		worker_pid          int,
		worker_state        text,
		index_count         int,
		evict_all           bool,
		heartbeat_ts        timestamptz
	)
	AS 'MODULE_PATHNAME', 'pg_stat_vamana_worker'
	LANGUAGE C;

CREATE VIEW pg_stat_vamana_worker AS
	SELECT * FROM pg_stat_vamana_worker();

CREATE FUNCTION pg_stat_vamana_worker_slot()
	RETURNS TABLE (
		db_oid              oid,
		slot_index          int,
		slot_status         text,
		slot_kind           text,
		index_relid         oid,
		error_message       text
	)
	AS 'MODULE_PATHNAME', 'pg_stat_vamana_worker_slot'
	LANGUAGE C;

CREATE VIEW pg_stat_vamana_worker_slot AS
	SELECT * FROM pg_stat_vamana_worker_slot();

-- Readable by everyone; the C-side row filter, not SQL privileges, scopes what
-- each caller sees (see the note above).
GRANT SELECT ON pg_stat_vamana_worker, pg_stat_vamana_worker_slot TO PUBLIC;

-- Worker restart

-- Bounce a single database's worker on demand without taking the database offline.
-- Increments restart_generation to signal the launcher to terminate and respawn
-- the worker. Only applies to enabled databases; raises an actionable error if the
-- database is paused or does not exist.
CREATE FUNCTION svs_restart_worker(dbname name) RETURNS void
	LANGUAGE plpgsql AS
$$
DECLARE
	rows int;
BEGIN
	UPDATE vamana_databases
	   SET restart_generation = restart_generation + 1
	 WHERE datname = dbname AND enabled;
	GET DIAGNOSTICS rows = ROW_COUNT;

	IF rows = 0 THEN
		IF EXISTS (SELECT 1 FROM vamana_databases WHERE datname = dbname) THEN
			RAISE EXCEPTION 'database "%" is paused; re-enable it instead of restarting', dbname;
		ELSE
			RAISE EXCEPTION 'database "%" is not configured for vamana', dbname;
		END IF;
	END IF;
END;
$$;

-- Permanent removal

-- Drops every vamana index in the current database, one row per index.
-- Not SECURITY DEFINER: each drop runs with the caller's own privileges.
CREATE FUNCTION svs_teardown_database()
	RETURNS TABLE (index_relid oid, index_name text, dropped bool, reason text)
	AS 'MODULE_PATHNAME', 'svs_teardown_database'
	LANGUAGE C;

-- Force a vamana index resident in the worker cache; fails if the argument is
-- not a vamana index or no worker is available.
CREATE FUNCTION svs_warmup_index(index regclass) RETURNS void
	AS 'MODULE_PATHNAME', 'svs_warmup_index'
	LANGUAGE C;

-- Warm every vamana index in the current database, best-effort, returning the
-- number warmed.  Per-index failures warn and are skipped.
CREATE FUNCTION svs_warmup_database() RETURNS integer
	AS 'MODULE_PATHNAME', 'svs_warmup_database'
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
