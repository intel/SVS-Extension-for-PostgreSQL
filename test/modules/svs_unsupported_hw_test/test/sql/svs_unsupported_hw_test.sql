CREATE EXTENSION svs_unsupported_hw_test;

-- Message, detail, and hint are all client-visible under default verbosity.
SELECT svs_unsupported_hw_test_report('mock SVS message: AVX512 required', 'LeanVec');

-- The compression name is interpolated, not hardcoded.
SELECT svs_unsupported_hw_test_report('mock SVS message: AVX512 required', 'LVQ');

-- SQLSTATE is 0A000 (ERRCODE_FEATURE_NOT_SUPPORTED), not a generic internal error.
DO $$
BEGIN
	PERFORM svs_unsupported_hw_test_report('mock SVS message', 'LeanVec');
EXCEPTION WHEN OTHERS THEN
	RAISE NOTICE 'sqlstate=%', SQLSTATE;
END;
$$;
