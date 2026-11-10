-- Copyright (C) 2026 Intel Corporation
-- SPDX-License-Identifier: PostgreSQL
--
-- The scan path trusts an opclass's claimed ordering with no verification
-- against the metric support function 1 actually computes. CREATE INDEX
-- must reject an opclass whose strategy-1 operator does not implement the
-- same distance metric as support function 1, since the only alternative
-- is an index that silently returns nearest neighbours in the wrong order.

-- A malformed opclass: <=> (cosine ordering operator) paired with an L2
-- support function 1. These disagree, so building an index on it must fail.
CREATE OPERATOR CLASS vamana_test_metric_mismatch_ops
    FOR TYPE vector USING vamana AS
    OPERATOR 1 <=> (vector, vector) FOR ORDER BY float_ops,
    FUNCTION 1 vector_l2_squared_distance(vector, vector);

CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vamana_test_metric_mismatch_ops);
DROP TABLE t;
DROP OPERATOR CLASS vamana_test_metric_mismatch_ops USING vamana;

-- Every shipped opclass still builds a vamana index successfully: no
-- regression on the common case.
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops);
CREATE INDEX ON t USING vamana (val vector_ip_ops);
CREATE INDEX ON t USING vamana (val vector_cosine_ops);
DROP TABLE t;

CREATE TABLE th (id serial PRIMARY KEY, val halfvec(3));
CREATE INDEX ON th USING vamana (val halfvec_l2_ops);
CREATE INDEX ON th USING vamana (val halfvec_ip_ops);
CREATE INDEX ON th USING vamana (val halfvec_cosine_ops);
DROP TABLE th;
