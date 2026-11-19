# Finder UI driver: pitfalls ledger

What real runs found out about driving Finder on the device-test Mac, and what the helpers do about it. One dated
entry per pitfall: symptom, cause, fix, evidence. Evidence is a run ID (its private record is in
`~/.rclick-roster/device/<run-id>/`, never copied here) or an issue on `anzchy/RClick`.

**The correction loop.** The tester never edits the repo. When a helper breaks or misleads during a run, the tester
writes it under "Script problems" in the validation record (what broke, what was done instead, which helper). After
the run the delegator collects those rows into this ledger and fixes the scripts through a ticket or PR (with a
failing offline test first where the logic is testable; a calibration dump in `$RUN_DIR/calibration/` can become a
fixture in `scripts/fixtures/` once personal paths are removed).

Helpers: `scripts/ui.sh` (rows, select, selection, open-menu, close-menu, menu, choose, dialog, press-button,
grant, lock-check), `scripts/calibrate.sh`. The checks each acting command makes: [ui-driver-safety.md](ui-driver-safety.md). Logic in `finderui.py` (unit-tested with `fixtures/`), AX calls in `axprobe.swift`, side
effects in `finderdrive.py` and `calibration.py`.

## Entries

### 2026-11-17 — AppleScript `items` order is not Finder's display order

- Symptom: a right-click at coordinates computed from the AppleScript `items` order landed on the sibling row; Delete
  Direct removed `%44ocuments` while `%2544ocuments` was the target, and the run recorded a FAIL for a product bug
  that did not exist. A fix round was nearly started for it.
- Cause: Finder's list view sorts with its own collation; `items of folder` comes in another order. Finder's own
  `Compress “%41.txt”` title at that click showed the menu belonged to the sibling.
- Fix: `ui.sh rows` and `ui.sh open-menu` order rows by their AX frames (on-screen y), never by AppleScript order.
  The guard inside `ui.sh choose` (there is no standalone `ui.sh guard` since #32 fix round 3) compares the Compress
  title and the selection with the target before any RClick item is chosen. Test: `test_finderui.Rows`, `test_finderui.Guard`.
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
- Superseded 2026-11-18 (#32 fix round 1): the known-titles run cannot tell RClick's items from another extension's
  same-titled ones. `choose` now needs `--group` (RClick's configured titles in order) and acts only in the ONE exact
  run of them after the LAST `Quick Actions`; the heuristic stays for reading (`ui.sh menu`). Test:
  `test_finderui.GroupIdentity`.
- Evidence: i22-device-20261116e.

### 2026-11-17 — Finder's Compress title names the raw file name

- Symptom: none; this is what makes the guard reliable for percent-encoded names.
- Cause: Finder titles the item `Compress “%2544ocuments”` with the on-disk name, undecoded.
- Fix: the guard expects `Compress “<basename of the target>”` (`Compress N Items` for N targets) and an English
  system language; another language makes the guard refuse.
- Evidence: i5-device-20261117d; the plural `Compress 2 Items`: device run, 2026-11-18 (the multi-selection rows).

### 2026-11-17 — the Option flag on the synthetic right-click is seen by the extension

- Symptom: none; it was listed as unverified.
- Cause: the extension reads the modifier state while it builds the menu; the CGEvent flag reaches it.
- Fix: `ui.sh open-menu NAME --option` (`rightclick.sh X Y option`) shows `Delete Direct (skip confirmation)`.
- Evidence: i22-device-20261116e, i13-device-20261117c.

### 2026-11-18 — not yet proven on a real run (first calibration decides)

- The file list of the folder panel: settled for the osascript panel by the device run, 2026-11-18 (a column
  browser, see the entry "the open panel is a column browser" below). Still not proven: that `AXSelected` on an
  entry's `AXGroup` makes the browser open it (`panel-grant-row`), and the shape of RClick's own sandboxed panel
  (PERM-01 proves it; calibration does not cover it).
- `ui.sh open-menu --background` clicks the middle of the empty list below the rows (`finderui.background_point`);
  that this opens the background menu, and that axprobe's `menu-session` re-check holds on a live menu, are proven
  by calibration steps `background-menu`, `background-choose` and `choose`.
- `ui.sh choose` reads Finder's front window through AX (`axprobe dump`) while its context menu is open, to bind the
  menu to the verified rows before the press (fix r4). Finder answering AX for its MENU while the menu is open is
  shown by the device run, 2026-11-18; answering AX for its WINDOW then is not. If it does not, `choose` refuses
  (65, nothing pressed) and calibration's `choose` step fails saying `cannot read the front Finder window through AX
  with the menu open`: that is the correct failure, not a reason to drop the check.
- The osascript `display alert` stands in for RClick's alerts in `dialog-read`/`press-button`; the real Delete Direct
  confirmation was read through AX the same way (i5-device-20261117d).

### 2026-11-18 — Finder does not answer AppleScript while its context menu is open (CONFIRMED)

- Symptom: with a Finder context menu open, every AppleScript call to Finder timed out after 20 s (exit 70):
  `ui.sh selection` after `ui.sh menu` left the menu open (and answered at once after Esc), `ui.sh open-menu
  --background` with a stale menu open, `ui.sh choose ... --target %41.txt` (nothing pressed), and calibration's
  `background-menu` step (`ui.sh guard --background` exited 70). Calibration's `guard` step was SKIP (a prior step
  had failed), not a timeout. System Events (AppleScript to another app) still answered. Calibration ended
  `CALIBRATION FAIL`, 13 helpers distrusted.
- Cause: Finder services Apple events only after its menu tracking ends; `guard`/`choose` read the selection (and
  the front window for `--background`) through AppleScript while the `menu-session` held the menu.
- Fix (#32 fix round 3): no AppleScript to Finder while a menu is open or about to open. `ui.sh choose` is one
  process: it selects through AppleScript BEFORE the right-click, then proves the target through AX (each target's
  row carries its full path as `AXURL`; the rows marked selected are exactly the targets; the row did not move),
  and checks the Compress title inside the menu session. `--background` takes the folder from the rows' `AXURL`
  parent (an empty folder is refused). The standalone `ui.sh guard` is removed: its pass did not carry to `choose`
  and it left a menu open for the next call to hang on. Test: `test_finderdrive.FakeDesktop` times out Finder
  AppleScript while a menu is open; `test_calibration.CalibrationThroughTheRealDriver`.
- Evidence: device run, 2026-11-18 ("Hypothesis settled", "Script problems").

### 2026-11-18 — the Compress title proves only a basename or a count (audit r3, offline)

- Symptom (offline, FakeDesktop): a change after the last AX read before the click, either another window in front
  with an equal file name at the click point or a same-size selection that keeps the clicked row, made Finder's
  menu act on other files while its title stayed `Compress “alpha.txt”` / `Compress 2 Items`; the guard passed and
  the press (Option: the skip-confirmation delete) was requested.
- Cause: the full-path identity was proven only BEFORE the right-click; after it only the title was checked.
- Fix (#32 fix round 4): with the menu open and held, `choose` reads the front window again through AX and requires
  the same selected `AXURL` set and the clicked row at the click point (`finderui.bound_menu`; background: the same
  front folder), else 65 and the menu closed. A gap remains between that read and `AXPress` (one AX dump, then the
  session's own owner and title re-check): it is milliseconds, not the seconds of the old gap. Test:
  `test_finderdrive.TheMenuIsBoundToTheVerifiedRows`.

### 2026-11-18 — `ui.sh close-menu` refused while a menu was open

- Symptom: `ui.sh close-menu` refused `Finder is not frontmost: no key sent` with a Finder menu open, so the menu
  stayed open; `finder-kc.sh 53` (Esc to Finder) closed it.
- Cause: its frontmost check (System Events) did not report Finder as frontmost while the menu was open.
- Fix: `ui.sh close-menu X,Y` reads the menu at the point through AX, cancels it with `AXCancel` (`axprobe
  menu-cancel`, owner pid checked: another process's menu is never touched), and only while AX still shows that
  Finder menu sends Esc to Finder through System Events. Every refusal or failure of `choose` or `open-menu` after its click
  closes the menu the same way (fix r4: also AX/transport errors and a session abort that times out; axprobe's
  session cancels only a menu Finder owns). UNVERIFIED on a device: that `AXCancel` closes a Finder context menu.
- Evidence: device run, 2026-11-18 ("Script problems").

### 2026-11-18 — the press allow-list compared `ps` comm, not the executable

- Symptom: `press-button`, `panel-grant-row` and `panel-grant-current` refused `pid N is osascript` for the
  calibration's own osascript, which the safety page allows.
- Cause: calibration spawned `osascript` through a PATH lookup, and `ps -o comm=` prints argv[0] (`osascript`), while
  the allow-list required `/usr/bin/osascript`. comm is whatever the process chose as argv[0], so it can also be
  spoofed (a real capture: `/bin/sleep` started with Finder's path as argv[0]).
- Fix: the allow-list reads the executable the kernel resolved (`proc_pidpath`), never comm; calibration spawns
  `/usr/bin/osascript`. Test: `test_finderui.ProcessAllowList` on a real capture (`fixtures/process-table.txt`).
- Evidence: device run, 2026-11-18 (calibration.txt; the capture on the same Mac).

### 2026-11-18 — the open panel is a column browser

- Symptom: both calibration grant steps would have refused "its file-list rows expose no AXURL".
- Cause: the `osascript choose folder` panel was in column view: `AXBrowser` → one `AXScrollArea` per column →
  `AXList` → one `AXGroup` per entry → `AXImage` + `AXTextField` (value = name, `url` = full path); no `AXRow`. The
  `selected` flag read False on every entry, even on the folders the browser showed opened. Columns 4 to 7 lay
  outside the window's frame.
- Fix: `ui.sh grant` reads the browser: the shown folder is the folder of the deepest column, each column must list
  an entry of the column before it, the `Where:` pop-up must agree; row mode selects the entry's `AXGroup` and
  presses only when the browser then shows the target. UNVERIFIED on a device: that `AXSelected` on the `AXGroup`
  opens the entry (it did not: see "`ui.sh grant` fails on the osascript panel" below), and the shape of RClick's
  own panel (PERM-01). Test: `test_finderui.PanelBrowser` on the
  sanitised real dumps (`fixtures/panel-browser-*.jsonl`).
- Evidence: device run, 2026-11-18 (calibration/panel-row.jsonl, panel-current.jsonl).

### 2026-11-18 — the fixture window could not be closed by its folder

- Symptom: calibration teardown's `close (every Finder window whose target is <alias>)` failed with -1708; the
  window had navigated to the parent folder and was closed by hand.
- Cause: the window was addressed by the folder it showed, which had changed.
- Fix: calibration reads the window's id together with its folder when the window opens and closes `Finder window
  id N`. UNVERIFIED on a device.
- Evidence: device run, 2026-11-18 (calibrate.out note).

### 2026-11-18 — `launch.sh` refuses a run dir with a retired ownership record

- Symptom: a second launch into the same run directory (phase 2 of a run) was refused.
- Cause: the run directory already held the retired ownership record of the first launch.
- Fix: none in the scripts (by design one run directory belongs to one launch): launch a second phase into a new run
  directory and copy `bundle.path` and `build.json` into it.
- Evidence: device run, 2026-11-18 ("Script problems").

### 2026-11-18 — `finder-kc.sh 9 command` works as Command-V

- Symptom: none; it was unproven.
- Cause: key code 9 is V; the `command` modifier reaches Finder through System Events.
- Fix: use `finder-kc.sh 9 command` to paste into Finder (for example into a rename field) instead of typing.
- Evidence: device run, 2026-11-18 (the paste-into-rename-field rows).

### 2026-11-18 — the Option flag stayed set after an Option right-click

- Symptom: after calibration's `option-menu` step every PLAIN right-click showed `Delete Direct (skip
  confirmation)`, so a plain `choose "Delete Direct"` would have refused, and a click on that item would have skipped
  the confirmation. `CGEventSourceFlagsState(.hidSystemState)` read 0x20080000 (Option set); the session state was
  0. The tester cleared it with a flagsChanged event with no flags; no Delete was clicked.
- Cause: `rightclick.sh … option` set the Option flag on the right-click's mouse events and posted them at the HID
  tap; nothing ever posted an event that cleared it (no key-up, no flagsChanged), so the HID system state kept
  Option. The extension reads the current modifier state once, while each menu is built.
- Fix (#32 fix round 5): `rightclick.sh` releases Option itself (key-ups and a flagsChanged with no flags) in a
  `finally` and from INT/TERM/HUP traps, after holding it 1 s for the menu build; `finderdrive` releases it again
  after the script returns on every path, Ctrl-C and SIGTERM included, and reads the state back. Every acting command
  refuses (65) while Shift, Control, Option or Command is held (`modifiers.sh state`, a read). Calibration checks the
  state at the start, after `option-menu` and at the end (21 steps). Tests: `test_finderdrive.ModifiersAreReleased`,
  `test_finderdrive.AStuckModifierIsRefused`, the modifier tests in `test_calibration`. UNVERIFIED on a device: that
  the 1 s hold is long enough for the skip title, and that the release clears the HID state (`option-menu` and
  `modifiers-after-option` prove both).
- Fix (#32 fix round 6, from the round-5 confirm, offline): the raw `rightclick.sh` and `click.sh` read the state
  first (`modifiers.sh check`) and refuse a held modifier (65) before posting anything; the release clears only
  Option (flagsChanged with the HID state minus Option, not all-zero flags, which cleared a modifier the owner held);
  `rightclick.sh` releases again when its osascript is terminated or killed (which skips the JXA `finally`) and on
  its own INT/TERM/HUP, keeping the failure status; every check reads the union of the HID and the combined session
  state, as the extension does. Tests: `test_raw_clicks` runs the real scripts under a fake osascript. UNVERIFIED on
  a device: that a flagsChanged carrying the remaining flags (0x20000000 rather than 0) clears Option.
- Evidence: device run, 2026-11-18 ("Script problems" 2).

### 2026-11-18 — `ui.sh grant` fails on the osascript panel

- Symptom: calibration's `panel-grant-row` failed `axprobe: select failed: AXError -25205` and
  `panel-grant-current` failed `axprobe: press failed: AXError -25204`. The pid allow-list and the panel plan
  passed; the AX action itself was refused by that panel.
- Cause: not known. -25205 is `kAXErrorAttributeUnsupported` (the entry's `AXGroup` does not take an `AXSelected`
  change), -25204 is `kAXErrorCannotComplete` (the button's `AXPress`).
- Fix: none yet; `ui.sh grant` is distrusted (a follow-up issue). Calibration keeps both steps honest: they FAIL.
  What worked on RClick's own panel: `ui.sh press-button <rclick pid> "Grant Access"` when the panel opened at the
  folder to grant (role and title re-checked by axprobe).
- Evidence: device run, 2026-11-18 (calibration.txt; row C4 for `press-button "Grant Access"`).

### 2026-11-18 — `doctor --expected-sha` needs the 8-character sha

- Symptom: `doctor.sh … --expected-sha <7 chars>` failed `bundle-hash`; the 8-character form passed.
- Cause: `build.json` records the 8-character short sha.
- Fix: the runbook (§6) and SKILL.md say 8 characters (`git rev-parse --short=8`). Briefs must pass that form.
- Evidence: device run, 2026-11-18 ("Script problems" 1).

### 2026-11-18 — `log show` returned nothing for RClick

- Symptom: `log show --predicate 'subsystem BEGINSWITH "cn.anzchy.RClick"'` printed only its header, so no app-log
  evidence existed for the Cut clicks.
- Cause: not known (log level or persistence on that Mac).
- Fix: none in the scripts; the runbook (§9) asks for a second view of every click's effect that does not need the
  log: the pasteboard (`pbpaste`, types, change count) and the absence of the "did not respond" alert (`ui.sh
  dialog <FinderSyncExt pid>` empty).
- Evidence: device run, 2026-11-18 ("Script problems" 5).

### 2026-11-18 — `cleanup.sh` does not make the extension offline at once

- Symptom: right after `cleanup.sh` (SIGTERM to the recorded pid) the Finder menu still looked online; it showed
  `RClick is not running` only after about 35 s.
- Cause: SIGTERM ends the app without the `.quit` message, so the extension falls back to its 30 s cache.
- Fix: none in the scripts; the runbook (§11) says to quit RClick through its own menu bar item first when the
  immediate offline state matters (CONN-01).
- Evidence: device run, 2026-11-18 ("Script problems" 6, row C6).
