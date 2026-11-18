# Finder UI driver: the safety contract on one page

Every `ui.sh` / `calibrate.sh` entry point that acts on the desktop, and the checks it makes before it acts. A failed
check exits **65** (refused: nothing was done, an open menu was closed) or **70** (environment), never a guess.
Code: `scripts/finderdrive.py` (side effects), `scripts/finderui.py` (the pure checks, unit-tested),
`scripts/axprobe.swift` (AX), `scripts/calibration.py`. The pitfalls behind each check are in
[ui-driver-notes.md](ui-driver-notes.md).

## Checks every acting command shares

| Check | Where | What it requires |
|---|---|---|
| GUI lock (Python) | `finderdrive.require_lock` → `finderui.check_lock` | `gui-lock.sh status` shows ONE complete owner record (`HELD:` plus the eight fields of `gui-lock.sh`, each once) with `project=rclick`, `batch=$RCLICK_GUI_LOCK_BATCH` and `acquisition_id=$RCLICK_GUI_LOCK_ACQUISITION_ID` (exported after `gui-lock.sh acquire`). Else 70. The record's `pid` is the short-lived acquire process (gui-lock.sh protocol), so pid liveness is not checked: the acquisition id identifies this run's lock. |
| GUI lock (axprobe) | `axprobe.swift` `requireLock()` in `act` and `menu-session` | the same check, run again by the AX helper itself (`python3 <driver> lock-check`), so calling `axprobe` directly does not skip it. |
| AX helper integrity | `finderdrive.probe_binary` | `axprobe` is compiled into `~/Library/Caches/rclick-axprobe/<digest>/` (every path from the home directory down is `lstat`-checked one level at a time, nothing is created or read below a refused one: home, `~/Library` and `~/Library/Caches` must be real directories of this user that group and other cannot write; `rclick-axprobe/` and `<digest>/` real 0700 directories of this user; the executable a regular file of this user that group and other cannot write. A symlink at any of these levels is refused, not followed. Above the home directory nothing is checked), built in a private temporary directory and renamed into place. |
| Path identity | `finderui.clean_path`, `parse_selection` | paths compare exactly: whitespace and case are significant, both sides NFC, one trailing `/` dropped; a path with a line break is refused. The selection is read back with a count line, so a lost or split line is refused. |

## Entry points

| Entry point | Acts on | Checks before acting |
|---|---|---|
| `ui.sh select PATH...` | Finder selection (AppleScript) | lock; reads the selection back and compares it exactly with the paths (65 on a difference). |
| `ui.sh open-menu NAME [--option]` | right-click on a row | lock; Esc only while Finder is frontmost; the one visible row named exactly NAME (duplicates refused); `AXSelected` through `axprobe act` (lock, role and title re-checked at the element); rows re-read and the row must not have moved; a menu must be found at the point. |
| `ui.sh open-menu --background [--option]` | right-click on the window background | lock; deselects, then reads the selection back: it must be empty; `finderui.background_point`: the front window's one file list (not the sidebar), at least 30 pt of empty space below its rows, inside its scroll area. |
| `ui.sh close-menu` | Esc (key code 53) | lock; sent only while Finder is the frontmost process, else 65 and no key sent. Use it instead of `finder-kc.sh 53`. |
| `ui.sh guard X,Y ...` | nothing (closes the menu on a refusal) | lock; the menu's Compress title names the target (`Compress N Items` for N) and the selection read now is exactly the target set; `--background DIR`: nothing selected, no Compress item, the front window shows DIR. |
| `ui.sh choose X,Y TITLE [--sub ITEM] --group ...` | `AXPress` on RClick's item | lock; ONE `axprobe menu-session` process holds the menu: its owner pid must be Finder's; the guard runs on that dump with the selection read inside the session; TITLE must be in RClick's group, the ONE exact run of the `--group` titles after the last `Quick Actions` (none or two runs refused); axprobe then re-checks, on the menu it holds, the owner pid, every top-level title, the item title and the submenu item title (before and after opening the submenu) before `AXPress`. Any refusal aborts the session and closes the menu. |
| `ui.sh press-button PID TITLE` | `AXPress` on a button | lock; PID must be Finder, RClick's FinderSyncExt (by executable path), the RClick of this run (`$RUN_DIR/rclick.pid`, RClick executable) or a calibration `osascript`: never a system prompt; exactly one button with that title (in the window holding `--window-text`); `axprobe act` re-checks role and title. |
| `ui.sh grant PID FOLDER` | selects a panel row, presses its button | lock; the same PID allow-list; the panel is matched by full paths (each row's `AXURL`; the shown folder from the location), never by a basename; after selecting the row the panel is re-read (`finderui.panel_ready`): the target is the only selected row (none in current-folder mode) and nothing moved, else nothing is pressed; the panel must close afterwards. |
| `ui.sh lock-check` | nothing | the lock check alone (axprobe calls it). |
| `calibrate.sh RUN_DIR --group ... --background-group ...` | a throwaway Finder window, one alert, two folder panels, the pasteboard | lock; the fixture folder is allocated exclusively (`mkdtemp` under `$RUN_DIR/fixtures/`, files `O_EXCL|O_NOFOLLOW`) and cleanup removes only what this calibration created or adopted. Teardown (stop its osascripts, Esc, close the fixture window, remove the fixture) runs on every path, including a failed step and Ctrl-C: a failing call (an osascript timeout, a missing tool) becomes a `note:` line and never skips the later calls, and the PASS/FAIL report plus the notes is always printed and saved; it terminates only the `osascript` processes it started; the menu steps run the `ui.sh` command lines above as subprocesses. `--dry-run` touches nothing. |

## Not covered offline, and not by calibration

- The axprobe re-check before `AXPress` (`menu-session`) and its lock check are compiled and type-checked by the unit
  tests when `xcrun` exists; their behaviour on a live menu is proven only by a device run (`calibrate.sh`).
- RClick's own sandboxed folder panel as a `grant` target: calibration uses an `osascript choose folder` panel.
  PERM-01 on the device proves RClick's panel.
