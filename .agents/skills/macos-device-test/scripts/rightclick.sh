#!/bin/zsh
# rightclick.sh X Y [option] — synthetic right click (move, down, up) at a screen point, in points.
# With `option`, the Option flag is set on the down/up events (Delete Direct's skip-confirmation title is decided
# while the menu is built, so hold Option on the click that opens the menu). Disclosed substitute for a real click.
# Before anything is posted the modifier state is read (modifiers.sh check, no event): Shift, Control, Option or
# Command already held → 65, unreadable → 70, nothing posted and nothing released (fix r6: a held key is the owner's
# or a stuck one, and the click would act on it).
# Posting events with the Option flag at the HID tap leaves Option set in the HID system state until something
# clears it (device run, 2026-11-18: every later plain menu showed `Delete Direct (skip confirmation)`). So with
# `option` the flag is held for HOLD seconds after the click (for the menu to be built), then released in a
# `finally`: the Option key-ups and a flagsChanged event whose flags are the HID state minus Option (only what this
# script pressed; never all-zero flags, which would also clear a key someone else holds), and again by a trap on
# INT, TERM and HUP. finderdrive.py releases and checks it once more after this script returns.
[[ $# -eq 2 || ( $# -eq 3 && $3 == option ) ]] || { print -u2 'usage: rightclick.sh X Y [option]'; exit 2 }
[[ $1 == <-> && $2 == <-> ]] || { print -u2 'FAIL rightclick — X and Y must be whole screen points'; exit 2 }
here=${0:A:h}
"$here/modifiers.sh" check 'rightclick.sh posted nothing' >/dev/null || exit $?
if [[ $3 == option ]]; then
  trap '"$here/modifiers.sh" release option >/dev/null; exit 130' INT
  trap '"$here/modifiers.sh" release option >/dev/null; exit 143' TERM
  trap '"$here/modifiers.sh" release option >/dev/null; exit 129' HUP
fi
osascript -l JavaScript - "$@" <<'JXA'
ObjC.import('CoreGraphics'); ObjC.import('Foundation');
var HOLD = 1.0; // seconds Option stays set after the click: the extension reads it once, while Finder builds the menu
function release() { // only the Option this script pressed: every other flag of the HID state stays as it is
  var keep = (Number($.CGEventSourceFlagsState(1)) & ~0x80000) >>> 0;
  [58, 61].forEach(function (code) {
    var up = $.CGEventCreateKeyboardEvent(null, code, false); $.CGEventSetFlags(up, keep); $.CGEventPost(0, up);
  });
  var changed = $.CGEventCreate(null); $.CGEventSetType(changed, 12); $.CGEventSetFlags(changed, keep); // flagsChanged
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
