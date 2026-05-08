## Description

<!-- Briefly describe the changes in this PR and the motivation behind them. -->

## Related Issues

<!-- Link any related issues: Fixes #123, Closes #456, Related to #789 -->

## Type of Change

- [ ] Bug fix
- [ ] New feature
- [ ] Refactor / code cleanup
- [ ] Documentation update
- [ ] Test addition or update
- [ ] Build / CI change

## Pre-Merge Checklist

### Build

- [ ] `make` completes without errors or warnings
- [ ] `make install` completes successfully

### Tests

- [ ] `make installcheck` passes with no failures (all regression tests in `test/sql/` produce expected output)
- [ ] If new SQL behavior was added, expected output files in `test/expected/` are updated
- [ ] If new index functionality was added, corresponding tests exist in `test/sql/` and/or `test/t/`

### Code Style

- [ ] `pgindent` has been run on all modified `.c` and `.h` files and formatting changes are included in this PR

  The easiest way is via the linter script (run from the repo root):
  ```bash
  docs/run-linter.sh --fix        # all files
  docs/run-linter.sh --vamana --fix  # Vamana/SVS files only
  ```

  Or manually, with `POSTGRES_SOURCE` set to your postgres source tree:
  ```bash
  # export POSTGRES_SOURCE=/path/to/postgres   # set once in your shell profile
  $POSTGRES_SOURCE/src/tools/pgindent/pgindent \
      --typedefs=$POSTGRES_SOURCE/src/tools/pgindent/typedefs.list \
      --indent=$(which pg_bsd_indent) \
      $(git diff --name-only origin/main | grep -E '\.[ch]$')
  ```

- [ ] No trailing whitespace or unintended formatting changes remain

### Vamana / SVS (if applicable)

- [ ] `make installcheck REGRESS='vamana_vector vamana_halfvec'` passes
- [ ] On-disk persistence round-trip verified (`test/t/045_vamana_persistence.pl`)
- [ ] LeanVec / compression paths exercised if compression options were changed

### Documentation

- [ ] `CHANGELOG.md` updated if this is a user-visible change
- [ ] Relevant docs under `docs/` updated if architecture or usage changed

## Testing Notes

<!-- Describe any manual testing performed, datasets used, or performance measurements taken. -->
