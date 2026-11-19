#!/bin/zsh
# rightclick.sh X Y [option] — synthetic right click (move, down, up) at a screen point, in points.
# With `option`, the Option flag is set on the down/up events (Delete Direct's skip-confirmation title is decided
# while the menu is built, so hold Option on the click that opens the menu). Disclosed substitute for a real click.
# Posting events with the Option flag at the HID tap leaves Option set in the HID system state until something
# clears it (device run, 2026-11-18: every later plain menu showed `Delete Direct (skip confirmation)`). So with
# `option` the flag is held for HOLD seconds after the click (for the menu to be built), then released (the Option
# key-up and a flagsChanged event with no flags: modifiers.sh release) in a `finally`, and again by a trap on
# INT, TERM and HUP. finderdrive.py releases and checks it once more after this script returns.
[[ $# -eq 2 || ( $# -eq 3 && $3 == option ) ]] || { print -u2 'usage: rightclick.sh X Y [option]'; exit 2 }
[[ $1 == <-> && $2 == <-> ]] || { print -u2 'FAIL rightclick — X and Y must be whole screen points'; exit 2 }
here=${0:A:h}
if [[ $3 == option ]]; then
  trap '"$here/modifiers.sh" release option >/dev/null; exit 130' INT
  trap '"$here/modifiers.sh" release option >/dev/null; exit 143' TERM
  trap '"$here/modifiers.sh" release option >/dev/null; exit 129' HUP
fi
osascript -l JavaScript - "$@" <<'JXA'
ObjC.import('CoreGraphics'); ObjC.import('Foundation');
var HOLD = 1.0; // seconds Option stays set after the click: the extension reads it once, while Finder builds the menu
function release() {
  [58, 61].forEach(function (code) {
    var up = $.CGEventCreateKeyboardEvent(null, code, false); $.CGEventSetFlags(up, 0); $.CGEventPost(0, up);
  });
  var changed = $.CGEventCreate(null); $.CGEventSetType(changed, 12); $.CGEventSetFlags(changed, 0); // flagsChanged
  $.CGEventPost(0, changed);
}
function run(a){ var p={x:+a[0],y:+a[1]}; var flags = a[2]==='option' ? 0x80000 : 0;
 function post(t){ var e=$.CGEventCreateMouseEvent(null,t,p,1); if(flags) $.CGEventSetFlags(e,flags); $.CGEventPost(0,e); }
 try {
  post(5); $.NSThread.sleepForTimeInterval(0.05);
  post(3); $.NSThread.sleepForTimeInterval(0.06);
  post(4);
  if (flags) $.NSThread.sleepForTimeInterval(HOLD);
 } finally { if (flags) release(); }
 return 'right-clicked' + (flags ? ' with option, released' : ''); }
JXA
