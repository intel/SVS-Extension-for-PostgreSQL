# Code Coverage for the SVS Extension

## Overview

Coverage is measured using GCC's built-in `gcov` instrumentation, with `gcovr` to
aggregate and render reports.

- **`gcov`** — part of GCC; generates `.gcno` (compile-time) and `.gcda` (runtime) files
- **`gcovr`** — Python tool that reads gcov data and outputs JSON, HTML, and text
  summaries in a single command; no root access required

`gcovr` is preferred over the traditional `lcov`/`genhtml` pipeline because it produces
a machine-readable JSON report (used for AI-assisted gap analysis) alongside the human
HTML report, and does so in one invocation.

---

## Prerequisites

```bash
pip install gcovr
gcovr --version
```

---

## Step 1 — Clean and rebuild with instrumentation

Coverage is opt-in: pass `COVERAGE=1` to add the `--coverage` flags to `PG_CFLAGS`
and `SHLIB_LINK`. Default builds are never instrumented.

```bash
source docs/dev/env.sh
make clean
make COVERAGE=1
make install
```

`--coverage` is a GCC shorthand:
- At compile time: `-fprofile-arcs -ftest-coverage` (generates `.gcno` beside each `.o`)
- At link time: `-lgcov` (links the gcov runtime into the shared library)

`make clean` is required when switching instrumentation on or off — the flags change
how every object file is compiled.

---

## Step 2 — Zero out stale runtime data

Before running tests, reset any leftover `.gcda` files from previous runs:

```bash
make coverage-clean
```

---

## Step 3 — Run the tests

```bash
make installcheck        # SQL regression tests (test/sql/*.sql)
make prove_installcheck  # Perl TAP tests (test/t/0*.pl)
```

> **Background worker note**: The Vamana BGW is a separate forked process. Its coverage
> data is written by `atexit()` handlers when the process exits. Always stop the cluster
> cleanly with `pg_ctl stop` before collecting data — `SIGKILL` or a crash will lose BGW
> coverage.

---

## Step 4 — Generate reports

One command produces all three outputs:

```bash
make coverage
```

Reports are written to `coverage_reports/` (gitignored — never committed):

| File | Purpose |
|---|---|
| `coverage_reports/coverage.txt` | Per-file line summary (human-readable) |
| `coverage_reports/coverage.json` | gcovr JSON v0.14 — per-line hit counts and function names; AI-consumable |
| `coverage_reports/index.html` | Interactive HTML; red/green line highlighting |

---

## Step 5 — Return to a production build

Drop `COVERAGE=1` and rebuild; no Makefile edit is needed:

```bash
make clean && make && make install
```

---

## AI-assisted gap analysis workflow

1. Run `make coverage` to generate `coverage_reports/coverage.json`.
2. Share `coverage_reports/coverage.json` with the AI assistant (or ask the assistant
   to read it directly from the workspace).
3. The assistant identifies uncovered lines and branches, cross-references against
   the source files, and writes targeted test cases.
4. Re-run `make coverage-clean && make prove_installcheck && make coverage` to verify improvement.

---

## Key files to examine

| Source file | What it exercises |
|---|---|
| `src/vamanabuild.c` | Batch build path |
| `src/vamanascan.c` | KNN query path |
| `src/vamanaworker.c` | BGW main loop, IPC handling |
| `src/vamanaworkerindex.c` | Index load/eviction in BGW cache |
| `src/vamanaworkersearch.c` | Batch search dispatch |
| `src/vamanaworkerwrite.c` | Insert/delete write path |
| `src/svs_wrapper.c` | SVS C API call sites |
| `src/vamanavacuum.c` | Vacuum/delete path (typically under-tested) |
| `src/vamana_undo.c` | Undo/abort path |

---

## Notes

- `.gcda` files are written to the same directory as the `.o` files (`src/`). The
  PostgreSQL server process must have write access to that directory. In a local dev
  build under `$HOME` this is automatic.
- Each test run accumulates into the existing `.gcda` files. Run `gcovr --delete` to
  start fresh.
- For the BGW, coverage accumulates across all index builds, searches, inserts, and
  vacuums executed during the test run. The Perl TAP tests (`test/t/`) exercise more
  BGW paths than the SQL regression tests alone.
