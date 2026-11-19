#!/bin/zsh
# modifiers.sh state | release MODIFIER... — the HID system's modifier state, for the Finder UI driver.
#   state    prints `flags=0x<hex>`: CGEventSourceFlagsState(kCGEventSourceStateHIDSystemState). A read: no event.
#   release  for each of option|shift|control|command: the key-up of its left and right key, then one flagsChanged
#            event with every flag cleared (the event that cleared the stuck Option on the device run, 2026-11-18),
#            all posted at the HID tap; then prints the state read again. Exit 1 when a released modifier still
#            shows as held. Releasing clears every modifier flag of the HID state, so run it only for a modifier
#            this process pressed (rightclick.sh option, finderdrive.py).
case $1 in
  state) (( $# == 1 )) || { print -u2 'usage: modifiers.sh state | release option|shift|control|command...'; exit 2 } ;;
  release)
    (( $# >= 2 )) || { print -u2 'usage: modifiers.sh release option|shift|control|command...'; exit 2 }
    for m in "${@:2}"; do [[ $m == (option|shift|control|command) ]] || { print -u2 "FAIL modifiers — invalid modifier $m"; exit 2 }; done ;;
  *) print -u2 'usage: modifiers.sh state | release option|shift|control|command...'; exit 2 ;;
esac
osascript -l JavaScript - "$@" <<'JXA'
ObjC.import('CoreGraphics'); ObjC.import('Foundation');
var MASK = {shift: 0x20000, control: 0x40000, option: 0x80000, command: 0x100000};
var KEYS = {shift: [56, 60], control: [59, 62], option: [58, 61], command: [55, 54]};
function flags() { return Number($.CGEventSourceFlagsState(1)); } // 1 = kCGEventSourceStateHIDSystemState
function line() { return 'flags=0x' + flags().toString(16); }
function run(a) {
  if (a[0] === 'state') return line();
  var names = a.slice(1);
  names.forEach(function (name) {
    KEYS[name].forEach(function (code) {
      var up = $.CGEventCreateKeyboardEvent(null, code, false); $.CGEventSetFlags(up, 0); $.CGEventPost(0, up);
    });
  });
  var changed = $.CGEventCreate(null); $.CGEventSetType(changed, 12); $.CGEventSetFlags(changed, 0); // flagsChanged
  $.CGEventPost(0, changed);
  $.NSThread.sleepForTimeInterval(0.05);
  var still = names.filter(function (name) { return (flags() & MASK[name]) !== 0; });
  if (still.length) throw new Error(still.join(', ') + ' still held after the release (' + line() + ')');
  return line();
}
JXA
