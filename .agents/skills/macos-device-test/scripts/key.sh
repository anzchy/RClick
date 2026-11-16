#!/bin/zsh
set -eu
# usage: key.sh RUN_DIR CHAR [modifiers] — exactly one printable character to the run's own RClick
exec python3 "${0:A:h}/input.py" key "$@"
