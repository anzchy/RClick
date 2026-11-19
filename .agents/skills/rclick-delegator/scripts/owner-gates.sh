#!/bin/zsh -f
# -f: skip ~/.zshenv and other startup files (#27); emulate: default zsh options, whatever the caller set.
emulate -R zsh
# Rerun RClick's gates on an exact commit, as the delegator, and write a summary file.
# usage: owner-gates.sh <repo-or-worktree> <sha> <prefix>
#   Exports <sha> into a fresh scratch directory (never touches any worktree), runs the
#   project's gate script there, and writes <prefix>-summary.txt plus one log per lane
#   under ~/.rclick-roster/gates/. The summary ends with DONE; exit 0 only when every lane
#   passed. Run it in the background; read the summary, not the logs.
#
# Refuses (DONE overall=1, no lanes) when less than RCLICK_GATES_MIN_FREE_GIB (default 8) GiB is free under
# $TMPDIR or $HOME: an Xcode build plus its DerivedData needs several GiB.
#
# Lanes:
#   gates  scripts/gates.sh (build, unit-tests, localization, skill-tooling). Its `GATE <lane> PASS|FAIL|SKIP`
#          lines and its final `GATES PASS|FAIL` line are copied into the summary; the lane passes only on exit 0
#          with `GATES PASS`. DerivedData stays inside the exported tree, so it is removed with it.
#          For each lane a `GATE <lane> FAIL` line names, gates.sh's own lane log (.build/gates/<lane>.log in the
#          exported tree: the traceback) is kept as <prefix>-<lane>-failure.log, at most its last 3000 lines, behind
#          a header with the commit, the UTC time, uptime, vm.loadavg, hw.ncpu and the failing items; the summary
#          gets `lane <lane> failure-log=<path>` (or `failure-log=none reason=…`). A passing run keeps no extra log.
#   leak   the sentinel-secret grep over the gates log (sentinels listed in scripts/test-secrets.txt when that
#          file exists; skipped with a reason otherwise)
setopt err_return no_unset pipe_fail

repo=${1:?usage: owner-gates.sh <repo-or-worktree> <sha> <prefix>}
sha=${2:?usage: owner-gates.sh <repo-or-worktree> <sha> <prefix>}
prefix=${3:?usage: owner-gates.sh <repo-or-worktree> <sha> <prefix>}
[[ $prefix =~ '^[A-Za-z0-9._-]+$' ]] || { print -u2 "owner-gates: prefix must be [A-Za-z0-9._-]+"; exit 2; }

out=${RCLICK_GATES_OUT:-$HOME/.rclick-roster/gates}
mkdir -p "$out"
summary=$out/$prefix-summary.txt
full=$(git -C "$repo" rev-parse --verify "$sha^{commit}") || { print -u2 "owner-gates: unknown commit $sha"; exit 2; }

{
  print "owner-gates $prefix head=${full[1,12]} started=$(date -u +%FT%TZ)"
} > "$summary"

# A nearly full disk breaks an Xcode build midway; refuse before exporting (#34 in the clay roster).
min_free_gib=${RCLICK_GATES_MIN_FREE_GIB:-8}
[[ $min_free_gib =~ '^[0-9]+$' ]] || { print -u2 "owner-gates: RCLICK_GATES_MIN_FREE_GIB must be a whole number"; exit 2; }
for dir in "${TMPDIR:-/tmp}" "$HOME"; do
  free_kib=$(df -Pk "$dir" | awk 'NR == 2 { print $4 }')
  if (( free_kib < min_free_gib * 1024 * 1024 )); then
    print "refused: low disk: $(( free_kib / 1024 )) MiB free under $dir, need ${min_free_gib} GiB; free space first" | tee -a "$summary"
    print "DONE overall=1" >> "$summary"
    print "DONE overall=1 summary=$summary"
    exit 1
  fi
done

scratch=$(mktemp -d "${TMPDIR:-/tmp}/rclick-gates.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT
git -C "$repo" archive "$full" | tar -x -C "$scratch"

overall=0
lane() {
  local name=$1; shift
  local log=$out/$prefix-$name.log rc=0
  ( cd "$scratch" && "$@" ) > "$log" 2>&1 || rc=$?
  print "lane $name rc=$rc log=$log" | tee -a "$summary"
  (( rc == 0 )) || overall=1
}

# Copy a failed lane's log out of the scratch tree, behind a header that records the machine load at failure time.
# Bounded: the build log can be huge, and the end of a log is where the failure is.
keep_failure_log() {
  local name=$1 gates_log=$2 max_lines=3000
  local src=$scratch/.build/gates/$name.log kept=$out/$prefix-$name-failure.log
  if [[ ! -f $src ]]; then
    print "lane $name failure-log=none reason=no .build/gates/$name.log in the scratch tree" | tee -a "$summary"
    return 0
  fi
  {
    print "owner-gates failure log $prefix"
    print "commit: $full"
    print "time: $(date -u +%FT%TZ)"
    print "lane: $name"
    # Linux uptime starts with a space; a missing command (no sysctl on Linux) says unavailable, never fails.
    print "uptime: $(uptime 2>/dev/null | sed 's/^[[:space:]]*//' || print unavailable)"
    print "loadavg: $(sysctl -n vm.loadavg 2>/dev/null || print unavailable)"
    print "ncpu: $(sysctl -n hw.ncpu 2>/dev/null || print unavailable)"
    # The failing items: the lane's GATE line and the indented lines gates.sh prints under it.
    awk -v lane="$name" '
      index($0, "GATE " lane " FAIL") == 1 { on = 1; print "gate: " $0; next }
      on && /^  / { print "item: " substr($0, 3); next }
      { on = 0 }' "$gates_log"
    local total=$(wc -l < "$src" | tr -d ' ')
    if (( total > max_lines )); then
      print "truncated: kept the last $max_lines of $total lines"
    else
      print "truncated: no ($total lines)"
    fi
    print "source: .build/gates/$name.log"
    print -- "---"
    tail -n "$max_lines" "$src"
  } > "$kept"
  print "lane $name failure-log=$kept" | tee -a "$summary"
}

if [[ -x $scratch/scripts/gates.sh ]]; then
  lane gates ./scripts/gates.sh
  log=$out/$prefix-gates.log
  # The per-lane lines are the evidence the auditors and the PR body quote.
  grep -E '^GATES? ' "$log" >> "$summary" || true
  if ! grep -qx 'GATES PASS' "$log"; then
    print "lane gates verdict=missing-or-fail reason=no 'GATES PASS' line in $log" | tee -a "$summary"
    overall=1
  fi
  # The EXIT trap removes the scratch tree, and with it gates.sh's own lane logs (.build/gates/<lane>.log): the only
  # copy of a failure's traceback. Keep each failed lane's log first (#17).
  for failed in ${(u)${(f)"$(sed -nE 's/^GATE ([A-Za-z0-9._-]+) FAIL.*/\1/p' "$log")"}}; do
    keep_failure_log "$failed" "$log" ||
      print "lane $failed failure-log=error reason=could not copy .build/gates/$failed.log" | tee -a "$summary"
  done
else
  print "lane gates rc=127 reason=scripts/gates.sh missing at ${full[1,12]}" | tee -a "$summary"
  overall=1
fi

if [[ -f $scratch/scripts/test-secrets.txt ]]; then
  leak() {
    local hit=0
    while IFS= read -r secret; do
      [[ -z $secret || $secret == \#* ]] && continue
      if grep -rqF -- "$secret" "$out/$prefix-gates.log"; then
        print "sentinel found in test output: ${secret[1,4]}…"; hit=1
      fi
    done < scripts/test-secrets.txt
    return $hit
  }
  lane leak leak
else
  print "lane leak rc=0 reason=n/a: no scripts/test-secrets.txt at ${full[1,12]}" | tee -a "$summary"
fi

print "DONE overall=$overall" >> "$summary"
print "DONE overall=$overall summary=$summary"
exit $overall
