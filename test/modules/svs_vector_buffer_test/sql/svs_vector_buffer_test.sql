-- Copyright (C) 2026 Intel Corporation
-- SPDX-License-Identifier: PostgreSQL

CREATE EXTENSION svs_vector_buffer_test;

-- Appending fewer vectors than the initial estimate: no regrowth, and the
-- output matches the input exactly, in order.
SELECT flat_output, final_count, final_capacity
  FROM svs_vector_buffer_test_run(5, 2, ARRAY[1,2, 3,4, 5,6, 7,8]::float8[]);

-- Appending exactly the initial estimate: capacity must not grow past it.
SELECT final_count = 4 AND final_capacity = 4 AS no_premature_growth
  FROM svs_vector_buffer_test_run(4, 2, ARRAY[1,2, 3,4, 5,6, 7,8]::float8[]);

-- Appending one more than the initial estimate: capacity must grow, and
-- every vector, including the ones written before the growth, must survive
-- intact.
SELECT flat_output, final_count, final_capacity > 2 AS capacity_grew
  FROM svs_vector_buffer_test_run(2, 2, ARRAY[1,2, 3,4, 5,6]::float8[]);

-- A non-positive estimate (never analyzed) falls back to the default seed,
-- not to zero or a garbage capacity.
SELECT final_capacity = 1000 AS falls_back_to_default_capacity
  FROM svs_vector_buffer_test_run(0, 3, ARRAY[1,2,3, 4,5,6, 7,8,9]::float8[]);
SELECT final_capacity = 1000 AS falls_back_to_default_capacity_on_negative
  FROM svs_vector_buffer_test_run(-1, 3, ARRAY[1,2,3, 4,5,6, 7,8,9]::float8[]);
