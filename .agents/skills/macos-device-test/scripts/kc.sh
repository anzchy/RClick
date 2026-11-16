#!/bin/zsh
set -eu
# usage: kc.sh RUN_DIR KEYCODE [command|control|option|shift ...] — key code to the run's own RClick (Esc 53, Return 36, Tab 48)
exec python3 "${0:A:h}/input.py" kc "$@"
