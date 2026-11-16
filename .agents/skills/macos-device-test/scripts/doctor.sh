#!/bin/zsh
set -eu
# usage: doctor.sh <absolute-run-directory> [--expected-sha <8-char sha>] | doctor.sh --fixture <observations.json>
exec python3 "${0:A:h}/device.py" doctor "$@"
