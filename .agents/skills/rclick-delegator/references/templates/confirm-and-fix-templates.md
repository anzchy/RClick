# Fix brief template

```
# Issue #<issue> fix round <k> (merged audit, delegator <date>)<. One round, no confirm round (no C/H).>

Report-Task for your updated handoff: `i<issue>-fix-r<k>` (replace the handoff's `Report-Task:` line; keep one).
<If the implementer's context was reset: "Your context was reset. Read your handoff … and the brief … first.">
Branch <branch> @ <head7>. <Step 0: rebase onto origin/main; never pipe git rebase; a conflict: stop and report.>
Reports (unblinded for you): ~/.rclick-roster/herdr/gpt-auditor/i<issue>-audit-r1.md and
~/.rclick-roster/herdr/opus-auditor/i<issue>-audit-r1.md.

## Must fix (blocking; confirm round follows)
F1 [High] <one-paragraph trace> Fix: <direction, not code>. Tests: <seam, gated / deterministic cases>.
<If a fenced file is needed: stop and ask.>

## One Medium round (no confirm for these)
- <finding>: <fix direction>

## Cheap Lows
- <…>

## Still open (do not fix)
<list>

## Accepted limitations (do not re-raise)
<item: reason, e.g. "RED provenance of <change> unverified: history is not rewritten">

Run `rclick-verify` again at the fix head and post a new evidence comment on #<issue> (task `i<issue>-fix-r<k>`); put its
URL in the handoff. Paste RED then GREEN per behavioural fix. Commit per fix with `#<issue>` in the body and
`Implemented-by: gpt-imple`. Update the handoff with a "Fix round <k>" section. Do not push.
```

# Confirm request template

Fill it once per auditor (`<auditor>` = `gpt-auditor` or `opus-auditor`).

```
# Confirm round <k>: issue #<issue>. Fresh context. — <auditor>

Report-Task for your report: `i<issue>-confirm-r<k>-<auditor>`.
Read `~/.rclick-roster/herdr/delegator/audit-brief.md` first: the confirm-phase read barrier and the scratch rule.

- Item issue #<issue>, tier <tier>. <Rebased onto <sha7> before fixing; rebased round-one head <sha7>.> Branch
  `<branch>` @ <head7>, worktree <path>. Full range <base>..<head7>. Fix diff <r1head>..<head7>.
- Gate evidence at <head7>: ~/.rclick-roster/gates/<prefix>-summary.txt. Verify evidence for the fix head: <comment URL>
  on #<issue> (opus-auditor: `gh issue view <issue> -R anzchy/RClick --comments`; gpt-auditor: the verbatim copy at
  ~/.rclick-roster/herdr/gpt-auditor/i<issue>-evidence-fix-r<k>.md; check it names this head).

## Findings in scope (merged verdict)
- **F1 [High]** (<who raised it>) <restated finding>. Requested: <fix>. <Approved fenced hunks.>
- Medium fixes (judged here only for regressions): <list>
Still open (do not re-judge): <list>.
Accepted limitations (do not re-raise; they go to the PR's Still open): <list with reasons>.
<If the user authorised this round beyond the two-round cap, quote the decision.>

Your own earlier report: ~/.rclick-roster/herdr/<auditor>/i<issue>-audit-r1.md. Fix brief: <path>. Handoff
`Fix round <k>`: <path>.

## Scope
- each finding above: CLOSED / PARTIAL / OPEN with evidence;
- any Critical or High that the fix diff or the rebase introduced, exposed or worsened.

Write ~/.rclick-roster/herdr/<auditor>/i<issue>-confirm-r<k>.md and end with the VERDICT / COUNT block.
```

For the auditor who did NOT raise a High, say so: "raised by the other auditor; you did not raise it — judge it
fresh".
