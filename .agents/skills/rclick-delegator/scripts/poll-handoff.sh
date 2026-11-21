#!/bin/zsh -f
# -f: skip ~/.zshenv and other startup files (#27); emulate: default zsh options, whatever the caller set.
emulate -R zsh
# poll-handoff.sh <agent> <handoff-file> <max_minutes> <grep-marker-or-empty> <agent_pane> <agent_terminal>
# For agents whose herdr status is reliable (Claude): exits when the handoff file exists (and, if a marker is
# given, contains it) AND herdr reports the agent idle/done. Prints "<agent> done|blocked|timeout <time>".
# Don't grep an agent's screen for words like "permission": that produced a false "question" once.
a=$1; f=$2; max=${3:-120}; marker=${4:-}
pane=${5:?agent_pane required}; terminal=${6:?agent_terminal required}
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
for i in $(seq 1 $max); do
  info=$("$rclick_python" "$script_dir/poll-report.py" --agent-info "$pane" "$terminal" 2>&1)
  get_rc=$?
  if (( get_rc )); then
    (( failures += 1 ))
    if (( get_rc != 75 )); then print -ru2 -- "$info"; exit 1; fi
    if (( failures >= get_failure_limit )); then
      print -ru2 -- "$failures consecutive lookup failures: $info"; exit 1
    fi
    "$rclick_sleep" 60
    continue
  fi
  failures=0
  st=$(print -r -- "$info" | grep -oE '"agent_status":"[a-z]+"' | cut -d'"' -f4)
  if [[ -f $f ]] && { [[ -z $marker ]] || grep -q -- "$marker" "$f"; } && [[ $st == idle || $st == done ]]; then
    echo "$a done $(date +%H:%M:%S)"; exit 0; fi
  [[ $st == blocked ]] && { echo "$a blocked $(date +%H:%M:%S)"; exit 0; }
  "$rclick_sleep" 60
done
echo "$a timeout status=$st"
