# macOS device test runbook — RClick

Exact helper contracts and proof standards for a real RClick device run. Adapted from picsee's (Mado) runbook;
the process-ownership, GUI-lock, screenshot and powerbox helpers are ports of picsee's, with their tests.

**Automation policy: automate every step that can be automated; bring in the user only where automation truly
can't work.** The brief names each user step up front; at that step the run stops, asks, then continues. A step the
tool cannot do is NOT VERIFIED (tool limit), never FAIL. Record every place where automation took a different path
from a real user (synthetic right-click, AX value write into a panel, SIGSTOP to simulate a hung app).

`$DT` = `.agents/skills/macos-device-test/scripts`. Run helpers from the worktree root.

## 1. When this lane is the right one

| The automated lanes can't see… | so this lane checks… |
|---|---|
| pluginkit registration and the user's enable switch | exactly one registered `FinderSyncExt`, from this run's bundle, enabled (`+`) |
| Finder calling `menu(for:)` | the RClick items on a file, a folder, the window background, the sidebar and the toolbar button |
| DistributedNotificationCenter between two real processes | a click reaches the app, the app acks, the action runs |
| the pasteboard, the file system and Finder after a real click | Copy Path / File Name text, a new file appearing and being renamed, hidden flags, deletion |
| `NSAlert` raised by the extension in Finder | "RClick is not running", "RClick did not respond" (3 s no-ack) |
| the powerbox | the folder-permission `NSOpenPanel` and the bookmark it leaves |
| relaunch and quit | the offline menu after quit, the hint-click relaunch, config persistence |

Do not use it for menu-model, IPC encoding, `RCAction` routing, `SingleInstanceGuard.shouldKeepSelf`, path or
template logic: those belong in `RClickTests`.

## 2. Machine

The Mac mini (this machine) is the device-test machine: run from an agent session with access to the local desktop.
Every record names machine model, chip, memory, macOS version, display and scale (`build.json` holds them). Finder
menus are native AppKit; @2x is not a criterion for RClick unless a brief says so.

## 3. Isolation

- **One device run per desktop**, enforced by the shared GUI lock: the directory `~/.cache/desktop-gui.lock/` with a
  key=value `owner` file, serialised by the flock mutex `~/.cache/desktop-gui.mutex`. It is the same lock and protocol
  as picsee's and mdpro's `gui-lock.sh` (`$DT/test_gui_lock.py` proves both directions against their real scripts
  when `RCLICK_PICSEE_GUI_SCRIPT` / `RCLICK_MDPRO_GUI_SCRIPT` are set). Acquire before the first launch, Finder
  window, click, key or screenshot; hold it across relaunches; release after cleanup, also on aborted runs. Builds
  and log reads don't need it.
- **One RClick per machine for device attribution.** Copies of the fork share its bundle ID, App Group and IPC
  channels. The fork uses `cn.anzchy.RClick.MainToExtension` / `cn.anzchy.RClick.ExtensionToMain`, isolating its
  clicks, acknowledgements and configuration from upstream copies. The HMAC key and message format are unchanged. `build.sh`, `launch.sh` and `adopt.sh` refuse when any
  `RClick` process is running that this run did not record. Ask the user to quit it; never quit it for them.
- **One extension registration.** If another `RClick.app` (an installed copy, an Xcode DerivedData build) has its
  `FinderSyncExt` registered, pluginkit may load that one instead. Doctor's `extension-registered` line fails and
  names the other identity and path, including dormant upstream registrations. Doctor inventories all FinderSync
  registrations via `pluginkit -m -A -v -p com.apple.FinderSync` (including unelected registrations), filters bundle IDs containing `RClick`
  (case-insensitive), and treats any non-fork identity or path outside this run as foreign. Fork and upstream
  extensions can both register and produce separate menu sections despite isolated IPC. Ask the user how to resolve it (remove the other copy, or approve a `pluginkit` change);
  don't decide it.

## 4. Build

```bash
RUN_ID="$(date +%Y%m%d-%H%M%S)-<recipe-ids>"
RUN_DIR="$HOME/.rclick-roster/device/$RUN_ID"
RCLICK_DEVICE_SIGNING=team:<TEAMID> $DT/build.sh "$RUN_DIR"     # or RCLICK_DEVICE_SIGNING=adhoc
```

- Builds Debug with `xcodebuild -project RClick.xcodeproj -scheme RClick` into `.build/device-<run-id>/` (ignored).
- Refuses modified or untracked build inputs (`RClick/`, `FinderSyncExt/`, `Shared/`, `RClick.xcodeproj/`, minus
  `xcuserdata` and `.DS_Store`) before and after the build; commit first.
- Writes `build.json`: short/full SHA, Xcode version, signing choice, machine facts, input hashes, and the SHA-256 of
  the app and extension executables (doctor's `bundle-hash`).
- **Signing must be chosen explicitly.** The project's `DEVELOPMENT_TEAM` (`GRT84NAK4T`) is the fork owner's.
  `team:<TEAMID>` builds with automatic signing for your team (`-allowProvisioningUpdates`; the App Group
  `group.cn.anzchy.RClick` must be provisionable for that team). `adhoc` signs to run locally. Which of these
  pluginkit and Finder accept for the extension on this Mac is **not yet proven**: the first run records it (§14).
- The App Sandbox stays on for both targets (doctor's `sandbox` line). Never build with it off.

## 5. Launch and app state

```bash
$DT/gui-lock.sh acquire "$RUN_ID" 45 "RClick device run"     # prints acquisition_id=<uuid>
export RCLICK_GUI_LOCK_BATCH="$RUN_ID" RCLICK_GUI_LOCK_ACQUISITION_ID=<uuid> RUN_DIR   # ui.sh acts only under this lock
$DT/launch.sh "$RUN_DIR"
```

`launch.sh` runs `open -n -W <bundle>`, finds exactly one new `RClick` process by exact executable path and birth
after launch, records `rclick.pid` and `process.json` (PID, executable, `ps lstart` birth), and waits up to 30 s for the
public `launch decision:` log line from that PID (subsystem `cn.anzchy.RClick`). A manual launch opens the Settings
window; that is expected.

**Settings language.** Write a tag (e.g. `zh-Hans`, `ja`) to `$RUN_DIR/app-lang.txt` before launching to run the app
with `-AppleLanguages`. This reaches the app only. The Finder menu and the extension's alerts are rendered inside
Finder and follow the **system** language; never change it. Rows that need another menu language are NOT VERIFIED
unless the owner's system already uses it.

**App Group state.** `~/Library/Group Containers/group.cn.anzchy.RClick/` holds the SwiftData config and folder
bookmarks for builds using this fork identity. The container starts empty; upstream settings and bookmarks are
not migrated. Old and new RClick can both register a Finder extension on this Mac. Before a recipe changes
settings or grants a folder:

- absent → the run creates it; say so in the record.
- present → Settings → General → export a backup into `$RUN_DIR/settings-before.json` (the real user path), and at
  the end import it back and note the restore. Never edit, move or delete the container files by hand without the
  user's approval for the named run.

## 6. Doctor

```bash
$DT/doctor.sh "$RUN_DIR" --expected-sha "$(git rev-parse --short=8 HEAD)"
```

Prints exactly one `PASS <check>` or `FAIL <check> — <why>` per line, saves `doctor.txt` and `doctor-input.json`, and
exits non-zero on any FAIL. Collection errors become FAIL on the affected lines.

| Check | Pass when |
|---|---|
| `bundle-hash` | app and extension executables match `build.json`, and its SHA is the expected SHA |
| `bundle-id` | `cn.anzchy.RClick` and `cn.anzchy.RClick.FinderSyncExt` |
| `signature-valid` | `codesign --verify --deep --strict` on the app |
| `sandbox` | `com.apple.security.app-sandbox` is true on the app and the extension |
| `process-bundle` | the recorded PID, executable and birth match the live process |
| `fresh-sources` | build inputs still match the recorded inventory |
| `single-instance` | the recorded PID is the only `RClick` process |
| `launch-log` | this PID logged the public `launch decision:` line since `start.txt` |
| `extension-registered` | exactly one fork `FinderSyncExt` registration inside this run's bundle; no foreign RClick registration, even dormant |
| `extension-enabled` | that registration has the `+` (user-enabled) flag |
| `extension-process` | exactly one `FinderSyncExt` process, running from this run's bundle |
| `accessibility` | the host terminal is AX-trusted: required for any Finder driving (menus, alerts, panels); the owner grants it, no restart needed |
| `machine` | model, chip, memory, macOS and scale match `build.json` |

`extension-process` may need one right-click in Finder before Finder loads the extension: right-click the fixture
folder once, Esc, then rerun doctor. Offline contract tests: `doctor.sh --fixture <observations.json>`.

## 7. Drive

Every Finder action goes through `$DT/ui.sh` (`ui.sh --help`), which needs the GUI lock held by this run and an
AX-trusted host terminal: `RCLICK_GUI_LOCK_BATCH`, `RCLICK_GUI_LOCK_ACQUISITION_ID` and `RUN_DIR` exported (§5).
Its pure logic is `finderui.py` (tested offline), its AX calls are `axprobe.swift` (compiled into the private cache
`~/Library/Caches/rclick-axprobe/` on first use), and the pitfalls it avoids are in
[ui-driver-notes.md](ui-driver-notes.md). The checks each acting command makes are on one page:
[ui-driver-safety.md](ui-driver-safety.md).
Exit codes of `ui.sh` and `calibrate.sh`: **0** ok, **64** usage, **65** refused (target missing, ambiguous or
mismatched: nothing was done and an open menu was closed), **70** environment (no Accessibility, GUI lock not held by
an rclick run, axprobe build failed, no single Finder process).

- **Calibrate first:** `$DT/calibrate.sh "$RUN_DIR" --group "<title>"... --background-group "<title>"...` after
  doctor, before any recipe (§7a).
- **RClick's group:** `--group "<title>"`, repeated in menu order, names RClick's configured top-level items for the
  menu at hand (file menu or background menu; read them once with `ui.sh menu X,Y`). `choose` needs it and acts only
  inside the ONE exact run of those titles after the last `Quick Actions`. Pass the FULL configured run, never a
  subset: fewer than two titles is a usage error (64), because one title such as `Copy Path` could be another
  extension's lone item when RClick is not loaded. The same holds for `menu --group` and both calibration groups.
- **Open the fixtures in Finder:** `open "$RUN_DIR/fixtures"` (under the lock), list view. Keep fixture names unique
  (expanded folders can show a name twice: `ui.sh` refuses duplicates).
- **Rows in display order:** `$DT/ui.sh rows` prints `index<TAB>name<TAB>x<TAB>y<TAB>visible|hidden` for the front
  Finder window, ordered by the on-screen position read through AX. AppleScript's `items` order is not the display
  order: never compute coordinates from it, and never from a screenshot or memory.
- **Select and read back:** `$DT/ui.sh select <abs path>...` selects through AppleScript and reads the selection's
  POSIX paths back (exit 65 if they differ); `$DT/ui.sh selection` prints them.
- **Open the context menu on a row:** `$DT/ui.sh open-menu "<exact name>" [--option]` finds the one visible row with
  that exact name (case, spaces and percent signs significant), sets `AXSelected` on it and right-clicks the centre
  of its name cell (`rightclick.sh`; `--option` sets the Option flag, for Delete Direct's skip title). It prints
  `row: <index> <name> <x>,<y>` and `menu-point X,Y`. `AXShowMenu` does not work on Finder rows. Synthetic input:
  disclose it. For the window background: `$DT/ui.sh open-menu --background [--option]` deselects, reads the empty
  selection back and right-clicks the empty list below the rows (refused if the list has no empty space). For a
  sidebar entry, right-click with `$DT/rightclick.sh X Y` at a point read from a dump, then probe with `ui.sh menu`.
- **Read the menu:** `$DT/ui.sh menu X,Y` (the `menu-point`) prints every item as
  `<index>|<title>|<enabled>|<x>,<y>|<submenu count>`, then `compress: <Finder's Compress title>` and
  `rclick-group (heuristic, never used to choose): <titles>`; with `--group` it also prints where that exact group
  is, or refuses (65). For the heuristic only, a user-added Open With app or common folder needs `--also "<title>"`.
- **Choose an RClick item:** `$DT/ui.sh choose "<title>" [--sub "<submenu item>"] [--option] --group "<title>"...
  --target <abs path>...` (or `--background <dir>`) is one process from selection to press, and it opens the menu
  itself (no `open-menu` first). While a Finder menu is open every AppleScript call to Finder times out (device run,
  2026-11-18), so all AppleScript happens BEFORE the right-click: it selects the targets (or deselects for
  `--background`), then reads the window through AX: each target's row must carry the target's full path (`AXURL`),
  the rows marked selected must be exactly the targets, and the row must not move between two reads (for
  `--background`: no row selected, and the rows' folder must be `<dir>`; an empty folder has no rows and is refused,
  65). It right-clicks the row, waits up to 4 s for the menu (refused with what the probe found instead), and the
  guard plus the press run inside one `axprobe` menu session: the menu must be Finder's, Finder's `Compress
  “<name>”` title (`Compress N Items` for N targets; no Compress item for `--background`) must name the target, the
  item must be inside RClick's `--group` (another extension's same-titled item is never taken), and axprobe re-checks
  the menu it holds right before `AXPress`. It prints `GUARD PASS — …` then `chose: …`. Any refusal or failure after the
  click closes the menu it opened (65 refused, 70 environment; another process's menu is left open). The system language must be English for the Compress title. Example: `ui.sh choose "New File" --sub
  TXT --group Terminal --group "New File" --background "$RUN_DIR/fixtures"`.
- **Close a menu:** `$DT/ui.sh close-menu X,Y` (the `menu-point`) cancels the Finder menu at that point through
  `AXCancel`; if it is still open, it sends Esc to Finder through System Events; a menu of another process is never
  touched (65). No AppleScript to Finder is involved. Do not use `finder-kc.sh 53` for it.
- **Read alerts and dialogs:** `$DT/ui.sh dialog <pid>` prints each window's `text:` and `button:` lines: the RClick
  PID (`rclick.pid`) for the Delete Direct confirmation, the folder panel and the auto-rename alert; the
  `FinderSyncExt` PID (`pgrep -x FinderSyncExt`) for "RClick is not running" / "RClick did not respond".
- **Press a button:** `$DT/ui.sh press-button <pid> "<title>" [--window-text "<text in that window>"]` presses the one
  button with that exact title; two candidates are refused. The PID must be Finder, RClick's FinderSyncExt or this
  run's RClick (`$RUN_DIR/rclick.pid`): a system prompt is refused. Prefer it to `kc.sh "$RUN_DIR" 36` (Return).
- **Folder permission panel:** `$DT/ui.sh grant <rclick pid> <abs folder> [--button "Grant Access"]` presses the
  button through AX, no typing, so the input source does not matter. The open panel seen on the device (device run,
  2026-11-18) is a column browser: the folder it shows is the folder of its deepest column, proven by each entry's
  full path (`AXURL`) and by each column listing an entry of the column before it; the `Where:` pop-up must agree.
  If the panel shows the folder itself (RClick opens the panel there) it presses the button directly; if the folder
  is an entry of the deepest column it selects that entry, re-reads the panel and presses only when the browser now
  shows the folder (an empty folder lists nothing and is refused). A list-view panel (rows with `AXURL`) is handled
  the old way: the target must then be the only selected row. Never matched by name, never the sidebar. It fails
  if the panel is still open afterwards. Check the grant through a second view (Settings → Folder Permissions, the app log).
- **Keys to RClick:** `$DT/key.sh "$RUN_DIR" <char> [mods]` (one printable character), `$DT/kc.sh "$RUN_DIR" <code>`
  (Esc 53, Return 36, Tab 48). Typed characters pass through the input method: switch the input source to ABC by
  hand before key checks; never from a script. Key codes (Esc, Return) do not depend on it.
- **Hung host (no-ack):** `$DT/pause.sh "$RUN_DIR"` sends SIGSTOP to the recorded PID only; `$DT/resume.sh` sends
  SIGCONT. Both are logged in `signals.log`. The extension still believes the host is online for up to 30 s after the
  last heartbeat, so click within that window.
- **Hint relaunch:** after `cleanup.sh`, clicking the offline hint starts the app again from this bundle. Record it
  with `$DT/adopt.sh "$RUN_DIR-relaunch" --from "$RUN_DIR"`, then doctor/cleanup that new run directory.
- **Probe symmetrically:** Hide then Unhide, cancel then confirm, without Option then with Option, online then offline.
- **When the list changes** (after a delete, a new file, a rename) run `open-menu` again: it re-reads the rows. Never
  reuse a `menu-point` after its menu closed.

### 7a. Calibration

`$DT/calibrate.sh "$RUN_DIR" --group "<title>"... --background-group "<title>"...` (under the lock, after doctor)
proves each helper on this Mac's macOS and Finder before the run relies on it. `--group` is RClick's top-level items
of a file menu (must hold Copy Path and Delete Direct), `--background-group` those of a window-background menu (must
hold New File). It creates its own folder `$RUN_DIR/fixtures/calibration-<random>/` (`%41.txt`, `%2541.txt`,
`alpha.txt`, `beta.txt`, `中文 名称.txt`, `folder a/inner.txt`), opens it in a Finder window in list view, and at the
end removes only what it created (a file left by anything else stays, with a note). It overwrites the pasteboard
once (Copy Path on a fixture), chooses New File → TXT once on the fixture's background, and shows one alert and two
folder panels from `osascript` processes it starts itself (only those may be terminated). The menu steps run the
`ui.sh` command lines a recipe uses. `--dry-run` prints the plan and touches nothing. Output, one line per step in
this order, then a summary:

| Step | PASS means | Distrust on FAIL/SKIP |
|---|---|---|
| `gui-lock`, `axprobe`, `accessibility` | lock held by rclick, probe compiled, host terminal AX-trusted | every `ui.sh` command (exit 70: fix and rerun) |
| `row-order` | every fixture name found once, visible, in display order; prints the display and AppleScript orders | `ui.sh rows` |
| `select-readback` | AppleScript select of `beta.txt` reads back exactly | `ui.sh select` |
| `context-menu` | `open-menu %2541.txt` opened a menu that the element-at-position probe finds | `ui.sh open-menu` |
| `menu-read` | that menu's Compress title is `Compress “%2541.txt”` | `ui.sh menu` |
| `rclick-group` | RClick's group is present (else: the extension is not loaded, §6) | `ui.sh menu` (RClick's group) |
| `close-menu` | `ui.sh close-menu X,Y` closes the `context-menu` step's menu (none left at its point) | `ui.sh close-menu` |
| `choose` | `ui.sh choose Copy Path --group … --target alpha.txt` puts that fixture path on the pasteboard | `ui.sh choose` |
| `choose-multi` | `ui.sh choose Copy Path … --target %41.txt --target %2541.txt`: `Compress 2 Items`, both paths on the pasteboard | `ui.sh choose` (several targets) |
| `option-menu` | `ui.sh open-menu %2541.txt --option`: the menu shows `Delete Direct (skip confirmation)` | `ui.sh open-menu --option` |
| `background-menu` | `ui.sh open-menu --background` on the fixture window; `--background-group` found; closed with `close-menu` | `ui.sh open-menu --background` |
| `background-choose` | `ui.sh choose … "New File" --sub TXT --background <fixture>` creates one new file in the fixture, or opens RClick's folder panel (saved, then Cancel) | `ui.sh choose --background --sub` |
| `dialog-read` | the calibration alert's text is read through AX | `ui.sh dialog` |
| `press-button` | pressing `OK` by title returns `OK` to its osascript | `ui.sh press-button` |
| `panel-grant-row` | an `osascript choose folder` panel showing the fixture: `grant … "folder a" --button Choose` returns that folder | `ui.sh grant` (row mode) |
| `panel-grant-current` | the same panel: `grant <fixture folder>` returns the shown folder | `ui.sh grant` (current-folder mode) |

Summary: `CALIBRATION PASS (18 steps) — NOT covered: RClick's own sandboxed folder panel (the grant steps use an
osascript panel); PERM-01 on the device proves it` → exit 0; `CALIBRATION FAIL — distrust: <commands>` → exit 65; `CALIBRATION
FAIL — environment (<step>): fix it and rerun; distrust: every ui.sh command` → exit 70. A step whose prerequisite
failed is `SKIP` and counts as not proven. The output is saved to `$RUN_DIR/calibration/calibration.txt` with the AX
dumps (`finder-window.jsonl`, `menu.jsonl`, `alert.jsonl`, `panel-*.jsonl`, `rclick-panel.jsonl`): cite them in
"Script problems". Calibration does NOT prove `grant` on RClick's own sandboxed panel: PERM-01 does.

## 8. Fixtures

Create them per run, never from personal files:

```bash
mkdir -p "$RUN_DIR/fixtures/folder a" && cd "$RUN_DIR/fixtures"
printf 'alpha\n' > alpha.txt; printf 'beta\n' > 'beta with spaces.md'; printf 'x\n' > "folder a/inner.txt"
printf 'gamma\n' > '中文 名称.txt'; printf 'delete me\n' > delete-1.txt; printf 'delete me\n' > delete-2.txt
shasum -a 256 -- * "folder a"/* > "$RUN_DIR/fixtures.sha256"
```

Names with spaces and non-ASCII catch quoting and path-encoding defects in Copy Path and Open With.

## 9. Proof standards

- **The real user path:** right-click in Finder and choose the item. No `defaults write`, no posting IPC
  notifications by hand, no files placed in the App Group container.
- **Every entry point the criterion lists** (file, folder, multi-selection, background, sidebar, toolbar). An entry
  point not driven is NOT VERIFIED for that criterion.
- **A second view of every effect:** `pbpaste` for Copy Path / File Name (then restore nothing: tell the user the
  pasteboard was used); `ls -la`, `ls -lO` (hidden flag), `stat` and `shasum` for files; `log show` for the app
  side.
- **Tagged artifacts:** `shots/<recipe-id>-<entry-point>-<state>.png`.

## 10. Evidence

```bash
log show --start "$(cat "$RUN_DIR/start.txt")" --style compact --info \
  --predicate 'subsystem BEGINSWITH "cn.anzchy.RClick"' > "$RUN_DIR/rclick.log"
```

`cn.anzchy.RClick.FinderSyncExt` lines carry the menu kind and the Option state at build time
(`菜单打开时 Option 状态`), and `菜单构建耗时` (menu build time). Values not marked public show as `<private>`; report
that as a logging gap instead of guessing.

Screenshots are optional (Screen Recording is optional): `ui.sh menu` and `ui.sh dialog` output saved to the run
folder is the evidence without them. `$DT/shot.sh "$RUN_DIR" <name> [x,y,w,h]` captures the main display or a rectangle (points), after a
Screen Recording preflight that never requests permission, and rejects black or empty captures. Context menus and
alerts belong to Finder, so a window-by-PID capture can't see them. Keep captures to the menu region, and make sure
nothing private is on screen. Never save a screenshot into the repo.

## 11. Cleanup

```bash
$DT/cleanup.sh "$RUN_DIR"          # SIGCONT then SIGTERM to the recorded PID only; retires the record
$DT/gui-lock.sh release "$RUN_ID" --acquisition-id <uuid>
```

No kill by name, no SIGKILL; a process that doesn't exit within 5 s is reported. A retired record can't drive
anything again. Close the fixture Finder windows the run opened. Restore the settings backup if §5 made one. The
build in `.build/device-<run-id>/` stays registered with LaunchServices; tell the user its path in the record (they
decide whether to remove it).

## 12. The verdict table

| # | Recipe | Criterion | Entry point | Result |
|---|---|---|---|---|
| 1 | EXT-02 | RClick items appear | right-click on a file | pass |
| 2 | ACT-01 | Copy Path puts every selected path on the pasteboard, one per line | 2-file selection | pass |
| 3 | ACT-05 | Delete Direct asks first | file, without Option | **FAIL** — file deleted with no dialog; inputs … |
| 4 | L10N-01 | Menu in Japanese | system language ja | **NOT VERIFIED** — system language is zh-Hans; not changed |

A FAIL carries the exact inputs, expected and observed result. Confirm a root cause by reading the code, not the
pixels.

## 13. Privacy and safety

- When the computer-use provider offers `request_access`, request Finder and RClick (and Terminal/TextEdit if a
  recipe opens them) in one call. Never grant anything else.
- An interactive permission prompt (Accessibility for auto-rename, a folder-access panel the recipe didn't expect)
  is a blocker to report, unless the recipe says to drive it.
- Never click web links, never change system settings, never open the user's own folders.
- The Copy Path recipes overwrite the user's pasteboard: say so in the brief.

## 14. Proving this skill

Runs i5, i13 and i22 drove RClick live with improvised helpers; what they found is in
[ui-driver-notes.md](ui-driver-notes.md), and `ui.sh` is built from the parts that worked. Each run proves the helpers
again with the calibration (§7a) before it relies on them; a calibration FAIL goes into the record's "Script
problems". Record which signing (`team:` or `adhoc`) Finder accepted and whether `extension-process` needed the
warm-up right-click. Fix any helper defect with a failing offline test first.

Offline tests (no desktop, no real lock):

```bash
cd $DT && python3 -m unittest test_device test_gui_lock test_finderui test_finderdrive
RCLICK_PICSEE_GUI_SCRIPT=~/Documents/mac-app/picsee/.agents/skills/picsee-delegator/scripts/gui-lock.sh \
RCLICK_MDPRO_GUI_SCRIPT=~/Documents/mac-app/mdpro/.agents/skills/mdpro-delegator/scripts/gui-lock.sh \
  python3 -m unittest test_gui_lock      # cross-project lock exclusion against the real scripts
```

## 15. Recording the result

Write `docs/validation/<YYYY-MM-DD>-<topic>.md` from
[validation-record-template.md](validation-record-template.md): machine, display, bundle path, SHA (and how doctor
verified it), signing, fixtures, calibration summary, verdict table, deviations, NOT VERIFIED reasons, Script
problems, and the run ID. Commit it on its own,
touching nothing outside `docs/validation/`:

```text
docs(validation): device run EXT-01..03, ACT-01 on Mac mini

Validated-by: <device-tester-role> run=<run-id>
```

A record without the trailer, or written by the implementer of the change, does not count as device validation.

## Checklist

```
[ ] The criteria really need Finder, pluginkit, the pasteboard, alerts or the powerbox (§1)
[ ] No other RClick running; one extension registration; GUI lock acquired (§3)
[ ] Built from a clean commit with an explicit signing choice (§4)
[ ] Launched; PID recorded; App Group state noted or backed up (§5)
[ ] Doctor: every line PASS (§6)
[ ] Calibration run; distrusted helpers not used, or their rows NOT VERIFIED (§7a)
[ ] Fixtures created per run; every entry point driven; effects checked through a second view (§7–9)
[ ] Logs saved for the run window (§10)
[ ] Verdict table honest about NOT VERIFIED (§12)
[ ] Cleanup by recorded PID; settings restored; lock released (§11)
[ ] Script problems recorded in the validation record (§15)
[ ] docs/validation record committed with Validated-by (§15)
```
