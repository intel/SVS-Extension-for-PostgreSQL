#!/bin/bash
# run-valgrind-vamana.sh
#
# PURPOSE:
#   Runs Valgrind (memcheck) against PostgreSQL while exercising all Vamana index
#   code paths: build, scan, insert, NULL handling, empty tables, LeanVec compression,
#   buffer growth, and REINDEX.
#
# PREREQUISITES:
#   1. valgrind must be installed (apt install valgrind)
#   2. pgvector-optimizations must be built with debug flags:
#        make clean && make OPTFLAGS="-g -O0 -fno-omit-frame-pointer"
#        make install
#   3. PostgreSQL must be built with --enable-debug (--with-valgrind is strongly
#      recommended to suppress false positives in palloc/pfree paths):
#        ./configure --enable-debug --enable-cassert --with-valgrind \
#          CFLAGS="-g -O0 -fno-omit-frame-pointer"
#   4. env.sh must be sourced (or paths set below)
#
# USAGE:
#   cd /path/to/pgvector-optimizations
#   source docs/env.sh
#   ./docs/run-valgrind-vamana.sh [--keep-data] [--no-rebuild] [--full-leak-check]
#
#   --keep-data        Keep the temporary cluster data directory after the run
#   --no-rebuild       Skip the make clean/make step (assume already built with debug flags)
#   --full-leak-check  Show all leak kinds (including 'possible') in valgrind output.
#                      Use this when investigating 'possibly lost' blocks; the extra
#                      output identifies whether they originate in SVS internals or
#                      in pgvector Vamana code.
#
# OUTPUT:
#   /tmp/valgrind-vamana/
#     valgrind_<pid>.log   Per-process valgrind output
#     pg.log               PostgreSQL server log
#     summary.txt          Filtered summary of errors and leaks
#
# EXIT CODE:
#   0  No definite errors or invalid reads/writes found
#   1  Valgrind reported definite memory errors
#   2  Test SQL failed or PostgreSQL did not start

set -euo pipefail

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
KEEP_DATA=false
NO_REBUILD=false
FULL_LEAK_CHECK=false

for arg in "$@"; do
    case "$arg" in
        --keep-data)        KEEP_DATA=true ;;
        --no-rebuild)       NO_REBUILD=true ;;
        --full-leak-check)  FULL_LEAK_CHECK=true ;;
        *)
            echo "Unknown argument: $arg"
            echo "Usage: $0 [--keep-data] [--no-rebuild] [--full-leak-check]"
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Environment — prefer values already exported (e.g. from env.sh)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_DIR="${WORKSPACE_DIR:-$(cd "$REPO_ROOT/.." && pwd)}"

PG_CONFIG="${PG_CONFIG:-$WORKSPACE_DIR/postgres/build/bin/pg_config}"
SVS_BUILD="${SVS_BUILD:-$WORKSPACE_DIR/libraries.ai.vector-search.svs/build}"
MKLROOT="${MKLROOT:-/opt/intel/oneapi/mkl/latest}"

PG_BIN_DIR="$($PG_CONFIG --bindir)"
POSTGRES_BIN="$PG_BIN_DIR/postgres"
PSQL="$PG_BIN_DIR/psql"
PG_CTL="$PG_BIN_DIR/pg_ctl"
INITDB="$PG_BIN_DIR/initdb"

PG_VALGRIND_SUPP="$WORKSPACE_DIR/postgres/src/tools/valgrind.supp"

# Working directories for this run
VALGRIND_DIR="/tmp/valgrind-vamana"
PG_DATA_DIR="$VALGRIND_DIR/data"
PG_LOG_FILE="$VALGRIND_DIR/pg.log"
VALGRIND_LOG_PATTERN="$VALGRIND_DIR/valgrind_%p.log"
SUMMARY_FILE="$VALGRIND_DIR/summary.txt"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
echo "==================================================================="
echo " Valgrind / Vamana pre-flight checks"
echo "==================================================================="

if ! command -v valgrind &>/dev/null; then
    echo "ERROR: valgrind not found. Install with: sudo apt install valgrind"
    exit 2
fi

if [ ! -x "$POSTGRES_BIN" ]; then
    echo "ERROR: postgres binary not found at: $POSTGRES_BIN"
    echo "  Update PG_CONFIG or source docs/env.sh"
    exit 2
fi

if [ ! -x "$PSQL" ]; then
    echo "ERROR: psql not found at: $PSQL"
    exit 2
fi

if [ ! -f "$PG_VALGRIND_SUPP" ]; then
    echo "WARNING: PostgreSQL valgrind suppression file not found at:"
    echo "  $PG_VALGRIND_SUPP"
    echo "  False positives from palloc/pfree may appear in output."
    echo "  Build PostgreSQL with --with-valgrind to generate this file."
    PG_VALGRIND_SUPP=""
fi

echo "  postgres     : $POSTGRES_BIN"
echo "  psql         : $PSQL"
echo "  SVS build    : $SVS_BUILD"
echo "  output dir   : $VALGRIND_DIR"
echo "  suppression  : ${PG_VALGRIND_SUPP:-<none>}"
echo

# ---------------------------------------------------------------------------
# Build with debug flags (unless --no-rebuild)
# ---------------------------------------------------------------------------
if [ "$NO_REBUILD" = false ]; then
    echo "==================================================================="
    echo " Building pgvector with debug flags (OPTFLAGS=-g -O0)"
    echo "==================================================================="
    echo "  Run with --no-rebuild to skip this step if already built."
    echo

    cd "$REPO_ROOT"

    export LD_LIBRARY_PATH="$SVS_BUILD/bindings/c:${MKLROOT}/lib/intel64:${LD_LIBRARY_PATH:-}"

    make clean
    make OPTFLAGS="-g -O0 -fno-omit-frame-pointer"
    make install

    echo
    echo "✓ Build complete"
fi

# ---------------------------------------------------------------------------
# Set up a fresh temporary cluster
# ---------------------------------------------------------------------------
echo "==================================================================="
echo " Setting up temporary PostgreSQL cluster"
echo "==================================================================="

rm -rf "$VALGRIND_DIR"
mkdir -p "$VALGRIND_DIR"

# Run initdb and filter its output, but ensure we still honor initdb's exit status.
set +e
"$INITDB" -D "$PG_DATA_DIR" --no-instructions 2>&1 \
    | grep -v "^$" \
    | grep -v "^The files belonging" \
    | grep -v "^This user must" \
    | grep -v "^Success\."
status_initdb=${PIPESTATUS[0]}
set -e

if [ "$status_initdb" -ne 0 ]; then
    echo "Error: initdb failed with status $status_initdb" >&2
    exit 2
fi
# Tune postgresql.conf for valgrind: single backend, no autovacuum workers,
# no parallel workers (parallelism spawns new processes that are not under
# valgrind), generous memory for index builds.
cat >> "$PG_DATA_DIR/postgresql.conf" <<'EOF'

# --- valgrind tuning ---
autovacuum = off
max_parallel_workers = 0
max_parallel_workers_per_gather = 0
max_parallel_maintenance_workers = 2
maintenance_work_mem = 512MB
work_mem = 256MB
shared_buffers = 128MB
log_min_messages = warning
EOF

echo "✓ Cluster initialized: $PG_DATA_DIR"

# ---------------------------------------------------------------------------
# Build the valgrind suppression file list
# ---------------------------------------------------------------------------
SUPP_ARGS=()
if [ -n "$PG_VALGRIND_SUPP" ]; then
    SUPP_ARGS+=("--suppressions=$PG_VALGRIND_SUPP")
fi

# SVS/Intel TBB/OpenMP suppressions — suppress indirect leaks from the
# Intel runtime that are outside our control.
SVS_SUPP_FILE="$VALGRIND_DIR/svs.supp"
cat > "$SVS_SUPP_FILE" <<'EOF'
# ---------------------------------------------------------------------------
# PostgreSQL process-startup false positives
# ---------------------------------------------------------------------------
# save_ps_display_args() in ps_status.c permanently allocates storage for the
# original argv[] so that the process title can later be changed for "ps"
# output.  This is intentional — the memory lives for the process lifetime.
# Without this suppression, --error-exitcode=1 causes every forked postgres
# child (startup process, checkpointer, etc.) to exit with code 1.
#
# Two variants exist depending on postgres build configuration:
#   - Release/non-valgrind builds: malloc → strdup → save_ps_display_args → main
#     (indirect leak: strdup allocates child blocks)
#   - Debug/--with-valgrind builds: malloc → save_ps_display_args → main
#     (definite leak: direct malloc call in ps_status.c:192)
{
   pg_ps_display_args_strdup
   Memcheck:Leak
   match-leak-kinds: indirect
   fun:malloc
   fun:strdup
   fun:save_ps_display_args
   fun:main
}
{
   pg_ps_display_args_direct
   Memcheck:Leak
   match-leak-kinds: definite,indirect
   fun:malloc
   fun:save_ps_display_args
   fun:main
}

# ---------------------------------------------------------------------------
# Intel TBB thread-local storage — allocated once, never freed (by design)
# ---------------------------------------------------------------------------
{
   tbb_tls_alloc
   Memcheck:Leak
   match-leak-kinds: reachable
   ...
   obj:*libtbb*
}
{
   tbb_tls_alloc2
   Memcheck:Leak
   match-leak-kinds: reachable
   ...
   obj:*libtbbmalloc*
}
# ---------------------------------------------------------------------------
# OpenMP runtime — persistent thread pool
# ---------------------------------------------------------------------------
{
   openmp_thread_pool
   Memcheck:Leak
   match-leak-kinds: reachable,possible
   ...
   obj:*libiomp5*
}
{
   openmp_gomp
   Memcheck:Leak
   match-leak-kinds: reachable,possible
   ...
   obj:*libgomp*
}
# ---------------------------------------------------------------------------
# Intel MKL — allocates BLAS buffers on first call, holds them for lifetime
# ---------------------------------------------------------------------------
{
   mkl_blas_buffer
   Memcheck:Leak
   match-leak-kinds: reachable
   ...
   obj:*libmkl*
}
# ---------------------------------------------------------------------------
# SVS large mmap — SVS reserves a large contiguous arena (~768 MB) at startup
# for SIMD and graph data.  Valgrind 3.18 records this as a Memcheck:Param
# error on the mmap system call argument.  It is not an invalid read or write.
# ---------------------------------------------------------------------------
{
   svs_large_mmap
   Memcheck:Param
   mmap(addr)
   ...
   obj:*libsvs_c*
}
EOF

SUPP_ARGS+=("--suppressions=$SVS_SUPP_FILE")

# ---------------------------------------------------------------------------
# Start PostgreSQL under valgrind
# ---------------------------------------------------------------------------
echo "==================================================================="
echo " Starting PostgreSQL under valgrind"
echo "==================================================================="

# LD_LIBRARY_PATH must include SVS and MKL so the extension loads
export LD_LIBRARY_PATH="$SVS_BUILD/bindings/c:${MKLROOT}/lib/intel64:${LD_LIBRARY_PATH:-}"

# Under --full-leak-check, report all leak kinds (including 'possible') so that
# stack traces for SVS-internal possibly-lost blocks can be inspected and either
# suppressed or filed as genuine leaks.
if [ "$FULL_LEAK_CHECK" = true ]; then
    LEAK_KINDS="all"
else
    LEAK_KINDS="definite,indirect"
fi

VALGRIND_CMD=(
    valgrind
    --tool=memcheck
    --leak-check=full
    --show-leak-kinds="$LEAK_KINDS"
    --track-origins=yes
    --error-exitcode=1
    --num-callers=30
    --log-file="$VALGRIND_LOG_PATTERN"
    "${SUPP_ARGS[@]}"
    "$POSTGRES_BIN"
    -D "$PG_DATA_DIR"
    -k "$VALGRIND_DIR"        # unix socket in our private directory
    -c listen_addresses=''    # disable TCP; use unix socket only
    -c log_destination=stderr
    -c logging_collector=off
)

"${VALGRIND_CMD[@]}" >> "$PG_LOG_FILE" 2>&1 &
PG_VALGRIND_PID=$!

echo "  postgres (under valgrind) PID: $PG_VALGRIND_PID"
echo "  server log: $PG_LOG_FILE"

# Wait for the socket to appear AND for postgres to accept connections (up to 120s — valgrind startup is slow)
SOCKET="$VALGRIND_DIR/.s.PGSQL.5432"
echo -n "  Waiting for socket $SOCKET ..."
READY=false
for i in $(seq 1 120); do
    if ! kill -0 "$PG_VALGRIND_PID" 2>/dev/null; then
        echo
        echo "ERROR: postgres under valgrind exited unexpectedly."
        echo "Check $PG_LOG_FILE for details."
        tail -30 "$PG_LOG_FILE"
        exit 2
    fi
    if [ -S "$SOCKET" ]; then
        # Socket exists — check if it's accepting connections yet
        if "$PSQL" -h "$VALGRIND_DIR" -p 5432 -d postgres -c "SELECT 1" >/dev/null 2>&1; then
            echo " ready (${i}s)"
            READY=true
            break
        fi
    fi
    sleep 1
done

if [ "$READY" = false ]; then
    echo
    echo "ERROR: Timed out waiting for PostgreSQL to accept connections."
    kill "$PG_VALGRIND_PID" 2>/dev/null || true
    exit 2
fi

PSQL_CONN=(-h "$VALGRIND_DIR" -p 5432 -d postgres)

# ---------------------------------------------------------------------------
# Create extension
# ---------------------------------------------------------------------------
echo
echo "==================================================================="
echo " Installing vector extension"
echo "==================================================================="
"$PSQL" "${PSQL_CONN[@]}" -c "CREATE EXTENSION IF NOT EXISTS vector;" 2>&1 | tee -a "$PG_LOG_FILE"
echo "✓ Extension installed"

# ---------------------------------------------------------------------------
# SQL test script — exercises all code paths in vamanabuild.c / vamanascan.c
# ---------------------------------------------------------------------------
VAMANA_TEST_SQL="$VALGRIND_DIR/vamana_valgrind_test.sql"

cat > "$VAMANA_TEST_SQL" <<'SQLEOF'
\set ON_ERROR_STOP on

-- ============================================================
-- Valgrind Vamana Test Suite
-- Exercises all major code paths in vamanabuild.c, vamanascan.c
-- ============================================================

-- -------------------------------------------------------
-- 1. L2 distance: basic build + scan (vector type)
--    Covers: BuildCallback, InitBuildState, GetDistanceMetricFromIndex (L2),
--            SVSCreateSimpleStorage, SVSBuildDynamicIndex, vamanagettuple
-- -------------------------------------------------------
\echo '--- Test 1: L2 build and scan (vector) ---'
CREATE TABLE vg_l2 (id int, v vector(3));
INSERT INTO vg_l2 SELECT i,
    ARRAY[
        ((i * 1731) % 100)::real / 100,
        ((i * 3331) % 100)::real / 100,
        ((i * 7919) % 100)::real / 100
    ]::vector
FROM generate_series(1, 1024) i;
CREATE INDEX ON vg_l2 USING vamana (v vector_l2_ops);
SELECT id FROM vg_l2 ORDER BY v <-> '[0.5,0.5,0.5]' LIMIT 10;
DROP TABLE vg_l2;

-- -------------------------------------------------------
-- 2. Cosine distance (vector type)
--    Covers: GetDistanceMetricFromIndex cosine branch (OidIsValid normFuncOid)
-- -------------------------------------------------------
\echo '--- Test 2: Cosine build and scan (vector) ---'
CREATE TABLE vg_cos (id int, v vector(4));
INSERT INTO vg_cos SELECT i,
    ARRAY[
        ((i * 1731) % 100)::real / 100 + 0.01,
        ((i * 3331) % 100)::real / 100 + 0.01,
        ((i * 7919) % 100)::real / 100 + 0.01,
        ((i * 5381) % 100)::real / 100 + 0.01
    ]::vector
FROM generate_series(1, 512) i;
CREATE INDEX ON vg_cos USING vamana (v vector_cosine_ops);
SELECT id FROM vg_cos ORDER BY v <=> '[0.1,0.9,0.2,0.8]' LIMIT 10;
DROP TABLE vg_cos;

-- -------------------------------------------------------
-- 3. Inner product distance (vector type)
--    Covers: GetDistanceMetricFromIndex IP branch (normFuncOid invalid)
-- -------------------------------------------------------
\echo '--- Test 3: Inner product build and scan (vector) ---'
CREATE TABLE vg_ip (id int, v vector(4));
INSERT INTO vg_ip SELECT i,
    ARRAY[
        ((i * 1731) % 100)::real / 100 + 0.01,
        ((i * 3331) % 100)::real / 100 + 0.01,
        ((i * 7919) % 100)::real / 100 + 0.01,
        ((i * 5381) % 100)::real / 100 + 0.01
    ]::vector
FROM generate_series(1, 512) i;
CREATE INDEX ON vg_ip USING vamana (v vector_ip_ops);
SELECT id FROM vg_ip ORDER BY v <#> '[0.1,0.9,0.2,0.8]' LIMIT 10;
DROP TABLE vg_ip;

-- -------------------------------------------------------
-- 4. Empty table
--    Covers: numVectors == 0 branch, VamanaInvalidateCache, goto cleanup
-- -------------------------------------------------------
\echo '--- Test 4: Empty table (numVectors==0 path) ---'
CREATE TABLE vg_empty (id int, v vector(3));
CREATE INDEX ON vg_empty USING vamana (v vector_l2_ops);
SELECT COUNT(*) FROM vg_empty;
DROP TABLE vg_empty;

-- -------------------------------------------------------
-- 5. NULL vectors
--    Covers: isnull[0] skip in BuildCallback
-- -------------------------------------------------------
\echo '--- Test 5: NULL vectors in BuildCallback ---'
CREATE TABLE vg_nulls (id int, v vector(3));
INSERT INTO vg_nulls VALUES (1, '[1,2,3]'), (2, NULL), (3, '[4,5,6]'), (4, NULL), (5, '[7,8,9]');
CREATE INDEX ON vg_nulls USING vamana (v vector_l2_ops);
SELECT id FROM vg_nulls ORDER BY v <-> '[5,5,5]' LIMIT 3;
DROP TABLE vg_nulls;

-- -------------------------------------------------------
-- 6. Buffer growth (> initial bufferCapacity of 1000)
--    Covers: repalloc branch in BuildCallback (bufferCapacity doubling)
-- -------------------------------------------------------
\echo '--- Test 6: Buffer growth beyond initial capacity (>1000 vectors) ---'
CREATE TABLE vg_large (id int, v vector(3));
INSERT INTO vg_large SELECT i,
    ARRAY[
        ((i * 1731) % 1000)::real / 1000,
        ((i * 3331) % 1000)::real / 1000,
        ((i * 7919) % 1000)::real / 1000
    ]::vector
FROM generate_series(1, 2000) i;
CREATE INDEX ON vg_large USING vamana (v vector_l2_ops);
SELECT COUNT(*) FROM (SELECT id FROM vg_large ORDER BY v <-> '[0.5,0.5,0.5]' LIMIT 20) t;
DROP TABLE vg_large;

-- -------------------------------------------------------
-- 7. REINDEX — rebuild of existing index
--    Covers: full build path again including VamanaInvalidateCache on second build
-- -------------------------------------------------------
\echo '--- Test 7: REINDEX (rebuild path) ---'
CREATE TABLE vg_reindex (id int, v vector(3));
INSERT INTO vg_reindex SELECT i,
    ARRAY[
        ((i * 1731) % 100)::real / 100,
        ((i * 3331) % 100)::real / 100,
        ((i * 7919) % 100)::real / 100
    ]::vector
FROM generate_series(1, 300) i;
CREATE INDEX vg_reindex_idx ON vg_reindex USING vamana (v vector_l2_ops);
SELECT id FROM vg_reindex ORDER BY v <-> '[0.5,0.5,0.5]' LIMIT 5;
REINDEX INDEX vg_reindex_idx;
SELECT id FROM vg_reindex ORDER BY v <-> '[0.5,0.5,0.5]' LIMIT 5;
DROP TABLE vg_reindex;

-- -------------------------------------------------------
-- 8. halfvec type with L2
--    Covers: halfvec_l2_squared_distance branch in GetDistanceMetricFromIndex
-- -------------------------------------------------------
\echo '--- Test 8: halfvec L2 ---'
CREATE TABLE vg_hv (id int, v halfvec(4));
INSERT INTO vg_hv SELECT i,
    ARRAY[
        ((i * 1731) % 100)::real / 100,
        ((i * 3331) % 100)::real / 100,
        ((i * 7919) % 100)::real / 100,
        ((i * 5381) % 100)::real / 100
    ]::halfvec
FROM generate_series(1, 300) i;
CREATE INDEX ON vg_hv USING vamana (v halfvec_l2_ops);
SELECT id FROM vg_hv ORDER BY v <-> '[0.5,0.5,0.5,0.5]'::halfvec LIMIT 5;
DROP TABLE vg_hv;

-- -------------------------------------------------------
-- 9. Higher-dimension vectors (stress mem allocation paths)
--    Covers: MemoryContextAllocHuge for flatData, per-vector palloc/pfree loop
-- -------------------------------------------------------
\echo '--- Test 9: Higher dimensions (128-d) ---'
CREATE TABLE vg_hd (id int, v vector(128));
INSERT INTO vg_hd
    SELECT i,
        (SELECT array_agg(((j * i * 1731) % 1000)::real / 1000 + 0.001)::vector
         FROM generate_series(1, 128) j)
    FROM generate_series(1, 200) i;
CREATE INDEX ON vg_hd USING vamana (v vector_l2_ops)
    WITH (graph_degree = 16, build_window_size = 32);
SELECT id FROM vg_hd
ORDER BY v <-> (SELECT array_agg(0.5::real)::vector FROM generate_series(1, 128))
LIMIT 5;
DROP TABLE vg_hd;

-- -------------------------------------------------------
-- 10. LeanVec compression
--     Covers: SVSCreateLeanVecStorage, compression_type==VAMANA_COMPRESSION_LEANVEC,
--             ValidateCompressionParam, primary/secondary precision check
-- -------------------------------------------------------
\echo '--- Test 10: LeanVec compression ---'
CREATE TABLE vg_lv (id int, v vector(32));
INSERT INTO vg_lv
    SELECT i,
        (SELECT array_agg(((j * i * 1731) % 1000)::real / 1000 + 0.001)::vector
         FROM generate_series(1, 32) j)
    FROM generate_series(1, 400) i;
CREATE INDEX ON vg_lv USING vamana (v vector_l2_ops)
    WITH (compression_type = 1, leanvec_dims = 16,
          compression_primary = 8, compression_secondary = 8);
SELECT id FROM vg_lv
ORDER BY v <-> (SELECT array_agg(0.5::real)::vector FROM generate_series(1, 32))
LIMIT 5;
DROP TABLE vg_lv;

-- -------------------------------------------------------
-- 11. Unlogged table — exercises vamanabuildempty path
-- -------------------------------------------------------
\echo '--- Test 11: Unlogged table (vamanabuildempty) ---'
CREATE UNLOGGED TABLE vg_unlogged (id int, v vector(3));
INSERT INTO vg_unlogged VALUES (1, '[1,2,3]'), (2, '[4,5,6]');
CREATE INDEX ON vg_unlogged USING vamana (v vector_l2_ops);
SELECT id FROM vg_unlogged ORDER BY v <-> '[3,3,3]' LIMIT 2;
DROP TABLE vg_unlogged;

-- -------------------------------------------------------
-- 12. Custom index parameters (non-default alpha, windows)
--     Covers: InitBuildState option parsing from rd_options
-- -------------------------------------------------------
\echo '--- Test 12: Custom index options (alpha, windows) ---'
CREATE TABLE vg_opts (id int, v vector(8));
INSERT INTO vg_opts
    SELECT i,
        (SELECT array_agg(((j * i * 1731) % 1000)::real / 1000 + 0.001)::vector
         FROM generate_series(1, 8) j)
    FROM generate_series(1, 300) i;
CREATE INDEX ON vg_opts USING vamana (v vector_l2_ops)
    WITH (graph_degree = 24, alpha = 135, build_window_size = 48, search_window_size = 20);
SELECT id FROM vg_opts
ORDER BY v <-> (SELECT array_agg(0.5::real)::vector FROM generate_series(1, 8))
LIMIT 5;
DROP TABLE vg_opts;

\echo '=== All Vamana valgrind tests completed ==='
SQLEOF

# ---------------------------------------------------------------------------
# Run the SQL tests
# ---------------------------------------------------------------------------
echo
echo "==================================================================="
echo " Running Vamana SQL test suite under valgrind"
echo "==================================================================="

SQL_EXIT=0
"$PSQL" "${PSQL_CONN[@]}" -f "$VAMANA_TEST_SQL" 2>&1 | tee -a "$PG_LOG_FILE" || SQL_EXIT=$?

if [ $SQL_EXIT -ne 0 ]; then
    echo
    echo "ERROR: SQL tests failed (exit $SQL_EXIT). See $PG_LOG_FILE"
fi

# ---------------------------------------------------------------------------
# Graceful shutdown — valgrind reports leaks at process exit
# ---------------------------------------------------------------------------
echo
echo "==================================================================="
echo " Shutting down PostgreSQL (valgrind reports leaks on exit)"
echo "==================================================================="

"$PSQL" "${PSQL_CONN[@]}" -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE pid <> pg_backend_pid();" 2>/dev/null || true
"$PSQL" "${PSQL_CONN[@]}" -c "CHECKPOINT;" 2>/dev/null || true

# Ask postgres to stop; give valgrind up to 5 minutes to finish
"$PG_CTL" stop -D "$PG_DATA_DIR" -m fast -t 300 2>/dev/null || true

# Wait for the valgrind-wrapped process itself to exit
wait "$PG_VALGRIND_PID" 2>/dev/null || true

echo "✓ PostgreSQL stopped"

# ---------------------------------------------------------------------------
# Collect and summarise valgrind output
# ---------------------------------------------------------------------------
echo
echo "==================================================================="
echo " Valgrind summary"
echo "==================================================================="

{
    echo "Valgrind Vamana run — $(date)"
    echo "Postgres : $POSTGRES_BIN"
    echo "SVS      : $SVS_BUILD"
    echo
    echo "=== ERRORS AND INVALID ACCESS ==="
    grep -h "ERROR\|Invalid read\|Invalid write\|Conditional jump\|Syscall param\|Use of uninitialised" \
        "$VALGRIND_DIR"/valgrind_*.log 2>/dev/null | sort | uniq -c | sort -rn || echo "  (none)"
    echo
    echo "=== DEFINITE / INDIRECT LEAKS ==="
    grep -h "definitely lost\|indirectly lost" \
        "$VALGRIND_DIR"/valgrind_*.log 2>/dev/null | sort | uniq -c | sort -rn || echo "  (none)"
    echo
    echo "=== HEAP SUMMARY (per process) ==="
    grep -h "HEAP SUMMARY\|total heap usage\|definitely lost\|indirectly lost\|possibly lost\|still reachable" \
        "$VALGRIND_DIR"/valgrind_*.log 2>/dev/null || echo "  (none)"
    echo
    echo "=== ERROR SUMMARY (per process) ==="
    grep -h "ERROR SUMMARY" "$VALGRIND_DIR"/valgrind_*.log 2>/dev/null || echo "  (none)"
} | tee "$SUMMARY_FILE"

# Determine exit status based on actual memory-access errors only.
# We check for Invalid read/write, uninitialised-value use, and similar
# rather than relying on a non-zero ERROR SUMMARY count, because Valgrind
# 3.18 records certain benign events (e.g. SVS large mmap) as "errors" in
# the summary even when no real access violation occurred.
DEFINITE_ERRORS=$({ grep -l \
    "Invalid read\|Invalid write\|Use of uninitialised\|Conditional jump\|Invalid free\|Syscall param" \
    "$VALGRIND_DIR"/valgrind_*.log 2>/dev/null || true; } | wc -l)

echo
echo "==================================================================="
if [ "$DEFINITE_ERRORS" -eq 0 ] && [ "$SQL_EXIT" -eq 0 ]; then
    echo " RESULT: PASS — No definite valgrind errors detected"
    FINAL_EXIT=0
elif [ "$DEFINITE_ERRORS" -gt 0 ]; then
    echo " RESULT: FAIL — $DEFINITE_ERRORS valgrind error(s) detected"
    echo "  Full logs: $VALGRIND_DIR/valgrind_*.log"
    FINAL_EXIT=1
else
    echo " RESULT: FAIL — SQL test failure (valgrind was clean)"
    FINAL_EXIT=2
fi
echo "  Summary: $SUMMARY_FILE"
echo "  Logs   : $VALGRIND_DIR/valgrind_*.log"
echo "==================================================================="

if [ "$KEEP_DATA" = false ]; then
    rm -rf "$PG_DATA_DIR"
fi

exit $FINAL_EXIT
