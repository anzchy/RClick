#!/bin/zsh
set -eu
# usage: build.sh <absolute-run-directory>
exec python3 "${0:A:h}/device.py" build "$@"
