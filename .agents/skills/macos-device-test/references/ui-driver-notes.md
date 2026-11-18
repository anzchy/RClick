# Finder UI driver: pitfalls ledger

What real runs found out about driving Finder on the device-test Mac, and what the helpers do about it. One dated
entry per pitfall: symptom, cause, fix, evidence. Evidence is a run ID (its private record is in
`~/.rclick-roster/device/<run-id>/`, never copied here) or an issue on `anzchy/RClick`.

**The correction loop.** The tester never edits the repo. When a helper breaks or misleads during a run, the tester
writes it under "Script problems" in the validation record (what broke, what was done instead, which helper). After
the run the delegator collects those rows into this ledger and fixes the scripts through a ticket or PR (with a
failing offline test first where the logic is testable; a calibration dump in `$RUN_DIR/calibration/` can become a
fixture in `scripts/fixtures/` once personal paths are removed).

Helpers: `scripts/ui.sh` (rows, select, selection, open-menu, menu, guard, choose, dialog, press-button, grant),
`scripts/calibrate.sh`. Logic in `finderui.py` (unit-tested with `fixtures/`), AX calls in `axprobe.swift`, side
effects in `finderdrive.py` and `calibration.py`.

## Entries

### 2026-11-17 — AppleScript `items` order is not Finder's display order

- Symptom: a right-click at coordinates computed from the AppleScript `items` order landed on the sibling row; Delete
  Direct removed `%44ocuments` while `%2544ocuments` was the target, and the run recorded a FAIL for a product bug
  that did not exist. A fix round was nearly started for it.
- Cause: Finder's list view sorts with its own collation; `items of folder` comes in another order. Finder's own
  `Compress “%41.txt”` title at that click showed the menu belonged to the sibling.
- Fix: `ui.sh rows` and `ui.sh open-menu` order rows by their AX frames (on-screen y), never by AppleScript order.
  The guard (`ui.sh guard`, built into `ui.sh choose`) compares the Compress title and the selection with the
  target before any RClick item is chosen. Test: `test_finderui.Rows`, `test_finderui.Guard`.
- Evidence: i5-device-20261117b (the FAIL), i5-device-20261117c ("Key harness finding", the AX row order).

### 2026-11-17 — `AXShowMenu` is unsupported on Finder rows

- Symptom: `AXShowMenu` on a Finder list row returns error -25206 and opens nothing.
- Cause: Finder's rows do not implement that action.
- Fix: `ui.sh open-menu NAME` sets `AXSelected` on the row, then posts a synthetic right-click (`rightclick.sh`) at
  the centre of the row's name cell read from AX. Disclose the synthetic click in the record.
- Evidence: i5-device-20261117c.

### 2026-11-16 — System Events cannot see Finder's context menu (`finder-menu.sh`, `axdump.sh`)

- Symptom: with a context menu visibly open, `finder-menu.sh` found no `AXMenu` under Finder and `axdump.sh` listed
  no menu items.
- Cause: the open context menu is not reachable from Finder's application element through System Events on this
  macOS; the element at the menu's screen position is.
- Fix: `ui.sh menu X,Y` reads the menu with `AXUIElementCopyElementAtPosition` (axprobe `menu-at`) at the
  `menu-point` that `open-menu` prints; items are pressed with `AXPress` (`ui.sh choose`), not clicked by
  coordinates. `finder-menu.sh` and `axdump.sh` are removed; `ui.sh dialog PID` replaces `axdump.sh` for alerts.
- Evidence: i22-device-20261116e, i13-device-20261117c; #26.

### 2026-11-16 — the folder panel helper depended on the input source

- Symptom: `panel-choose.sh` opened the Go-to sheet, but Return never confirmed it under a pinyin input method; the
  sheet stayed open, the panel was cancelled, and the app logged that the user cancelled the authorization.
- Cause: the helper drove the panel with key codes (⌘⇧G, Return) that pass through the input method.
- Fix: `ui.sh grant PID FOLDER` uses no keyboard: it selects the folder's row in the panel's file list (never the
  sidebar) through AX and presses the button by title (`Grant Access`). It refuses when the panel's location pop-up
  does not show the folder's parent, or when the row is missing or ambiguous. When the panel already shows the
  folder itself it presses the button without a row ('current' mode). `panel-choose.sh` is removed.
- Evidence: i22-device-20261116e (the failure, then the AX row-select + `Grant Access` that worked),
  i13-device-20261117c (the same AX path worked again); #26.

### 2026-11-17 — coordinates drift when the list shifts after a delete

- Symptom: after `del-1.txt` was deleted the rows moved up; a right-click at the old y of `del-2.txt` hit the fixture
  folder `docs`, and an Option Delete Direct removed it.
- Cause: coordinates were reused after the list changed.
- Fix: `ui.sh open-menu` never takes coordinates: it reads the rows fresh on every call, re-reads them after
  selecting and refuses if the row moved; the guard refuses a menu whose Compress title or selection is not the
  target. Never reuse a `menu-point` after the menu closed.
- Evidence: i13-device-20261117c ("Operator slip").

### 2026-11-16 — Accessibility is required; Screen Recording is optional

- Symptom: with the host terminal not AX-trusted, no Finder check could be driven (synthetic clicks, menus, alerts,
  panels all need it); every Finder row was NOT VERIFIED.
- Cause: AX and posted events need the Accessibility grant of the process that runs the helpers (the host terminal).
- Fix: Accessibility for the host terminal is a precondition (doctor `accessibility`, calibration `accessibility`).
  The owner grants it; it took effect without restarting the terminal. Screen Recording is not needed: runs without
  it read menus, alerts and panels through AX dumps instead of screenshots.
- Evidence: i22-device-20261116d (untrusted host), i13-device-20261117c and i22-device-20261116e (no Screen
  Recording, AX dumps as evidence); #26.

### 2026-11-17 — Finder does not load the extension from a rebuilt bundle path until the owner toggles it

- Symptom: doctor `extension-process` FAIL; Finder never started `FinderSyncExt` from the run's bundle, even after
  right-clicks and a 30 s wait; the RClick section was missing from the menu.
- Cause: Finder keeps the extension it elected before; a new bundle path is not picked up by itself.
- Fix: none in the scripts (enabling extensions is the owner's step). The run stops and asks the owner to toggle
  RClick off and on in System Settings → General → Login Items & Extensions → Finder (or relaunch Finder), then
  resumes. Calibration's `rclick-group` step fails in this state.
- Evidence: i5-device-20261117c.

### 2026-11-16 — stale LaunchServices registrations from scratch builds

- Symptom: System Settings listed several RClick entries; 40 ghost registrations (29 with the old bundle ID, 11 with
  the new one) came from scratch and verification builds.
- Cause: every built `RClick.app` is registered with LaunchServices and stays registered.
- Fix: not in this skill's scripts (the builds that register are `scripts/gates.sh`/owner builds, outside its
  scope). They were removed with `lsregister -u` after the owner approved it, deleting no files. A device run never
  runs `lsregister` or `pluginkit -e/-a/-r` on its own; it reports and asks (runbook §3, §11).
- Evidence: #26.

### 2026-11-16 — doctor's pluginkit parsing

- Symptom: `launch.sh` printed `FAIL launch — unrecognised pluginkit line: (2 plug-ins)`.
- Cause: `pluginkit -m -A -v` ends with a `(N plug-ins)` summary line and a blank line.
- Fix: `device.parse_pluginkit` accepts exactly that summary line and still fails closed on any other unknown line
  (`test_device.Pluginkit`).
- Evidence: i22-device-20261116.

### 2026-11-16 — other extensions share the context menu with RClick

- Symptom: the menu holds other extensions' items right after RClick's, with no separator, including a second
  `Copy Path` and a second `New File` submenu.
- Cause: Finder lists all extension items after its own `Quick Actions` item.
- Fix: `ui.sh menu`/`choose` take RClick's group as the run of known RClick titles after `Quick Actions`, ending at
  the first unknown or repeated title; `choose` refuses a title outside that group. A user-added Open With app or
  common folder needs `--also "<title>"`. Test: `test_finderui.Menu`, `test_finderui.Choose`.
- Evidence: i22-device-20261116e.

### 2026-11-17 — Finder's Compress title names the raw file name

- Symptom: none; this is what makes the guard reliable for percent-encoded names.
- Cause: Finder titles the item `Compress “%2544ocuments”` with the on-disk name, undecoded.
- Fix: the guard expects `Compress “<basename of the target>”` (`Compress N Items` for N targets; that plural form is
  UNVERIFIED on a real run) and an English system language; another language makes the guard refuse.
- Evidence: i5-device-20261117d.

### 2026-11-17 — the Option flag on the synthetic right-click is seen by the extension

- Symptom: none; it was listed as unverified.
- Cause: the extension reads the modifier state while it builds the menu; the CGEvent flag reaches it.
- Fix: `ui.sh open-menu NAME --option` (`rightclick.sh X Y option`) shows `Delete Direct (skip confirmation)`.
- Evidence: i22-device-20261116e, i13-device-20261117c.

### 2026-11-18 — not yet proven on a real run (first calibration decides)

- The file list of the folder panel: its element shape (outline rows in list view, or a column browser) and the value
  of its location pop-up were not in any recorded dump. `ui.sh grant` assumes rows (`AXRow`) and a pop-up whose value
  is the shown folder's name. Calibration steps `panel-grant-row` and `panel-grant-current` prove or refute it on
  an `osascript choose folder` panel, and save the dumps (`calibration/panel-*.jsonl`).
- The osascript `display alert` stands in for RClick's alerts in `dialog-read`/`press-button`; the real Delete Direct
  confirmation was read through AX the same way (i5-device-20261117d).
