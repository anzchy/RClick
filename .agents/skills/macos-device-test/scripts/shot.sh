#!/bin/zsh
set -eu
# usage: shot.sh RUN_DIR NAME [x,y,w,h] -> RUN_DIR/shots/NAME.png
# Captures the main display (or a rectangle in points). Context menus and alerts belong to Finder and
# FinderSyncExt, not to RClick, so a PID-addressed window capture cannot see them. Keep the capture small:
# pass the rectangle around the menu when you can, and never capture with private windows on screen.
exec python3 "${0:A:h}/screenshot.py" "$@"
