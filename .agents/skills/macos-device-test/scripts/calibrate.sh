#!/bin/zsh
# calibrate.sh RUN_DIR [--dry-run] — step zero of every device run (under the GUI lock): proves each ui.sh helper on
# a throwaway Finder window under RUN_DIR/fixtures/, prints PASS|FAIL|SKIP per step and `CALIBRATION PASS` or
# `CALIBRATION FAIL — distrust: <commands>`. Exit 0 all pass, 65 a helper failed, 70 environment, 64 usage.
# Dumps go to RUN_DIR/calibration/. --dry-run prints the plan and touches nothing.
exec python3 "${0:A:h}/finderdrive.py" calibrate "$@"
