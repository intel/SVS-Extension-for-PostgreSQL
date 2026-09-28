#!/usr/bin/env bash
#
# Build PostgreSQL, SVS, pgvector and the svs extension from a clean machine,
# then run the extension's own test suites against what was just built.
#
# Runs identically on a developer's machine and in CI: every path lives under
# WORKDIR, nothing is written outside it or to a shared install, and each
# sub-command can be run on its own once its dependencies exist.
#
# Usage: ci/build_and_test.sh <command>
#   deps            install OS packages needed by every later step
#   build-postgres  build and install PostgreSQL from source, with TAP and
#                   injection points enabled, plus the injection_points test
#                   module (needed by TAP, not installed by a plain 'make install')
#   build-svs       build the SVS C API bindings at the pinned commit
#   build-pgvector  build and install vanilla pgvector
#   build-extension build and install this extension (WERROR=1)
#   build-modules   build and install every test/modules/*/ PGXS module
#   hardening-check verify the SDL429 protections in the installed svs.so
#   test-sql        start a server with ci/test_server.conf and run 'make installcheck'
#   test-tap        run 'make prove_installcheck'
#   all             run every step above in order
#
# Environment (all optional, defaults suit a fresh checkout):
#   WORKDIR          scratch directory for sources and installs (default: ./ci/.workdir)
#   PG_VERSION       PostgreSQL git tag to build                (default: REL_18_1)
#   SVS_REPO         SVS git remote                              (default: public GitHub)
#   SVS_COMMIT       pinned commit on SVS_REPO's dev/c-api branch (see ci/SVS_COMMIT)
#   PGVECTOR_TAG     vanilla pgvector tag                        (default: v0.8.2)
#   NPROC            parallel build jobs                         (default: nproc)
#   PROVE_FLAGS      extra flags passed to 'prove' (e.g. '-j4')

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

WORKDIR="${WORKDIR:-${REPO_ROOT}/ci/.workdir}"
PG_VERSION="${PG_VERSION:-REL_18_1}"
SVS_REPO="${SVS_REPO:-https://github.com/intel/ScalableVectorSearch.git}"
SVS_COMMIT="${SVS_COMMIT:-$(cat "${SCRIPT_DIR}/SVS_COMMIT" 2>/dev/null || echo ffe9cec02864e78b980e7ae66c73bd4a6a4aa11f)}"
# bindings/c at SVS_COMMIT calls a core-library method (estimate_memory_footprint)
# that the CMakeLists' own default download (the versioned v0.4.0 release asset)
# predates, so that default fails to compile. SVS_URL pins the prebuilt core
# tarball this pin actually needs. See ci/SVS_URL for the currently known-good
# asset and why it is a "nightly" name rather than a stable release tag.
SVS_URL="${SVS_URL:-$(cat "${SCRIPT_DIR}/SVS_URL" 2>/dev/null || true)}"
PGVECTOR_TAG="${PGVECTOR_TAG:-v0.8.2}"
NPROC="${NPROC:-$(nproc)}"
PROVE_FLAGS="${PROVE_FLAGS:-}"

PG_SRC_DIR="${WORKDIR}/postgres"
PG_INSTALL_DIR="${WORKDIR}/pgsql_install"
PG_CONFIG="${PG_INSTALL_DIR}/bin/pg_config"

SVS_SRC_DIR="${WORKDIR}/ScalableVectorSearch"
SVS_BUILD_DIR="${SVS_SRC_DIR}/build"
SVS_INSTALL_DIR="${WORKDIR}/svs_install"

PGVECTOR_SRC_DIR="${WORKDIR}/pgvector-vanilla"

PG_DATA_DIR="${WORKDIR}/pgdata"
PG_LOG_FILE="${WORKDIR}/postgres.log"
PG_PORT="${PG_PORT:-55432}"

banner() {
	printf '\n=== %s ===\n' "$1"
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
	banner "build-postgres: ${PG_VERSION}"
	if [ -x "${PG_CONFIG}" ]; then
		echo "found existing pg_config at ${PG_CONFIG}, skipping build"
		return 0
	fi
	mkdir -p "${WORKDIR}"
	if [ ! -d "${PG_SRC_DIR}" ]; then
		git clone --depth 1 --branch "${PG_VERSION}" \
			https://github.com/postgres/postgres.git "${PG_SRC_DIR}"
	fi
	(
		cd "${PG_SRC_DIR}"
		./configure --prefix="${PG_INSTALL_DIR}" \
			--enable-tap-tests --enable-injection-points
		make -j"${NPROC}"
		make install
		# CREATE EXTENSION injection_points needs this test module. A plain
		# top-level 'make install' does not build or install src/test/modules.
		make -C src/test/modules/injection_points
		make -C src/test/modules/injection_points install
	)
}

step_build_svs() {
	banner "build-svs: SVS C API bindings at ${SVS_COMMIT}"
	if [ -f "${SVS_INSTALL_DIR}/lib/libsvs_c_api.so" ]; then
		echo "found existing SVS install at ${SVS_INSTALL_DIR}, skipping build"
		return 0
	fi
	mkdir -p "${WORKDIR}"
	if [ ! -d "${SVS_SRC_DIR}" ]; then
		git clone --recurse-submodules "${SVS_REPO}" "${SVS_SRC_DIR}"
	fi
	(
		cd "${SVS_SRC_DIR}"
		git fetch --depth 1 origin "${SVS_COMMIT}"
		git checkout --detach "${SVS_COMMIT}"
	)
	# SVS_RUNTIME_ENABLE_LVQ_LEANVEC=ON does not build the SVS core from this
	# checkout: bindings/c/CMakeLists.txt fetches a prebuilt core library from
	# a GitHub release via FetchContent(SVS_URL) and only compiles the thin C
	# API wrapper here, so no MKL install or SVS-core source build is needed.
	# CMakeLists.txt's own default for SVS_URL depends on the exact compiler
	# version and, on every compiler this project targets, resolves to the
	# versioned v0.4.0 release asset. That asset predates a core-library
	# method this pinned bindings/c commit calls, so the default fails to
	# compile; SVS_URL above overrides it with a tarball known to match.
	local svs_url_arg=()
	if [ -n "${SVS_URL}" ]; then
		svs_url_arg=(-DSVS_URL="${SVS_URL}")
	fi
	cmake -S "${SVS_SRC_DIR}/bindings/c" \
		-B "${SVS_BUILD_DIR}" \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_POSITION_INDEPENDENT_CODE=ON \
		-DSVS_RUNTIME_ENABLE_LVQ_LEANVEC=ON \
		-DCMAKE_INSTALL_PREFIX="${SVS_INSTALL_DIR}" \
		"${svs_url_arg[@]}"
	cmake --build "${SVS_BUILD_DIR}" -j"${NPROC}"
	cmake --install "${SVS_BUILD_DIR}"
}

step_build_pgvector() {
	banner "build-pgvector: ${PGVECTOR_TAG}"
	if [ ! -x "${PG_CONFIG}" ]; then
		echo "pg_config not found at ${PG_CONFIG}; run build-postgres first" >&2
		exit 1
	fi
	if [ ! -d "${PGVECTOR_SRC_DIR}" ]; then
		git clone --depth 1 --branch "${PGVECTOR_TAG}" \
			https://github.com/pgvector/pgvector.git "${PGVECTOR_SRC_DIR}"
	fi
	make -C "${PGVECTOR_SRC_DIR}" -j"${NPROC}" PG_CONFIG="${PG_CONFIG}"
	make -C "${PGVECTOR_SRC_DIR}" install PG_CONFIG="${PG_CONFIG}"
}

step_build_extension() {
	banner "build-extension: svs (WERROR=1)"
	if [ ! -x "${PG_CONFIG}" ]; then
		echo "pg_config not found at ${PG_CONFIG}; run build-postgres first" >&2
		exit 1
	fi
	if [ ! -f "${SVS_INSTALL_DIR}/lib/libsvs_c_api.so" ]; then
		echo "SVS library not found at ${SVS_INSTALL_DIR}; run build-svs first" >&2
		exit 1
	fi
	make -C "${REPO_ROOT}" clean PG_CONFIG="${PG_CONFIG}" SVS_INSTALL="${SVS_INSTALL_DIR}"
	make -C "${REPO_ROOT}" -j"${NPROC}" WERROR=1 PG_CONFIG="${PG_CONFIG}" SVS_INSTALL="${SVS_INSTALL_DIR}"
	make -C "${REPO_ROOT}" install PG_CONFIG="${PG_CONFIG}" SVS_INSTALL="${SVS_INSTALL_DIR}"
}

step_build_modules() {
	banner "build-modules: test/modules/*"
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
	local libdir
	libdir="$("${PG_CONFIG}" --pkglibdir)"
	make -C "${REPO_ROOT}" hardening-check PG_CONFIG="${PG_CONFIG}" SVS_INSTALL="${SVS_INSTALL_DIR}" \
		SVS_SO="${libdir}/svs.so"
}

start_server() {
	local conf="$1"
	mkdir -p "${WORKDIR}"
	if [ ! -d "${PG_DATA_DIR}" ]; then
		"${PG_INSTALL_DIR}/bin/initdb" -D "${PG_DATA_DIR}" -U postgres -A trust >/dev/null
	fi
	cp "${conf}" "${PG_DATA_DIR}/postgresql.conf"
	"${PG_INSTALL_DIR}/bin/pg_ctl" -D "${PG_DATA_DIR}" -l "${PG_LOG_FILE}" \
		-o "-p ${PG_PORT}" -w start
}

stop_server() {
	"${PG_INSTALL_DIR}/bin/pg_ctl" -D "${PG_DATA_DIR}" -m immediate stop || true
}

step_test_sql() {
	banner "test-sql: make installcheck"
	if [ ! -x "${PG_CONFIG}" ]; then
		echo "pg_config not found at ${PG_CONFIG}; run build-postgres first" >&2
		exit 1
	fi
	trap stop_server EXIT
	start_server "${SCRIPT_DIR}/test_server.conf"
	export PATH="${PG_INSTALL_DIR}/bin:${PATH}"
	export PGPORT="${PG_PORT}"
	export PGHOST=localhost
	export PGUSER=postgres
	"${PG_INSTALL_DIR}/bin/psql" -v ON_ERROR_STOP=1 -c \
		"SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE database = 'contrib_regression';" \
		postgres || true
	# WITH (FORCE) (PG 13+): the background worker can reconnect to
	# contrib_regression the moment it is enrolled, racing a plain DROP.
	"${PG_INSTALL_DIR}/bin/psql" -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS contrib_regression WITH (FORCE);" postgres
	make -C "${REPO_ROOT}" installcheck \
		PG_CONFIG="${PG_CONFIG}" SVS_INSTALL="${SVS_INSTALL_DIR}" PGPORT="${PG_PORT}"
	stop_server
	trap - EXIT
}

step_test_tap() {
	banner "test-tap: make prove_installcheck"
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
