# gpt-imple task: issue #<issue> — <one-line summary> (delegator, <date>)

You are **gpt-imple** (Codex). New task, fresh session. Worktree `~/Documents/mac-app/RClick-wt/gpt-imple`.
Branch: `git fetch origin && git switch -c i<issue>-<slug> origin/main` (main ≥ <sha7>). Issue #<issue> on
`anzchy/RClick` (`gh` is set to the fork; never touch upstream `wflixu/RClick`).
Tier **<Low|Medium|High>** because <reason>. Every tier gets two blind audits (gpt-auditor and opus-auditor).

## Read first
- `CLAUDE.md` (the project constitution: Swift 6.2, SwiftUI for all UI, AppKit for system integration only,
  macOS 15+, `@AppLog`, the two-catalog localization rules).
- The ticket: `gh issue view <issue>` (acceptance criteria are binding). Its parent spec: `gh issue view <spec>`,
  sections <list the decisions this ticket depends on>.
- `GLOSSARY.md` and `docs/adr/` if they exist (use the glossary's terms in names and tests); `specs/<file>` when the
  ticket cites it.
- User decisions to honour, quoted: 「…」.

## Today / wanted
<what exists now on main (file:line or "nothing yet"); what must work when this ticket is done>

## Process and seams under test
- Process: <app (`RClick/`) | extension (`FinderSyncExt/`) | shared (`Shared/`) | IPC (both sides)>.
- Seams the tests use (do not add new ones without saying why): <e.g. `ActionService` with a temp directory and a
  fake permission check; `MenuService` building a menu config from given settings; `Messager` encode/sign/decode
  round trip; `SettingsBackup` export/import>.
Name the seam each acceptance criterion is proved at. A test against a private helper is a finding.

## Acceptance
- AC-1 … (copied from the ticket, each testable)
- AC-n: `scripts/gates.sh` ends with `GATES PASS`.

## Ownership
**You own, and may edit:** <paths>. **Not yours:** <paths>, and always `.github/`, `RClick.xcodeproj` (unless the
ticket adds a file that must be registered there: then only that registration), entitlements and `Info.plist`
files.
(Delegator: list real paths; `overlap-check.py claim` reads them before dispatch.)
If a needed change crosses a fence: stop, propose the minimal hunk, and write it under the handoff's open questions.

## Test-first (Matt Pocock's `/tdd`)
- Read and follow the repo's tdd skill: `.agents/skills/tdd/SKILL.md` (and its `tests.md`, `mocking.md` beside it).
- One vertical slice per cycle: one failing test at a seam, the least code to pass it, repeat. No horizontal
  batches of tests first. Refactoring belongs to review, not the loop.
- **Evidence:** for each slice, paste the failing assertion output (a real assertion failure, not a compile
  error) and then the passing run of the same test into the handoff, with the `-only-testing:RClickTests/<Class>/<test>`
  filter used (same flags as `scripts/gates.sh`).
- **Tag every slice** in the handoff as either `RED→GREEN` or `test only, already enforced`. A "test only" slice shows
  the test passing at the base commit and names the mutant that makes it fail, with that failure pasted. A test
  that no mutant can break is a finding, not coverage.
- **Every production hunk belongs to a slice.** A changed message, default or signature needs its own RED; a hunk
  with no behaviour change is called "no-behaviour refactor" in the handoff with one line why.
- Changing an existing assertion: only where it asserts the old behaviour; list before/after/why.

## Verify (rclick-verify)
Read `.agents/skills/rclick-verify/SKILL.md` and run its steps literally (Claude implementers run
`/rclick-verify`; never the bundled `/verify`). It covers the gate ladder (`scripts/gates.sh`), the test-integrity
review, the checks by change type and the evidence: a comment on issue #<issue> on `anzchy/RClick` for your final
head, plus the record `evidence.mjs check` reads.

This ticket's specifics:
- Checks from rclick-verify §3 that apply: <IPC on both sides | both string catalogs | concurrency (repeat
  `<TestClass>` N times) | security-scoped access | destructive action | SwiftData migration | none, because …>.
- Finder expectations (run what you can; list the rest under NOT VERIFIED for the delegator's device check):
  <per behaviour: selection and trigger (items / container / sidebar / toolbar) → menu entry → expected result on
  disk, clipboard or screen>.

## Commits
`<type>(<scope>): <summary>`; body names `#<issue>`; trailer `Implemented-by: gpt-imple`; one RED slice per commit
(its test and its code), so an auditor can rebuild each RED from history; "test only" slices may share a commit.
Stage named paths only (never `git add -A`, `.` or `-u`). A user-visible change adds a `CHANGELOG.md`
`[Unreleased]` line. New user-visible strings go in the right catalog with all five languages, by exact-string edits.
A ticket that adds or changes a menu item, a Settings capability or a default updates its spine entry (`docs/feature-ledger/feature-map.json`) and ledger block (`docs/feature-ledger.md`) in the same PR (`docs/agents/feature-ledger.md`).
The evidence comment on #<issue> is your only GitHub write. No push, PR, other comment or issue edit, branch
switch away from your branch, branch deletion, `rm -r`, or touching other worktrees. Never launch or kill Finder or
an installed `RClick.app`, and never change system settings or Finder extension registration.

## Handoff
`~/.rclick-roster/herdr/gpt-imple/i<issue>-handoff.md`, starting with exactly one line `Report-Task: <task ID>`
(the delegator gives you the ID: `i<issue>-implementation-r1`). Contents: design in a few lines; AC table
(AC → seam → proving test); RED/GREEN per slice; changed existing assertions;
"Evidence: <comment URL> @ <sha7>" (the `rclick-verify` comment on #<issue>);
`git diff --stat origin/main..HEAD`; production lines changed; NOT VERIFIED list; open questions.
Reply DONE with the path.

## Open questions (defaults)
- OQ-1 … default: … — Follow each default; if the code or spec contradicts one, stop and report.

**No questions in the pane.** Don't ask through a sub-agent or user-input prompt: nobody watches the pane. Take the
default, record the question under the handoff's open questions, and go on. If you are truly blocked, write the
handoff with a `BLOCKED: <reason>` line and stop.
