# Audit dimensions: what both pre-landing auditors check

This is the single list of audit dimensions for RClick. Both auditors load it:
- `gpt-auditor` (Codex, in its own herdr pane);
- `opus-auditor` (Claude Code on Opus, in its own herdr pane; `.claude/agents/rclick-opus-auditor.md`).

Change it here, never in a brief or an agent wrapper. The two verdicts can only challenge each other if they
cover the same ground, so a dimension one auditor checks and the other doesn't is a defect in the process,
not a style choice.

The list is adapted from the Mado and clay rosters' audit dimensions (Google Engineering Practices, ISO/IEC 25010).
RClick's risk sits in the two-process split (main app and FinderSync extension), the signed IPC between them,
sandboxed file access through security-scoped bookmarks, and file actions that cannot be undone, so those get
their own dimensions.

## The dimensions

| ID | Dimension | What it asks in RClick |
|---|---|---|
| D1 | Design & architecture fit | Does the change belong, in this target, now? Work goes in the main app (`RClick/`, through `RCRuntime` services: `ActionService`, `MenuService`, `PermissionService`, `ConfigService`); the extension (`FinderSyncExt/`) stays a thin renderer and event forwarder; code both use lives in `Shared/`. Does it follow `GLOSSARY.md` terms, `docs/adr/` and the specs in `specs/`? Simplest design that meets the ticket, no speculative generality? |
| D2 | Correctness & reliability | Does it do what the ticket's acceptance criteria say, on ordinary and edge paths: one item and many selected items, files and folders, names with spaces and non-ASCII, a path on an external volume, a missing or moved target, the toolbar, container and sidebar menu triggers? Error handling and the state left behind after a failure. |
| D3 | IPC protocol & signing | A `Messager` change (`Shared/Messager.swift`) updates both sides: the enum case and payload, the sender, the handler in the app and in the extension. Every message stays HMAC-SHA256 signed and verified (`MessageSecurity`); an unsigned or badly signed message is dropped, never acted on. Payloads stay decodable by the other side's older and newer version where the change says they must (decoding defaults for new fields). Each `.click` still gets exactly one `.actionAck`. |
| D4 | Extension thinness & liveness | No file work, persistence or heavy logic in the extension; it renders the pushed menu config and forwards clicks. The liveness rules hold: the 30 s `lastMainActivity` cache only drives the "RClick is not running" hint; the click-time check (ack within 3 s or the "did not respond" alert) decides failure; `.quit` marks the extension offline at once; heartbeats stay lightweight. No blocking call on the extension's main thread while Finder builds a menu. |
| D5 | Sandbox & security-scoped access | Access to user folders goes through `PermissionService.hasAccess(to:)` / `promptForPermission(for:)` and `BookmarkManager`; no new entitlement, no pre-granted path, no temporary-exception entitlement. Every successful `startAccessingSecurityScopedResource()` is paired with `stopAccessingSecurityScopedResource()` on every path (use `defer`). Stale bookmarks are refreshed. No personal paths, keys or the HMAC secret in logs, tests or evidence. |
| D6 | Destructive & file actions | Delete Direct keeps its confirmation unless Option was held when the menu was built; hide/unhide, new-file creation and opening never overwrite an existing file (unique names via `getUniqueFilePath`), never act on items outside the selection, and report failures instead of failing silently. Any action that removes or rewrites user data is High tier. |
| D7 | Concurrency | Swift 6.2 strict concurrency: `@MainActor` on UI and `AppState` mutation, `Sendable` across isolation boundaries, no `nonisolated(unsafe)` or `@unchecked Sendable` without a written reason, no new concurrency warnings in the build log. Notification handlers hop to the right actor. A superseded or cancelled operation must never deliver a stale result (an old menu config, a late ack). |
| D8 | Persistence & migration | SwiftData `@Model` changes in `RClick/Model/` come with a migration path (`DataMigrationManager`, `DataVersion`), keep the shared App Group container readable by both processes, and keep settings backup/import (`SettingsBackup`) round-tripping. `UserDefaults` keys are stable or migrated. Reset All Settings restores every category. |
| D9 | Localization | Every new or changed user-visible string is a key in the right catalog: `RClick/Localizable.xcstrings` for the app, `FinderSyncExt/Localizable.xcstrings` for anything the extension renders (each target resolves only its own `Bundle.main`). Translations exist for en, zh-Hans, ja, es and fr with the same format specifiers; `scripts/gates.sh --lane localization` passes. Catalogs were edited by exact-string edits, not re-serialized. |
| D10 | Testing & validation | Do the tests in `RClickTests/` prove each acceptance criterion through public behaviour? Was the RED real and recorded before the code it tests? Missing cases: an edge, a failure, a concurrent interleaving, a decode of an old payload. No test deleted, skipped, disabled or loosened (rclick-verify's test-integrity report explains every hit). Does the `rclick-verify` evidence comment on the issue for this head cover each runnable criterion, with menu-in-Finder behaviour either device-verified or listed as NOT VERIFIED? |
| D11 | Compliance with rules | The ticket's scope and the brief's ownership fences; `CLAUDE.md` constitution: Swift 6.2, SwiftUI for all UI (AppKit only for system integration such as `NSWorkspace`, `NSPasteboard`, the FinderSync menu itself), macOS 15+ only, `@AppLog` logging; commit format and the `Implemented-by:` trailer; named-path staging; no push or PR from an implementer; no write to upstream `wflixu/RClick`; no CI change under `.github/` unless the ticket asks. |
| D12 | Updater, release & environment | Changes to `Updater`, `SingleInstanceGuard`, launch-at-login or the release workflow: a failed install never reports success, the staged bundle's version is checked before it replaces the app, a failed relaunch keeps the running app. Every new dependency needs a reason; the toolchain (Xcode 26+, Swift 6.2) and deployment target (15.6) stay unchanged unless the ticket says otherwise. |
| D13 | Maintainability, observability & docs | Duplication, dead code, unclear names, long functions, leftover TODOs; comments explain why. Enough `@AppLog` logging to diagnose the change in the field, at the right privacy level, without noise on hot paths (menu building, heartbeats). `CHANGELOG.md` `[Unreleased]` has a user-facing line for a user-visible change; README, `CLAUDE.md`, specs, glossary and ADRs stay true. |

**Every dimension is checked on every audit.** When a change cannot touch a dimension, the auditor says `n/a`
and gives a reason in a few words (for example, `D3 n/a: no Messager change`). An auditor does not drop
dimensions to save time. The risk tier changes how deep each check goes, not which dimensions are checked:
- **Low** tier (docs, localization-only, agent tooling and scripts outside the app): D1, D5, D9, D11 and D13 at full
  depth; the rest only for whatever the change actually touches.
- **Medium** tier: all dimensions at full depth.
- **High** tier (IPC protocol or signing, bookmark/permission handling, Delete Direct and any other action that
  removes or rewrites user files, SwiftData schema, the updater): all dimensions, plus a reproduction or a
  counter-proof for every D3, D5, D6 and D8 finding.

## Severity

| Severity | Meaning | Blocks landing |
|---|---|---|
| Critical | User data deleted or overwritten without confirmation, a file action on the wrong target, an unsigned message acted on, the HMAC secret or a bookmark leaked, settings silently lost on upgrade | Yes |
| High | One of: a defect a user or the test suite reaches on an ordinary path; an acceptance criterion claimed but not met; a broken rule (AppKit UI, a new concurrency warning, an unpaired security-scoped access, a string missing from a catalog the target renders, a weakened test, an invented number) | Yes |
| Medium | A real defect or risk off the ordinary path, or debt with a concrete cost | No; counted, listed briefly |
| Low | A nit: style, naming, a small clean-up | No; counted only |

Before landing, Medium findings that affect user-visible behaviour or violate an acceptance criterion get one
fix round, with no confirm round. Every other Medium goes under the PR's `Still open` section for a later
follow-up; it does not block landing.

- Every Critical or High needs three things: the file and line, an ordered trace of how an ordinary path reaches
  it, and the reason existing tests miss it. A suspicion without a trace is at most Medium.
- An auditor never downgrades its own High without a reproduction or a counter-proof.
- A defect in code the change did not touch counts only when the change makes it reachable.
- Lows never block.
- A range over about 400 changed lines of production code gets a Medium recommending a split.

## Independence

Every tier gets two blind audits in parallel, `gpt-auditor` and `opus-auditor`, at most two auditor rounds per
item (the blind audit plus one confirm). Round one is blind:
- neither auditor reads the other's report folder, the delegator's notes, or PR comments;
- both get the same range, tier and acceptance list at the same time;
- the delegator merges the two verdicts.

When the auditors disagree on a finding, the delegator may send it as a `challenge` to the auditor that did not
raise it. That auditor confirms the finding with its own trace or refutes it with a reproduction or a
counter-proof. "Unlikely" is not a refutation.

## Report shape

```
VERDICT   <audit|confirm|challenge> · <item> @ <sha7>   (range <base7>..<sha7>)   tier <Low|Medium|High>
COVERAGE  D1 ok|n/a — <few words> · D2 … · … · D13 …
AC        AC-1 PROVED|NOT PROVED|WRONG — <own evidence>   (one line per acceptance criterion)
FINDINGS
  F1. [Critical|High] D<n> <dimension> · <file:line> · <issue>
      trace: <ordered steps>
      fix: <one line>
  M1. [Medium] D<n> · <file:line> · <issue>
CONFIRM   (confirm mode) <finding id>: CLOSED|PARTIAL|OPEN — <evidence>
COUNT     C<n> H<n> M<n> L<n>   BLOCKING C<n> H<n>
```

The delegator rejects a report that has no `COVERAGE` line, or that skips a dimension without a reason.
