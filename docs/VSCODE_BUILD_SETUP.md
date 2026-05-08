# VSCode Build Configuration for pgvector-optimizations

This document explains how to build and debug pgvector-optimizations using VSCode.

## Configuration Files Created

The following VSCode configuration files have been set up:

1. **`.vscode/settings.json`** - Environment variables and editor settings
2. **`.vscode/tasks.json`** - Build tasks for Make commands
3. **`.vscode/c_cpp_properties.json`** - IntelliSense configuration
4. **`.vscode/launch.json`** - Debug configurations

## Environment Variables

All VSCode tasks automatically set these environment variables:

```bash
PG_CONFIG=/home/mattwelch/workspace/postgres/build/bin/pg_config
SVS_ROOT=/home/mattwelch/workspace/libraries.ai.vector-search.svs
SVS_BUILD=/home/mattwelch/workspace/libraries.ai.vector-search.svs/build
PATH=/home/mattwelch/workspace/postgres/build/bin:$PATH
LD_LIBRARY_PATH=/home/mattwelch/workspace/libraries.ai.vector-search.svs/build/bindings/c:/opt/intel/oneapi/mkl/latest/lib/intel64:$LD_LIBRARY_PATH
MKLROOT=/opt/intel/oneapi/mkl/latest
```

## Building in VSCode

### Method 1: Using Tasks (Recommended)

Press `Ctrl+Shift+P` and type "Run Task", then select:

- **Build pgvector-optimizations** - Runs `make`
- **Clean pgvector-optimizations** - Runs `make clean`
- **Install pgvector-optimizations** - Runs `make install`
- **Run Tests (make installcheck)** - Runs all regression tests
- **Run Vamana Tests Only** - Runs just Vamana tests
- **Build, Install & Test** - Complete build pipeline

### Method 2: Using Keyboard Shortcuts

- **Build**: Press `Ctrl+Shift+B` (runs default build task)

### Method 3: Terminal with Auto-Loaded Env

Open a new terminal in VSCode (`Ctrl+Shift+``) and the environment variables will be automatically loaded. Then run:

```bash
make clean
make
make install
make installcheck
```

## Running Tests

### All Tests
```bash
# Using VSCode Task: Ctrl+Shift+P → "Run Task" → "Run Tests (make installcheck)"

# Or in VSCode terminal:
make installcheck
```

### Vamana Tests Only
```bash
# Using VSCode Task: Ctrl+Shift+P → "Run Task" → "Run Vamana Tests Only"

# Or in VSCode terminal:
make installcheck REGRESS='vamana_vector vamana_halfvec'
```

### View Test Results
```bash
# Check test output
cat results/vamana_vector.out

# Check for differences
cat results/vamana_vector.out.diff

# View regression summary
cat regression.out
```

## Debugging

### Method 1: Attach to Running PostgreSQL Process

1. Start PostgreSQL server
2. In VSCode, press `F5` or go to Run → Start Debugging
3. Select "Debug PostgreSQL with Vamana"
4. Choose the postgres backend process from the list

### Method 2: Attach with Known PID

1. Get the backend PID:
   ```bash
   # In psql:
   SELECT pg_backend_pid();
   ```
2. In VSCode, select "Debug PostgreSQL Backend (PID)"
3. Enter the PID when prompted

### Setting Breakpoints

Open any `.c` file (e.g., `src/vamanabuild.c`) and click in the left margin to set breakpoints.

Common files to debug:
- `src/vamana.c` - Access method handler
- `src/vamanabuild.c` - Index building
- `src/vamanascan.c` - Query execution
- `src/vamanainsert.c` - Insert operations
- `src/svs_wrapper.c` - SVS library integration

## IntelliSense Features

The configuration provides:

- **Code completion** - Auto-complete for PostgreSQL and SVS APIs
- **Go to definition** - `F12` on any function/type
- **Find references** - `Shift+F12` on any symbol
- **Hover information** - Hover over variables for type info
- **Error squiggles** - Real-time syntax checking

## Troubleshooting

### Issue: "Cannot find pg_config"

**Solution**: Update the paths in `.vscode/settings.json` if your postgres build is in a different location:
```json
"PG_CONFIG": "${workspaceFolder}/../YOUR_POSTGRES_PATH/build/bin/pg_config"
```

### Issue: "SVS library not found"

**Solution**: Update the SVS paths in `.vscode/settings.json`:
```json
"SVS_ROOT": "${workspaceFolder}/../YOUR_SVS_PATH"
"SVS_BUILD": "${workspaceFolder}/../YOUR_SVS_PATH/build"
```

### Issue: IntelliSense errors

**Solution**: 
1. Press `Ctrl+Shift+P`
2. Type "C/C++: Edit Configurations (JSON)"
3. Verify paths in `.vscode/c_cpp_properties.json`
4. Reload VSCode window: `Ctrl+Shift+P` → "Developer: Reload Window"

### Issue: Build errors about missing libraries

**Solution**: Make sure you've built SVS and PostgreSQL first:
```bash
cd /home/mattwelch/workspace/pgv-svs-dev-scripts
./build_svs.sh
./build_install_pgsql.sh
```

### Issue: Terminal doesn't have environment variables

**Solution**: 
1. Close all terminals in VSCode
2. Open a new terminal (`Ctrl+Shift+``)
3. Variables should load automatically
4. Verify with: `echo $PG_CONFIG`

## Recommended VSCode Extensions

Install these for the best experience:

- **C/C++** (ms-vscode.cpptools) - Already configured
- **Makefile Tools** (ms-vscode.makefile-tools) - Makefile support
- **PostgreSQL** (ckolkman.vscode-postgres) - SQL syntax highlighting
- **GitLens** (eamodio.gitlens) - Enhanced git integration

## Quick Reference

| Action | Shortcut | Command |
|--------|----------|---------|
| Build | `Ctrl+Shift+B` | Default build task |
| Run Task | `Ctrl+Shift+P` → Run Task | Opens task menu |
| Debug | `F5` | Start debugging |
| Open Terminal | `Ctrl+Shift+`` | New terminal with env vars |
| Go to Definition | `F12` | Jump to symbol definition |
| Find References | `Shift+F12` | Find all usages |
| Command Palette | `Ctrl+Shift+P` | Access all commands |

## Command Line Comparison

| Command Line | VSCode Equivalent |
|--------------|-------------------|
| `source docs/env.sh` | Automatic in terminal |
| `make` | `Ctrl+Shift+B` or "Build" task |
| `make clean` | "Clean" task |
| `make install` | "Install" task |
| `make installcheck` | "Run Tests" task |
| `gdb --args postgres` | `F5` → Debug config |

## Tips

1. **Fast iteration**: Use the "Build, Install & Test" task to run the full pipeline
2. **Debug failing tests**: Set breakpoints, then run tests in debug mode
3. **Code navigation**: Use `Ctrl+P` to quickly open files by name
4. **Search across files**: `Ctrl+Shift+F` for workspace-wide search
5. **Integrated git**: Source control panel (`Ctrl+Shift+G`) for commits

## Next Steps

After setup:
1. Press `Ctrl+Shift+B` to test building
2. Open `src/vamana.c` and verify IntelliSense works (hover over functions)
3. Run "Run Vamana Tests Only" task to test your current implementation
4. Set breakpoints and use `F5` to debug
