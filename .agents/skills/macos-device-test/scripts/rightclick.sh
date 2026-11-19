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
# script pressed; never all-zero flags, which would also clear a key someone else holds), and again by this shell
# however osascript ended (a SIGTERM or SIGKILL of osascript skips its `finally`) and on the shell's own INT, TERM
# and HUP (fix r6). finderdrive.py releases and checks it once more after this script returns.
[[ $# -eq 2 || ( $# -eq 3 && $3 == option ) ]] || { print -u2 'usage: rightclick.sh X Y [option]'; exit 2 }
[[ $1 == <-> && $2 == <-> ]] || { print -u2 'FAIL rightclick — X and Y must be whole screen points'; exit 2 }
here=${0:A:h}
"$here/modifiers.sh" check 'rightclick.sh posted nothing' >/dev/null || exit $?
jxa=$(cat <<'JXA'
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
 return flags ? 'posted' : 'right-clicked'; }
JXA
)
[[ $3 == option ]] || { osascript -l JavaScript - "$@" <<<"$jxa"; exit }

# With option: osascript runs in the background and the shell waits, so the shell outlives it and can still release
# when it ends without its `finally` (SIGTERM, SIGKILL, a crash), and can stop it when the shell itself gets INT, TERM
# or HUP. Whatever happened, finish releases ONLY Option (modifiers.sh release option: the HID state minus Option),
# reads the state back, keeps the click's failure status and never prints "released" when Option is still set.
child=0
finish() {  # $1: the status to keep (0 when the click finished)
  trap '' INT TERM HUP  # a second signal must not cut the release short
  local keep=$1 out
  if out=$("$here/modifiers.sh" release option 2>&1); then
    if (( keep )); then print -u2 "FAIL rightclick — the click did not finish (status $keep); Option released ($out)"
    else print "right-clicked with option, released ($out)"; fi
  else
    print -u2 "FAIL rightclick — Option could not be released after the click: ${out//$'\n'/ }. Every acting ui.sh command and raw click refuses until \`modifiers.sh state\` shows no modifier: press and release Option on the keyboard (or \`modifiers.sh release option\`), then check \`modifiers.sh state\`"
    (( keep )) || keep=70
  fi
  exit $keep
}
interrupted() {  # $1: the shell's own exit status for the signal
  trap '' INT TERM HUP
  (( child )) && { kill -TERM $child 2>/dev/null; wait $child 2>/dev/null }
  finish $1
}
trap 'interrupted 130' INT
trap 'interrupted 143' TERM
trap 'interrupted 129' HUP
osascript -l JavaScript - "$@" <<<"$jxa" >/dev/null &
child=$!
wait $child
code=$?
child=0
finish $code
