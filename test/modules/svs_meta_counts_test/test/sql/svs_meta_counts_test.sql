CREATE EXTENSION svs_meta_counts_test;

-- Valid: all counters equal, as a fresh build produces.
SELECT svs_meta_counts_test_validate(1, 1024::bigint, 1024::bigint, 0::bigint, 1024::bigint) AS fresh_build_equal_counts;

-- Valid: capacity larger than the other counters, as growth produces.
SELECT svs_meta_counts_test_validate(1, 2048::bigint, 1024::bigint, 10::bigint, 1030::bigint) AS grown_capacity;

-- Valid: an untouched empty table (all zero).
SELECT svs_meta_counts_test_validate(1, 0::bigint, 0::bigint, 0::bigint, 0::bigint) AS empty_table;

-- Type ceiling: capacity one past the supported maximum.
SELECT svs_meta_counts_test_validate(1, 2147483648::bigint, 0::bigint, 0::bigint, 0::bigint) AS capacity_above_int_max;

-- Type ceiling: numVectors one past the supported maximum.
SELECT svs_meta_counts_test_validate(1, 0::bigint, 2147483648::bigint, 0::bigint, 0::bigint) AS num_vectors_above_int_max;

-- Type ceiling: numDeleted one past the supported maximum.
SELECT svs_meta_counts_test_validate(1, 0::bigint, 0::bigint, 2147483648::bigint, 0::bigint) AS num_deleted_above_int_max;

-- Type ceiling: exactly at the maximum is accepted (no other counter violates consistency).
SELECT svs_meta_counts_test_validate(1, 2147483647::bigint, 2147483647::bigint, 0::bigint, 2147483647::bigint) AS capacity_at_int_max;

-- Consistency: numVectors exceeds capacity.
SELECT svs_meta_counts_test_validate(1, 100::bigint, 101::bigint, 0::bigint, 100::bigint) AS num_vectors_exceeds_capacity;

-- Consistency: numDeleted exceeds capacity.
SELECT svs_meta_counts_test_validate(1, 100::bigint, 50::bigint, 101::bigint, 100::bigint) AS num_deleted_exceeds_capacity;

-- Consistency: nextExternalId exceeds capacity.
SELECT svs_meta_counts_test_validate(1, 100::bigint, 50::bigint, 0::bigint, 101::bigint) AS next_external_id_exceeds_capacity;

-- Consistency: nextExternalId is not checked against a zero capacity (no allocation follows it).
SELECT svs_meta_counts_test_validate(1, 0::bigint, 0::bigint, 0::bigint, 5::bigint) AS next_external_id_ignored_at_zero_capacity;
