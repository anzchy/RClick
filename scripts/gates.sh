#!/usr/bin/env bash
# RClick gate ladder. Used by rclick-verify (implementers) and rclick-delegator (owner gates).
#
#   scripts/gates.sh                 run every lane in order, stop at the first FAIL
#   scripts/gates.sh --all           run every lane even after a FAIL (owner summary)
#   scripts/gates.sh --lane <name>   run one lane: build | unit-tests | localization | skill-tooling
#
# Output: one `GATE <lane> PASS|FAIL|SKIP [detail]` line per lane, then `GATES PASS|FAIL`.
# Full logs: .build/gates/<lane>.log. DerivedData: .build/DerivedData (per worktree, so parallel
# worktrees never share a build folder).
#
# Exit codes: 0 every lane PASS or SKIP; 1 a lane failed; 2 usage error.
# With --lane unit-tests only: 70 means an environment failure (xcodebuild produced no test result,
# e.g. no GUI session or the test runner never connected). rclick-verify records that as NOT VERIFIED;
# the delegator's desktop run is binding.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
LOGS="$ROOT/.build/gates"
DD="$ROOT/.build/DerivedData"
LANES=(build unit-tests localization skill-tooling)
LANGUAGES=(zh-Hans ja es fr)
ENV_EXIT=70
# Same interpreter the delegator scripts use: /usr/bin/python3 (3.9) is too old for them.
PY="${RCLICK_PYTHON:-$( [ -x /opt/homebrew/bin/python3 ] && echo /opt/homebrew/bin/python3 || command -v python3 )}"

# Same flags as .github/workflows/pr-build.yml, plus a per-worktree DerivedData.
XC_FLAGS=(
  -project RClick.xcodeproj -scheme RClick -configuration Debug
  -derivedDataPath "$DD"
  ARCHS=arm64 MACOSX_DEPLOYMENT_TARGET=15.6
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
)

usage() { echo "usage: scripts/gates.sh [--all] [--lane build|unit-tests|localization|skill-tooling]" >&2; exit 2; }

lane_build() {
  local log="$LOGS/build.log"
  xcodebuild build "${XC_FLAGS[@]}" -destination "generic/platform=macOS" >"$log" 2>&1
  local rc=$?
  local warnings
  warnings=$(grep -cE ': warning: ' "$log" || true)
  if [ $rc -eq 0 ] && grep -q '\*\* BUILD SUCCEEDED \*\*' "$log"; then
    echo "GATE build PASS (warnings: $warnings)"; return 0
  fi
  echo "GATE build FAIL (exit $rc)"
  grep -E ': error: ' "$log" | sort -u | head -20 | sed 's/^/  /'
  return 1
}

lane_unit_tests() {
  local log="$LOGS/unit-tests.log"
  xcodebuild test "${XC_FLAGS[@]}" -destination "platform=macOS" -only-testing:RClickTests >"$log" 2>&1
  local rc=$?
  # xcodebuild prints one line per test case, for XCTest ("Test Case '-[C t]' passed (…)") and Swift Testing
  # ("Test case 'C/t()' passed on '…'") alike. Count them; parameterized Swift tests count once per case line.
  local passed failed summary
  passed=$(grep -cE "^Test [Cc]ase '.*' passed" "$log" || true)
  failed=$(grep -cE "^Test [Cc]ase '.*' failed" "$log" || true)
  summary="tests: $passed passed, $failed failed"
  if [ $rc -eq 0 ] && [ "$failed" -eq 0 ] && grep -q '\*\* TEST SUCCEEDED \*\*' "$log"; then
    echo "GATE unit-tests PASS ($summary)"; return 0
  fi
  if [ $((passed + failed)) -eq 0 ]; then
    echo "GATE unit-tests FAIL environment: no test result (exit $rc; see .build/gates/unit-tests.log)"
    grep -E 'error|hung|Testing failed' "$log" | head -5 | sed 's/^/  /'
    return $ENV_EXIT
  fi
  echo "GATE unit-tests FAIL (exit $rc; $summary)"
  grep -E "^Test [Cc]ase '.*' failed|: error: " "$log" | sort -u | head -20 | sed 's/^/  /'
  return 1
}

lane_localization() {
  local log="$LOGS/localization.log"
  "$PY" scripts/check-localization.py --languages "${LANGUAGES[@]}" >"$log" 2>&1
  local rc=$?
  if [ $rc -eq 0 ]; then
    echo "GATE localization PASS ($(grep -m1 '^OK:' "$log" | cut -c1-60)...)"; return 0
  fi
  echo "GATE localization FAIL (exit $rc)"
  grep -vE '^(skipped|OK):' "$log" | head -20 | sed 's/^/  /'
  return 1
}

lane_skill_tooling() {
  local log="$LOGS/skill-tooling.log"
  : >"$log"
  local py=() js=() f
  while IFS= read -r f; do py+=("$f"); done < <(
    find .agents/skills scripts/codex-rules -type f -name 'test_*.py' -not -path '*/fixtures/*' 2>/dev/null | sort)
  while IFS= read -r f; do js+=("$f"); done < <(
    find .agents/skills scripts/codex-rules -type f -name '*.test.mjs' -not -path '*/node_modules/*' 2>/dev/null | sort)
  if [ ${#py[@]} -eq 0 ] && [ ${#js[@]} -eq 0 ]; then
    echo "GATE skill-tooling SKIP (no tooling tests)"; return 0
  fi
  local failed=() n=0
  for f in "${py[@]}"; do
    n=$((n + 1))
    echo "### $PY -m unittest $f" >>"$log"
    (cd "$(dirname "$f")" && "$PY" -m unittest -q "$(basename "$f" .py)") >>"$log" 2>&1 || failed+=("$f")
  done
  if [ ${#js[@]} -gt 0 ]; then
    for f in "${js[@]}"; do
      n=$((n + 1))
      echo "### node --test $f" >>"$log"
      node --test "$f" >>"$log" 2>&1 || failed+=("$f")
    done
  fi
  if [ ${#failed[@]} -eq 0 ]; then
    echo "GATE skill-tooling PASS ($n test files)"; return 0
  fi
  echo "GATE skill-tooling FAIL (${#failed[@]} of $n test files)"
  printf '  %s\n' "${failed[@]}"
  return 1
}

run_lane() {
  case "$1" in
    build) lane_build ;;
    unit-tests) lane_unit_tests ;;
    localization) lane_localization ;;
    skill-tooling) lane_skill_tooling ;;
    *) usage ;;
  esac
}

ALL=0; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --all) ALL=1; shift ;;
    --lane) [ $# -ge 2 ] || usage; ONLY="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

mkdir -p "$LOGS"

if [ -n "$ONLY" ]; then
  run_lane "$ONLY"; rc=$?
  if [ $rc -eq 0 ]; then echo "GATES PASS"; else echo "GATES FAIL"; fi
  exit $rc
fi

status=0
for lane in "${LANES[@]}"; do
  if [ $status -ne 0 ] && [ $ALL -eq 0 ]; then
    echo "GATE $lane SKIP (earlier lane failed)"; continue
  fi
  run_lane "$lane" || status=1
done
if [ $status -eq 0 ]; then echo "GATES PASS"; else echo "GATES FAIL"; fi
exit $status
