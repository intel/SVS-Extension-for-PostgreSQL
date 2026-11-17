CREATE EXTENSION svs_compression_config_test;

-- none: every primary/secondary combination is ignored and accepted.
SELECT svs_compression_config_test_is_valid(0, 0, 0) AS none_zeros;
SELECT svs_compression_config_test_is_valid(0, 99, -99) AS none_garbage_values;

-- leanvec: valid pairs, primary bits <= secondary bits, both encodings
-- valid (4, -4, 8, -8).
SELECT svs_compression_config_test_is_valid(1, 4, 4) AS leanvec_4_4;
SELECT svs_compression_config_test_is_valid(1, 4, 8) AS leanvec_4_8;
SELECT svs_compression_config_test_is_valid(1, -4, 8) AS leanvec_neg4_8;
SELECT svs_compression_config_test_is_valid(1, 4, -8) AS leanvec_4_neg8;
SELECT svs_compression_config_test_is_valid(1, 8, 8) AS leanvec_8_8;
SELECT svs_compression_config_test_is_valid(1, -8, -8) AS leanvec_neg8_neg8;

-- leanvec: invalid, primary bits higher precision than secondary bits.
SELECT svs_compression_config_test_is_valid(1, 8, 4) AS leanvec_order_violation;

-- leanvec: invalid, primary is not one of the valid encodings.
SELECT svs_compression_config_test_is_valid(1, 5, 8) AS leanvec_bad_primary_value;

-- leanvec: invalid, secondary = 0 is LVQ's no-residual value, not a valid
-- leanvec encoding; leanvec has no such mode.
SELECT svs_compression_config_test_is_valid(1, 4, 0) AS leanvec_secondary_zero;

-- lvq: valid (primary bits, residual bits) pairs: (4,0), (8,0), (4,4), (4,8).
SELECT svs_compression_config_test_is_valid(2, 4, 0) AS lvq_4_0;
SELECT svs_compression_config_test_is_valid(2, 8, 0) AS lvq_8_0;
SELECT svs_compression_config_test_is_valid(2, 4, 4) AS lvq_4_4;
SELECT svs_compression_config_test_is_valid(2, 4, 8) AS lvq_4_8;
SELECT svs_compression_config_test_is_valid(2, -4, 0) AS lvq_neg4_0;
SELECT svs_compression_config_test_is_valid(2, -4, -8) AS lvq_neg4_neg8;

-- lvq: invalid, pair not in the supported set.
SELECT svs_compression_config_test_is_valid(2, 8, 8) AS lvq_bad_pair_8_8;
SELECT svs_compression_config_test_is_valid(2, 8, 4) AS lvq_bad_pair_8_4;

-- lvq: invalid, primary is not one of the valid encodings. Unlike secondary,
-- primary never gets the no-residual exception; 0 is not a valid primary.
SELECT svs_compression_config_test_is_valid(2, 5, 0) AS lvq_bad_primary_value;
SELECT svs_compression_config_test_is_valid(2, 0, 0) AS lvq_primary_zero;

-- lvq: invalid, secondary is neither no-residual nor a valid encoding.
SELECT svs_compression_config_test_is_valid(2, 4, 5) AS lvq_bad_secondary_value;

-- Unrecognized compression_type: rejected regardless of primary/secondary.
SELECT svs_compression_config_test_is_valid(3, 4, 8) AS unknown_compression_type;
