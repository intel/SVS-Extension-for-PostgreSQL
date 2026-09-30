#!/usr/bin/env bash
#
# Build PostgreSQL, SVS, pgvector and the svs extension from a clean machine,
# then run the extension's own test suites against what was just built.
#
# Dependency builds are delegated to docs/build_guide/*.sh, the same scripts
# a developer runs locally and codeql.yml runs in CI, so there is one place
# that knows how to build PostgreSQL/SVS/pgvector rather than two. This
# script only adds the CI-specific test-execution steps those scripts don't
# cover: building test/modules/*/, the hardening check, and running the SQL
# and TAP suites against the result.
#
# Usage: ci/build_and_test.sh <command>
#   deps            install OS packages needed by every later step
#   build-postgres  build and install PostgreSQL via docs/build_guide, with
#                   TAP and injection points enabled, plus the
#                   injection_points test module (needed by TAP, not
#                   installed by docs/build_guide's own install)
#   build-svs       build the SVS C API bindings via docs/build_guide,
#                   pinned to a known-good nightly release tarball
#   build-pgvector  build and install vanilla pgvector via docs/build_guide
#   build-extension build and install this extension via docs/build_guide
#                   (WERROR=1)
#   build-modules   build and install every test/modules/*/ PGXS module
#   hardening-check verify the SDL429 protections in the installed svs.so
#   test-sql        start a server with ci/test_server.conf and run 'make installcheck'
#   test-tap        run 'make prove_installcheck'
#   all             run every step above in order
#
# Environment (all optional, defaults suit a fresh checkout):
#   PG_PORT                  port for the test-sql server        (default: 55432)
#   PROVE_FLAGS              extra flags passed to 'prove' (e.g. '-j4')
#   PG_CONFIGURE_EXTRA_ARGS  configure flags for build-postgres
#                            (default: --enable-tap-tests --enable-injection-points)
#   SVS_URL                  SVS release tarball for build-svs (default: pinned nightly)
#
# All dependency install locations (PostgreSQL, SVS, pgvector) are controlled
# by docs/build_guide/config, not by anything in this script. Edit that file,
# or export PG_CONFIG/SVS_URL/etc before sourcing it, to change them.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_GUIDE_DIR="${REPO_ROOT}/docs/build_guide"

# Pinned nightly SVS release tarball. bindings/c at SVS_BRANCH (see
# docs/build_guide/config) calls a core-library method that the CMakeLists'
# own default download predates, so that default fails to compile; this pin
# is a known-good match. Overridable via SVS_URL for a one-off bump.
DEFAULT_SVS_URL="https://github.com/intel/ScalableVectorSearch/releases/download/nightly/svs-shared-library-nightly-2026-09-15-1529.tar.gz"

# CI-specific test-run scratch: the running data directory and log for
# test-sql. Dependency install locations are owned by docs/build_guide/config,
# not by this variable.
WORKDIR="${WORKDIR:-${REPO_ROOT}/ci/.workdir}"
PG_DATA_DIR="${WORKDIR}/pgdata"
PG_LOG_FILE="${WORKDIR}/postgres.log"
PG_PORT="${PG_PORT:-55432}"

PROVE_FLAGS="${PROVE_FLAGS:-}"

banner() {
	printf '\n=== %s ===\n' "$1"
}

load_config() {
	# shellcheck source=/dev/null
	source "${BUILD_GUIDE_DIR}/config"
}

step_deps() {
	banner "deps: installing OS packages"
	local sudo_cmd=""
	if [ "$(id -u)" -ne 0 ]; then
		sudo_cmd="sudo"
	fi
	${sudo_cmd} apt-get update -qq
	${sudo_cmd} apt-get install -y --no-install-recommends \
		build-essential bison flex \
		libreadline-dev zlib1g-dev libicu-dev \
		pkg-config cmake git ca-certificates \
		gcc g++ \
		perl libipc-run-perl \
		binutils
}

step_build_postgres() {
	banner "build-postgres"
	load_config
	if [ -x "${PG_CONFIG}" ]; then
		echo "found existing pg_config at ${PG_CONFIG}, skipping build"
	else
		PG_CONFIGURE_EXTRA_ARGS="${PG_CONFIGURE_EXTRA_ARGS:---enable-tap-tests --enable-injection-points}" \
			bash "${BUILD_GUIDE_DIR}/install_postgres.sh"
	fi
	# CREATE EXTENSION injection_points needs this test module. Neither
	# install_postgres.sh nor a plain top-level 'make install' builds or
	# installs src/test/modules; it is specific to our TAP needs.
	make -C "${PGSQL_SRC_DIR}/src/test/modules/injection_points"
	make -C "${PGSQL_SRC_DIR}/src/test/modules/injection_points" install
}

step_build_svs() {
	banner "build-svs"
	load_config
	if [ -f "${SVS_INSTALL_DIR}/lib/libsvs_c_api.so" ]; then
		echo "found existing SVS install at ${SVS_INSTALL_DIR}, skipping build"
		return 0
	fi
	SVS_URL="${SVS_URL:-${DEFAULT_SVS_URL}}" bash "${BUILD_GUIDE_DIR}/build_svs.sh"
}

step_build_pgvector() {
	banner "build-pgvector"
	load_config
	if [ ! -x "${PG_CONFIG}" ]; then
		echo "pg_config not found at ${PG_CONFIG}; run build-postgres first" >&2
		exit 1
	fi
	bash "${BUILD_GUIDE_DIR}/build_pgvector_vanilla.sh"
}

step_build_extension() {
	banner "build-extension (WERROR=1)"
	load_config
	if [ ! -x "${PG_CONFIG}" ]; then
		echo "pg_config not found at ${PG_CONFIG}; run build-postgres first" >&2
		exit 1
	fi
	if [ ! -f "${SVS_INSTALL_DIR}/lib/libsvs_c_api.so" ]; then
		echo "SVS library not found at ${SVS_INSTALL_DIR}; run build-svs first" >&2
		exit 1
	fi
	make -C "${REPO_ROOT}" clean PG_CONFIG="${PG_CONFIG}" SVS_INSTALL="${SVS_INSTALL_DIR}"
	export WERROR=1
	bash "${BUILD_GUIDE_DIR}/build_svs_extension.sh"
}

step_build_modules() {
	banner "build-modules: test/modules/*"
	load_config
	if [ ! -x "${PG_CONFIG}" ]; then
		echo "pg_config not found at ${PG_CONFIG}; run build-postgres first" >&2
		exit 1
	fi
	for moddir in "${REPO_ROOT}"/test/modules/*/; do
		local name
		name="$(basename "${moddir}")"
		echo "  building test module: ${name}"
		make -C "${moddir}" PG_CONFIG="${PG_CONFIG}"
		make -C "${moddir}" install PG_CONFIG="${PG_CONFIG}"
	done
}

step_hardening_check() {
	banner "hardening-check: svs.so"
	load_config
	local libdir
	libdir="$("${PG_CONFIG}" --pkglibdir)"
	make -C "${REPO_ROOT}" hardening-check PG_CONFIG="${PG_CONFIG}" SVS_INSTALL="${SVS_INSTALL_DIR}" \
		SVS_SO="${libdir}/svs.so"
}

start_server() {
	local conf="$1"
	mkdir -p "${WORKDIR}"
	if [ ! -d "${PG_DATA_DIR}" ]; then
		"${PGSQL_INSTALL_DIR}/bin/initdb" -D "${PG_DATA_DIR}" -U postgres -A trust >/dev/null
	fi
	cp "${conf}" "${PG_DATA_DIR}/postgresql.conf"
	"${PGSQL_INSTALL_DIR}/bin/pg_ctl" -D "${PG_DATA_DIR}" -l "${PG_LOG_FILE}" \
		-o "-p ${PG_PORT}" -w start
}

stop_server() {
	"${PGSQL_INSTALL_DIR}/bin/pg_ctl" -D "${PG_DATA_DIR}" -m immediate stop || true
}

step_test_sql() {
	banner "test-sql: make installcheck"
	load_config
	if [ ! -x "${PG_CONFIG}" ]; then
		echo "pg_config not found at ${PG_CONFIG}; run build-postgres first" >&2
		exit 1
	fi
	trap stop_server EXIT
	start_server "${SCRIPT_DIR}/test_server.conf"
	export PATH="${PGSQL_INSTALL_DIR}/bin:${PATH}"
	export PGPORT="${PG_PORT}"
	export PGHOST=localhost
	export PGUSER=postgres
	"${PGSQL_INSTALL_DIR}/bin/psql" -v ON_ERROR_STOP=1 -c \
		"SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE database = 'contrib_regression';" \
		postgres || true
	# WITH (FORCE) (PG 13+): the background worker can reconnect to
	# contrib_regression the moment it is enrolled, racing a plain DROP.
	"${PGSQL_INSTALL_DIR}/bin/psql" -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS contrib_regression WITH (FORCE);" postgres
	make -C "${REPO_ROOT}" installcheck \
		PG_CONFIG="${PG_CONFIG}" SVS_INSTALL="${SVS_INSTALL_DIR}" PGPORT="${PG_PORT}"
	stop_server
	trap - EXIT
}

step_test_tap() {
	banner "test-tap: make prove_installcheck"
	load_config
	if [ ! -x "${PG_CONFIG}" ]; then
		echo "pg_config not found at ${PG_CONFIG}; run build-postgres first" >&2
		exit 1
	fi
	make -C "${REPO_ROOT}" prove_installcheck \
		PG_CONFIG="${PG_CONFIG}" SVS_INSTALL="${SVS_INSTALL_DIR}" \
		PROVE_FLAGS="${PROVE_FLAGS}" ${PROVE_TESTS:+PROVE_TESTS="${PROVE_TESTS}"}
}

step_all() {
	step_deps
	step_build_postgres
	step_build_svs
	step_build_pgvector
	step_build_extension
	step_build_modules
	step_hardening_check
	step_test_sql
	step_test_tap
}

cmd="${1:-}"
case "${cmd}" in
	deps) step_deps ;;
	build-postgres) step_build_postgres ;;
	build-svs) step_build_svs ;;
	build-pgvector) step_build_pgvector ;;
	build-extension) step_build_extension ;;
	build-modules) step_build_modules ;;
	hardening-check) step_hardening_check ;;
	test-sql) step_test_sql ;;
	test-tap) step_test_tap ;;
	all) step_all ;;
	*)
		echo "usage: $0 {deps|build-postgres|build-svs|build-pgvector|build-extension|build-modules|hardening-check|test-sql|test-tap|all}" >&2
		exit 1
		;;
esac
