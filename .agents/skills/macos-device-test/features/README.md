# RClick verification map

Run recipes for device-testing RClick, one file per feature area, with stable recipe IDs (`EXT-01`, `ACT-03`, …)
that briefs, verdict tables and validation records cite. Read this index before a run, then the matching file.

Runs i5, i13 and i22 drove part of these recipes live with improvised helpers; `ui.sh` is built from what worked
(runbook §14, [ui-driver-notes.md](../references/ui-driver-notes.md)). Correct a recipe when the real app differs, in
the same change, and record the deviation.

## Baseline preconditions

- A Debug build of the commit under test, built and launched by this run; doctor prints 13 PASS lines
  ([runbook](../references/device-runbook.md) §4–6).
- The GUI lock belongs to this run; no RClick this run didn't start; one `FinderSyncExt` registration.
- The extension is enabled by the owner (System Settings → General → Login Items & Extensions → File Providers /
  Finder extensions, depending on macOS version). Never enable it from the run.
- Fixtures created under `$RUN_DIR/fixtures/` (runbook §8), opened in a Finder window in list view.
- App Group state noted or backed up (runbook §5). Default settings unless the recipe says otherwise: Actions,
  Apps, New File and Common Dirs each shown in a submenu or inline as Settings says; record which.
- Calibration run after doctor (`calibrate.sh`, runbook §7a); a distrusted helper is not used.
- Input source ABC only for recipes that type characters (`key.sh`); the Finder helpers (`ui.sh`) do not type.

## Driving conventions

- Open the menu on a row with `ui.sh open-menu "<exact name>"`; read it with `ui.sh menu X,Y`; dismiss with
  `finder-kc.sh 53` (runbook §7).
- A menu's item list is taken while it is open; record its titles verbatim (they are localized). Save the
  `ui.sh menu` output under `$RUN_DIR/menus/`.
- Choose an RClick item with `ui.sh choose X,Y "<title>" --target <path>` (it runs the pre-action guard first). Never
  aim by AppleScript order, remembered coordinates or a screenshot.
- Undo what a recipe changes (settings, hidden flags, granted folders) when the brief asks for a clean machine;
  never delete evidence.

## Proof and skip reporting

- Capture the action and the resulting state; check every effect through a second view (`pbpaste`, `ls`, `log`).
- One verdict line per criterion and entry point; an entry point not driven is NOT VERIFIED.
- Name artifacts `<recipe-id>-<entry-point>-<state>.png` in `$RUN_DIR/shots/`.

## Feature entry contract

Each feature file: an H1 title and one paragraph of user-visible behaviour, then four H2 sections in this order:
`Sub-features` (recipe IDs, one line each), `How to get to it (user POV)`, `Driving it` (starts with
`Preconditions:`, numbered steps pairing an action with its observable result), and `Gotchas`. Name only user paths,
stable handles, required state and observable proof.

## Known tool behaviour

Record here what a real run finds out about the tools.

The dated ledger with evidence is [ui-driver-notes.md](../references/ui-driver-notes.md); the tester records new
findings under "Script problems" in the validation record, and the delegator moves them there.

- Context menus and `NSAlert`s belong to Finder (or the extension), not RClick: capture them by region, not by window,
  or read them through AX (`ui.sh menu`, `ui.sh dialog`).
- Finder's context menu is visible to the element-at-position probe (`ui.sh menu`), not to System Events.
- The Option flag on the synthetic right-click is seen by the extension (`Delete Direct (skip confirmation)`).

## Features

- [Extension and menu presence](./extension-and-menu.md) — `EXT-01`…`EXT-06`: registration, menu on file, folder,
  background, sidebar and toolbar, multi-selection.
- [Actions](./actions.md) — `ACT-01`…`ACT-07`: Copy Path, Copy File Name, Hide/Unhide, Delete Direct with and without
  Option, AirDrop.
- [New File, Open With and Common Dirs](./new-file-open-with.md) — `NEW-01`…`NEW-03`, `APP-01`…`APP-03`,
  `DIR-01`: templates, auto-rename, Accessibility hint, opening in an app, terminal containing-folder, common dirs.
- [Connection states and relaunch](./connection-states.md) — `CONN-01`…`CONN-05`: offline menu, offline Copy Path,
  hint relaunch, the 3 s no-ack alert, the not-running alert.
- [Permission and localization](./permission-and-l10n.md) — `PERM-01`…`PERM-02`, `L10N-01`…`L10N-02`: the folder
  authorization panel and bookmark reuse; menu and alert language.
