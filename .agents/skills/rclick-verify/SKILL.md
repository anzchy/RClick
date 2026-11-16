---
name: rclick-verify
description: Verify an RClick change before calling it done. Runs the gate ladder (`scripts/gates.sh`: unsigned Xcode build, RClickTests, the five-language localization check, agent tooling tests), a test-integrity review, the RClick-specific checks for the change type (IPC on both sides, both string catalogs, Swift 6.2 concurrency, security-scoped access, destructive actions, SwiftData migration), then posts the evidence as a comment on the ticket's issue on anzchy/RClick and writes a record the delegator checks before audit and merge. Use when finishing a ticket or a fix round, and in place of the bundled /verify in this repo. Not for auditing someone else's diff (auditors read the posted evidence).
---

# rclick-verify

"Tests pass" is not done. This skill is done when you have run every step below that applies and recorded each
command with its decisive output. Run it on the final head of your first handoff and again on the final head of
every fix round. Claude implementers run `/rclick-verify`; `gpt-imple` (Codex) reads this file and runs the steps
literally. There is no hook: the brief requires this skill (its `## Verify (rclick-verify)` section), and the
delegator checks the record before audit and before merge:

```sh
node .agents/skills/rclick-verify/scripts/evidence.mjs check --head <sha> --issue <n> [--worktree <wt>]
```

It exits 0 and prints `OK head=… issue=… comment=…` only when `.build/rclick-verify/<head>.json` exists for that
head, the record's issue is `<n>`, every mandatory gate passed, and `commentUrl` is
`https://github.com/anzchy/RClick/issues/<n>#issuecomment-<digits>` (the fork; upstream `wflixu/RClick` is never
accepted). It first prints `case=at-head` (worktree HEAD is `<sha>`; the tree must also be clean of tracked
changes) or `case=head-moved` (the worktree moved on, e.g. after a rebase; the record is still checked). Anything
else exits 1 with the reason. The check does not fetch the comment; the delegator opens it by hand.

Run everything from the root of your worktree. Put scratch files in `$TMPDIR/rclick-verify-<issue>/`, never in the
repo or another worktree.

## Rules for every step

- **Evidence or it didn't happen.** Record each command and its decisive output. "All green" is no evidence.
- **Nothing sensitive in the evidence.** It is posted to GitHub. No personal paths (`/Users/…`), no HMAC secret,
  bookmark data, tokens or keys. `evidence.mjs render` refuses such a body; fix the input, don't bypass it.
- **Never weaken a test to get green.** No deleting, skipping, disabling or loosening a test or assertion, no
  retry loops, no longer timeouts to hide a race. There are no known flakes in this repo: a flaky failure is a
  failure until a reviewed commit says otherwise.
- **Don't touch the user's RClick.** Never quit, kill or relaunch a running RClick or Finder, and never change
  System Settings. Real-desktop checks belong to the delegator (`macos-device-test`).
- A step that cannot run goes into the evidence's **NOT VERIFIED** list with the reason. Do not skip silently.

## 0. Define scope

Read the brief, the ticket's acceptance criteria and `git diff --name-status origin/main..HEAD`. Before dispatch the
delegator writes `<pane home>/.build/rclick-verify/target-worktree` with `scripts/mark-target.mjs`; check its JSON
`{worktree, branch, issue, task, handoff}` against the brief and do not rewrite it. Name the process the change
touches: **app** (`RClick/`), **extension** (`FinderSyncExt/`), **shared** (`Shared/`), **IPC** (a `Messager`
change), **tooling** (`scripts/`, `.agents/`, docs). Pin the merge-base (`git merge-base origin/main HEAD`) and the
final head SHA.

## 1. Gate ladder

Commit first; never run gates with tracked changes or during a rebase, merge or cherry-pick.

```sh
git diff --check "$(git merge-base origin/main HEAD)"..HEAD   # gate `diffcheck`: must print nothing
scripts/gates.sh                                              # build → unit-tests → localization → skill-tooling
```

`scripts/gates.sh` prints one `GATE <lane> PASS|FAIL|SKIP` line per lane and a final `GATES PASS|FAIL`; full logs
are in `.build/gates/<lane>.log` and DerivedData in `.build/DerivedData` (per worktree). It stops at the first
failure: fix it and rerun from the top. Run a single lane with `scripts/gates.sh --lane <name>`.

- **build**: the unsigned Debug build CI runs. The PASS line shows the warning count. Compare it with the same lane
  on the merge-base (or the count the delegator gives in the brief): a new warning, above all a Swift 6
  concurrency warning, is a failure to fix, not to explain.
- **unit-tests**: `xcodebuild test -only-testing:RClickTests`. Record the `tests: N passed, F failed` part of the GATE line
  and compare N with the merge-base: fewer tests needs an explanation in §2. If a Codex sandbox cannot run hosted
  tests, the lane exits **70** with `FAIL environment: no test result`; record the gate with `exitCode: 70` and a
  `notVerified` reason. Only `unit-tests` accepts that, only with exit 70; the delegator's desktop run is then the
  binding result. Exit 1 (a test failed) is always a failure.
- **localization**: `scripts/check-localization.py --languages zh-Hans ja es fr` over both catalogs.
- **skill-tooling**: the Python and Node tests under `.agents/skills/*/` and `scripts/codex-rules/`; SKIP when none.

## 2. Test integrity

```sh
mkdir -p .build/rclick-verify
node .agents/skills/rclick-verify/scripts/test-integrity.mjs --base <merge-base> > .build/rclick-verify/integrity.json
```

It lists removed `XCTAssert` / `#expect`, new trivially-true assertions, `XCTSkip` / `.disabled` / skips, retries,
timeout changes and `exit(0)`, plus test counts before and after. Hits are review findings, not automatic
failures: explain **every hit** in the evidence. Also show the RED: the failing assertion (not a compile error)
from before the implementation, with its SHA.

## 3. Checks by change type

| Change | Run and record |
|---|---|
| **Bug fix** | A regression test that is RED on the merge-base and GREEN on head; give both SHAs and outputs. If the bug only shows in Finder, give reproduction steps for the delegator's device run. |
| **A test that already passed when written** | Show it can fail: name a one-line mutant, apply it in a scratch copy (`git archive HEAD \| tar -x -C $TMPDIR/…`), paste the failing assertion. A test the mutant leaves green proves nothing. |
| **IPC** (`Shared/Messager.swift`, a payload, a new message) | Both sides changed: enum case and payload, sender, app handler (`RClickApp.swift` / runtime) and extension handler (`FinderSyncExt.swift`). Messages still go through `MessageSecurity` signing and verification; a test shows a tampered or unsigned message is rejected. Each `.click` still gets one `.actionAck`. New payload fields decode from an old payload (default values) and the other way round where the brief requires it; test both. |
| **Extension** (`FinderSyncExt/`) | It stays thin: no file I/O, persistence or heavy work; nothing blocking while Finder builds a menu. The liveness rules still hold (30 s `lastMainActivity` hint, 3 s ack at click time, `.quit` marks offline). |
| **User-visible strings** | Every new or changed key exists in the catalog of the target that renders it: `RClick/Localizable.xcstrings` and/or `FinderSyncExt/Localizable.xcstrings` (each target reads only its own). All of en, zh-Hans, ja, es, fr, same format specifiers. List the keys and which catalogs hold them. Catalogs edited by exact-string edits only, never re-serialized: `git diff --stat` on the catalogs should show only the lines you meant to change. |
| **Concurrency** (`@MainActor`, `Task`, notification handlers, `Sendable`) | Build warning count unchanged; no new `nonisolated(unsafe)` / `@unchecked Sendable` without a written reason. Run the affected tests repeatedly: `xcodebuild test … -only-testing:RClickTests/<Class> -test-iterations 20 -run-tests-until-failure` (same flags and DerivedData as `gates.sh`); record the iteration count. |
| **Folder access** (`BookmarkManager`, `PermissionService`, any `startAccessingSecurityScopedResource`) | `grep -n 'startAccessingSecurityScopedResource\|stopAccessingSecurityScopedResource'` over the changed files; every start is paired with a stop on every path (prefer `defer`). No new entitlement in `*.entitlements`. Stale bookmarks refreshed. |
| **Destructive or file actions** (delete, hide/unhide, new file, copy) | Delete Direct still asks unless Option was held when the menu was built. New files never overwrite (`getUniqueFilePath`). Actions touch only the selection. A test or a dry run in `$TMPDIR` shows each of these. |
| **SwiftData / settings** (`RClick/Model/`, `ConfigService`, `SettingsBackup`, `UserDefaults` keys) | A model change comes with a migration (`DataMigrationManager`, `DataVersion`) and a test that loads the old shape. Settings export → import round-trips. Reset All Settings still restores every category. |
| **UI** (`RClick/Settings/`, `MenuBarView`) | SwiftUI only; AppKit only for system integration. Light and dark appearance. Screenshots, if any, are taken by the delegator on the desktop; list them as NOT VERIFIED here. |
| **Menu behaviour in Finder** (what the user sees when right-clicking) | Cannot be proved by unit tests. Give the delegator the exact steps and expected menu for a `macos-device-test` run and list it as NOT VERIFIED. |
| **Updater / single instance / launch at login** | Tests for the failure paths: a failed install never reports success, a failed relaunch keeps the running app. |

## 4. Evidence: issue comment, handoff and record

Do this after your last commit for the round, so the evidence matches the head the auditors read. A later commit
means a new comment and a new record.

1. Write `$TMPDIR/rclick-verify-<issue>/input.json` following [`evidence-template.md`](evidence-template.md):
   `issue`, `task`, `branch`, `head` (full SHA), `base`, `toolchain`, `machine`, `sandbox`, `gates` (each
   `{name, command, exitCode, keyLine}` for `diffcheck`, `build`, `unit-tests`, `localization`, `skill-tooling`;
   a SKIP lane is `exitCode: 0` with the SKIP line), `integrity` (text), `byType` (rows of
   `{behavior, expected, actual, result}`), `notVerified` (list; `["none"]` when empty).
2. `node .agents/skills/rclick-verify/scripts/evidence.mjs render <input.json>`: read the body. It refuses personal
   paths and key-like strings.
3. `node .agents/skills/rclick-verify/scripts/evidence.mjs post <input.json>`: posts it with
   `gh issue comment <issue> -R anzchy/RClick` and prints the comment URL. This comment is the only GitHub write
   you make: no other comments, edits, labels, closes, PRs or pushes, and nothing ever on `wflixu/RClick`.
4. Add `"commentUrl": "<url>"` to the input and run `evidence.mjs record <input.json>`: it writes
   `.build/rclick-verify/<head>.json` (ignored by git). Failed or incomplete gates can be recorded but never satisfy
   `check`.
5. Write the handoff `~/.rclick-roster/herdr/<pane>/<item>-handoff.md`: keep its `Report-Task:` line and the brief's
   sections, put the comment URL and the head SHA it covers on the `Evidence:` line, and copy the rendered body
   below it so the delegator can read it offline.

## 5. Keep this skill true

When a command here is stale or broken, fix this file or its scripts on the same branch, rerun the affected gate,
and name the correction in the handoff; it is audited with the rest. Script changes keep
`node --test .agents/skills/rclick-verify/tests/verify.test.mjs` green.
