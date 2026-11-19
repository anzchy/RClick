# Actions

The Actions section of the RClick menu copies paths or names, hides and unhides items, deletes permanently, and
shares through AirDrop, always for every selected item.

## Sub-features

- `ACT-01`: Copy Path puts every selected item's full path on the pasteboard, one per line, and also file URLs so
  Finder can paste the files.
- `ACT-02`: Copy File Name puts every selected item's name (no path), one per line.
- `ACT-03`: Hide sets the hidden flag on every selected item; Unhide clears it.
- `ACT-04`: Delete Direct without Option shows a confirmation; Cancel keeps the files; confirming removes them
  permanently (not in the Trash).
- `ACT-05`: Delete Direct with Option held while the menu opens shows the title with **(skip confirmation)** and
  deletes without a dialog.
- `ACT-06`: AirDrop opens the AirDrop share sheet for the selection.
- `ACT-07`: a folder outside every granted folder triggers the permission flow first (see `PERM-01`).

## How to get to it (user POV)

Select one or more items in Finder, right-click, and choose the action (inline or in the **Actions** submenu).

## Driving it

Preconditions: baseline; the fixture folder is granted, or `PERM-01` runs first. Tell the user the pasteboard is
used.

1. `ACT-01`: select `alpha.txt` and `beta with spaces.md`; right-click → Copy Path. Result: `pbpaste` prints both
   absolute paths, one per line, in selection order; save it to `$RUN_DIR/ACT-01.txt`. Paste in a Finder window
   other than the fixtures one only if the brief asks (it copies files).
2. `ACT-02`: same selection plus `中文 名称.txt` → Copy File Name. Result: `pbpaste` prints the three names exactly,
   non-ASCII intact.
3. `ACT-03`: select `alpha.txt` → Hide. Result: `ls -lO` shows `hidden`; Finder no longer lists it (unless the owner
   shows hidden files). Show hidden files with ⌘⇧. only if the owner agrees, then select it → Unhide. Result: flag
   cleared. Without ⌘⇧., Unhide on the container trigger is the user path; record which one was used.
4. `ACT-04`: select `delete-1.txt` → Delete Direct. Result: a confirmation (`ui.sh dialog <rclick pid>`: the title, the
   Cancel button and the tip about Option; `ui.sh press-button <rclick pid> Cancel`); capture `ACT-04-confirm`. Cancel → the file is still there (`shasum`
   matches `fixtures.sha256`). Repeat and confirm → the file is gone and is not in `~/.Trash`.
5. `ACT-05`: read the menu: `ui.sh open-menu delete-2.txt --option`, then `ui.sh menu X,Y` (the `menu-point`).
   Result: the item title ends with **(skip confirmation)**. Close it: `ui.sh close-menu X,Y` (`choose` opens its own
   menu, and with a menu already open its first AppleScript call to Finder times out: exit 70). Then act:
   `ui.sh choose "Delete Direct (skip confirmation)" --option --group … --target "$RUN_DIR/fixtures/delete-2.txt"`
   (RClick's full `--group` run; without `--option` the menu has only the confirming Delete Direct) → `GUARD PASS`,
   no dialog, the file is gone, not in the Trash. Log shows the Option state at menu build. If the title lacks the suffix, NOT VERIFIED (synthetic Option not seen by the extension) unless a real
   held Option reproduces it with the owner.
6. `ACT-06`: select `alpha.txt` → AirDrop. Result: the system AirDrop sheet appears; capture and cancel it. Never send.

## Gotchas

- Delete Direct is permanent. Use only `delete-*.txt` fixtures, and check paths in the menu screenshot before
  confirming.
- The Option state is read when the menu is **built**, not when the item is chosen; pressing Option after the menu
  opens changes nothing (by design).
- Hide/Unhide changes Finder's view of the fixture folder; take the `ls -lO` readback before and after.
