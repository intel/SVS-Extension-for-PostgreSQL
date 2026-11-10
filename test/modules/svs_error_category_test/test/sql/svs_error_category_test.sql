CREATE EXTENSION svs_error_category_test;

-- ERRCODE_FEATURE_NOT_SUPPORTED categorizes to VAMANA_ERR_UNSUPPORTED and
-- back again, instead of falling through to the generic internal-error
-- bucket.
SELECT svs_error_category_test_unsupported_hw_round_trips() AS unsupported_hw_round_trips;

-- The three pre-existing categories (and the generic fallback) are
-- unaffected by adding the new one.
SELECT svs_error_category_test_existing_categories_unchanged() AS existing_categories_unchanged;
