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

-- Observability

CREATE FUNCTION pg_stat_vamana_worker()
	RETURNS TABLE (
		worker_pid          int,
		db_oid              oid,
		reload_queue_depth  int,
		active_slot_count   int,
		reload_all          bool,
		heartbeat_ts        timestamptz,
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
