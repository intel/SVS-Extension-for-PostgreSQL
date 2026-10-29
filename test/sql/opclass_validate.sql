-- Copyright (C) 2026 Intel Corporation
-- SPDX-License-Identifier: PostgreSQL

-- vamanavalidate() coverage: the shipped opclasses must all validate clean,
-- and each malformed shape CREATE OPERATOR CLASS / ALTER OPERATOR FAMILY
-- accepts today must be flagged.

-- Positive: every shipped opclass validates with no INFO output.
SELECT opcname, amvalidate(oid) FROM pg_opclass
 WHERE opcmethod = (SELECT oid FROM pg_am WHERE amname = 'vamana')
 ORDER BY opcname;

-- Unsupported indexed type.
CREATE OPERATOR CLASS vamana_test_point_ops
	FOR TYPE point USING vamana AS
	OPERATOR 1 <-> (point, point) FOR ORDER BY float_ops,
	FUNCTION 1 point_distance(point, point);

SELECT amvalidate(oid) FROM pg_opclass
 WHERE opcname = 'vamana_test_point_ops'
   AND opcmethod = (SELECT oid FROM pg_am WHERE amname = 'vamana');

DROP OPERATOR FAMILY vamana_test_point_ops USING vamana CASCADE;

-- Missing support function 1.
CREATE OPERATOR CLASS vamana_test_missing_proc1_ops
	FOR TYPE vector USING vamana AS
	OPERATOR 1 <-> (vector, vector) FOR ORDER BY float_ops;

SELECT amvalidate(oid) FROM pg_opclass
 WHERE opcname = 'vamana_test_missing_proc1_ops'
   AND opcmethod = (SELECT oid FROM pg_am WHERE amname = 'vamana');

DROP OPERATOR FAMILY vamana_test_missing_proc1_ops USING vamana CASCADE;

-- Wrong support function 1 signature.
CREATE OPERATOR CLASS vamana_test_wrong_proc1_sig_ops
	FOR TYPE vector USING vamana AS
	OPERATOR 1 <-> (vector, vector) FOR ORDER BY float_ops,
	FUNCTION 1 vector_dims(vector);

SELECT amvalidate(oid) FROM pg_opclass
 WHERE opcname = 'vamana_test_wrong_proc1_sig_ops'
   AND opcmethod = (SELECT oid FROM pg_am WHERE amname = 'vamana');

DROP OPERATOR FAMILY vamana_test_wrong_proc1_sig_ops USING vamana CASCADE;

-- Right signature, but a support function 1 name the build path does not map
-- to a metric.
CREATE OPERATOR CLASS vamana_test_unmapped_proc1_ops
	FOR TYPE vector USING vamana AS
	OPERATOR 1 <-> (vector, vector) FOR ORDER BY float_ops,
	FUNCTION 1 l2_distance(vector, vector);

SELECT amvalidate(oid) FROM pg_opclass
 WHERE opcname = 'vamana_test_unmapped_proc1_ops'
   AND opcmethod = (SELECT oid FROM pg_am WHERE amname = 'vamana');

DROP OPERATOR FAMILY vamana_test_unmapped_proc1_ops USING vamana CASCADE;

-- Wrong support function 2 signature.
CREATE OPERATOR CLASS vamana_test_wrong_proc2_sig_ops
	FOR TYPE vector USING vamana AS
	OPERATOR 1 <#> (vector, vector) FOR ORDER BY float_ops,
	FUNCTION 1 vector_negative_inner_product(vector, vector),
	FUNCTION 2 vector_dims(vector);

SELECT amvalidate(oid) FROM pg_opclass
 WHERE opcname = 'vamana_test_wrong_proc2_sig_ops'
   AND opcmethod = (SELECT oid FROM pg_am WHERE amname = 'vamana');

DROP OPERATOR FAMILY vamana_test_wrong_proc2_sig_ops USING vamana CASCADE;

-- A search operator with no FOR ORDER BY: this access method serves no
-- search quals.
CREATE OPERATOR CLASS vamana_test_search_op_ops
	FOR TYPE vector USING vamana AS
	OPERATOR 1 = (vector, vector),
	FUNCTION 1 vector_l2_squared_distance(vector, vector);

SELECT amvalidate(oid) FROM pg_opclass
 WHERE opcname = 'vamana_test_search_op_ops'
   AND opcmethod = (SELECT oid FROM pg_am WHERE amname = 'vamana');

DROP OPERATOR FAMILY vamana_test_search_op_ops USING vamana CASCADE;

-- Ordering operator declared against the wrong sort opfamily.
CREATE OPERATOR CLASS vamana_test_wrong_sortfamily_ops
	FOR TYPE vector USING vamana AS
	OPERATOR 1 <-> (vector, vector) FOR ORDER BY integer_ops,
	FUNCTION 1 vector_l2_squared_distance(vector, vector);

SELECT amvalidate(oid) FROM pg_opclass
 WHERE opcname = 'vamana_test_wrong_sortfamily_ops'
   AND opcmethod = (SELECT oid FROM pg_am WHERE amname = 'vamana');

DROP OPERATOR FAMILY vamana_test_wrong_sortfamily_ops USING vamana CASCADE;

-- A second ordering operator at a strategy other than 1: amstrategies = 0
-- means DDL will not reject this on its own.
CREATE OPERATOR CLASS vamana_test_extra_strategy_ops
	FOR TYPE vector USING vamana AS
	OPERATOR 1 <-> (vector, vector) FOR ORDER BY float_ops,
	OPERATOR 2 <=> (vector, vector) FOR ORDER BY float_ops,
	FUNCTION 1 vector_l2_squared_distance(vector, vector);

SELECT amvalidate(oid) FROM pg_opclass
 WHERE opcname = 'vamana_test_extra_strategy_ops'
   AND opcmethod = (SELECT oid FROM pg_am WHERE amname = 'vamana');

DROP OPERATOR FAMILY vamana_test_extra_strategy_ops USING vamana CASCADE;

-- Support function 3: declared but never read anywhere in the build or scan
-- path.
CREATE OPERATOR CLASS vamana_test_proc3_ops
	FOR TYPE vector USING vamana AS
	OPERATOR 1 <-> (vector, vector) FOR ORDER BY float_ops,
	FUNCTION 1 vector_l2_squared_distance(vector, vector),
	FUNCTION 3 vector_dims(vector);

SELECT amvalidate(oid) FROM pg_opclass
 WHERE opcname = 'vamana_test_proc3_ops'
   AND opcmethod = (SELECT oid FROM pg_am WHERE amname = 'vamana');

DROP OPERATOR FAMILY vamana_test_proc3_ops USING vamana CASCADE;

-- A support function registered with left type != right type: the runtime
-- lookup by (opcintype, opcintype) would never see it.
CREATE OPERATOR CLASS vamana_test_cross_type_ops
	FOR TYPE vector USING vamana AS
	OPERATOR 1 <-> (vector, vector) FOR ORDER BY float_ops,
	FUNCTION 1 vector_l2_squared_distance(vector, vector);

ALTER OPERATOR FAMILY vamana_test_cross_type_ops USING vamana
	ADD FUNCTION 2 (vector, halfvec) vector_norm(vector);

SELECT amvalidate(oid) FROM pg_opclass
 WHERE opcname = 'vamana_test_cross_type_ops'
   AND opcmethod = (SELECT oid FROM pg_am WHERE amname = 'vamana');

DROP OPERATOR FAMILY vamana_test_cross_type_ops USING vamana CASCADE;

-- Support function 2 present on an L2 opclass: a norm function only makes
-- sense paired with the inner-product/cosine metric.
CREATE OPERATOR CLASS vamana_test_l2_with_norm_ops
	FOR TYPE vector USING vamana AS
	OPERATOR 1 <-> (vector, vector) FOR ORDER BY float_ops,
	FUNCTION 1 vector_l2_squared_distance(vector, vector),
	FUNCTION 2 vector_norm(vector);

SELECT amvalidate(oid) FROM pg_opclass
 WHERE opcname = 'vamana_test_l2_with_norm_ops'
   AND opcmethod = (SELECT oid FROM pg_am WHERE amname = 'vamana');

DROP OPERATOR FAMILY vamana_test_l2_with_norm_ops USING vamana CASCADE;

-- Operator/metric mismatch: the ordering operator is <=> (cosine) but
-- support function 1 is the L2 distance. CREATE INDEX builds this as an L2
-- graph and serves ORDER BY <=> from it with no recheck, returning the
-- wrong nearest neighbours rather than erroring. Confirmed separately by
-- building an index on this shape and comparing its ORDER BY <=> result to
-- the true cosine order; the fix for that is this validator catching the
-- shape at amvalidate() time, not a change to the scan itself.
CREATE OPERATOR CLASS vamana_test_metric_mismatch_ops
	FOR TYPE vector USING vamana AS
	OPERATOR 1 <=> (vector, vector) FOR ORDER BY float_ops,
	FUNCTION 1 vector_l2_squared_distance(vector, vector);

SELECT amvalidate(oid) FROM pg_opclass
 WHERE opcname = 'vamana_test_metric_mismatch_ops'
   AND opcmethod = (SELECT oid FROM pg_am WHERE amname = 'vamana');

DROP OPERATOR FAMILY vamana_test_metric_mismatch_ops USING vamana CASCADE;
