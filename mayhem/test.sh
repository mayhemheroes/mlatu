#!/usr/bin/env bash
#
# mlatu/mayhem/test.sh — RUN the pre-built known-answer oracle suite and emit a CTRF summary.
# exit 0 iff no test failed.
#
# Upstream mlatu-lang/mlatu ships NO test suite (no #[test] anywhere, no tests/ dir — the
# crate is a thin CLI/terminal-editor over the mlatu_lib library), so this is an AUTHORED
# behavioral oracle (mayhem/oracle/): known-answer tests over mlatu_lib's parse / pretty /
# rewrite — the exact library code path the `parse` fuzz target drives. Every test asserts
# concrete parsed structure, golden pretty-printed strings, or rewrite results, so a no-op /
# exit(0) patch cannot pass. build.sh pre-compiled the libtest binary to
# /mayhem/mlatu-oracle-test; this script only RUNS it.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

BIN=/mayhem/mlatu-oracle-test
if [ ! -x "$BIN" ]; then
  echo "oracle test binary missing at $BIN — build.sh should have produced it" >&2
  emit_ctrf "cargo-test" 0 1 0; exit 2
fi

echo "=== running mlatu KAT oracle (libtest binary) ==="
out="$("$BIN" 2>&1)"; rc=$?
echo "$out"

# libtest: "test result: ok. 10 passed; 0 failed; 0 ignored; ..."
PASSED=0; FAILED=0; IGNORED=0
while read -r p f i; do
  PASSED=$(( PASSED + p )); FAILED=$(( FAILED + f )); IGNORED=$(( IGNORED + i ))
done < <(printf '%s\n' "$out" \
  | sed -n 's/^test result:.* \([0-9][0-9]*\) passed; \([0-9][0-9]*\) failed; \([0-9][0-9]*\) ignored.*/\1 \2 \3/p')

# No parsable result line (e.g. the binary aborted or printed nothing) = failure.
if [ "$(( PASSED + FAILED + IGNORED ))" -eq 0 ]; then
  echo "could not parse any 'test result:' lines from the oracle run (rc=$rc)" >&2
  emit_ctrf "cargo-test" 0 1 0; exit 1
fi
[ "$rc" -ne 0 ] && [ "$FAILED" -eq 0 ] && FAILED=1

emit_ctrf "cargo-test" "$PASSED" "$FAILED" "$IGNORED"
