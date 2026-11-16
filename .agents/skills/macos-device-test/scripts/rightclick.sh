#!/bin/zsh
# rightclick.sh X Y [option] — synthetic right click (move, down, up) at a screen point, in points.
# With `option`, the Option flag is set on the down/up events (Delete Direct's skip-confirmation title is decided
# while the menu is built, so hold Option on the click that opens the menu). Disclosed substitute for a real click.
[[ $# -eq 2 || ( $# -eq 3 && $3 == option ) ]] || { print -u2 'usage: rightclick.sh X Y [option]'; exit 2 }
[[ $1 == <-> && $2 == <-> ]] || { print -u2 'FAIL rightclick — X and Y must be whole screen points'; exit 2 }
osascript -l JavaScript - "$@" <<'JXA'
ObjC.import('CoreGraphics'); ObjC.import('Foundation');
function run(a){ var p={x:+a[0],y:+a[1]}; var flags = a[2]==='option' ? 0x80000 : 0;
 function post(t){ var e=$.CGEventCreateMouseEvent(null,t,p,1); if(flags) $.CGEventSetFlags(e,flags); $.CGEventPost(0,e); }
 post(5); $.NSThread.sleepForTimeInterval(0.05);
 post(3); $.NSThread.sleepForTimeInterval(0.06);
 post(4); return 'right-clicked' + (flags ? ' with option' : ''); }
JXA
