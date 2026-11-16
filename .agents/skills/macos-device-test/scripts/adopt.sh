#!/bin/zsh
set -eu
# usage: adopt.sh NEW_RUN_DIR --from RETIRED_RUN_DIR — record the RClick the offline hint relaunched from this run's bundle
exec python3 "${0:A:h}/device.py" adopt "$@"
