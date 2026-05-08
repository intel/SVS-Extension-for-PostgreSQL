# Common Development Tasks for pgvector-optimizations

## Adding a new vector type

1. Create `src/newtype.c` with I/O functions (in/out/recv/send/typmod_in)
2. Add typedef in `src/newtype.h` with size macro (e.g., `NEWTYPE_SIZE(dim)`)
3. Define SQL type in `sql/vector.sql` with functions using `FUNCTION_PREFIX PG_FUNCTION_INFO_V1`
4. Add distance operators and operator classes for each index type
5. Update `OBJS` in `Makefile`

## Adding index support for a new distance metric

1. Implement distance function in relevant `src/*vec.c` file
2. Create SQL operator with proper binding (`LEFTARG`, `RIGHTARG`, `PROCEDURE`)
3. Add to operator class in `sql/vector.sql` (strategy number for AM)
4. Register in support function table (e.g., `HNSW_DISTANCE_PROC`)

## Adding a new index access method (like Vamana)

1. Create core files: `src/newindex.c`, `src/newindex.h`, `src/newindexbuild.c`, `src/newindexscan.c`, `src/newindexinsert.c`, `src/newindexvacuum.c`, `src/newindexutils.c`
2. Define handler function with `IndexAmRoutine` callbacks (build, insert, scan, vacuum, etc.)
3. Add opaque page data structures and tuple types (element, neighbor, etc.)
4. Implement support functions (`*_DISTANCE_PROC`, `*_NORM_PROC`, `*_TYPE_INFO_PROC`)
5. Define operator classes for each vector type and distance metric in `sql/vector.sql`
6. Add migration script: `sql/vector--X.Y--X.Z.sql`
7. Create tests: `test/sql/newindex_*.sql` and `test/t/*_newindex_*.pl`
8. Update `OBJS` in `Makefile` and update `vector.control` `default_version`

## Debugging index builds

- Use `SET client_min_messages = DEBUG1` to see build phase progress
- Check `pg_stat_progress_create_index` view during builds
- Enable `-DIVFFLAT_BENCH` for timing instrumentation (see `src/ivfflat.h`)
- For parallel builds: check shared memory usage and worker spawning with `log_min_messages = DEBUG1`

## Testing WAL replication

- Perl TAP tests in `test/t/*_wal.pl` create primary/replica clusters
- Use `PostgreSQL::Test::Cluster` API: `init`, `backup`, `init_from_backup`, `start`, `safe_psql`
- Wait for replication with `poll_query_until` checking `pg_stat_replication`
- Verify index operations replicate correctly by comparing query results on primary and replica
