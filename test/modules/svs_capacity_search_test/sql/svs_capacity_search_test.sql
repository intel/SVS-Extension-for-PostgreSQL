-- Copyright (C) 2026 Intel Corporation
-- SPDX-License-Identifier: PostgreSQL

CREATE EXTENSION svs_capacity_search_test;

-- Mid-block: 5 rows against a 10-row block still has 5 free rows before
-- the block at 11 would need to grow.
SELECT svs_capacity_search_test_headroom(5, 10, 1000);

-- Exactly at a block boundary: the very next row already needs growth.
SELECT svs_capacity_search_test_headroom(10, 10, 1000);

-- Empty index: the first insert allocates the first block, so there is
-- no free room yet.
SELECT svs_capacity_search_test_headroom(0, 10, 1000);

-- One row below the boundary.
SELECT svs_capacity_search_test_headroom(9, 10, 1000);

-- Every row grows the block (blockSizeVectors = 1): no free room ever.
SELECT svs_capacity_search_test_headroom(1000000, 1, 1000);

-- The real boundary is far beyond the search range: the search reports
-- "at least this much" rather than searching past its bound.
SELECT svs_capacity_search_test_headroom(5, 10000, 100);
