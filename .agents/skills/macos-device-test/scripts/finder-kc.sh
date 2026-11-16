#!/bin/zsh
# finder-kc.sh KEYCODE [command|control|option|shift ...] — key code to Finder (Esc 53 closes a menu, Return 36).
[[ $# -ge 1 && $1 == <-> ]] || { print -u2 'usage: finder-kc.sh KEYCODE [modifiers...]'; exit 2 }
code=$1; shift
for m in "$@"; do [[ $m == (command|control|option|shift) ]] || { print -u2 "FAIL finder-kc — invalid modifier $m"; exit 2 }; done
mods=(); for m in "$@"; do mods+=("$m down"); done
using=""; (( $# )) && using=" using {${(j:, :)mods}}"
osascript -e "tell application \"System Events\" to tell process \"Finder\" to key code $code$using"
