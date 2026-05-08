#!/bin/bash
#
# run-linter.sh - Run static analysis and linting on pgvector-optimizations
#
# This script runs various linters and static analysis tools to check code quality.
# Usage: ./run-linter.sh [options]
#
# Options:
#   --fix             Apply automatic fixes where possible
#   --vamana          Only check Vamana-related files
#   --all             Check all files (default)
#   --verbose         Show detailed output
#   --pgindent-only   Run ONLY pgindent formatting (first pass, auto-fixes)
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Options
FIX_MODE=false
VAMANA_ONLY=false
VERBOSE=false
PGINDENT_ONLY=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --fix)
            FIX_MODE=true
            shift
            ;;
        --vamana)
            VAMANA_ONLY=true
            shift
            ;;
        --all)
            VAMANA_ONLY=false
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --pgindent-only)
            PGINDENT_ONLY=true
            FIX_MODE=true  # Automatically enable fix mode for pgindent
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--fix] [--vamana|--all] [--verbose] [--pgindent-only]"
            exit 1
            ;;
    esac
done

# Change to project root
cd "$PROJECT_ROOT"

echo -e "${BLUE}=== pgvector-optimizations Linter ===${NC}"
echo

# Determine which files to check
if [ "$VAMANA_ONLY" = true ]; then
    SOURCE_FILES="src/vamana*.c src/svs_wrapper.c"
    echo -e "${YELLOW}Checking Vamana-related files only${NC}"
else
    SOURCE_FILES="src/*.c"
    echo -e "${YELLOW}Checking all source files${NC}"
fi
echo

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to print section header
print_section() {
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}$1${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
}

# Track if any linter found issues
ISSUES_FOUND=false

# 1. pgindent - PostgreSQL code formatting (MOST IMPORTANT)
print_section "1. pgindent - PostgreSQL Code Formatting"
echo -e "${BLUE}This is the primary code formatting tool for PostgreSQL extensions${NC}"
echo

if command_exists pgindent; then
    echo "Running pgindent..."
    
    # Create temp directory for pgindent output
    INDENT_DIR=$(mktemp -d)
    trap "rm -rf $INDENT_DIR" EXIT
    
    # Find typedefs.list file
    TYPEDEFS_LIST=""
    if [ -f "/home/mattwelch/workspace/postgres/src/tools/pgindent/typedefs.list" ]; then
        TYPEDEFS_LIST="/home/mattwelch/workspace/postgres/src/tools/pgindent/typedefs.list"
    elif [ -n "$POSTGRES_SOURCE" ] && [ -f "$POSTGRES_SOURCE/src/tools/pgindent/typedefs.list" ]; then
        TYPEDEFS_LIST="$POSTGRES_SOURCE/src/tools/pgindent/typedefs.list"
    fi
    
    PGINDENT_CMD="pgindent"
    if [ -n "$TYPEDEFS_LIST" ]; then
        PGINDENT_CMD="pgindent --typedefs=$TYPEDEFS_LIST"
        if [ "$VERBOSE" = true ]; then
            echo "  Using typedefs from: $TYPEDEFS_LIST"
        fi
    else
        echo -e "${YELLOW}  Warning: typedefs.list not found, formatting may be suboptimal${NC}"
    fi
    
    PGINDENT_ISSUES=0
    
    for file in $SOURCE_FILES; do
        if [ -f "$file" ]; then
            if [ "$VERBOSE" = true ]; then
                echo "  Checking $file..."
            fi
            
            # Run pgindent and compare
            if [ "$FIX_MODE" = true ]; then
                echo "  Formatting $file..."
                $PGINDENT_CMD "$file"
                echo -e "${GREEN}  ✓ Formatted $file${NC}"
            else
                # Check mode - compare without modifying
                $PGINDENT_CMD "$file" > "$INDENT_DIR/$(basename $file).formatted" 2>/dev/null
                if ! diff -q "$file" "$INDENT_DIR/$(basename $file).formatted" > /dev/null 2>&1; then
                    echo -e "${RED}  ✗ $file needs formatting${NC}"
                    if [ "$VERBOSE" = true ]; then
                        echo "    Run with --fix to apply formatting"
                        diff -u "$file" "$INDENT_DIR/$(basename $file).formatted" | head -20
                    fi
                    PGINDENT_ISSUES=$((PGINDENT_ISSUES + 1))
                    ISSUES_FOUND=true
                fi
            fi
        fi
    done
    
    if [ "$FIX_MODE" = false ]; then
        if [ $PGINDENT_ISSUES -eq 0 ]; then
            echo -e "${GREEN}✓ All files are properly formatted${NC}"
        else
            echo -e "${RED}✗ $PGINDENT_ISSUES file(s) need formatting${NC}"
            echo -e "${YELLOW}Run with --fix to automatically format code${NC}"
        fi
    fi
else
    echo -e "${YELLOW}⚠ pgindent not installed or not in PATH${NC}"
    echo
    echo "pgindent is PostgreSQL's official code formatter."
    echo "To install:"
    echo "  1. Ensure PostgreSQL source is available at: /home/mattwelch/workspace/postgres"
    echo "  2. Add to PATH:"
    echo "     export PATH=\$PATH:/home/mattwelch/workspace/postgres/src/tools/pgindent"
    echo "  3. Or create symlink:"
    echo "     sudo ln -s /home/mattwelch/workspace/postgres/src/tools/pgindent/pgindent /usr/local/bin/"
    echo "  4. Or set in shell config (~/.bashrc):"
    echo "     export PATH=\"\$PATH:/home/mattwelch/workspace/postgres/src/tools/pgindent\""
    echo
    echo -e "${RED}⚠ Skipping pgindent - this is the most important formatter for PostgreSQL code!${NC}"
fi
echo

# Exit early if only pgindent was requested
if [ "$PGINDENT_ONLY" = true ]; then
    print_section "Summary"
    if [ "$ISSUES_FOUND" = true ]; then
        echo -e "${RED}✗ Some files needed formatting${NC}"
        echo
        echo "pgindent has reformatted the files."
        echo "Review changes with: git diff"
        exit 1
    else
        echo -e "${GREEN}✓ pgindent formatting completed!${NC}"
        echo
        echo "All files are now properly formatted."
        exit 0
    fi
fi

# 2. Check for basic syntax errors with GCC
print_section "2. GCC Syntax Check"
if command_exists gcc; then
    echo "Running GCC syntax check..."
    
    # Source environment if needed
    if [ -f "docs/env.sh" ]; then
        source docs/env.sh
    fi
    
    # Check if PG_CONFIG is set
    if [ -z "$PG_CONFIG" ]; then
        echo -e "${YELLOW}Warning: PG_CONFIG not set, using pg_config from PATH${NC}"
        PG_CONFIG=$(command -v pg_config || echo "")
    fi
    
    if [ -n "$PG_CONFIG" ] && [ -x "$PG_CONFIG" ]; then
        CFLAGS="-Wall -Wextra -Wpedantic -Wno-unused-parameter -fsyntax-only"
        CFLAGS="$CFLAGS -I. -I$($PG_CONFIG --includedir-server)"
        
        if [ -n "$SVS_ROOT" ]; then
            CFLAGS="$CFLAGS -I$SVS_ROOT/bindings/c/include"
        fi
        
        ERROR_COUNT=0
        for file in $SOURCE_FILES; do
            if [ -f "$file" ]; then
                if [ "$VERBOSE" = true ]; then
                    echo "  Checking $file..."
                fi
                if ! gcc $CFLAGS "$file" 2>&1 | grep -v "note:"; then
                    ERROR_COUNT=$((ERROR_COUNT + 1))
                    ISSUES_FOUND=true
                fi
            fi
        done
        
        if [ $ERROR_COUNT -eq 0 ]; then
            echo -e "${GREEN}✓ No syntax errors found${NC}"
        else
            echo -e "${RED}✗ Found syntax errors in $ERROR_COUNT file(s)${NC}"
        fi
    else
        echo -e "${YELLOW}⚠ pg_config not found, skipping GCC check${NC}"
    fi
else
    echo -e "${YELLOW}⚠ gcc not installed, skipping${NC}"
fi
echo

# 3. cppcheck static analysis
print_section "3. cppcheck Static Analysis"
if command_exists cppcheck; then
    echo "Running cppcheck..."
    
    CPPCHECK_OPTS="--enable=warning,style,performance,portability"
    CPPCHECK_OPTS="$CPPCHECK_OPTS --suppress=unusedFunction"
    CPPCHECK_OPTS="$CPPCHECK_OPTS --suppress=missingIncludeSystem"
    CPPCHECK_OPTS="$CPPCHECK_OPTS --inline-suppr"
    CPPCHECK_OPTS="$CPPCHECK_OPTS --quiet"
    
    if [ "$VERBOSE" = true ]; then
        CPPCHECK_OPTS="$CPPCHECK_OPTS --verbose"
    fi
    
    if cppcheck $CPPCHECK_OPTS $SOURCE_FILES 2>&1 | tee /tmp/cppcheck.out | grep -q "error:\|warning:"; then
        echo -e "${RED}✗ cppcheck found issues${NC}"
        ISSUES_FOUND=true
    else
        echo -e "${GREEN}✓ No issues found${NC}"
    fi
else
    echo -e "${YELLOW}⚠ cppcheck not installed${NC}"
    echo "  Install with: sudo apt install cppcheck"
fi
echo

# 4. clang-tidy
print_section "4. clang-tidy Analysis"
if command_exists clang-tidy; then
    echo "Running clang-tidy..."
    
    CLANG_TIDY_OPTS="-checks=-*,bugprone-*,clang-analyzer-*,readability-*"
    CLANG_TIDY_OPTS="$CLANG_TIDY_OPTS,performance-*,portability-*"
    
    if [ "$FIX_MODE" = true ]; then
        CLANG_TIDY_OPTS="$CLANG_TIDY_OPTS -fix"
        echo -e "${YELLOW}Fix mode enabled - applying automatic fixes${NC}"
    fi
    
    # Build compilation database if possible
    if [ -f "compile_commands.json" ]; then
        CLANG_TIDY_OPTS="$CLANG_TIDY_OPTS -p ."
    fi
    
    ISSUE_COUNT=0
    for file in $SOURCE_FILES; do
        if [ -f "$file" ]; then
            if [ "$VERBOSE" = true ]; then
                echo "  Checking $file..."
            fi
            if clang-tidy $CLANG_TIDY_OPTS "$file" 2>&1 | grep -q "warning:\|error:"; then
                ISSUE_COUNT=$((ISSUE_COUNT + 1))
                ISSUES_FOUND=true
            fi
        fi
    done
    
    if [ $ISSUE_COUNT -eq 0 ]; then
        echo -e "${GREEN}✓ No issues found${NC}"
    else
        echo -e "${RED}✗ Found issues in $ISSUE_COUNT file(s)${NC}"
    fi
else
    echo -e "${YELLOW}⚠ clang-tidy not installed${NC}"
    echo "  Install with: sudo apt install clang-tidy"
fi
echo

# 5. Check for common code smells
print_section "5. Code Pattern Check"
echo "Checking for common issues..."

PATTERN_ISSUES=0

# Check for missing NULL checks after malloc/palloc
if grep -n "palloc\|malloc" $SOURCE_FILES | grep -v "NULL" | head -5; then
    echo -e "${YELLOW}⚠ Found palloc/malloc without nearby NULL check${NC}"
    PATTERN_ISSUES=$((PATTERN_ISSUES + 1))
fi

# Check for potential buffer overflows
if grep -n "strcpy\|strcat\|sprintf" $SOURCE_FILES | head -5; then
    echo -e "${YELLOW}⚠ Found potentially unsafe string functions (strcpy/strcat/sprintf)${NC}"
    echo "  Consider using: strlcpy, strlcat, snprintf"
    PATTERN_ISSUES=$((PATTERN_ISSUES + 1))
fi

# Check for missing error checks
if grep -n "ereport.*NOTICE" $SOURCE_FILES | wc -l | grep -v "^0$"; then
    NOTICE_COUNT=$(grep -n "ereport.*NOTICE" $SOURCE_FILES | wc -l)
    echo -e "${YELLOW}⚠ Found $NOTICE_COUNT NOTICE messages (consider using DEBUG1 for internal messages)${NC}"
fi

if [ $PATTERN_ISSUES -eq 0 ]; then
    echo -e "${GREEN}✓ No common code smell patterns detected${NC}"
else
    ISSUES_FOUND=true
fi
echo

# 6. Check code formatting
print_section "6. Code Style Check"
echo "Checking indentation and formatting..."

STYLE_ISSUES=0

# Check for mixed tabs and spaces
if grep -Pn "^\t+ " $SOURCE_FILES | head -5; then
    echo -e "${YELLOW}⚠ Found mixed tabs and spaces${NC}"
    STYLE_ISSUES=$((STYLE_ISSUES + 1))
fi

# Check for trailing whitespace
if grep -n " $" $SOURCE_FILES | head -5; then
    echo -e "${YELLOW}⚠ Found trailing whitespace${NC}"
    STYLE_ISSUES=$((STYLE_ISSUES + 1))
fi

# Check for lines over 80 characters
LONG_LINES=$(grep -n "^.\{81,\}" $SOURCE_FILES | wc -l)
if [ $LONG_LINES -gt 0 ]; then
    echo -e "${YELLOW}⚠ Found $LONG_LINES lines exceeding 80 characters${NC}"
fi

if [ $STYLE_ISSUES -eq 0 ]; then
    echo -e "${GREEN}✓ Code style looks good${NC}"
fi
echo

# Summary
print_section "Summary"
if [ "$ISSUES_FOUND" = true ]; then
    echo -e "${RED}✗ Linting completed with issues found${NC}"
    echo
    echo "Review the output above and fix the issues."
    echo "Run with --fix to apply automatic fixes where possible."
    exit 1
else
    echo -e "${GREEN}✓ All linting checks passed!${NC}"
    echo
    echo "Code quality looks good."
    exit 0
fi
