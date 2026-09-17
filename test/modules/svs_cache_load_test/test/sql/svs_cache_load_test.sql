CREATE EXTENSION IF NOT EXISTS injection_points;
CREATE EXTENSION svs_cache_load_test;

SELECT injection_points_attach('vamana-cache-index-load-failure', 'error');

BEGIN;
SAVEPOINT before_failed_load;
SELECT svs_cache_load_test_fake_load(680, (4 * 1024)::bigint);
ROLLBACK TO SAVEPOINT before_failed_load;
COMMIT;

SELECT injection_points_detach('vamana-cache-index-load-failure');

SELECT svs_cache_load_test_fake_load(680, (5 * 1024)::bigint);

SELECT svs_cache_load_test_committed_bytes(680) = (5 * 1024) AS retry_reservation_survives_stale_teardown;
SELECT svs_cache_load_test_reservation_exists(680) AS retry_reservation_still_tracked;
