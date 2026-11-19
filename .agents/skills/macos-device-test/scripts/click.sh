#!/bin/zsh
# click.sh X Y — synthetic left click (down/up) at a screen point. Disclosed substitute for a real click.
# Refused before anything is posted (modifiers.sh check, a read): 65 when Shift, Control, Option or Command is held
# (a stuck Option turns Delete Direct into its skip-confirmation form), 70 when the state cannot be read.
[[ $# -eq 2 && $1 == <-> && $2 == <-> ]] || { print -u2 'usage: click.sh X Y (whole screen points)'; exit 2 }
"${0:A:h}/modifiers.sh" check 'click.sh posted nothing' >/dev/null || exit $?
osascript -l JavaScript - "$1" "$2" <<'JXA'
ObjC.import('CoreGraphics'); ObjC.import('Foundation');
function run(a){ var p={x:+a[0],y:+a[1]};
 $.CGEventPost(0,$.CGEventCreateMouseEvent(null,5,p,0)); $.NSThread.sleepForTimeInterval(0.05);
 $.CGEventPost(0,$.CGEventCreateMouseEvent(null,1,p,0)); $.NSThread.sleepForTimeInterval(0.06);
 $.CGEventPost(0,$.CGEventCreateMouseEvent(null,2,p,0)); return 'clicked'; }
JXA
