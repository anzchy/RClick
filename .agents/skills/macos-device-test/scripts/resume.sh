#!/bin/zsh
set -eu
# usage: resume.sh <absolute-run-directory>
exec python3 "${0:A:h}/device.py" resume "$@"
