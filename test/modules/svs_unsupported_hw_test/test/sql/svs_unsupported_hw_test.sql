CREATE EXTENSION svs_unsupported_hw_test;

-- Message and hint are client-visible under default verbosity; the raw SVS
-- message goes to errdetail_log (server log only, so it never shows up
-- here), matching this file's existing convention for third-party text.
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
