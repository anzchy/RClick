#!/bin/zsh -f
if [[ ${1:-} == --help ]]; then print -- "Usage: poll-idle.sh (see script header)"; exit 0; fi
# -f: skip ~/.zshenv and other startup files (#27); emulate: default zsh options, whatever the caller set.
emulate -R zsh
# poll-idle.sh <agent> <interval> <max_minutes> <agent_pane> <agent_terminal>
# Exits 0 with "<agent> idle|question <time>".
# - Codex panes: herdr status sticks at "working" and the narrow screen may hide "esc to interrupt", so a turn
#   is done when the last lines above the composer show Codex's end-of-turn "Worked for …" line.
# - A sub-agent question ("? 1 question … to answer") blocks the turn: report it at once.
# - Claude panes: herdr's agent_status is reliable.
a=$1; iv=${2:-60}; max=${3:-600}; hits=0; start=$(date +%s)
pane=${4:?agent_pane required}; terminal=${5:?agent_terminal required}
rclick_herdr=${RCLICK_HERDR:-herdr}
rclick_sleep=${RCLICK_SLEEP:-sleep}
rclick_python=${RCLICK_PYTHON:-}
if [[ -z $rclick_python ]]; then
  # Homebrew python3 on the Mac (/usr/bin/python3 is 3.9, too old); plain python3 elsewhere (Linux CI, preflight host).
  if [[ -x /opt/homebrew/bin/python3 ]]; then rclick_python=/opt/homebrew/bin/python3; else rclick_python=python3; fi
fi
script_dir=${0:A:h}
get_failure_limit=$("$rclick_python" "$script_dir/poll-report.py" --get-failure-limit) || exit 1
failures=0
"$rclick_sleep" $iv
while :; do
  info=$("$rclick_python" "$script_dir/poll-report.py" --agent-info "$pane" "$terminal" 2>&1)
  get_rc=$?
  if (( get_rc )); then
    (( failures += 1 ))
    if (( get_rc != 75 )); then print -ru2 -- "$info"; exit 1; fi
    if (( failures >= get_failure_limit )); then
      print -ru2 -- "$failures consecutive lookup failures: $info"; exit 1
    fi
    hits=0
    [ $(( $(date +%s) - start )) -gt $((max*60)) ] && { echo "$a timeout"; exit 1; }
    "$rclick_sleep" $iv
    continue
  fi
  failures=0
  out=$("$rclick_herdr" agent read "$pane" --source visible 2>&1)
  if print -r -- "$out" | grep -q -e 'to answer' -e 'enter submit'; then echo "$a question $(date +%H:%M:%S)"; exit 0; fi
  if [[ -z ${out//[[:space:]]/} ]]; then
    # An empty visible screen (pane too small) tells nothing: fall back to herdr's status.
    [[ $info == *'"agent_status":"working"'* ]] && busy=1 || busy=0
  elif [[ $info == *'"agent":"claude"'* ]]; then
    [[ $info == *'"agent_status":"working"'* ]] && busy=1 || busy=0
  else
    tail_lines=$(print -r -- "$out" | grep -v '^[[:space:]]*$' | sed -n '/^› /q;p' | tail -6)
    if print -r -- "$out" | grep -q 'esc to interrupt'; then busy=1
    elif print -r -- "$(print -r -- "$out" | grep -v '^[[:space:]]*$' | tail -8)" | grep -q 'Worked for'; then busy=0
    else busy=1; fi
  fi
  if (( busy )); then hits=0; else hits=$((hits+1)); fi
  [ $hits -ge 2 ] && { echo "$a idle $(date +%H:%M:%S)"; exit 0; }
  [ $(( $(date +%s) - start )) -gt $((max*60)) ] && { echo "$a timeout"; exit 1; }
  "$rclick_sleep" $iv
done
