#!/bin/zsh
# panel-choose.sh RUN_DIR PATH — in an open NSOpenPanel/powerbox of the run's RClick: ⌘⇧G, write PATH into the
# Go-to field through accessibility, read it back, Return (go), check the sheet closed, Return (Open/Grant).
# Ported from picsee (Mado). There, on 2026-10-28, a ⌘A ⌘V paste never reached the Go-to field, so Return confirmed
# whatever folder the panel remembered while the script reported success. Writing the AX value bypasses the pasteboard
# and the input method, and every step is verified; any mismatch fails before Open is pressed.
# In RClick the panel is PermissionService.promptForPermission's folder-authorization NSOpenPanel.
# Synthetic input: disclose it in the validation record.
[[ $# -eq 2 && -n $2 ]] || { print -u2 'usage: panel-choose.sh RUN_DIR PATH'; exit 2 }
here=${0:A:h}
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
run=$1 target=$2
[[ -r $run/rclick.pid ]] || { print -u2 "FAIL panel-choose — no $run/rclick.pid; launch through launch.sh or record the identity first"; exit 1 }
pid=${"$(<$run/rclick.pid)"%%$'\n'*}
[[ $pid == <-> ]] || { print -u2 -r -- "FAIL panel-choose — $run/rclick.pid does not start with a pid line"; exit 1 }

key() { $here/kc.sh $run "$@" >/dev/null || { print -u2 -r -- "FAIL panel-choose — key $* failed"; return 1 } }
# AX on the panel of this run's process. A runModal panel is its own AXDialog window; a beginSheetModal panel is
# sheet 1 of window 1 (e.g. the Settings window). Neither form has been driven live in RClick yet: disclose it.
proc="first process whose unix id is $pid"
osa() { osascript -e "tell application \"System Events\" to tell ($proc) to $1" 2>/dev/null }
if [[ $(osa 'return exists (first window whose subrole is "AXDialog")') == true ]]; then
  panel='first window whose subrole is "AXDialog"'
elif [[ $(osa 'return exists sheet 1 of window 1') == true ]]; then
  panel='sheet 1 of window 1'
else
  print -u2 'FAIL panel-choose — no open panel (AXDialog window or window sheet) on the run process'; exit 1
fi
print -r -- "panel: $panel"
ax() { osa "tell ($panel) to $1" }
panel_open() { [[ $(osa "return exists ($panel)") == true ]] }
wait_sheets() { local want=$1 t; for t in {1..20}; do [[ $(ax 'return count of sheets') == $want ]] && return 0; sleep 0.25; done; return 1 }

source_id=$(osascript -l JavaScript -e 'ObjC.import("Carbon"); ObjC.castRefToObject($.TISGetInputSourceProperty($.TISCopyCurrentKeyboardInputSource(), $.kTISPropertyInputSourceID)).js' 2>&1) &&
  print -r -- "input-source: $source_id" || print -r -- "input-source: unknown (${source_id%%$'\n'*})"

key 5 command shift || exit 1
wait_sheets 1 || { print -u2 'FAIL panel-choose — Go-to sheet did not open'; exit 1 }
quoted=${target//\\/\\\\}; quoted=${quoted//\"/\\\"}
ax "set value of text field 1 of sheet 1 to \"$quoted\"" >/dev/null
got=$(ax 'return value of text field 1 of sheet 1')
[[ $got == $target ]] || { print -u2 -r -- "FAIL panel-choose — Go-to field holds '$got', not the target; nothing chosen"; key 53; exit 1 }
key 36 || exit 1
wait_sheets 0 || { print -u2 -r -- "FAIL panel-choose — Go-to sheet still open after Return (path not found?); nothing chosen"; key 53; exit 1 }
key 36 || exit 1
for t in {1..20}; do panel_open || break; sleep 0.25; done
panel_open && { print -u2 -r -- "FAIL panel-choose — panel still open after Open (button disabled or wrong kind of item?); nothing chosen"; key 53; exit 1 }
print -r -- "chose: $target"
