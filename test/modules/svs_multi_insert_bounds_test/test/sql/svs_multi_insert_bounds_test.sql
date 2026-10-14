CREATE EXTENSION svs_multi_insert_bounds_test;

-- Valid: a typical in-range, consistent record.
SELECT svs_multi_insert_bounds_test_validate(10, false, 4 + 10 * 2) AS typical_valid;

-- Boundary: ntuples = 0 is invalid (nothing to insert).
SELECT svs_multi_insert_bounds_test_validate(0, false, 8) AS ntuples_zero;

-- Boundary: ntuples = 1 is the smallest valid count.
SELECT svs_multi_insert_bounds_test_validate(1, false, 4 + 1 * 2) AS ntuples_one;

-- Boundary: ntuples = MaxHeapTuplesPerPage (291 at 8KB BLCKSZ) is valid.
SELECT svs_multi_insert_bounds_test_validate(291, false, 4 + 291 * 2) AS ntuples_at_max;

-- Boundary: ntuples = MaxHeapTuplesPerPage + 1 is invalid.
SELECT svs_multi_insert_bounds_test_validate(292, false, 4 + 292 * 2) AS ntuples_above_max;

-- Boundary: ntuples = 65535 (uint16 max) is invalid, far above the page limit.
SELECT svs_multi_insert_bounds_test_validate(65535, false, 4 + 1 * 2) AS ntuples_uint16_max;

-- Data length: exactly sufficient for the claimed ntuples is valid.
SELECT svs_multi_insert_bounds_test_validate(5, false, 4 + 5 * 2) AS data_len_exact;

-- Data length: one OffsetNumber short of the claimed ntuples is invalid.
SELECT svs_multi_insert_bounds_test_validate(5, false, 4 + 5 * 2 - 1) AS data_len_one_short;

-- isinit = true skips the data-length check entirely: a short length that
-- would fail for isinit = false is accepted when the page is freshly
-- initialised, since there are no offsets in the record to read.
SELECT svs_multi_insert_bounds_test_validate(5, true, 0) AS isinit_skips_length_check;

-- isinit = true still enforces the ntuples bound.
SELECT svs_multi_insert_bounds_test_validate(292, true, 0) AS isinit_still_bounds_ntuples;
