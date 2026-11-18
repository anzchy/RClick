# AX dump fixtures

Replayed by `test_finderui.py`; each file is in the JSON-lines format `axprobe.swift` prints (one element per line;
see `finderui.py`). They hold no personal path and no machine identifier: replace any such value before adding a dump.

| File | Source | Exact or shaped |
|---|---|---|
| `finder-window-display-order.jsonl` | names and on-screen y of `ax-row-order.txt`, run i5-device-20261117d; the AX tree order is the AppleScript `items` order of the same run | names, display order and y are recorded; the element shape (outline, cells, text field) is reconstructed |
| `finder-window-duplicate-name.jsonl` | two expanded folders that each hold `inner.txt` | constructed |
| `menu-file-alpha.jsonl` | `menu-alpha.txt`, run i22-device-20261116e (Finder, RClick and other extensions' items with centres) | titles, order, enabled flags and centres are recorded; frames are derived from the centres |
| `menu-file-sibling-option.jsonl` | the same menu as seen in run i5-device-20261117b when the click landed on the sibling: `Compress “%41.txt”` while `%2541.txt` was the target, opened with Option | derived from the two records |
| `dialog-delete-confirm.jsonl` | the Delete Direct confirmation of `a-dialog.txt`, run i5-device-20261117d, above the Settings window | texts and buttons recorded; frames constructed |
| `process-table.txt` | per pid: `ps -o pid=,comm=` comm and the executable `proc_pidpath` resolved, captured on the test Mac (device run, 2026-11-18): Finder, FinderSyncExt, universalAccessAuthWarn, UserNotificationCenter, tccd, an `osascript` spawned by a PATH lookup (comm `osascript`) and by its absolute path, `/bin/sleep` with Finder's path as argv[0] | recorded, build paths replaced by `/private/tmp/…`; the RClick, System Settings, other-extension and open-panel-service lines are constructed in the same format (marked in the file) |
| `panel-grant.jsonl` | the folder-permission panel of RClick, `PERM-panel-ax-newfile.txt`, run i22-device-20261116e | VERIFIED against that dump: an `AXWindow` titled `Open` in the RClick process, its sidebar `AXOutline`, the prompt text and the `Cancel` / `Grant Access` buttons. UNVERIFIED (ASSUMED, not in any recorded dump): the file list (`AXOutline` of `AXRow`s in list view), the location `AXPopUpButton` and its value, and the `url` (AXURL) on the file-list rows that `ui.sh grant` takes the full location from; the calibration's `panel-*.jsonl` and `rclick-panel.jsonl` dumps settle them |

When a calibration run saves real dumps (`$RUN_DIR/calibration/*.jsonl`), the delegator may replace a shaped
fixture with the real one (personal paths removed) through a ticket; the tests must still pass on it.
