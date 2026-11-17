<!-- GENERATED FILE. Do not edit by hand: run `node scripts/feature-ledger/gen-feature-ledger.mjs`. -->
# RClick feature metrics

Generated from commit `4e62e2b5413336929e55075f1fd7150e5577e10e` by `scripts/feature-ledger/gen-feature-ledger.mjs` from the spine `docs/feature-ledger/feature-map.json`.
This is the quantitative half of the feature ledger. Every cell below is measured from the repository; nothing is typed by hand or estimated.
The qualitative half, `docs/feature-ledger.md`, cites these cells and never restates them. Maintenance: `docs/agents/feature-ledger.md`.

**`--` means not measured; `0` means measured and none.** A spine entry with no `tests`, `specs` or `changelog` list was never linked by anyone, so those cells print `--`. An empty list is a deliberate "looked, found none" and prints `0`. Without a `CHANGELOG.md` every CHANGELOG cell is `--`.

## Columns

| Column | Measured from |
|---|---|
| Process | the spine's `process` list (where the feature runs: `app`, `extension`, `shared`, `ipc`) |
| Code files | tracked files under the feature's `paths` with a code extension (.swift .m .h .mjs .js .ts .py .sh) |
| Code lines | non-blank lines of those files that are not only a comment. A file listed by several features counts in each: the column is how much code a reader opens, not an ownership share |
| Test files | tracked files under the feature's `tests` entries |
| Test cases | Swift Testing `@Test` and XCTest `func test…` declarations, Python `def test_…`, node:test `test(…)` in those files; an entry `file::name` counts only the cases whose name contains `name` |
| Test lines | non-blank, non-comment lines of those test files; for a `file::name` entry, only the lines of the matched cases (declaration through closing brace, or the indented body in Python) |
| Last touch | the newest commit that changed one of the feature's files, through renames (`git log -M --name-status`), with its commit date |
| Commits (90 d) | commits that changed the feature's files in the 90 days before the generating commit's date (`--window-days`), through renames |
| Specs | linked spec files (every one must exist, or the generator refuses) |
| CHANGELOG | lines of `CHANGELOG.md` naming one of the feature's `changelog` terms, case-insensitive |

There is no issue-count column: a feature that is off by default (Hide, Unhide, AirDrop, Common Dirs) draws no issues because nobody reaches it, so a low count would restate the default and read as evidence. Issues are linked in the spine and discussed in the ledger.

## Features per process

| Process | Features |
|---|---:|
| app | 29 |
| extension | 10 |
| shared | 12 |
| ipc | 11 |

## Metrics

| Feature | Name | Area | Process | Code files | Code lines | Test files | Test cases | Test lines | Last touch | Commits (90 d) | Specs | CHANGELOG |
|---|---|---|---|---:|---:|---:|---:|---:|---|---:|---:|---:|
| `copy-path` | Copy Path | Finder menu: Actions | extension, shared | 3 | 937 | 2 | 4 | 36 | d4439a7 2026-11-14 | 16 | 0 | 3 |
| `copy-file-name` | Copy File Name | Finder menu: Actions | app, ipc, shared | 3 | 876 | 3 | 3 | 28 | 1cf27fc 2026-11-17 | 16 | 0 | 2 |
| `delete-direct` | Delete Direct | Finder menu: Actions | app, ipc | 7 | 736 | 2 | 11 | 179 | d63c29c 2026-11-17 | 21 | 1 | 3 |
| `hide` | Hide | Finder menu: Actions | app, ipc | 3 | 551 | 0 | 0 | 0 | 1cf27fc 2026-11-17 | 16 | 0 | 2 |
| `unhide` | Unhide | Finder menu: Actions | app, ipc | 1 | 516 | 0 | 0 | 0 | 1cf27fc 2026-11-17 | 15 | 0 | 2 |
| `airdrop` | AirDrop | Finder menu: Actions | app, ipc | 2 | 532 | 0 | 0 | 0 | 1cf27fc 2026-11-17 | 15 | 0 | 3 |
| `open-with` | Open With (configured apps) | Finder menu: Open With | app, ipc, extension, shared | 4 | 1534 | 3 | 4 | 81 | 1cf27fc 2026-11-17 | 25 | 0 | 3 |
| `open-in-terminal` | Open in Terminal (containing-folder rule) | Finder menu: Open With | app, shared | 3 | 957 | 1 | 1 | 23 | 1cf27fc 2026-11-17 | 16 | 0 | 1 |
| `new-file` | New File (templates) | Finder menu: New File | app, ipc, extension | 4 | 1545 | 2 | 2 | 33 | 1cf27fc 2026-11-17 | 26 | 0 | 5 |
| `new-file-auto-rename` | New File: select and rename after creation | Finder menu: New File | app | 2 | 563 | 0 | 0 | 0 | 1cf27fc 2026-11-17 | 17 | 0 | 2 |
| `common-dirs` | Common Dirs | Finder menu: Common Dirs | app, ipc, extension | 4 | 990 | 0 | 0 | 0 | 1cf27fc 2026-11-17 | 17 | 0 | 3 |
| `finder-menu` | RClick section in the Finder context menu | Finder menu: presence | extension, app, ipc | 4 | 1253 | 1 | 2 | 45 | 641225e 2026-11-17 | 22 | 0 | 4 |
| `finder-toolbar-button` | RClick toolbar button in Finder | Finder menu: presence | extension | 2 | 911 | 1 | 2 | 45 | d4439a7 2026-11-14 | 16 | 0 | 2 |
| `menu-layout` | Menu sections: collapse toggles and icon style | Finder menu: presence | app, extension, shared | 6 | 1024 | 2 | 7 | 79 | 8b1ebd0 2026-11-17 | 24 | 0 | 3 |
| `connection-state` | Connection-state UX (offline menu, hint relaunch, no-ack alert) | Finder menu: presence | extension, ipc, shared | 4 | 933 | 1 | 1 | 23 | 641225e 2026-11-17 | 15 | 0 | 5 |
| `observed-volumes` | Observed folders and external volumes | Finder menu: presence | extension, shared | 2 | 631 | 1 | 3 | 89 | d4439a7 2026-11-14 | 14 | 1 | 1 |
| `settings-window` | Settings window | Settings | app | 3 | 377 | 0 | 0 | 0 | c861dcd 2026-11-17 | 13 | 0 | 1 |
| `menu-bar-item` | Menu bar item | Settings | app | 3 | 655 | 0 | 0 | 0 | 8b1ebd0 2026-11-17 | 24 | 0 | 0 |
| `launch-at-login` | Launch at login | Settings | app | 2 | 479 | 0 | 0 | 0 | 8b1ebd0 2026-11-17 | 14 | 0 | 2 |
| `apps-settings` | Apps settings (presets, add, edit, visibility, order) | Settings | app, shared | 5 | 643 | 3 | 4 | 61 | aec622a 2026-11-02 | 4 | 0 | 1 |
| `actions-settings` | Actions settings (enable, order, restore) | Settings | app | 3 | 264 | 1 | 4 | 65 | 09e9aa0 2026-11-07 | 10 | 0 | 0 |
| `new-file-settings` | New File settings (custom types, templates) | Settings | app | 3 | 392 | 2 | 2 | 33 | 9c180f6 2026-09-13 | 3 | 0 | 4 |
| `folder-permissions` | Folder permissions (security-scoped bookmarks) | Settings | app | 5 | 320 | 3 | 11 | 141 | d63c29c 2026-11-17 | 4 | 1 | 8 |
| `permission-status` | Permission status (Finder extension, Accessibility) | Settings | app | 2 | 437 | 0 | 0 | 0 | 8b1ebd0 2026-11-17 | 15 | 0 | 2 |
| `settings-backup` | Settings backup (export, import) | Settings | app | 2 | 582 | 1 | 4 | 101 | 8b1ebd0 2026-11-17 | 14 | 0 | 1 |
| `export-logs` | Export logs | Settings | app | 2 | 401 | 0 | 0 | 0 | 8b1ebd0 2026-11-17 | 14 | 0 | 2 |
| `reset-all-settings` | Reset All Settings | Settings | app | 3 | 660 | 0 | 0 | 0 | 8b1ebd0 2026-11-17 | 20 | 0 | 1 |
| `update` | Check for updates and install | Settings | app | 4 | 769 | 1 | 7 | 58 | 4ab0b17 2026-11-14 | 5 | 2 | 5 |
| `about` | About (version, community links, more apps) | Settings | app | 2 | 650 | 0 | 0 | 0 | 4ab0b17 2026-11-14 | 5 | 0 | 2 |
| `localization` | Localization (English, zh-Hans, ja, es, fr) | Settings | app, extension, shared | 2 | 117 | 0 | 0 | 0 | 4ab0b17 2026-11-14 | 26 | 0 | 5 |
| `ipc` | Two-process IPC (signed click, ack, menu config, heartbeat) | Infrastructure | ipc, shared | 3 | 398 | 3 | 4 | 99 | 641225e 2026-11-17 | 7 | 0 | 4 |
| `persistence` | Persistence (SwiftData in the App Group, migrations) | Infrastructure | app, shared | 10 | 823 | 5 | 17 | 252 | 8b1ebd0 2026-11-17 | 12 | 0 | 5 |
| `app-lifecycle` | App lifecycle (single instance, startup failure, quiet launches) | Infrastructure | app, shared | 6 | 351 | 2 | 6 | 51 | 8b1ebd0 2026-11-17 | 14 | 1 | 2 |
| `action-execution` | Action execution layer (serial executor, file operations, access lease) | Infrastructure | app | 4 | 165 | 4 | 20 | 312 | d63c29c 2026-11-17 | 10 | 0 | 0 |
