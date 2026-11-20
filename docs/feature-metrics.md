<!-- GENERATED FILE. Do not edit by hand: run `node scripts/feature-ledger/gen-feature-ledger.mjs`. -->
# RClick feature metrics

Generated from commit `644a19e806a8ff3be3e137e8dee2b7c7bb43b7b7` by `scripts/feature-ledger/gen-feature-ledger.mjs` from the spine `docs/feature-ledger/feature-map.json`.
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
| Test cases | Swift Testing `@Test` and XCTest `func test…` declarations, Python `def test_…`, node:test `test(…)` in those files, read past comments and strings; an entry `file::name` counts only the cases whose name contains `name`. `--` when a listed file is in another format (.swift .js .mjs .ts .py are parsed) |
| Test lines | non-blank, non-comment lines of those test files; for a `file::name` entry, only the lines of the matched cases (declaration through closing brace, or the indented body in Python); `--` when Test cases is `--` |
| Last touch | the newest commit that changed one of the feature's files, through renames (`git log -M --name-status`), with its commit date |
| Commits (90 d) | commits that changed the feature's files in the 90 days before the generating commit's date (`--window-days`), through renames |
| Specs | linked spec files (every one must exist, or the generator refuses) |
| CHANGELOG | lines of `CHANGELOG.md` naming one of the feature's `changelog` terms, case-insensitive, where the term starts a word (`Hide` counts `Hides`, not `Unhide`). A line counts whatever sense the word has there (`Update` also counts "Update the settings links"), so read the cell as an upper bound |

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
| `copy-path` | Copy Path | Finder menu: Actions | extension, shared | 3 | 908 | 2 | 4 | 62 | 1b7f23a 2026-11-20 | 33 | 0 | 5 |
| `copy-file-name` | Copy File Name | Finder menu: Actions | app, ipc, shared | 3 | 1396 | 3 | 3 | 39 | 644a19e 2026-11-20 | 55 | 0 | 3 |
| `delete-direct` | Delete Direct | Finder menu: Actions | app, ipc | 7 | 1293 | 2 | 13 | 205 | 644a19e 2026-11-20 | 70 | 1 | 4 |
| `hide` | Hide | Finder menu: Actions | app, ipc | 3 | 1094 | 0 | 0 | 0 | 644a19e 2026-11-20 | 59 | 0 | 3 |
| `unhide` | Unhide | Finder menu: Actions | app, ipc | 1 | 1040 | 0 | 0 | 0 | 644a19e 2026-11-20 | 49 | 0 | 2 |
| `airdrop` | AirDrop | Finder menu: Actions | app, ipc | 2 | 1078 | 0 | 0 | 0 | 644a19e 2026-11-20 | 58 | 0 | 4 |
| `open-with` | Open With (configured apps) | Finder menu: Open With | app, ipc, extension, shared | 4 | 2038 | 3 | 5 | 95 | 644a19e 2026-11-20 | 72 | 0 | 3 |
| `open-in-terminal` | Open in Terminal (containing-folder rule) | Finder menu: Open With | app, shared | 3 | 1486 | 1 | 1 | 23 | 644a19e 2026-11-20 | 52 | 0 | 1 |
| `new-file` | New File (templates) | Finder menu: New File | app, ipc, extension | 4 | 2049 | 2 | 2 | 33 | 644a19e 2026-11-20 | 73 | 0 | 6 |
| `new-file-auto-rename` | New File: select and rename after creation | Finder menu: New File | app | 2 | 1087 | 0 | 0 | 0 | 644a19e 2026-11-20 | 51 | 0 | 2 |
| `common-dirs` | Common Dirs | Finder menu: Common Dirs | app, ipc, extension | 4 | 1519 | 0 | 0 | 0 | 644a19e 2026-11-20 | 54 | 0 | 3 |
| `finder-menu` | RClick section in the Finder context menu | Finder menu: presence | extension, app, ipc | 4 | 1390 | 1 | 3 | 59 | 1b7f23a 2026-11-20 | 54 | 0 | 4 |
| `finder-toolbar-button` | RClick toolbar button in Finder | Finder menu: presence | extension | 2 | 891 | 1 | 3 | 59 | 1b7f23a 2026-11-20 | 30 | 0 | 2 |
| `menu-layout` | Menu sections: collapse toggles and icon style | Finder menu: presence | app, extension, shared | 6 | 1001 | 2 | 7 | 79 | 1b7f23a 2026-11-20 | 38 | 0 | 3 |
| `connection-state` | Connection-state UX (offline menu, hint relaunch, no-ack alert) | Finder menu: presence | extension, ipc, shared | 4 | 1063 | 1 | 1 | 23 | 1b7f23a 2026-11-20 | 45 | 0 | 5 |
| `observed-volumes` | Observed folders and external volumes | Finder menu: presence | extension, shared | 2 | 606 | 1 | 3 | 89 | 1b7f23a 2026-11-20 | 27 | 1 | 1 |
| `settings-window` | Settings window | Settings | app | 3 | 398 | 0 | 0 | 0 | 2bad87b 2026-11-20 | 21 | 0 | 1 |
| `menu-bar-item` | Menu bar item | Settings | app | 3 | 680 | 0 | 0 | 0 | 2bad87b 2026-11-20 | 32 | 0 | 0 |
| `launch-at-login` | Launch at login | Settings | app | 2 | 479 | 0 | 0 | 0 | 8b1ebd0 2026-11-17 | 14 | 0 | 2 |
| `apps-settings` | Apps settings (presets, add, edit, visibility, order) | Settings | app, shared | 5 | 643 | 3 | 5 | 75 | aec622a 2026-11-02 | 4 | 0 | 1 |
| `actions-settings` | Actions settings (enable, order, restore) | Settings | app | 3 | 265 | 1 | 5 | 85 | d31747b 2026-11-19 | 11 | 0 | 0 |
| `new-file-settings` | New File settings (custom types, templates) | Settings | app | 3 | 392 | 2 | 2 | 33 | 9c180f6 2026-09-13 | 3 | 0 | 4 |
| `folder-permissions` | Folder permissions (security-scoped bookmarks) | Settings | app | 5 | 320 | 3 | 11 | 141 | d63c29c 2026-11-17 | 4 | 1 | 8 |
| `permission-status` | Permission status (Finder extension, Accessibility) | Settings | app | 2 | 437 | 0 | 0 | 0 | 8b1ebd0 2026-11-17 | 15 | 0 | 3 |
| `settings-backup` | Settings backup (export, import) | Settings | app | 2 | 582 | 1 | 4 | 101 | 8b1ebd0 2026-11-17 | 14 | 0 | 1 |
| `export-logs` | Export logs | Settings | app | 2 | 401 | 0 | 0 | 0 | 8b1ebd0 2026-11-17 | 14 | 0 | 1 |
| `reset-all-settings` | Reset All Settings | Settings | app | 3 | 660 | 0 | 0 | 0 | 8b1ebd0 2026-11-17 | 20 | 0 | 1 |
| `update` | Check for updates and install | Settings | app | 4 | 769 | 1 | 7 | 58 | 4ab0b17 2026-11-14 | 5 | 2 | 5 |
| `about` | About (version, community links, more apps) | Settings | app | 2 | 650 | 0 | 0 | 0 | 4ab0b17 2026-11-14 | 5 | 0 | 2 |
| `localization` | Localization (English, zh-Hans, ja, es, fr) | Settings | app, extension, shared | 2 | 117 | 0 | 0 | 0 | 9495ba0 2026-11-20 | 42 | 0 | 6 |
| `ipc` | Two-process IPC (signed click, ack, menu config, heartbeat) | Infrastructure | ipc, shared | 3 | 698 | 3 | 4 | 101 | c9dbec0 2026-11-19 | 36 | 0 | 4 |
| `persistence` | Persistence (SwiftData in the App Group, migrations) | Infrastructure | app, shared | 10 | 824 | 5 | 18 | 272 | d31747b 2026-11-19 | 14 | 0 | 5 |
| `app-lifecycle` | App lifecycle (single instance, startup failure, quiet launches) | Infrastructure | app, shared | 6 | 372 | 2 | 6 | 51 | 2bad87b 2026-11-20 | 22 | 1 | 2 |
| `action-execution` | Action execution layer (serial executor, file operations, access lease) | Infrastructure | app | 4 | 179 | 4 | 20 | 312 | 644a19e 2026-11-20 | 23 | 0 | 0 |
