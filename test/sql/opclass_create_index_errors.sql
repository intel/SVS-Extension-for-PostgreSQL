-- Copyright (C) 2026 Intel Corporation
-- SPDX-License-Identifier: PostgreSQL
--
-- CREATE INDEX error text for the type and distance-metric checks vamanautils.c
-- shares with vamanavalidate. Covers error paths opclass_validate.sql cannot
-- reach without an actual index build. The operator/metric mismatch error has
-- its own test file, test/sql/opclass_metric_mismatch.sql.

-- Unsupported type.
CREATE OPERATOR CLASS vamana_test_create_index_point_ops
	FOR TYPE point USING vamana AS
	OPERATOR 1 <-> (point, point) FOR ORDER BY float_ops,
	FUNCTION 1 point_distance(point, point);

CREATE TABLE t (id serial PRIMARY KEY, val point);
CREATE INDEX ON t USING vamana (val vamana_test_create_index_point_ops);
DROP TABLE t;
DROP OPERATOR CLASS vamana_test_create_index_point_ops USING vamana;

-- No distance function at all: core's own index_getprocinfo() in
-- VamanaInitSupport rejects this before VamanaGetDistanceMetric's own
-- "no distance function found" check is ever reached, so the observed
-- error is core's generic missing-support-function text, not ours.
CREATE OPERATOR CLASS vamana_test_create_index_no_proc1_ops
	FOR TYPE vector USING vamana AS
	OPERATOR 1 <-> (vector, vector) FOR ORDER BY float_ops;

CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vamana_test_create_index_no_proc1_ops);
DROP TABLE t;
DROP OPERATOR CLASS vamana_test_create_index_no_proc1_ops USING vamana;

-- Right signature, unmapped name.
CREATE OPERATOR CLASS vamana_test_create_index_unmapped_proc1_ops
	FOR TYPE vector USING vamana AS
	OPERATOR 1 <-> (vector, vector) FOR ORDER BY float_ops,
	FUNCTION 1 l2_distance(vector, vector);

CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vamana_test_create_index_unmapped_proc1_ops);
DROP TABLE t;
DROP OPERATOR CLASS vamana_test_create_index_unmapped_proc1_ops USING vamana;
