#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# RUN the Check unit-test binaries that mayhem/build.sh produced (build-tests/bin/tests/<name>) and sum
# their counts. Each binary prints `NN%: Checks: N, Failures: F, Errors: E`; a binary that prints no such
# line (crashed, neutered to exit(0), missing) counts as one failed test, so a no-op program cannot pass.
TESTS="check_types_builtin check_types_builtin_json check_types_json_encode check_types_json_decode
 check_base64 check_dtoa check_itoa check_utf8 check_parse_num check_cj5 check_ziptree check_mp_printf
 check_yxml check_libc_time check_pcg_basic check_musl_inet_pton"
BIN="$SRC/build-tests/bin/tests"
passed=0 failed=0
for t in $TESTS; do
  if [ ! -x "$BIN/$t" ]; then echo "MISSING test binary $BIN/$t (build.sh bug)" >&2; failed=$((failed+1)); continue; fi
  out="$(cd "$BIN" && CK_VERBOSITY=normal timeout 600 "./$t" 2>&1)"; rc=$?
  line="$(printf '%s\n' "$out" | grep -E '^[0-9]+%: Checks: [0-9]+, Failures: [0-9]+, Errors: [0-9]+' | tail -1)"
  if [ -z "$line" ]; then echo "$t: no Check summary (rc=$rc)" >&2; failed=$((failed+1)); continue; fi
  n="$(printf '%s' "$line" | sed -E 's/.*Checks: ([0-9]+),.*/\1/')"
  f="$(printf '%s' "$line" | sed -E 's/.*Failures: ([0-9]+),.*/\1/')"
  e="$(printf '%s' "$line" | sed -E 's/.*Errors: ([0-9]+).*/\1/')"
  [ "$n" -gt 0 ] || { echo "$t: zero checks ran" >&2; failed=$((failed+1)); continue; }
  echo "$t: $line"
  if [ "$rc" -ne 0 ] && [ "$f" -eq 0 ] && [ "$e" -eq 0 ]; then failed=$((failed+1)); continue; fi
  passed=$((passed + n - f - e)); failed=$((failed + f + e))
done
emit_ctrf "check" "$passed" "$failed" 0
