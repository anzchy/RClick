#!/bin/zsh -f
if [[ ${1:-} == --help ]]; then print -- "Usage: reset.sh (see script header)"; exit 0; fi
# -f: skip ~/.zshenv and other startup files (#27); emulate: default zsh options, whatever the caller set.
emulate -R zsh
# Python runtime: RCLICK_PYTHON, else Homebrew python3, else python3 on PATH.
rclick_python=${RCLICK_PYTHON:-}
if [[ -z $rclick_python ]]; then
  # Homebrew python3 on the Mac (/usr/bin/python3 is 3.9, too old); plain python3 elsewhere (Linux CI, preflight host).
  if [[ -x /opt/homebrew/bin/python3 ]]; then rclick_python=/opt/homebrew/bin/python3; else rclick_python=python3; fi
fi
# Reset a herdr Codex pane to a fresh conversation (RClick fresh-context rule).
# usage: reset.sh <agent-name> <pane-id>   (the pane is the identity; the name labels messages)
# Verified 2026-10-22 on Codex 0.163.0: `/new` opens a "Where should the new conversation run?"
# chooser (option 1 = current worktree, preselected), so two Enters are needed, sent with
# `herdr pane send-keys` (agent send-keys does not submit). Require a fresh Codex
# title or complete Codex welcome logo over an empty transcript in one recent read, or a pane session id change.
# Use the last unfenced title; ignore older scrollback. Title-only proof after scrollback needs
# cwd metadata below it, so a bare title echoed by an old reply cannot re-prove freshness. Allow one placeholder
# followed only by blanks or known footer hints before the bottom-most footer. The logo fallback
# also requires that placeholder; arbitrary box art and partial logos are not session boundaries.
# herdr may retain the old id until the first turn; an unchanged id is not a veto.
set -eu
name=$1 pane=$2
rclick_herdr=${RCLICK_HERDR:-herdr}
rclick_sleep=${RCLICK_SLEEP:-sleep}
context_secs=${RCLICK_RESET_CONTEXT_SECS-30}
poll_secs=${RCLICK_RESET_POLL_SECS-0.25}
# Validate literal decimal text before any pane input or shell arithmetic.
for timer in RCLICK_RESET_CONTEXT_SECS RCLICK_RESET_POLL_SECS; do
  if [[ $timer == RCLICK_RESET_CONTEXT_SECS ]]; then value=$context_secs; else value=$poll_secs; fi
  if ! [[ $value =~ '^[0-9]+([.][0-9]+)?$' ]] ||
     ! LC_ALL=C awk -v n="$value" 'BEGIN { exit !(n + 0 > 0 && n + 0 <= 300) }'; then
    echo "FAIL reset $name: invalid $timer=$value"; exit 1
  fi
done
# Parse one screen only: the last unfenced title and bottom-most eligible footer win.
# A chooser is a boundary, but its footer still belongs to the pre-start UI.
script_dir=${0:A:h}
# Missing/malformed pane metadata falls back to the same visible-screen classifier used by tests.
pane_session() {
  "$rclick_herdr" pane get "$pane" 2>/dev/null | "$rclick_python" "$script_dir/reset_screen.py" session
}
# Read the agent through its pane, as the pollers do since #99: a reset plus a dispatched prompt
# loses the herdr name, so <name> is only a label in messages (#107).
agent_out=$("$rclick_herdr" agent get "$pane" 2>&1) && agent_rc=0 || agent_rc=$?
st=$(print -r -- "$agent_out" | grep -oE '"agent_status":"[a-z]+"' | head -1 | cut -d'"' -f4)
if [[ $agent_rc -ne 0 || -z $st ]]; then
  # Name the real cause: herdr's error message, else its first output line.
  cause=$(print -r -- "$agent_out" | grep -oE '"message":"[^"]*"' | head -1 | cut -d'"' -f4)
  [[ -n $cause ]] || cause=$(print -r -- "$agent_out" | grep -m1 -v '^[[:space:]]*$' || true)
  (( agent_rc == 0 )) && cause="no agent_status in herdr agent get output"
  [[ -n $cause ]] || cause="herdr agent get exited $agent_rc"
  echo "FAIL reset $name: cannot read pane $pane: ${cause[1,200]}"; exit 1
fi
case $st in idle|done) ;; *) echo "FAIL reset $name: pane $pane status $st, not idle"; exit 1;; esac
old=$(print -r -- "$agent_out" | grep -oE '"value":"[^"]+"' | head -1 | cut -d'"' -f4 || true)
old_pane_session=$(pane_session)
[[ -z $old_pane_session ]] || old=$old_pane_session
"$rclick_herdr" pane send-text $pane '/new' >/dev/null
# The first Enter can be swallowed by the slash-command popup; press until the chooser shows.
for i in 1 2 3; do
  "$rclick_herdr" pane send-keys $pane enter >/dev/null; "$rclick_sleep" 3
  "$rclick_herdr" pane read $pane 2>&1 | grep -q 'Where should the new conversation run' && break
done
"$rclick_herdr" pane read $pane 2>&1 | grep -q 'Where should the new conversation run' || { echo "FAIL reset $name: chooser never appeared"; exit 1; }
"$rclick_herdr" pane send-keys $pane enter >/dev/null
# The shared controller uses monotonic time; tests drive it with a virtual clock.
"$rclick_python" "$script_dir/reset_screen.py" "$name" "$pane" "$old_pane_session" "$old" "$context_secs" "$poll_secs"
