---
name: macos-device-test
description: Verify RClick on a real macOS desktop — the menu bar app plus its FinderSync extension inside Finder — by right-clicking in Finder, driving the actions on disposable fixtures, capturing evidence outside the repo and writing a validation record. Use when acceptance depends on the real Finder menu, the extension being registered and enabled, pasteboard or file results of a click, the offline and no-ack alerts, the folder-permission panel, or relaunch; and when rclick-delegator hands a device run to a fresh subagent. Not for anything a unit test in RClickTests can decide.
---

# RClick macOS device test

RClick is two processes: the menu bar app (`cn.anzchy.RClick`) does the work, and the FinderSync extension
(`cn.anzchy.RClick.FinderSyncExt`) runs inside Finder and only draws the menu and forwards clicks. The unit tests
cannot see Finder, pluginkit, the pasteboard after a real click, an `NSAlert` raised in the extension, or the
powerbox. This lane checks those. Read [features/README.md](features/README.md) and the recipe for the run, then
[references/device-runbook.md](references/device-runbook.md) for the helper contracts and proof standards, and
[references/ui-driver-notes.md](references/ui-driver-notes.md) for what is known to break when driving Finder.

`$DT` below is `.agents/skills/macos-device-test/scripts` (`.claude/skills` is a symlink to `.agents/skills`).

## Run boundary

- **Independent tester.** The device tester is not the implementer of the change under test. Under
  `rclick-delegator`, a fresh subagent runs this skill from a brief and returns a verdict table and evidence paths.
- **Shared GUI lock first.** Before any launch, click, key, screenshot or Finder window, run `$DT/gui-lock.sh status`,
  then `$DT/gui-lock.sh acquire <run-id> <minutes> "<purpose>"` and keep the `acquisition_id=<uuid>` it prints. The lock
  (`~/.cache/desktop-gui.lock/`) is shared with picsee (Mado) and mdpro on this Mac. Exit 75 = someone else holds
  it: drive no GUI; `gui-lock.sh wait …` or tell the user. Release with
  `$DT/gui-lock.sh release <run-id> --acquisition-id <uuid>` only after cleanup, aborted runs included. Never remove
  another project's lock.
- **Never touch an RClick the run did not start.** If any `RClick` process is running, stop and ask the user to
  quit it. Do not launch beside it: `SingleInstanceGuard` makes the older copy of the same version quit itself, so a
  launch would end the user's RClick. Cleanup signals only the recorded PID.
- **Never change system or privacy settings.** Enabling the extension (System Settings → Login Items &
  Extensions → Finder), Accessibility and Screen Recording are the owner's steps. `pluginkit -e/-a/-r` is a system
  change too: ask first. A missing grant makes the affected rows NOT VERIFIED, never FAIL.
- **Accessibility is required** for any Finder driving: the host terminal that runs the helpers must be AX-trusted
  (the owner grants it; no restart needed). Without it doctor's `accessibility` line fails and no Finder row can be
  driven. Screen Recording is optional: AX dumps (`ui.sh menu`, `ui.sh dialog`) are the evidence without it.
- **Disposable fixtures only.** All file actions (New File, Hide, Delete Direct, Open With) run on copies under
  `$RUN_DIR/fixtures/`, never on the user's files. Evidence (screenshots, logs, pasteboard readbacks) stays under
  `~/.rclick-roster/device/<run-id>/`, never in the repo.
- **Shared app state.** The app and extension share the App Group `group.cn.anzchy.RClick` (SwiftData config and
  folder bookmarks). If it already exists, export a Settings backup into `$RUN_DIR` before changing any setting and
  import it back at the end (runbook §5).

## Sequence

1. Brief: run ID, commit SHA, recipe IDs, signing choice, and the user steps known up front.
2. `RCLICK_DEVICE_SIGNING=team:<TEAMID>|adhoc $DT/build.sh "$RUN_DIR"` (no lock needed for the build).
3. Take the GUI lock. `$DT/launch.sh "$RUN_DIR"`, then `$DT/doctor.sh "$RUN_DIR" --expected-sha <8-char sha>`.
   Every doctor line must pass; a failing line stops the run with that line as the reason.
4. **Step zero of driving: calibrate.** `$DT/calibrate.sh "$RUN_DIR"` proves every Finder helper on a throwaway
   folder (a few minutes) and prints `PASS|FAIL|SKIP <step>` lines, then `CALIBRATION PASS` or
   `CALIBRATION FAIL — distrust: <commands>`. Do not use a distrusted helper: drive that part another way and record
   it, or mark the rows it serves NOT VERIFIED. Keep `calibration/` in the evidence.
5. Drive each recipe through the real user path with `$DT/ui.sh` (runbook §7): `open-menu` on the row by exact
   name, `menu` to read it, `choose` (which runs the pre-action guard first), `dialog` / `press-button` for alerts,
   `grant` for the folder panel. Never aim by AppleScript order or by remembered coordinates. Capture the action and
   the result; check results through a second view (`pbpaste`, `ls -lO`, `mdls`, the app log).
6. One verdict per criterion and entry point: `pass`, `FAIL` with reproduction, or `NOT VERIFIED` with the blocker.
   Before a FAIL, check the guard passed for that action: a mis-aimed click is a tool problem, not a product FAIL.
7. `$DT/cleanup.sh "$RUN_DIR"`, release the lock, then write `docs/validation/<YYYY-MM-DD>-<topic>.md` from
   [references/validation-record-template.md](references/validation-record-template.md) in its own commit with
   `Validated-by: <role> run=<run-id>`. Fill its "Script problems" section: every helper that broke or misled,
   what was done instead.

## Correcting the helpers

The helpers are corrected from real runs. The tester never edits the repo: it records each helper problem under
"Script problems" in the validation record (and keeps the calibration dumps). After each run the delegator collects
those rows into [references/ui-driver-notes.md](references/ui-driver-notes.md) and fixes the scripts through a
ticket or PR, with a failing offline test first where the logic is testable (`scripts/test_finderui.py` replays AX
dumps from `scripts/fixtures/`).

A defect found here becomes an issue on `anzchy/RClick` and goes back through `/tdd` with a regression test. This lane
finds defects; it does not patch them.
