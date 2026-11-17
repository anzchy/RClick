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
- **One RClick per machine.** All copies share the bundle ID, the App Group, the IPC notification names and the HMAC
  key, so two running copies both execute every Finder click. `build.sh`, `launch.sh` and `adopt.sh` refuse when any
  `RClick` process is running that this run did not record. Ask the user to quit it; never quit it for them.
- **One extension registration.** If another `RClick.app` (an installed copy, an Xcode DerivedData build) has its
  `FinderSyncExt` registered, pluginkit may load that one instead. Doctor's `extension-registered` line fails and
  names the other path. Ask the user how to resolve it (remove the other copy, or approve a `pluginkit` change);
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
$DT/gui-lock.sh acquire "$RUN_ID" 45 "RClick device run"     # keep acquisition_id=<uuid>
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
| `extension-registered` | exactly one `FinderSyncExt` registration, inside this run's bundle |
| `extension-enabled` | that registration has the `+` (user-enabled) flag |
| `extension-process` | exactly one `FinderSyncExt` process, running from this run's bundle |
| `accessibility` | the host terminal is AX-trusted (needed for menus, alerts and panels) |
| `machine` | model, chip, memory, macOS and scale match `build.json` |

`extension-process` may need one right-click in Finder before Finder loads the extension: right-click the fixture
folder once, Esc, then rerun doctor. Offline contract tests: `doctor.sh --fixture <observations.json>`.

## 7. Drive

- **Open the fixtures in Finder:** `open "$RUN_DIR/fixtures"` (under the lock). Use list view so rows have stable
  positions; read coordinates from a screenshot, never from memory.
- **Right-click:** `$DT/rightclick.sh X Y` on a row, the window background, or a sidebar entry. Add `option` to hold
  Option while the menu is built (Delete Direct's skip title). Synthetic input: disclose it.
- **Read the menu:** `$DT/finder-menu.sh` prints `<title>|<enabled>|<submenu count>` for Finder's open menu. If it
  prints nothing while a menu is visibly open, record the tool limit and use a region screenshot of the menu.
- **Choose an item:** `$DT/click.sh X Y` on the item, or keyboard: type the title's first letters and Return through
  `$DT/finder-kc.sh`. Close a menu with `$DT/finder-kc.sh 53`.
- **Read alerts and dialogs:** `$DT/axdump.sh FinderSyncExt` (extension alerts), `$DT/axdump.sh <rclick pid>` (Delete
  Direct confirmation, permission panel). Press buttons by AX title or `kc.sh "$RUN_DIR" 36` (Return) / `53` (Esc).
- **Folder permission panel:** `$DT/panel-choose.sh "$RUN_DIR" "$RUN_DIR/fixtures"` writes the path into the Go-to
  field through AX, reads it back, and confirms; it fails before Open on any mismatch.
- **Keys to RClick:** `$DT/key.sh "$RUN_DIR" <char> [mods]` (one printable character), `$DT/kc.sh "$RUN_DIR" <code>`
  (Esc 53, Return 36, Tab 48). Switch the input source to ABC by hand before key checks; never from a script.
- **Hung host (no-ack):** `$DT/pause.sh "$RUN_DIR"` sends SIGSTOP to the recorded PID only; `$DT/resume.sh` sends
  SIGCONT. Both are logged in `signals.log`. The extension still believes the host is online for up to 30 s after the
  last heartbeat, so click within that window.
- **Hint relaunch:** after `cleanup.sh`, clicking the offline hint starts the app again from this bundle. Record it
  with `$DT/adopt.sh "$RUN_DIR-relaunch" --from "$RUN_DIR"`, then doctor/cleanup that new run directory.
- **Probe symmetrically:** Hide then Unhide, cancel then confirm, without Option then with Option, online then offline.

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

Screenshots: `$DT/shot.sh "$RUN_DIR" <name> [x,y,w,h]` captures the main display or a rectangle (points), after a
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

Not yet proven live on RClick. The first run is a proof run: build → lock → launch → doctor (13 PASS) → one
right-click on `alpha.txt` with `finder-menu.sh` output → Copy Path with `pbpaste` → cleanup → release. Record which
signing (`team:` or `adhoc`) Finder accepted, whether `finder-menu.sh` reads the context menu, and whether
`extension-process` needed the warm-up right-click. Fix any helper defect with a failing offline test first.

Offline tests (no desktop, no real lock):

```bash
cd $DT && python3 -m unittest test_device test_gui_lock test_panel_choose
RCLICK_PICSEE_GUI_SCRIPT=~/Documents/mac-app/picsee/.agents/skills/picsee-delegator/scripts/gui-lock.sh \
RCLICK_MDPRO_GUI_SCRIPT=~/Documents/mac-app/mdpro/.agents/skills/mdpro-delegator/scripts/gui-lock.sh \
  python3 -m unittest test_gui_lock      # cross-project lock exclusion against the real scripts
```

## 15. Recording the result

Write `docs/validation/<YYYY-MM-DD>-<topic>.md` from
[validation-record-template.md](validation-record-template.md): machine, display, bundle path, SHA (and how doctor
verified it), signing, fixtures, verdict table, deviations, NOT VERIFIED reasons, and the run ID. Commit it on its own,
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
[ ] Fixtures created per run; every entry point driven; effects checked through a second view (§7–9)
[ ] Logs saved for the run window (§10)
[ ] Verdict table honest about NOT VERIFIED (§12)
[ ] Cleanup by recorded PID; settings restored; lock released (§11)
[ ] docs/validation record committed with Validated-by (§15)
```
