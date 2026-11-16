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

if [[ -x $scratch/scripts/gates.sh ]]; then
  lane gates ./scripts/gates.sh
  log=$out/$prefix-gates.log
  # The per-lane lines are the evidence the auditors and the PR body quote.
  grep -E '^GATES? ' "$log" >> "$summary" || true
  if ! grep -qx 'GATES PASS' "$log"; then
    print "lane gates verdict=missing-or-fail reason=no 'GATES PASS' line in $log" | tee -a "$summary"
    overall=1
  fi
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
