CREATE EXTENSION svs_parallel_build_test;

-- Normal case: launched workers attach, are independently visible in
-- pg_stat_activity, and are cleanly stopped -- all verified inside the
-- function itself, so a successful call proves the round trip.
SELECT n BETWEEN 1 AND 2 AS launched_ok
FROM (SELECT svs_parallel_build_test_run(2) AS n) s;

-- Edge case: zero workers requested launches nothing.
SELECT svs_parallel_build_test_run(0) AS launched;

-- Edge case: requesting far more workers than the cluster can supply still
-- launches cleanly, capped by max_parallel_workers.
SELECT n <= current_setting('max_parallel_workers')::int AS clamped
FROM (SELECT svs_parallel_build_test_run(1000) AS n) s;

DROP EXTENSION svs_parallel_build_test;
