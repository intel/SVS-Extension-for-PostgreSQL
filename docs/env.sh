#!/bin/bash
# Environment setup for pgvector-optimizations development
# Source this file before building: source docs/env.sh

# =============================================================================
# CUSTOMIZE THESE PATHS FOR YOUR WORKSPACE
# =============================================================================

# Root directory containing all repositories
# Example: /home/username/workspace or /home/username/Projects
WORKSPACE_DIR="$HOME/workspace"

# If your workspace structure is different, adjust individual paths below
# Expected structure:
#   $WORKSPACE_DIR/
#     ├── applications.databases.postgresql.pgvector-optimizations/
#     ├── ScalableVectorSearch/
#     ├── postgres/
#     └── pgv-svs-dev-scripts/
#           ├── pgsql_install/       (PostgreSQL install prefix)
#           └── svs_install_public/  (SVS install prefix)

# =============================================================================
# POSTGRESQL CONFIGURATION
# =============================================================================

# PostgreSQL install prefix (set by ./configure --prefix=...)
PG_INSTALL="$WORKSPACE_DIR/pgv-svs-dev-scripts/pgsql_install"

# Path to pg_config from your PostgreSQL install
export PG_CONFIG="$PG_INSTALL/bin/pg_config"

# Add PostgreSQL binaries to PATH (for postgres, psql, pg_ctl, etc.)
export PATH="$PG_INSTALL/bin:$WORKSPACE_DIR/postgres/src/tools/pgindent:$PATH"

# Add PostgreSQL libraries to dynamic linker path (prevents loading system libpq)
export LD_LIBRARY_PATH="$PG_INSTALL/lib:$LD_LIBRARY_PATH"

# Port used by the dev server (matches pgv-svs-dev-scripts/config)
export PGPORT=${PGPORT:-7435}

# =============================================================================
# SVS LIBRARY CONFIGURATION
# =============================================================================

# SVS install directory (produced by docs/build_guide/build_svs.sh)
export SVS_INSTALL="$WORKSPACE_DIR/svs_install_public"

# Add SVS C library to dynamic linker path
export LD_LIBRARY_PATH="$SVS_INSTALL/lib:$LD_LIBRARY_PATH"

# =============================================================================
# PERL / TAP TEST CONFIGURATION
# =============================================================================

# For from-source builds, PGXS does not automatically add the Postgres source
# tree's Perl modules to @INC.  Setting PERL5LIB here makes PostgreSQL::Test::*
# available to 'make prove_installcheck' without modifying the Makefile.
# The shim in test/perl (already on @INC via the Makefile's PROVE_FLAGS) is
# found before these paths, so it can intercept and delegate correctly.
export PERL5LIB="$WORKSPACE_DIR/postgres/src/test/perl${PERL5LIB:+:$PERL5LIB}"

# PGXS adds $PG_INSTALL/lib/pgxs/src/test/perl to @INC *before* ./test/perl,
# so if the real PostgreSQL::Test::* modules exist there they win over the stubs.
# For a from-source install that directory is absent; symlink it to the source tree.
_PGXS_PERL_DIR="$PG_INSTALL/lib/pgxs/src/test/perl"
_PG_SRC_PERL_DIR="$WORKSPACE_DIR/postgres/src/test/perl"
if [ ! -e "$_PGXS_PERL_DIR" ] && [ -d "$_PG_SRC_PERL_DIR" ]; then
    ln -s "$_PG_SRC_PERL_DIR" "$_PGXS_PERL_DIR"
fi
unset _PGXS_PERL_DIR _PG_SRC_PERL_DIR

# =============================================================================
# INTEL MKL CONFIGURATION (Optional - for optimized BLAS operations)
# =============================================================================

# If you have Intel oneAPI MKL installed, set this path
# Common locations:
#   - /opt/intel/oneapi/mkl/latest
#   - $HOME/intel/oneapi/mkl/latest
# Comment out if not using MKL
export MKLROOT="/opt/intel/oneapi/mkl/latest"

# Add MKL libraries to dynamic linker path (only if MKLROOT is set)
if [ -n "$MKLROOT" ] && [ -d "$MKLROOT/lib/intel64" ]; then
    export LD_LIBRARY_PATH="$MKLROOT/lib/intel64:$LD_LIBRARY_PATH"
fi

# =============================================================================
# VERIFICATION
# =============================================================================

# Function to verify environment is correctly set up
verify_env() {
    local errors=0
    
    echo "Verifying pgvector-optimizations environment..."
    echo
    
    # Check PostgreSQL
    if [ ! -x "$PG_CONFIG" ]; then
        echo "❌ ERROR: pg_config not found at: $PG_CONFIG"
        echo "   Build PostgreSQL or update PG_CONFIG in env.sh"
        errors=$((errors + 1))
    else
        echo "✓ PostgreSQL: $($PG_CONFIG --version) (PGPORT=$PGPORT)"
    fi
    
    # Check SVS
    if [ ! -d "$SVS_INSTALL" ]; then
        echo "❌ ERROR: SVS install directory not found at: $SVS_INSTALL"
        echo "   Run docs/build_guide/build_svs.sh or update SVS_INSTALL in env.sh"
        errors=$((errors + 1))
    elif [ ! -f "$SVS_INSTALL/lib/libsvs_c_api.so" ] && [ ! -f "$SVS_INSTALL/lib/libsvs_c_api.dylib" ]; then
        echo "❌ ERROR: SVS C library not found at: $SVS_INSTALL/lib/"
        echo "   Run docs/build_guide/build_svs.sh"
        errors=$((errors + 1))
    else
        echo "✓ SVS: $SVS_INSTALL"
    fi
    
    # Check TAP test infrastructure
    if [ ! -d "$WORKSPACE_DIR/postgres/src/test/perl/PostgreSQL/Test" ]; then
        echo "⚠ WARNING: PostgreSQL Perl test modules not found at:"
        echo "   $WORKSPACE_DIR/postgres/src/test/perl/PostgreSQL/Test"
        echo "   'make prove_installcheck' will not work without the postgres source tree"
    else
        echo "✓ TAP Perl modules: $WORKSPACE_DIR/postgres/src/test/perl"
    fi
    # Check pgxs perl symlink (needed so the real modules precede the stubs in @INC)
    if [ ! -e "$PG_INSTALL/lib/pgxs/src/test/perl" ]; then
        echo "⚠ WARNING: pgxs perl symlink missing: $PG_INSTALL/lib/pgxs/src/test/perl"
        echo "   Re-source env.sh to create it automatically"
    else
        echo "✓ PGXS perl symlink: $PG_INSTALL/lib/pgxs/src/test/perl"
    fi

    # Check MKL (optional)
    if [ -n "$MKLROOT" ]; then
        if [ ! -d "$MKLROOT" ]; then
            echo "⚠ WARNING: MKLROOT set but directory not found: $MKLROOT"
            echo "   MKL optimizations will not be available"
        else
            echo "✓ Intel MKL: $MKLROOT"
        fi
    else
        echo "ℹ Intel MKL: Not configured (optional)"
    fi
    
    echo
    if [ $errors -eq 0 ]; then
        echo "✓ Environment verified successfully!"
        echo
        echo "You can now build pgvector-optimizations:"
        echo "  make clean && make -j $(nproc) && make install"
        echo "  make installcheck                         # SQL regression tests"
        echo "  make prove_installcheck                   # all TAP tests"
        echo "  make prove_installcheck PROVE_TESTS=test/t/045_vamana_worker_tests.pl"
        return 0
    else
        echo
        echo "❌ Found $errors error(s). Please fix the issues above."
        echo "   Edit docs/env.sh to update paths for your workspace."
        return 1
    fi
}

# =============================================================================
# AUTO-RUN VERIFICATION
# =============================================================================

# If sourced interactively, run verification
# (Skip if being sourced by a script that will handle errors)
if [ -n "${BASH_VERSION:-}" ] && [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    verify_env
fi

# Export verification function so scripts can call it
export -f verify_env
