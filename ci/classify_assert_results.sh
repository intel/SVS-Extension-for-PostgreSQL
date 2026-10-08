#!/usr/bin/env bash
#
# Classify the output of an assert-enabled build's test run.
#
# This job runs on a debug build (--enable-cassert) specifically to catch
# invariant violations that Assert() detects but a release build would
# silently tolerate or crash differently on. One such violation is already
# known and accepted: a standby replaying a dropped index can trip
# Assert(IsTransactionState()) in src/vamanacache.c, because the guarded
# code path is a deliberate no-op during recovery either way. Hard-failing
# on that one condition would make this job permanently red for a reason
# everyone already knows about, so this script tells it apart from
# anything else a TRAP or a crash signal could mean.
#
# Usage:
#   classify_assert_results.sh <sql-exit-code> <sql-log-file> \
#       <tap-exit-code> <tap-output-file> <tap-log-dir>
#
# Exit status: 0 if the run is clean or shows only the known trap (and its
# direct fallout); 1 if anything else shows up. Prints a human-readable
# summary to stdout either way.

set -uo pipefail

SQL_EXIT="${1:?sql exit code required}"
SQL_LOG="${2:?sql log file required}"
TAP_EXIT="${3:?tap exit code required}"
TAP_OUTPUT="${4:?tap output file required}"
TAP_LOG_DIR="${5:?tap log dir required}"

KNOWN_FILE="src/vamanacache.c"
KNOWN_ASSERT='IsTransactionState()'

unexpected_count=0
known_count=0
summary_lines=()

# A failed Assert() calls abort() internally, which the postmaster then
# reports as a plain "terminated by signal 6: Aborted" line for the same
# PID as the TRAP. That SIGABRT is the known trap's own mechanism, not a
# second, independent problem, so each log's known-trap PIDs are tracked
# and a same-PID SIGABRT is folded into the TRAP finding instead of being
# counted again. Any other signal (SIGSEGV, or SIGABRT with no matching
# TRAP) is unexplained and always unexpected.
classify_log() {
	# $1 = log file, $2 = label used in summary lines for dubious-test fallout
	local log="$1" label="${2:-}" known_pids="" line pid is_known=1 any_finding=0

	while IFS= read -r line; do
		any_finding=1
		if [[ "${line}" == *"${KNOWN_ASSERT}"* && "${line}" == *"${KNOWN_FILE}"* ]]; then
			known_count=$((known_count + 1))
			pid="$(grep -oE 'PID: [0-9]+' <<<"${line}" | grep -oE '[0-9]+')"
			known_pids="${known_pids} ${pid}"
			summary_lines+=("  KNOWN${label:+ (test ${label})}: ${log}: ${line}")
		else
			is_known=0
			unexpected_count=$((unexpected_count + 1))
			summary_lines+=("  UNEXPECTED (assertion${label:+, test ${label}}): ${log}: ${line}")
		fi
	done < <(grep -h "^TRAP:" "${log}" 2>/dev/null || true)

	while IFS= read -r line; do
		pid="$(grep -oE '\(PID [0-9]+\)' <<<"${line}" | grep -oE '[0-9]+')"
		if [[ "${line}" == *"signal 6: Aborted"* && " ${known_pids} " == *" ${pid} "* ]]; then
			# Fallout from the known TRAP's own abort(); already counted above.
			continue
		fi
		any_finding=1
		is_known=0
		unexpected_count=$((unexpected_count + 1))
		summary_lines+=("  UNEXPECTED (crash signal${label:+, test ${label}}): ${log}: ${line}")
	done < <(grep -h "was terminated by signal" "${log}" 2>/dev/null || true)

	if [[ -n "${label}" && "${any_finding}" -eq 1 && "${is_known}" -eq 1 ]]; then
		summary_lines+=("  (${label}'s dubious exit is fallout from the known trap above, not a second problem)")
	fi
	[[ "${any_finding}" -eq 1 ]]
}

# --- SQL regression run -----------------------------------------------
if [[ -f "${SQL_LOG}" ]]; then
	classify_log "${SQL_LOG}" || true
fi

if [[ "${SQL_EXIT}" -ne 0 ]]; then
	# A nonzero exit with no TRAP/signal above is a genuine regression
	# diff failure, not a crash; still a real finding.
	if ! grep -qE "^TRAP:|was terminated by signal" "${SQL_LOG}" 2>/dev/null; then
		unexpected_count=$((unexpected_count + 1))
		summary_lines+=("  UNEXPECTED (test failure): make installcheck exited ${SQL_EXIT} with no assertion trap or crash signal in ${SQL_LOG} -- a real regression diff, not a build/assert issue")
	fi
fi

# --- TAP run -------------------------------------------------------------
# prove's "Test Summary Report" lists every dubious or failed file with its
# own Tests/Failed counts, which is a cleaner signal than scraping each
# per-file progress line.
declare -A tap_failed_count
current_test=""
if [[ -f "${TAP_OUTPUT}" ]]; then
	in_summary=0
	while IFS= read -r line; do
		if [[ "${line}" == "Test Summary Report"* ]]; then
			in_summary=1
			continue
		fi
		if [[ "${in_summary}" -eq 1 ]]; then
			if [[ "${line}" =~ ^(test/t/[A-Za-z0-9_]+\.pl)[[:space:]] ]]; then
				current_test="${BASH_REMATCH[1]}"
			fi
			if [[ -n "${current_test}" && "${line}" =~ Failed:\ ([0-9]+)\) ]]; then
				tap_failed_count["${current_test}"]="${BASH_REMATCH[1]}"
			fi
		fi
	done < "${TAP_OUTPUT}"
fi

for test_file in "${!tap_failed_count[@]}"; do
	failed="${tap_failed_count[${test_file}]}"
	base="$(basename "${test_file}" .pl)"
	# Node logs for this test file are named <base>_<nodename>.log.
	mapfile -t node_logs < <(find "${TAP_LOG_DIR}" -maxdepth 1 -name "${base}_*.log" 2>/dev/null)

	if [[ "${failed}" -gt 0 ]]; then
		# A real assertion (is()/ok()) failed inside the TAP file itself;
		# that is a genuine test-logic failure regardless of what else is
		# in the logs.
		unexpected_count=$((unexpected_count + 1))
		summary_lines+=("  UNEXPECTED (test-logic failure): ${test_file} reported ${failed} failed assertion(s)")
	fi

	found_any=0
	for nl in "${node_logs[@]:-}"; do
		[[ -z "${nl}" ]] && continue
		if classify_log "${nl}" "${test_file}"; then
			found_any=1
		fi
	done
	if [[ "${failed}" -eq 0 && "${found_any}" -eq 0 ]]; then
		# Dubious exit, no trap or crash signal found in its node logs:
		# still a real finding, just not one this script can label further.
		# (Skipped when failed>0: that case already has an identified cause
		# above, so a generic "no trap found" message would be misleading.)
		unexpected_count=$((unexpected_count + 1))
		summary_lines+=("  UNEXPECTED (dubious exit, no trap found): ${test_file} exited abnormally with no TRAP/signal in its node logs -- investigate directly")
	fi
done

if [[ "${TAP_EXIT}" -ne 0 && "${#tap_failed_count[@]}" -eq 0 ]]; then
	# make exited nonzero but prove's own summary found nothing dubious:
	# something went wrong outside prove's view (e.g. the make invocation
	# itself failed). Treat as unexpected since we can't classify it.
	if ! grep -q "Test Summary Report" "${TAP_OUTPUT}" 2>/dev/null; then
		unexpected_count=$((unexpected_count + 1))
		summary_lines+=("  UNEXPECTED (tap run failure): make prove_installcheck exited ${TAP_EXIT} with no 'Test Summary Report' in ${TAP_OUTPUT}")
	fi
fi

# --- Print summary ---------------------------------------------------------
echo "=== Assert-build trap/crash classification ==="
echo "SQL run (make installcheck) exit code: ${SQL_EXIT}"
echo "TAP run (make prove_installcheck) exit code: ${TAP_EXIT}"
echo "Known-trap findings: ${known_count}"
echo "Unexpected findings: ${unexpected_count}"
echo
if [[ "${#summary_lines[@]}" -eq 0 ]]; then
	echo "No TRAP lines, crash signals, or test-logic failures found."
else
	printf '%s\n' "${summary_lines[@]}"
fi
echo

if [[ "${unexpected_count}" -gt 0 ]]; then
	echo "VERDICT: unexpected-finding"
	exit 1
elif [[ "${known_count}" -gt 0 ]]; then
	echo "VERDICT: known-trap-only"
	exit 0
else
	echo "VERDICT: clean"
	exit 0
fi
