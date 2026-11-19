#!/bin/zsh
# modifiers.sh state | check DOING | release MODIFIER... — the HID system's modifier state, for the Finder UI driver.
#   state    prints `flags=0x<hex>`: CGEventSourceFlagsState(kCGEventSourceStateHIDSystemState). A read: no event.
#   check    the same read, fail closed, for the raw click scripts before they post anything: exit 65 (REFUSED, on
#            stderr, naming the key) when Shift, Control, Option or Command is held, 70 when the state cannot be
#            read; else prints the state line and exits 0. DOING says what was not done.
#   release  for each of option|shift|control|command: the key-up of its left and right key, then one flagsChanged
#            event whose flags are the HID state read just before minus the released modifiers (so a key someone else
#            holds, Caps Lock and the other bits stay as they were), all posted at the HID tap; then prints the state
#            read again. Exit 1 when a released modifier still shows as held. Run it only for a modifier this process
#            pressed (rightclick.sh option, finderdrive.py): it releases that key whoever holds it.
usage='usage: modifiers.sh state | check DOING | release option|shift|control|command...'
case $1 in
  state) (( $# == 1 )) || { print -u2 $usage; exit 2 } ;;
  check) (( $# == 2 )) || { print -u2 $usage; exit 2 } ;;
  release)
    (( $# >= 2 )) || { print -u2 $usage; exit 2 }
    for m in "${@:2}"; do [[ $m == (option|shift|control|command) ]] || { print -u2 "FAIL modifiers — invalid modifier $m"; exit 2 }; done ;;
  *) print -u2 $usage; exit 2 ;;
esac
if [[ $1 == check ]]; then
  line=$("${0:A}" state 2>&1)
  if [[ $? -ne 0 || ! $line =~ '^flags=0x([0-9a-f]+)' ]]; then
    print -u2 "ENVIRONMENT: modifiers.sh state printed '${line[1,120]}': the modifier state is unknown, so nothing was posted ($2)"
    exit 70
  fi
  integer flags=$(( 16#${match[1]} ))
  held=()
  (( flags & 0x20000 )) && held+=(Shift)
  (( flags & 0x40000 )) && held+=(Control)
  (( flags & 0x80000 )) && held+=(Option)
  (( flags & 0x100000 )) && held+=(Command)
  if (( $#held )); then
    print -u2 "REFUSED: ${(j: and :)held} held down in the HID system state ($line) that this command did not press: $2. A stuck modifier changes what a click does (Option makes Delete Direct skip its confirmation). Release it (press and release that key on the keyboard, or \`modifiers.sh release <key>\` when no one is holding it), check \`modifiers.sh state\` shows no modifier, record it under Script problems, then rerun"
    exit 65
  fi
  print -r -- $line
  exit 0
fi
osascript -l JavaScript - "$@" <<'JXA'
ObjC.import('CoreGraphics'); ObjC.import('Foundation');
var MASK = {shift: 0x20000, control: 0x40000, option: 0x80000, command: 0x100000};
var KEYS = {shift: [56, 60], control: [59, 62], option: [58, 61], command: [55, 54]};
function flags() { return Number($.CGEventSourceFlagsState(1)); } // 1 = kCGEventSourceStateHIDSystemState
function line() { return 'flags=0x' + flags().toString(16); }
function run(a) {
  if (a[0] === 'state') return line();
  var names = a.slice(1);
  var clear = 0;
  names.forEach(function (name) { clear |= MASK[name]; });
  var keep = (flags() & ~clear) >>> 0; // only the released modifiers go: what else is set stays set
  names.forEach(function (name) {
    KEYS[name].forEach(function (code) {
      var up = $.CGEventCreateKeyboardEvent(null, code, false); $.CGEventSetFlags(up, keep); $.CGEventPost(0, up);
    });
  });
  var changed = $.CGEventCreate(null); $.CGEventSetType(changed, 12); $.CGEventSetFlags(changed, keep); // flagsChanged
  $.CGEventPost(0, changed);
  $.NSThread.sleepForTimeInterval(0.05);
  var still = names.filter(function (name) { return (flags() & MASK[name]) !== 0; });
  if (still.length) throw new Error(still.join(', ') + ' still held after the release (' + line() + ')');
  return line();
}
JXA
