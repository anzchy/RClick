#!/bin/zsh
# ui.sh COMMAND ... — the Finder UI driver: rows, select, selection, open-menu, menu, close-menu, choose, dialog,
# press-button, grant. `ui.sh --help` prints every command. Exit 0 ok, 64 usage, 65 refused (target missing,
# ambiguous or mismatched: nothing was done, an open menu was closed), 70 environment (no Accessibility, GUI lock
# not held by an rclick run, axprobe build, Finder). Acting commands need the GUI lock (gui-lock.sh acquire).
exec python3 "${0:A:h}/finderdrive.py" "$@"
