# Linter Script Documentation

## Overview

The `run-linter.sh` script performs static analysis and code quality checks on the pgvector-optimizations codebase. It runs multiple linters and checks to help catch bugs, improve code quality, and maintain consistency.

## Usage

### Basic Usage

```bash
# Check all source files
./docs/run-linter.sh

# Check only Vamana-related files
./docs/run-linter.sh --vamana

# Apply automatic fixes (where supported)
./docs/run-linter.sh --fix

# FIRST PASS: Run ONLY pgindent formatting (recommended workflow)
./docs/run-linter.sh --vamana --pgindent-only

# Show detailed output
./docs/run-linter.sh --verbose
```

### Options

| Option | Description |
|--------|-------------|
| `--all` | Check all source files (default) |
| `--vamana` | Check only Vamana-related files (`vamana*.c`, `svs_wrapper.c`) |
| `--fix` | Apply automatic fixes where possible (pgindent + clang-tidy) |
| `--pgindent-only` | Run ONLY pgindent formatting, skip all other checks (auto-fixes) |
| `--verbose` | Show detailed output from all linters |

## Checks Performed

### 1. pgindent - PostgreSQL Code Formatting (MOST IMPORTANT)
- PostgreSQL's official code formatter for consistent style
- Enforces PostgreSQL coding standards and conventions
- Automatically formats code with `--fix` option
- **This is the primary and most important formatter** for PostgreSQL extensions
- Requires: PostgreSQL source with pgindent tool
- Install guide provided if not found

### 2. GCC Syntax Check
### 2. GCC Syntax Check
- Compiles files with `-fsyntax-only` to catch syntax errors
- Uses extra warning flags: `-Wall -Wextra -Wpedantic`
- Requires: `gcc`, `pg_config`

### 3. cppcheck Static Analysis
### 3. cppcheck Static Analysis
- Checks for memory leaks, null pointer dereferences, buffer overflows
- Enables: warnings, style, performance, portability checks
- Install: `sudo apt install cppcheck`

### 4. clang-tidy Analysis
### 4. clang-tidy Analysis
- Advanced static analysis for C/C++
- Checks: bug-prone patterns, readability, performance issues
- Supports automatic fixes with `--fix`
- Install: `sudo apt install clang-tidy`

### 5. Code Pattern Check
### 5. Code Pattern Check
- Searches for common code smells:
  - Missing NULL checks after malloc/palloc
  - Unsafe string functions (strcpy, strcat, sprintf)
  - Excessive NOTICE messages (should use DEBUG1)
- Uses grep patterns

### 6. Code Style Check
- Checks for:
  - Mixed tabs and spaces
  - Trailing whitespace
  - Lines exceeding 80 characters
- Basic formatting verification

## Installation Requirements

### Required
- `bash`
- `grep`
- `pgindent` (PostgreSQL's official formatter - **highly recommended**)
- `gcc` (for syntax checking)

### Optional (but recommended)
```bash
# Install pgindent (from PostgreSQL source)
git clone https://github.com/postgres/postgres.git /tmp/postgres
sudo ln -s /tmp/postgres/src/tools/pgindent/pgindent /usr/local/bin/

# Install cppcheck
sudo apt install cppcheck

# Install clang-tidy
sudo apt install clang-tidy

# Install clang-format (for future formatting support)
sudo apt install clang-format
```

## Environment Setup

The script automatically sources `docs/env.sh` if present to load environment variables like `PG_CONFIG`, `SVS_ROOT`, etc.

Alternatively, set these manually:
```bash
export PG_CONFIG=/path/to/postgres/build/bin/pg_config
export SVS_ROOT=/path/to/svs
./docs/run-linter.sh
```

## Exit Codes

- `0`: All checks passed, no issues found
- `1`: Issues found, review output and fix

## Examples

### Recommended workflow (two-pass approach)
```bash
# FIRST PASS: Format with pgindent only
./docs/run-linter.sh --vamana --pgindent-only

# Review the formatting changes
git diff

# SECOND PASS: Run all other linters
./docs/run-linter.sh --vamana
```

### Quick check before commit
```bash
# Check only files you changed
./docs/run-linter.sh --vamana
```

### Full analysis
```bash
# Check everything with details
./docs/run-linter.sh --all --verbose
```

### Auto-fix issues
```bash
# Apply pgindent formatting only (recommended first pass)
./docs/run-linter.sh --vamana --pgindent-only

# Apply all automatic fixes (pgindent + clang-tidy)
./docs/run-linter.sh --vamana --fix
```

### Integration with Git
```bash
# Add as pre-commit hook
ln -s ../../docs/run-linter.sh .git/hooks/pre-commit
```

## Common Issues

### "pg_config not found"
Set `PG_CONFIG` environment variable:
```bash
export PG_CONFIG=/path/to/postgres/build/bin/pg_config
```

### "cppcheck not installed"
Install with package manager:
```bash
sudo apt install cppcheck
```

### PostgreSQL header warnings
Pedantic warnings from PostgreSQL headers are expected and can be ignored. Focus on warnings from your own code (`src/*.c` files).

## Tips

1. **Use two-pass approach**: Run `--pgindent-only` first, review with `git diff`, then run full linter
2. **Run before commits**: Make it a habit to run the linter before committing changes
3. **Focus on your code**: PostgreSQL header warnings can be filtered; focus on issues in `src/` files
4. **Use --vamana for quick checks**: Faster iteration when working on Vamana index
5. **Auto-fix cautiously**: Review changes before committing, especially from clang-tidy
6. **Verbose mode for debugging**: Use `--verbose` when investigating specific issues

## Integration with VSCode

Add to `.vscode/tasks.json`:
```json
{
    "label": "Run Linter",
    "type": "shell",
    "command": "./docs/run-linter.sh",
    "problemMatcher": [],
    "group": "test"
}
```

## Future Enhancements

Planned improvements:
- [ ] Support for `clang-format` automatic code formatting
- [ ] Integration with PostgreSQL's `pgindent` tool
- [ ] HTML report generation
- [ ] CI/CD integration examples
- [ ] Custom configuration file support
- [ ] Incremental checking (only changed files)

## Contributing

To add new checks:
1. Add a new section in the script (e.g., "6. Your New Check")
2. Update this README with the new check description
3. Test thoroughly before committing

## Troubleshooting

### Script hangs or runs slowly
- Use `--vamana` to check fewer files
- Check if a specific linter is hanging (comment it out temporarily)

### False positives
- Use inline suppressions in code comments
- Configure linter options in the script

### Linter not available
- The script gracefully skips unavailable linters
- Install recommended tools for complete coverage

## See Also

- [VSCode Build Setup](VSCODE_BUILD_SETUP.md)
- [Vamana Test Implementation Plan](VAMANA_TEST_IMPLEMENTATION_PLAN.md)
- [SVS Vamana Architecture](SVS_VAMANA_ARCHITECTURE.md)
