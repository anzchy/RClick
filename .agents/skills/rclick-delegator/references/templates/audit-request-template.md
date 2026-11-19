# Audit request: issue #<issue> <summary> — round 1, blind — <auditor>

Report-Task for your report: `i<issue>-audit-r1-<auditor>` (exactly one `Report-Task:` line).

Item: issue #<issue> on anzchy/RClick. Range: base <sha7>..<head7> on branch `<branch>`, worktree
~/Documents/mac-app/RClick-wt/gpt-imple. <N> commits, ~<lines> production lines. Objects are shared; use
git show and git diff --no-ext-diff. Main checkout: ~/Documents/mac-app/RClick.
<main has moved to <sha7> (…); the rebase comes after audit — name conflict risks as notes only.>

Risk tier: **<tier>** (<why>). <Raise to High if it touches IPC or message signing, security-scoped access, a
destructive file action, the updater, or a SwiftData model.> Audit every dimension at full depth from
docs/agents/audit-dimensions.md on origin/main (<tier> policy under the severity table). Use the severity table,
COVERAGE line and report shape exactly.

Rules: ~/.rclick-roster/herdr/delegator/audit-brief.md (blind, read-only, only `gh issue view`, scratch isolation).

Inputs:
- the ticket's acceptance criteria, quoted: <paste>;
- the spec decisions it depends on, quoted: <paste the relevant bullets from the parent spec>;
- the brief: ~/.rclick-roster/herdr/gpt-imple/i<issue>-brief.md; scope amendments: <files or none>;
- the handoff, a claim to test: ~/.rclick-roster/herdr/gpt-imple/i<issue>-handoff.md;
- the verify evidence comment: <comment URL> on #<issue>, for head `<full SHA>` (opus-auditor: read it with
  `gh issue view <issue> -R anzchy/RClick --comments`; gpt-auditor, whose sandbox cannot reach GitHub: read the
  verbatim copy at ~/.rclick-roster/herdr/gpt-auditor/i<issue>-evidence-r1.md and run no `gh`; the format is
  `.agents/skills/rclick-verify/SKILL.md` §4 on origin/main): a claim to test against the code and the brief's
  expectations;
- gate evidence: ~/.rclick-roster/gates/<prefix>-summary.txt (rerun by the delegator at <head7>; `DONE overall=0`
  means every lane passed; the `GATE` lines name each lane). <If a gate flake needed a rerun: also the failing
  run's summary and its `lane <lane> failure-log=<path>` file; read both and judge whether the failure is this
  diff's.>

Beyond the dimensions, judge these specifically:
- <5–10 bullets on the risky points: both IPC sides changed together and still signed; one ack per click;
  start/stop security-scoped access paired on every path; Delete Direct confirmation and the Option snapshot; no
  overwrite of existing files; strings in the right catalog with all five languages; `@MainActor` on state
  mutation; extension stays thin; RED genuine; Finder behaviours either evidenced or NOT VERIFIED for the device
  check>

Run no `gh` command other than `gh issue view <issue> -R anzchy/RClick --comments`; do not push, launch the app, or
touch Finder. Write ~/.rclick-roster/herdr/<auditor>/i<issue>-audit-r1.md with the report shape's VERDICT /
COVERAGE / COUNT block. The delegator merges both verdicts; poll completion is not audit acceptance.

No questions in the pane: don't ask through a sub-agent or user-input prompt. Record an open point as a finding or a
note in the report; if you are truly blocked, write the report with a `BLOCKED: <reason>` line and stop.
