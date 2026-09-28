#!/bin/sh
#
# Verify the hardening protections expected in the built svs.so, and fail if
# any is missing. Checks the extension's own shared object only: the SVS C
# API library it links against is a dependency this project does not build
# or release, so its hardening is out of scope here.
#
# Uses only readelf and nm from binutils, already required to build the
# extension, so nothing new needs installing. A generic checker such as
# 'hardening-check' (from the hardening-includes package) is not used: that
# package has no installation candidate on Ubuntu 22.04, and a generic tool
# also reports a shared library as "not a PIE", which is true and irrelevant
# for something PostgreSQL always loads via dlopen().
#
# The Intel CET row is informational only and never fails the check: the
# property appears whenever the toolchain defaults -fcf-protection on, which
# is a distribution default rather than something this build requests.
#
# Usage: hardening_check.sh <path to svs.so>
# Exit:  0 if every required check passes, 1 otherwise.

SO="${1:?usage: hardening_check.sh <path to svs.so>}"
[ -f "$SO" ] || { echo "no such file: $SO" >&2; exit 2; }
for t in readelf nm; do
    command -v "$t" >/dev/null || { echo "missing required tool: $t" >&2; exit 2; }
done

fail=0
ok()  { printf '  PASS  %-34s %s\n' "$1" "$2"; }
bad() { printf '  FAIL  %-34s %s\n' "$1" "$2"; fail=1; }
info() { printf '  INFO  %-34s %s\n' "$1" "$2"; }

f1=$(readelf -d "$SO" | sed -n 's/.*(FLAGS_1).*Flags:[[:space:]]*//p')
stack=$(readelf -lW "$SO" | awk '/GNU_STACK/{print $(NF-1)}')

echo "checking $SO"

# Full RELRO. -z relro alone gives only partial read-only relocations; -z now
# is what completes it, and is not the linker's default for a shared library.
case "$f1" in
    *NOW*) ok  "full RELRO (DT_FLAGS_1 NOW)" "$f1" ;;
    *)     bad "full RELRO (DT_FLAGS_1 NOW)" "got '${f1:-none}'; add -Wl,-z,now" ;;
esac

# PostgreSQL loads every extension module with dlopen(). DF_1_NOOPEN makes
# glibc refuse it, so this flag must never appear.
case "$f1" in
    *NOOPEN*) bad "not dlopen-blocked" \
                  "NOOPEN present; PostgreSQL cannot load this. Remove -Wl,-z,nodlopen" ;;
    *)        ok  "not dlopen-blocked" "no NOOPEN" ;;
esac

if readelf -lW "$SO" | grep -q GNU_RELRO; then
    ok  "RELRO segment present" "GNU_RELRO"
else
    bad "RELRO segment present" "missing; add -Wl,-z,relro"
fi

case "$stack" in
    RW) ok  "non-executable stack" "GNU_STACK=RW" ;;
    *)  bad "non-executable stack" "GNU_STACK=$stack; add -Wl,-z,noexecstack" ;;
esac

if nm -uD "$SO" 2>/dev/null | grep -q stack_chk; then
    ok  "stack canaries" "__stack_chk_fail referenced"
else
    bad "stack canaries" "no canary symbol; add -fstack-protector-strong"
fi

# Informational: enabling this as a hard requirement needs -fcf-protection=full
# passed explicitly, which this build does not do today.
if readelf -n "$SO" 2>/dev/null | grep -q 'IBT'; then
    info "Intel CET" "IBT, SHSTK present (toolchain default)"
else
    info "Intel CET" "not present"
fi

if [ "$fail" -eq 0 ]; then
    echo "  all required checks passed"
else
    echo "  one or more required checks FAILED"
fi
exit "$fail"
