# Terminal Build & Test Setup for pgvector-optimizations

This guide explains how to build and test pgvector-optimizations from a Linux terminal.

## Prerequisites

1. PostgreSQL built from source
2. Intel SVS library built
3. Intel oneAPI MKL installed (optional, for optimizations)

## Environment Setup

### Step 1: Configure Your Paths

Edit `docs/env.sh` and update the workspace paths to match your setup:

```bash
# Example workspace layout:
# ~/workspace/
#   ├── applications.databases.postgresql.pgvector-optimizations/
#   ├── libraries.ai.vector-search.svs/
#   ├── postgres/
#   └── pgv-svs-dev-scripts/

# Update these paths to match YOUR workspace:
WORKSPACE_DIR="$HOME/workspace"  # Change this to your workspace location
```

### Step 2: Load Environment

Before building, always source the environment file:

```bash
cd /path/to/pgvector-optimizations
source docs/env.sh
```

**Verify the environment is loaded:**

```bash
echo $PG_CONFIG
# Should output: /your/workspace/postgres/build/bin/pg_config

which postgres
# Should output: /your/workspace/postgres/build/bin/postgres
```

## Building

```bash
# Clean previous builds
make clean

# Build extension
make

# Install to PostgreSQL
make install  # May need sudo depending on pg_config --libdir permissions
```

## Running Tests

### All Regression Tests
```bash
make installcheck
```

### Specific Test Files
```bash
# Run only Vamana tests
make installcheck REGRESS='vamana_vector vamana_halfvec'

# Run single test
make installcheck REGRESS='vamana_vector'

# Run HNSW tests
make installcheck REGRESS='hnsw_vector hnsw_halfvec'
```

### Perl TAP Tests
```bash
# Run all TAP tests
make prove_installcheck

# Run specific TAP test
prove test/t/001_ivfflat_wal.pl
```

## Viewing Test Results

### Check test output
```bash
# View actual output
cat results/vamana_halfvec.out

# Compare with expected
diff -u test/expected/vamana_halfvec.out results/vamana_halfvec.out

# View summary
cat regression.out
```

### Test failures show up as:
```bash
# Diff files created for failures
ls results/*.out.diff

# View specific failure
cat results/vamana_halfvec.out.diff
```

## Debugging with GDB

### Method 1: Attach to Running PostgreSQL Backend

1. Start PostgreSQL and connect with psql
2. Get the backend PID:
   ```sql
   SELECT pg_backend_pid();
   ```

3. In another terminal, attach GDB:
   ```bash
   source docs/env.sh  # Load LD_LIBRARY_PATH
   gdb -p <PID>
   ```

4. Set breakpoints and continue:
   ```gdb
   (gdb) break vamanabuild.c:123
   (gdb) continue
   ```

### Method 2: Run Query Under GDB from Start

```bash
# Start postgres backend under GDB (single-user mode)
gdb --args postgres --single -D /path/to/data postgres

# In GDB:
(gdb) break vamanabuild.c:123
(gdb) run

# Then execute SQL that triggers the breakpoint
```

### Common Files to Debug

- `src/vamana.c` - Access method handler
- `src/vamanabuild.c` - Index building
- `src/vamanascan.c` - Query execution
- `src/vamanainsert.c` - Insert operations
- `src/svs_wrapper.c` - SVS library integration
- `src/hnsw*.c` - HNSW implementation
- `src/ivfflat*.c` - IVFFlat implementation

## Common Workflows

### Quick Iteration Cycle
```bash
source docs/env.sh
make clean && make && make install && make installcheck REGRESS='vamana_halfvec'
```

### Build and Run All Tests
```bash
source docs/env.sh
make clean && make && make install && make installcheck && make prove_installcheck
```

### Check for Memory Leaks with Valgrind
```bash
source docs/env.sh

# Start postgres under valgrind (very slow!)
valgrind --leak-check=full --show-leak-kinds=all \
  postgres --single -D $PGDATA postgres

# Then run SQL queries
```

### Enable Debug Output
```sql
-- In psql session:
SET client_min_messages = DEBUG1;
SET log_min_messages = DEBUG1;

-- Now run index creation/queries to see internal messages
CREATE INDEX ON t USING vamana (val vector_l2_ops);
```

### Profile with perf (Linux)
```bash
source docs/env.sh

# Record performance data
sudo perf record -g postgres --single -D $PGDATA postgres

# View results
sudo perf report
```

## Troubleshooting

### Issue: "postgres: command not found"

**Cause**: Environment not loaded or incorrect workspace paths.

**Solution**:
```bash
# Load environment
source docs/env.sh

# Verify paths
which postgres  # Should show your build path
echo $PG_CONFIG  # Should show pg_config path

# If wrong, edit docs/env.sh and update WORKSPACE_DIR
```

### Issue: "libsvs.so: cannot open shared object file"

**Cause**: `LD_LIBRARY_PATH` not set correctly.

**Solution**:
```bash
# Load environment
source docs/env.sh

# Verify library path
echo $LD_LIBRARY_PATH  # Should include SVS build path

# Test library loading
ldd $(pg_config --libdir)/vector.so | grep svs

# Alternative: Add to system config (persistent)
sudo sh -c "echo '$WORKSPACE_DIR/libraries.ai.vector-search.svs/build/bindings/c' > /etc/ld.so.conf.d/svs.conf"
sudo ldconfig
```

### Issue: Tests fail with different results

**Cause**: Approximate algorithms may produce different orderings.

**Solution**:
```bash
# Check actual vs expected differences
diff -u test/expected/vamana_halfvec.out results/vamana_halfvec.out

# Update expected output if changes are intentional:
cp results/vamana_halfvec.out test/expected/vamana_halfvec.out

# Or investigate if recall has degraded:
# - Check Vamana parameters (graph_degree, alpha)
# - Verify SVS library version
```

### Issue: Build errors about missing headers

**Cause**: Incorrect PostgreSQL or SVS paths.

**Solution**:
```bash
# Verify pg_config is correct
$PG_CONFIG --version
$PG_CONFIG --includedir-server

# Verify SVS paths
ls $SVS_BUILD/bindings/c/include/svs/c_api/svs_c.h

# If missing, rebuild SVS with C bindings:
cd $SVS_ROOT
cmake -B build -DCMAKE_BUILD_TYPE=Release -DSVS_BUILD_C_BINDINGS=ON
cmake --build build -j$(nproc)
```

### Issue: "make: pg_config: Command not found"

**Cause**: PostgreSQL not built or `PG_CONFIG` not set.

**Solution**:
```bash
# Check if PostgreSQL is built
ls ~/workspace/postgres/build/bin/pg_config

# If missing, build PostgreSQL:
cd ~/workspace/postgres
./configure --prefix=$PWD/build
make -j$(nproc)
make install

# Then reload environment
source docs/env.sh
```

### Issue: Tests timeout or hang

**Cause**: PostgreSQL server not running or connection issues.

**Solution**:
```bash
# Check if PostgreSQL is running
pg_ctl status -D $PGDATA

# Start if needed
pg_ctl start -D $PGDATA -l logfile

# Or use the start script:
cd ~/workspace/pgv-svs-dev-scripts
./start_pg_server.sh
```

## Continuous Integration Flow

Example CI script for automated testing:

```bash
#!/bin/bash
# ci-build-and-test.sh

set -e  # Exit on error
set -u  # Exit on undefined variable

# Load environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/docs/env.sh"

# Clean build
echo "==> Cleaning previous build..."
make clean

# Build extension
echo "==> Building extension..."
make -j$(nproc)

# Install
echo "==> Installing extension..."
make install

# Run all tests
echo "==> Running regression tests..."
make installcheck

echo "==> Running TAP tests..."
make prove_installcheck

# Check for failures
if [ -f regression.diffs ]; then
    echo "ERROR: Regression tests failed!"
    cat regression.diffs
    exit 1
fi

echo "✓ All tests passed!"
```

## Performance Testing

### Benchmark Vamana vs HNSW
```bash
source docs/env.sh

# Create test script
cat > bench_indexes.sql <<'EOF'
CREATE TABLE vectors AS 
SELECT id, array_agg(random())::vector(128) as vec 
FROM generate_series(1, 100000) id, generate_series(1, 128) 
GROUP BY id;

-- HNSW index
\timing on
CREATE INDEX ON vectors USING hnsw (vec vector_l2_ops);
\timing off

-- Vamana index
\timing on
CREATE INDEX ON vectors USING vamana (vec vector_l2_ops);
\timing off

-- Compare query performance
EXPLAIN ANALYZE SELECT * FROM vectors ORDER BY vec <-> '[...]' LIMIT 10;
EOF

# Run benchmark
psql -f bench_indexes.sql
```

### Check Index Size
```bash
psql -c "
SELECT 
  schemaname || '.' || tablename as table,
  indexname,
  pg_size_pretty(pg_relation_size(indexname::regclass)) as index_size
FROM pg_indexes 
WHERE tablename = 'your_table'
ORDER BY pg_relation_size(indexname::regclass) DESC;
"
```

## Advanced: Using Multiple PostgreSQL Versions

If testing against multiple PostgreSQL versions:

```bash
# Create separate env files
cat > docs/env-pg15.sh <<EOF
export WORKSPACE_DIR="$HOME/workspace"
export PG_CONFIG="\$WORKSPACE_DIR/postgres-15/build/bin/pg_config"
# ... rest of env setup
EOF

cat > docs/env-pg16.sh <<EOF
export WORKSPACE_DIR="$HOME/workspace"
export PG_CONFIG="\$WORKSPACE_DIR/postgres-16/build/bin/pg_config"
# ... rest of env setup
EOF

# Use specific version
source docs/env-pg15.sh
make clean && make && make install && make installcheck
```

## Quick Reference

| Action | Command |
|--------|---------|
| Load environment | `source docs/env.sh` |
| Build | `make` |
| Clean build | `make clean` |
| Install | `make install` |
| Run all tests | `make installcheck` |
| Run specific test | `make installcheck REGRESS='test_name'` |
| Run TAP tests | `make prove_installcheck` |
| Debug with GDB | `gdb -p $(pgrep -f "postgres: .* postgres")` |
| View test diff | `cat results/test_name.out.diff` |

## See Also

- [VSCode Build Setup](VSCODE_BUILD_SETUP.md) - IDE integration with tasks and debugging
- [SVS Vamana Architecture](SVS_VAMANA_ARCHITECTURE.md) - Implementation details
- [SVS Vamana Requirements](SVS_VAMANA_REQUIREMENTS.md) - API requirements and limitations
- [Copilot Instructions](../.github/copilot-instructions.md) - Development guide for contributors
- [CI Environment](CI_ENVIRONMENT.md) - Continuous integration setup
