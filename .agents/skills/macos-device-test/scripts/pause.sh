#!/bin/zsh
set -eu
# usage: pause.sh <absolute-run-directory>
exec python3 "${0:A:h}/device.py" pause "$@"
