<!-- GENERATED FILE. Do not edit by hand: run `node scripts/feature-ledger/gen-feature-ledger.mjs`. -->
# RClick feature metrics

Generated from commit `801bd37457b9ca9056ae75d73365c6e61675eca8` by `scripts/feature-ledger/gen-feature-ledger.mjs` from the spine `docs/feature-ledger/feature-map.json`.
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
| app | 33 |
| extension | 12 |
| shared | 14 |
| ipc | 13 |

## Metrics

| Feature | Name | Area | Process | Code files | Code lines | Test files | Test cases | Test lines | Last touch | Commits (90 d) | Specs | CHANGELOG |
|---|---|---|---|---:|---:|---:|---:|---:|---|---:|---:|---:|
| `copy-path` | Copy Path | Finder menu: Actions | extension, shared | 3 | 991 | 2 | 4 | 62 | 3ff20ed 2026-11-22 | 43 | 0 | 5 |
| `copy-file-name` | Copy File Name | Finder menu: Actions | app, ipc, shared | 3 | 1516 | 3 | 3 | 39 | 3ff20ed 2026-11-22 | 73 | 0 | 3 |
| `delete-direct` | Delete Direct | Finder menu: Actions | app, ipc | 7 | 1344 | 3 | 22 | 357 | 656cedb 2026-11-22 | 79 | 1 | 4 |
| `hide` | Hide | Finder menu: Actions | app, ipc | 3 | 1139 | 2 | 11 | 175 | 656cedb 2026-11-22 | 66 | 0 | 4 |
| `unhide` | Unhide | Finder menu: Actions | app, ipc | 1 | 1085 | 1 | 1 | 17 | 656cedb 2026-11-22 | 56 | 0 | 2 |
| `airdrop` | AirDrop | Finder menu: Actions | app, ipc | 2 | 1123 | 2 | 10 | 164 | 656cedb 2026-11-22 | 65 | 0 | 4 |
| `cut` | Cut | Finder menu: Actions | app, ipc, extension, shared | 8 | 2256 | 5 | 20 | 561 | 3ff20ed 2026-11-22 | 108 | 1 | 2 |
| `paste-move` | Paste (move here) | Finder menu: Actions | app, ipc, extension, shared | 10 | 2555 | 8 | 67 | 1591 | 3ff20ed 2026-11-22 | 117 | 1 | 11 |
| `open-with` | Open With (configured apps) | Finder menu: Open With | app, ipc, extension, shared | 4 | 2166 | 3 | 5 | 95 | 3ff20ed 2026-11-22 | 90 | 0 | 3 |
| `open-in-terminal` | Open in Terminal (containing-folder rule) | Finder menu: Open With | app, shared | 3 | 1606 | 1 | 1 | 23 | 3ff20ed 2026-11-22 | 70 | 0 | 1 |
| `new-file` | New File (templates) | Finder menu: New File | app, ipc, extension | 9 | 2576 | 9 | 23 | 640 | 3ff20ed 2026-11-22 | 110 | 0 | 12 |
| `new-file-office-templates` | New File: bundled DOCX, PPTX and XLSX templates | Finder menu: New File | app | 1 | 1085 | 2 | 5 | 121 | 656cedb 2026-11-22 | 57 | 0 | 1 |
| `new-file-auto-rename` | New File: select and rename after creation | Finder menu: New File | app | 2 | 1132 | 0 | 0 | 0 | 656cedb 2026-11-22 | 58 | 0 | 2 |
| `common-dirs` | Common Dirs | Finder menu: Common Dirs | app, ipc, extension | 4 | 1639 | 1 | 2 | 24 | 3ff20ed 2026-11-22 | 72 | 0 | 3 |
| `finder-menu` | RClick section in the Finder context menu | Finder menu: presence | extension, app, ipc | 4 | 1482 | 2 | 4 | 93 | 3ff20ed 2026-11-22 | 65 | 0 | 4 |
| `finder-toolbar-button` | RClick toolbar button in Finder | Finder menu: presence | extension | 2 | 974 | 1 | 3 | 59 | 3ff20ed 2026-11-22 | 40 | 0 | 2 |
| `menu-layout` | Menu sections: collapse toggles and icon style | Finder menu: presence | app, extension, shared | 6 | 1016 | 3 | 8 | 114 | 3ff20ed 2026-11-22 | 47 | 0 | 3 |
| `connection-state` | Connection-state UX (offline menu, hint relaunch, no-ack alert) | Finder menu: presence | extension, ipc, shared | 4 | 1074 | 1 | 1 | 23 | 3ff20ed 2026-11-22 | 51 | 0 | 6 |
| `observed-volumes` | Observed folders and external volumes | Finder menu: presence | extension, shared | 2 | 614 | 1 | 3 | 89 | 3ff20ed 2026-11-22 | 32 | 1 | 1 |
| `settings-window` | Settings window | Settings | app | 3 | 396 | 0 | 0 | 0 | aa934c5 2026-11-22 | 23 | 0 | 1 |
| `menu-bar-item` | Menu bar item | Settings | app | 3 | 698 | 0 | 0 | 0 | aa934c5 2026-11-22 | 36 | 0 | 0 |
| `launch-at-login` | Launch at login | Settings | app | 2 | 499 | 0 | 0 | 0 | d8f74f4 2026-11-21 | 14 | 0 | 2 |
| `apps-settings` | Apps settings (presets, add, edit, visibility, order) | Settings | app, shared | 5 | 700 | 3 | 5 | 75 | 528b378 2026-11-21 | 10 | 0 | 1 |
| `actions-settings` | Actions settings (enable, order, restore) | Settings | app | 3 | 266 | 1 | 5 | 85 | d8f74f4 2026-11-21 | 10 | 0 | 0 |
| `new-file-settings` | New File settings (custom types, templates) | Settings | app | 5 | 556 | 6 | 16 | 367 | fb8baf1 2026-11-21 | 16 | 0 | 5 |
| `folder-permissions` | Folder permissions (security-scoped bookmarks) | Settings | app | 5 | 320 | 3 | 11 | 141 | cb97c9a 2026-11-22 | 4 | 1 | 8 |
| `permission-status` | Permission status (Finder extension, Accessibility) | Settings | app | 2 | 457 | 0 | 0 | 0 | d8f74f4 2026-11-21 | 15 | 0 | 3 |
| `settings-backup` | Settings backup (export, import) | Settings | app | 3 | 763 | 3 | 8 | 220 | fb8baf1 2026-11-21 | 26 | 0 | 2 |
| `export-logs` | Export logs | Settings | app | 2 | 421 | 0 | 0 | 0 | d8f74f4 2026-11-21 | 14 | 0 | 1 |
| `reset-all-settings` | Reset All Settings | Settings | app | 4 | 864 | 0 | 0 | 0 | fb8baf1 2026-11-21 | 33 | 0 | 2 |
| `update` | Check for updates and install | Settings | app | 4 | 691 | 1 | 7 | 58 | d0ef7c6 2026-11-22 | 12 | 2 | 6 |
| `about` | About (version, repository link, attribution) | Settings | app | 2 | 572 | 0 | 0 | 0 | d0ef7c6 2026-11-22 | 12 | 0 | 2 |
| `localization` | Localization (English, zh-Hans, ja, es, fr) | Settings | app, extension, shared | 2 | 117 | 2 | 4 | 58 | 4a282eb 2026-11-22 | 53 | 0 | 6 |
| `ipc` | Two-process IPC (signed click, ack, menu config, heartbeat) | Infrastructure | ipc, shared | 5 | 843 | 6 | 56 | 1168 | 25c6b7a 2026-11-21 | 39 | 0 | 4 |
| `persistence` | Persistence (SwiftData in the App Group, migrations) | Infrastructure | app, shared | 12 | 1032 | 10 | 27 | 578 | fb8baf1 2026-11-21 | 28 | 0 | 5 |
| `app-lifecycle` | App lifecycle (single instance, startup failure, quiet launches) | Infrastructure | app, shared | 6 | 370 | 2 | 6 | 51 | aa934c5 2026-11-22 | 25 | 1 | 2 |
| `action-execution` | Action execution layer (serial executor, file operations, access lease) | Infrastructure | app | 4 | 185 | 4 | 20 | 312 | 6f60d36 2026-11-22 | 24 | 0 | 0 |
| `warning-window` | Shared warning window (Cut, Paste, New File) | Infrastructure | app | 2 | 261 | 0 | 0 | 0 | aa934c5 2026-11-22 | 22 | 0 | 1 |
