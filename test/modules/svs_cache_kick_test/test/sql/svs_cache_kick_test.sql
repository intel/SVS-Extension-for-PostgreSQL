CREATE EXTENSION svs_cache_kick_test;

-- Case 1: loading several entries, then evicting one of several, must not
-- kick: the count drops by exactly one and stays above zero.
SELECT svs_cache_reset_kick_tracking();
SELECT svs_cache_fake_load(101::oid);
SELECT svs_cache_fake_load(102::oid);
SELECT svs_cache_fake_load(103::oid);
SELECT svs_cache_count() AS count_after_load; -- 3

SELECT svs_cache_evict(102::oid);
SELECT svs_cache_count() AS count_after_partial_evict; -- 2
SELECT svs_cache_kicked() AS kicked_after_partial_evict; -- f

-- Case 2: evicting the remaining entries one at a time, the kick fires only
-- once the count reaches zero, not before.
SELECT svs_cache_evict(101::oid);
SELECT svs_cache_count() AS count_after_second_evict; -- 1
SELECT svs_cache_kicked() AS kicked_after_second_evict; -- f

SELECT svs_cache_evict(103::oid);
SELECT svs_cache_count() AS count_after_last_evict; -- 0
SELECT svs_cache_kicked() AS kicked_after_last_evict; -- t
SELECT svs_cache_kick_count() AS kick_count_after_last_evict; -- 1

-- Case 3: VamanaEvictAllCacheEntries clears several entries but kicks
-- exactly once (the call site is after its internal loop, not inside it).
SELECT svs_cache_reset_kick_tracking();
SELECT svs_cache_fake_load(201::oid);
SELECT svs_cache_fake_load(202::oid);
SELECT svs_cache_fake_load(203::oid);
SELECT svs_cache_count() AS count_before_evict_all; -- 3

SELECT svs_cache_evict_all();
SELECT svs_cache_count() AS count_after_evict_all; -- 0
SELECT svs_cache_kicked() AS kicked_after_evict_all; -- t
SELECT svs_cache_kick_count() AS kick_count_after_evict_all; -- 1

-- Case 4: VamanaInvalidateCache's call site behaves the same way: no kick
-- while other entries remain, exactly one kick once the last one goes.
SELECT svs_cache_reset_kick_tracking();
SELECT svs_cache_fake_load(301::oid);
SELECT svs_cache_fake_load(302::oid);
SELECT svs_cache_count() AS count_before_invalidate; -- 2

SELECT svs_cache_invalidate(301::oid);
SELECT svs_cache_count() AS count_after_first_invalidate; -- 1
SELECT svs_cache_kicked() AS kicked_after_first_invalidate; -- f

SELECT svs_cache_invalidate(302::oid);
SELECT svs_cache_count() AS count_after_second_invalidate; -- 0
SELECT svs_cache_kicked() AS kicked_after_second_invalidate; -- t
SELECT svs_cache_kick_count() AS kick_count_after_second_invalidate; -- 1
