#!/bin/bash
# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: PostgreSQL

# check-rpath.sh — library-integrity gate for the packaged svs extension.
#
# Verifies three properties of the shared objects that ship to customers:
#
#   A1  libsvs_c_api.so has no dynamic dependency on Intel MKL or the Intel
#       OpenMP runtime. The shipping flavor of the SVS library links MKL
#       statically; a dynamic libmkl*/libiomp* DT_NEEDED entry means the link
#       flavor changed, which both breaks the self-contained-artifact promise
#       and opens a library-substitution path via a writable directory on the
#       loader search path.
#
#   A2  svs.so's run-time library search path contains no absolute paths from
#       the machine that built it (developer home directories, scratch
#       filesystems), and is otherwise $ORIGIN-relative or empty. Such a path
#       is attacker-writable on a customer host -- often it does not exist at
#       all, so an unprivileged user can create it and plant a substitute
#       libsvs_c_api.so.
#
#   A3  libsvs_c_api.so's run-time library search path gets the same two
#       checks as A2 (no build-machine paths, $ORIGIN-relative or empty),
#       plus a check for leftover MKL build-environment paths (an expanded or
#       unexpanded $MKLROOT, an oneAPI toolkit prefix). Both objects ship to
#       the same customer host and have the same substitution exposure, so
#       neither gets a narrower check than the other.
#
# IMPORTANT -- run this against the PACKAGED artifact, never a local build.
# A developer build deliberately carries an absolute -Wl,-rpath to the
# uninstalled SVS tree so the extension can find it without LD_LIBRARY_PATH,
# and the PostgreSQL build infrastructure adds a second absolute rpath to the
# target libdir. Both are correct for development and both fail A2. The
# properties above are claims about the shipping artifact only, so the script
# has no default target: you must name the artifact explicitly.
#
# Usage:
#   check-rpath.sh --package-dir DIR      locate both objects under DIR
#   check-rpath.sh --svs-so PATH --capi-so PATH
#   check-rpath.sh --self-test            verify the checks can still fail
#
# Exit codes (stable; intended for a CI gate):
#   0  all assertions passed
#   1  at least one assertion failed -- do not publish the artifact
#   2  usage error (no target named, or unreadable target)
#   3  a required inspection tool is missing; the artifact was NOT checked
#   4  a named object is missing or is not an ELF shared object
#   5  --self-test found a check that no longer detects its own bad input
#
# Exit 3 is deliberately distinct from 0. A missing readelf/patchelf must never
# be reported as a pass: an unchecked artifact is not a clean artifact.

set -u
set -o pipefail

readonly PROG="${0##*/}"

# ---------------------------------------------------------------------------
# Output helpers. Every verdict is emitted on one line as
#   RESULT <id> <PASS|FAIL> <message>
# so a CI job can grep the log without parsing prose. Under GitHub Actions we
# additionally raise a workflow annotation for each failure.
# ---------------------------------------------------------------------------

fail_count=0
pass_count=0

log()  { printf '%s\n' "$*"; }
err()  { printf '%s: %s\n' "$PROG" "$*" >&2; }

result_pass() {
    # $1 = assertion id, $2... = message
    local id=$1; shift
    printf 'RESULT %s PASS %s\n' "$id" "$*"
    pass_count=$((pass_count + 1))
}

result_fail() {
    local id=$1; shift
    printf 'RESULT %s FAIL %s\n' "$id" "$*"
    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        printf '::error title=%s::%s\n' "$id" "$*"
    fi
    fail_count=$((fail_count + 1))
}

# ---------------------------------------------------------------------------
# Predicates.
#
# Each predicate is a pure function from text to a list of offending items on
# stdout: empty output means the property holds. They take strings rather than
# file paths so that --self-test can drive them with known-bad input and prove
# they still fire. A check that cannot be shown to fail is not evidence of
# anything.
# ---------------------------------------------------------------------------

# A1: offending DT_NEEDED lines. Input is raw "readelf -d" output.
#
# The pattern is anchored on the "lib" prefix on purpose. Intel's OpenMP
# runtime is libiomp5.so; GNU's is libgomp.so.1 and is an expected, benign
# dependency of the shipping library. A looser "omp" pattern matches libgomp
# and would fail every artifact. Do not relax "libiomp" to "iomp" or "omp".
mkl_needed_violations() {
    printf '%s\n' "$1" \
        | grep -E '\(NEEDED\)' \
        | grep -E 'libmkl|libiomp' \
        || true
}

# A2: run-path entries that name an absolute path on the build machine.
# Split the colon-separated run path and test each entry independently, so one
# bad entry in an otherwise reasonable list is still caught.
devpath_violations() {
    local rpath=$1 entry
    [[ -z "$rpath" ]] && return 0
    local IFS=:
    for entry in $rpath; do
        [[ -z "$entry" ]] && continue
        case "$entry" in
            /home/*|/Users/*|/root/*|/data[0-9]*|/data[0-9]*/*|/scratch/*|/tmp/*|/var/tmp/*)
                printf '%s\n' "$entry" ;;
            *"/workspace/"*|*"/build/"*|*"/builddir/"*)
                printf '%s\n' "$entry" ;;
        esac
    done
    return 0
}

# A2: run-path entries that are not $ORIGIN-relative. The pass criterion for a
# production build is "$ORIGIN/../lib or an empty string", so any absolute
# entry is a violation even when it is not a developer path -- an absolute
# system path still pins the artifact to one layout and is reported here
# rather than silently tolerated.
#
# The single quotes below are required: "$ORIGIN" is a literal four-character
# token stored in the ELF dynamic section and expanded by the loader, not a
# shell variable. Expanding it here would compare against the empty string and
# make the check accept anything.
# shellcheck disable=SC2016
nonrelative_rpath_violations() {
    local rpath=$1 entry
    [[ -z "$rpath" ]] && return 0
    local IFS=:
    for entry in $rpath; do
        [[ -z "$entry" ]] && continue
        case "$entry" in
            '$ORIGIN'|'$ORIGIN/'*|'${ORIGIN}'|'${ORIGIN}/'*) ;;
            *) printf '%s\n' "$entry" ;;
        esac
    done
    return 0
}

# A3: run-path entries derived from the MKL / oneAPI build environment, either
# as an unexpanded variable reference or as the expanded toolkit prefix.
#
# Single quotes again intentional: we are matching the literal text "$MKLROOT"
# as it appears in a badly-built artifact's dynamic section.
# shellcheck disable=SC2016
mklroot_violations() {
    local rpath=$1 entry
    [[ -z "$rpath" ]] && return 0
    local IFS=:
    for entry in $rpath; do
        [[ -z "$entry" ]] && continue
        case "$entry" in
            *'$MKLROOT'*|*'${MKLROOT}'*|*'$ONEAPI_ROOT'*|*'${ONEAPI_ROOT}'*)
                printf '%s\n' "$entry" ;;
            /opt/intel/*|*/oneapi/*|*/mkl/*|*/mkl)
                printf '%s\n' "$entry" ;;
        esac
    done
    return 0
}

# ---------------------------------------------------------------------------
# Tool discovery. Hard failure, never a skip: if we cannot inspect the
# artifact we say so and exit 3.
# ---------------------------------------------------------------------------

READELF=""
PATCHELF=""

discover_tools() {
    READELF=$(command -v readelf 2>/dev/null || true)
    PATCHELF=$(command -v patchelf 2>/dev/null || true)

    if [[ -z "$READELF" ]]; then
        err "readelf not found on PATH."
        err "readelf is required to read DT_NEEDED. Install binutils."
        err "Refusing to report a pass on an artifact that was never inspected."
        exit 3
    fi

    if [[ -z "$PATCHELF" ]]; then
        # readelf reads the same DT_RUNPATH/DT_RPATH dynamic-section tags that
        # patchelf --print-rpath reports, so the run-path assertions still run
        # at full strength. Recorded as a notice, not a skip.
        log "NOTICE patchelf not found; reading DT_RUNPATH/DT_RPATH via readelf instead."
    fi
}

# ---------------------------------------------------------------------------
# ELF readers.
# ---------------------------------------------------------------------------

# A named object that is missing or not an ELF file means the artifact is
# malformed, which is a different condition from "inspected and found bad".
# Exit 4 immediately rather than continuing: reporting a per-assertion verdict
# on a file we could not read would be misleading, and a partially-inspected
# artifact must never yield exit 0.
require_elf() {
    local so=$1 label=$2
    if [[ ! -e "$so" ]]; then
        result_fail "$label" "object not found: $so"
        exit 4
    fi
    if [[ ! -r "$so" ]]; then
        result_fail "$label" "object not readable: $so"
        exit 4
    fi
    if ! "$READELF" -h "$so" >/dev/null 2>&1; then
        result_fail "$label" "not an ELF object: $so"
        exit 4
    fi
    return 0
}

read_needed() {
    "$READELF" -d "$1" 2>/dev/null
}

# Extract the effective run-time library search path from "readelf -d" output.
#
# BOTH dynamic tags must be matched. Current linkers emit DT_RUNPATH (readelf
# prints "(RUNPATH)"), but the legacy DT_RPATH ("(RPATH)") is still what you get
# from an older toolchain or from an explicit -Wl,--disable-new-dtags, and the
# loader honors it. Matching only RUNPATH would report an empty run path -- and
# therefore a clean pass -- for a binary that records a developer path in
# DT_RPATH. That false pass is the specific failure this function exists to
# avoid; see the RPATH-only case in the self-test.
#
# Precedence follows the loader and "patchelf --print-rpath": when both tags
# are present DT_RUNPATH wins and DT_RPATH is ignored.
parse_rpath_from_dyn() {
    local dyn=$1 runpath rpath
    runpath=$(printf '%s\n' "$dyn" | sed -n 's/.*(RUNPATH)[^[]*\[\(.*\)\].*/\1/p' | head -n 1)
    if [[ -n "$runpath" ]]; then
        printf '%s\n' "$runpath"
        return 0
    fi
    rpath=$(printf '%s\n' "$dyn" | sed -n 's/.*(RPATH)[^[]*\[\(.*\)\].*/\1/p' | head -n 1)
    printf '%s\n' "$rpath"
}

# Print the effective run-time library search path, matching what the loader
# uses and what "patchelf --print-rpath" reports. Prints an empty line when
# neither tag exists.
read_rpath() {
    local so=$1
    if [[ -n "$PATCHELF" ]]; then
        "$PATCHELF" --print-rpath "$so" 2>/dev/null
        return 0
    fi
    parse_rpath_from_dyn "$("$READELF" -d "$so" 2>/dev/null)"
}

# ---------------------------------------------------------------------------
# Assertions.
# ---------------------------------------------------------------------------

check_a1_no_dynamic_mkl() {
    local so=$1 dyn needed bad
    require_elf "$so" A1

    dyn=$(read_needed "$so")
    needed=$(printf '%s\n' "$dyn" | grep -E '\(NEEDED\)' || true)
    log "INFO A1 DT_NEEDED of ${so}:"
    if [[ -n "$needed" ]]; then
        printf '%s\n' "$needed" | sed 's/^/INFO   /'
    else
        log "INFO   (none)"
    fi

    bad=$(mkl_needed_violations "$dyn")
    if [[ -n "$bad" ]]; then
        result_fail A1 "dynamic MKL/Intel-OpenMP dependency in $(basename "$so"); MKL must be statically linked in the shipping flavor"
        printf '%s\n' "$bad" | sed 's/^/FAIL   offending: /'
    else
        result_pass A1 "no libmkl*/libiomp* DT_NEEDED in $(basename "$so")"
    fi
}

check_a2_svs_so_rpath() {
    local so=$1 rpath bad_dev bad_rel
    require_elf "$so" A2

    rpath=$(read_rpath "$so")
    log "INFO A2 run path of ${so}: [${rpath}]"

    bad_dev=$(devpath_violations "$rpath")
    if [[ -n "$bad_dev" ]]; then
        result_fail A2a "build-machine path in run path of $(basename "$so"); attacker-writable on a customer host"
        printf '%s\n' "$bad_dev" | sed 's/^/FAIL   offending entry: /'
    else
        result_pass A2a "no build-machine paths in run path of $(basename "$so")"
    fi

    bad_rel=$(nonrelative_rpath_violations "$rpath")
    if [[ -n "$bad_rel" ]]; then
        result_fail A2b "run path of $(basename "$so") must be \$ORIGIN-relative or empty; found absolute entries"
        printf '%s\n' "$bad_rel" | sed 's/^/FAIL   offending entry: /'
    else
        result_pass A2b "run path of $(basename "$so") is \$ORIGIN-relative or empty"
    fi
}

check_a3_capi_rpath() {
    local so=$1 rpath bad_dev bad_rel bad_mkl
    require_elf "$so" A3

    rpath=$(read_rpath "$so")
    log "INFO A3 run path of ${so}: [${rpath}]"

    bad_dev=$(devpath_violations "$rpath")
    if [[ -n "$bad_dev" ]]; then
        result_fail A3a "build-machine path in run path of $(basename "$so"); attacker-writable on a customer host"
        printf '%s\n' "$bad_dev" | sed 's/^/FAIL   offending entry: /'
    else
        result_pass A3a "no build-machine paths in run path of $(basename "$so")"
    fi

    bad_rel=$(nonrelative_rpath_violations "$rpath")
    if [[ -n "$bad_rel" ]]; then
        result_fail A3b "run path of $(basename "$so") must be \$ORIGIN-relative or empty; found absolute entries"
        printf '%s\n' "$bad_rel" | sed 's/^/FAIL   offending entry: /'
    else
        result_pass A3b "run path of $(basename "$so") is \$ORIGIN-relative or empty"
    fi

    bad_mkl=$(mklroot_violations "$rpath")
    if [[ -n "$bad_mkl" ]]; then
        result_fail A3c "MKL/oneAPI build-environment path in run path of $(basename "$so")"
        printf '%s\n' "$bad_mkl" | sed 's/^/FAIL   offending entry: /'
    else
        result_pass A3c "no MKL/oneAPI build-environment paths in run path of $(basename "$so")"
    fi
}

# ---------------------------------------------------------------------------
# Self-test: drive every predicate with input that must be rejected and input
# that must be accepted. This is what keeps the gate from decaying into a
# check that passes everything. Run it in CI next to the real check.
# ---------------------------------------------------------------------------

st_fail=0

expect_violation() {
    # $1 = label, $2 = predicate, $3 = input
    local label=$1 pred=$2 input=$3 out
    out=$("$pred" "$input")
    if [[ -z "$out" ]]; then
        printf 'SELFTEST %s FAIL expected a violation for input [%s] but predicate %s reported none\n' \
            "$label" "$input" "$pred"
        st_fail=$((st_fail + 1))
    else
        printf 'SELFTEST %s ok detected [%s]\n' "$label" "$input"
    fi
}

expect_clean() {
    local label=$1 pred=$2 input=$3 out
    out=$("$pred" "$input")
    if [[ -n "$out" ]]; then
        printf 'SELFTEST %s FAIL false positive: input [%s] flagged by %s as [%s]\n' \
            "$label" "$input" "$pred" "$out"
        st_fail=$((st_fail + 1))
    else
        printf 'SELFTEST %s ok accepted [%s]\n' "$label" "$input"
    fi
}

expect_parse() {
    # $1 = label, $2 = expected run path, $3 = synthetic "readelf -d" output
    local label=$1 want=$2 dyn=$3 got
    got=$(parse_rpath_from_dyn "$dyn")
    if [[ "$got" != "$want" ]]; then
        printf 'SELFTEST %s FAIL parsed [%s] but expected [%s]\n' "$label" "$got" "$want"
        st_fail=$((st_fail + 1))
    else
        printf 'SELFTEST %s ok parsed [%s]\n' "$label" "$got"
    fi
}

# Literal "$ORIGIN"/"$MKLROOT" tokens appear throughout the fixtures below and
# must reach the predicates unexpanded, exactly as the loader would see them.
# shellcheck disable=SC2016
self_test() {
    log "== self-test: each check must reject its own known-bad input =="

    # -- A1 -----------------------------------------------------------------
    # Synthetic readelf output for a hypothetical dynamically-linked-MKL build.
    local bad_needed good_needed
    bad_needed=' 0x0000000000000001 (NEEDED)             Shared library: [libmkl_rt.so.2]
 0x0000000000000001 (NEEDED)             Shared library: [libiomp5.so]
 0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]'
    # Verbatim DT_NEEDED list of the current SVS library: the near-miss case.
    good_needed=' 0x0000000000000001 (NEEDED)             Shared library: [libgomp.so.1]
 0x0000000000000001 (NEEDED)             Shared library: [libstdc++.so.6]
 0x0000000000000001 (NEEDED)             Shared library: [libm.so.6]
 0x0000000000000001 (NEEDED)             Shared library: [libgcc_s.so.1]
 0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]
 0x0000000000000001 (NEEDED)             Shared library: [ld-linux-x86-64.so.2]'

    expect_violation A1-mkl-rt  mkl_needed_violations "$bad_needed"
    expect_violation A1-static  mkl_needed_violations \
        ' 0x0000000000000001 (NEEDED)             Shared library: [libmkl_intel_lp64.so.2]'
    expect_clean     A1-libgomp mkl_needed_violations "$good_needed"
    # An MKL-looking string that is not a DT_NEEDED entry must not trip A1:
    # the pattern is scoped to NEEDED lines only.
    expect_clean     A1-scope   mkl_needed_violations \
        ' 0x000000000000001d (RUNPATH)            Library runpath: [/opt/intel/mkl/lib]'

    # -- A2a: build-machine paths -------------------------------------------
    expect_violation A2a-home     devpath_violations '/home/alice/svs_install/lib'
    expect_violation A2a-data     devpath_violations '/data1/someuser/pgv-dev/lib'
    expect_violation A2a-mixed    devpath_violations '$ORIGIN/../lib:/home/bob/lib'
    expect_violation A2a-tmp      devpath_violations '/tmp/stage/lib'
    expect_violation A2a-work     devpath_violations '/srv/jenkins/workspace/x/lib'
    expect_clean     A2a-origin   devpath_violations '$ORIGIN/../lib'
    expect_clean     A2a-empty    devpath_violations ''
    expect_clean     A2a-sysprefix devpath_violations '/usr/lib/x86_64-linux-gnu'

    # -- A2b: production run-path form --------------------------------------
    expect_violation A2b-abs      nonrelative_rpath_violations '/usr/lib/postgresql/18/lib'
    expect_violation A2b-mixed    nonrelative_rpath_violations '$ORIGIN/../lib:/opt/svs/lib'
    expect_clean     A2b-origin   nonrelative_rpath_violations '$ORIGIN/../lib'
    expect_clean     A2b-origin2  nonrelative_rpath_violations '$ORIGIN/../lib:$ORIGIN'
    expect_clean     A2b-braced   nonrelative_rpath_violations '${ORIGIN}/../lib'
    expect_clean     A2b-empty    nonrelative_rpath_violations ''

    # -- A3a/A3b: libsvs_c_api.so gets the same build-machine-path and
    # $ORIGIN-relative checks as svs.so (A2a/A2b above). A non-MKL absolute
    # path here used to slip through uncaught, since the old A3 only ran
    # mklroot_violations; these fixtures pin that it no longer does.
    expect_violation A3a-home    devpath_violations '/home/builder/svs/lib'
    expect_violation A3a-data    devpath_violations '/data1/someuser/svs_install/lib'
    expect_clean     A3a-origin  devpath_violations '$ORIGIN/../lib'
    expect_clean     A3a-empty   devpath_violations ''

    expect_violation A3b-abs     nonrelative_rpath_violations '/home/builder/svs/lib'
    expect_clean     A3b-origin  nonrelative_rpath_violations '$ORIGIN/../lib'
    expect_clean     A3b-empty   nonrelative_rpath_violations ''

    # -- A3c: MKL build-environment paths ------------------------------------
    expect_violation A3c-unexpanded mklroot_violations '$MKLROOT/lib/intel64'
    expect_violation A3c-braced     mklroot_violations '${MKLROOT}/lib'
    expect_violation A3c-oneapi     mklroot_violations '/opt/intel/oneapi/mkl/2024.1/lib/intel64'
    expect_violation A3c-mkldir     mklroot_violations '/usr/local/mkl/lib'
    expect_violation A3c-mixed      mklroot_violations '$ORIGIN/../lib:/opt/intel/oneapi/compiler/latest/lib'
    expect_clean     A3c-origin     mklroot_violations '$ORIGIN/../lib'
    expect_clean     A3c-empty      mklroot_violations ''

    # -- dynamic-tag parsing ------------------------------------------------
    # The false-pass trap: a developer path recorded in the legacy DT_RPATH is
    # invisible to a reader that only matches DT_RUNPATH. Both tags, and the
    # RUNPATH-wins precedence, are pinned here.
    expect_parse tag-runpath '/opt/a/lib' \
        ' 0x000000000000001d (RUNPATH)            Library runpath: [/opt/a/lib]'
    expect_parse tag-rpath-legacy '/home/devuser/svs_install/lib' \
        ' 0x000000000000000f (RPATH)              Library rpath: [/home/devuser/svs_install/lib]'
    expect_parse tag-both-runpath-wins '/from/runpath' \
        ' 0x000000000000000f (RPATH)              Library rpath: [/from/rpath]
 0x000000000000001d (RUNPATH)            Library runpath: [/from/runpath]'
    expect_parse tag-neither '' \
        ' 0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]'

    # A run path parsed out of the legacy tag must still reach the predicates.
    expect_violation tag-rpath-reaches-a2 devpath_violations \
        "$(parse_rpath_from_dyn ' 0x000000000000000f (RPATH)              Library rpath: [/home/devuser/lib]')"

    log ""
    if (( st_fail > 0 )); then
        log "SELFTEST SUMMARY FAIL ${st_fail} predicate check(s) did not behave as specified"
        return 5
    fi
    log "SELFTEST SUMMARY PASS all predicates reject known-bad input and accept known-good input"
    return 0
}

# ---------------------------------------------------------------------------
# Artifact discovery inside a packaged tree.
# ---------------------------------------------------------------------------

find_one() {
    # $1 = root dir, $2 = -name pattern. Prints the first match, sorted for
    # determinism. Prints nothing when there is no match.
    find -L "$1" -type f -name "$2" 2>/dev/null | sort | head -n 1
}

usage() {
    cat <<EOF
Usage:
  $PROG --package-dir DIR
  $PROG --svs-so PATH --capi-so PATH
  $PROG --self-test
  $PROG --help

Checks the run-time linking hygiene of the packaged svs extension. Run this
against the artifact that is published to customers, not a local build: a
developer build intentionally carries absolute rpaths and will fail.

Exit: 0 pass, 1 assertion failed, 2 usage, 3 missing tool, 4 bad object,
      5 self-test regression.
EOF
}

main() {
    local package_dir="" svs_so="" capi_so="" do_self_test=0

    while (( $# > 0 )); do
        case "$1" in
            --package-dir) package_dir=${2:-}; shift 2 ;;
            --svs-so)      svs_so=${2:-};      shift 2 ;;
            --capi-so)     capi_so=${2:-};     shift 2 ;;
            --self-test)   do_self_test=1;     shift ;;
            -h|--help)     usage; exit 0 ;;
            *) err "unknown argument: $1"; usage >&2; exit 2 ;;
        esac
    done

    if (( do_self_test )); then
        self_test
        exit $?
    fi

    discover_tools

    if [[ -n "$package_dir" ]]; then
        if [[ ! -d "$package_dir" ]]; then
            err "--package-dir is not a directory: $package_dir"
            exit 2
        fi
        [[ -z "$svs_so"  ]] && svs_so=$(find_one "$package_dir" 'svs.so')
        [[ -z "$capi_so" ]] && capi_so=$(find_one "$package_dir" 'libsvs_c_api.so*')
        if [[ -z "$svs_so" ]]; then
            err "no svs.so found under $package_dir"
            err "the artifact is incomplete, or the layout changed; not treating this as a pass"
            exit 4
        fi
        if [[ -z "$capi_so" ]]; then
            err "no libsvs_c_api.so found under $package_dir"
            err "the artifact is incomplete, or the layout changed; not treating this as a pass"
            exit 4
        fi
    fi

    if [[ -z "$svs_so" || -z "$capi_so" ]]; then
        err "no target named. Pass --package-dir, or both --svs-so and --capi-so."
        err "There is deliberately no default: these checks describe the packaged"
        err "artifact, and a local development build legitimately fails them."
        usage >&2
        exit 2
    fi

    log "== library integrity check =="
    log "INFO svs.so           : $svs_so"
    log "INFO libsvs_c_api.so  : $capi_so"
    log "INFO readelf          : $READELF"
    log "INFO patchelf         : ${PATCHELF:-<not present, using readelf>}"
    log ""

    check_a1_no_dynamic_mkl "$capi_so"
    log ""
    check_a2_svs_so_rpath "$svs_so"
    log ""
    check_a3_capi_rpath "$capi_so"
    log ""

    log "SUMMARY ${pass_count} passed, ${fail_count} failed"
    if (( fail_count > 0 )); then
        log "SUMMARY VERDICT FAIL do not publish this artifact"
        exit 1
    fi
    log "SUMMARY VERDICT PASS"
    exit 0
}

main "$@"
