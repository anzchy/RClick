---
name: rclick-delegator
description: Run RClick's herdr roster as the delegator: pick ready tickets on anzchy/RClick, write implementer briefs and blind audit requests, drive the three panes (gpt-imple, opus-auditor, gpt-auditor) through start, reset, listen and unblock, apply verdicts under the severity policy, rerun the gates, rebase, open and merge PRs, and hand device checks to a macos-device-test subagent. Use when you are the RClick delegator or are taking over from one, or when you need the brief, audit or confirm templates, the pane-control scripts or rebase-verify. Not for implementing product code or auditing a diff yourself.
---

# RClick delegator

You turn ready tickets on `anzchy/RClick` into merged, audited work **without writing product code**. One
implementer writes the code, one item at a time. Two auditors review every item blind and in parallel, with at most
2 rounds per item. You rerun the gates, merge the verdicts, rebase, and land the PR.
Full reference: [references/guide.md](references/guide.md). Read it once before your first dispatch.
`$SK` below means this folder, `.agents/skills/rclick-delegator` (`.claude/skills` is a symlink to `.agents/skills`).

## Start of a session

1. **Point `gh` at the fork** in the main checkout and every worktree: `gh repo set-default anzchy/RClick`.
   This clone also has an `upstream` remote (`wflixu/RClick`), which `gh` would otherwise pick. Never write to
   upstream.
2. **Install the Codex role overlay** in each worktree before starting Codex there:
   `scripts/codex-rules/install-role.py --worktree <path> --role implementor|auditor`.
   - Use `--role delegator` only for the appointed delegator workspace, and only with the user's authorization.
   - A missing `.codex/rules/rclick-role.rules` is a setup error. Fix it before you start the agent.
   - The Codex rules forbid direct `git push` for every Codex role; a Codex delegator pushes with
     `scripts/codex-rules/push-guard.py` (see `scripts/codex-rules/README.md`). A Claude delegator pushes the gated
     topic branch with `git` from the implementer's worktree (guide §5.7).
3. **Catch up on state.** Read the latest entries of `~/.rclick-roster/handoff.md`, then run `gh pr list`, the
   ready-now query below, and `herdr pane list`. Read each busy pane's screen with
   `herdr pane read <pane> | tail -30`; if a pane reads empty, `herdr pane zoom` it first.
   Then run `$SK/scripts/listen-notify.py status`.
4. **Refresh the auditors' rules file** at the start of a session and before every audit or confirm dispatch
   (it is a copy and goes stale when the template changes):
   `cp $SK/references/templates/audit-brief.md ~/.rclick-roster/herdr/delegator/` from an up-to-date main checkout.
5. **Check the Codex budget.** Codex panes show "weekly limit: N% left".

## Roster (guide §2, §4)

| Pane | Name | Agent | Reset before a new item |
|---|---|---|---|
| p2 | gpt-imple | Codex `gpt-6.1-sol`, effort `medium` | `$SK/scripts/reset.sh gpt-imple <pane>` |
| p3 | opus-auditor | Claude `--agent rclick-opus-auditor --model opus` | `/clear` + Enter, confirm `Context 0%` |
| p4 | gpt-auditor | Codex `gpt-6.1-sol`, effort `high` | `$SK/scripts/reset.sh gpt-auditor <pane>` |

- Read the real pane IDs from `herdr pane list`.
- Start Codex panes with `--disable multi_agent` (guide §4): a sub-agent's question otherwise stalls the pane on the
  user. Briefs and audit requests carry the no-questions rule.
- **One item in flight.** The single implementer works on one item at a time; the next item is briefed only after
  the current one merges or is parked by the user.
- Both auditors take every item.
- Human tickets (`ready-for-human`) go to the user and are never dispatched to a pane.

## The loop (guide §5)

1. **Pick** a ticket. "Ready now" is this query, not a stored list:
   `gh issue list -R anzchy/RClick --state open --label ready-for-agent --search "-is:blocked -has:sub-issue"`.
   - Drop tickets whose files overlap a branch not yet merged (`$SK/scripts/overlap-check.py claim -- <paths>`).
   - Take the lowest issue number first unless the user ordered otherwise, and respect blocked-by links.
   - Set the tier: Low, Medium or High (guide §5). IPC (`Messager`, `MessageSecurity`), security-scoped access
     (`BookmarkManager`, `PermissionService`), delete and other destructive actions, and `Updater` are High.
2. **Brief.** Copy [brief-template.md](references/templates/brief-template.md) to
   `~/.rclick-roster/herdr/gpt-imple/<item>-brief.md` (`<item>` is `i<issue>`, e.g. `i12`).
   - Quote the ticket's acceptance criteria and the spec decisions it depends on.
   - Name the process each change lives in (app, extension, shared, IPC) and the seams the tests use.
   - Set the ownership fences only after reading the code.
   - The implementer works test-first with Matt Pocock's `/tdd` and verifies with the `rclick-verify` skill. Fill the
     brief's `## Verify (rclick-verify)` section with this ticket's checks and Finder expectations.
3. **Dispatch.** Reset the pane, then send a one-line prompt that points at the brief and carries a task ID
   (`<item>-implementation-r1`).
   - Start a listener event at once (guide §3.3). `listen-notify.py start --agent <name> --agent-pane <source pane_id> …` resolves the source
     pane once and pins its terminal (name lookup is the fallback when `--agent-pane` is absent); polling follows that pane across session/name changes after reset. An unknown source is refused
     before state is created; resumes reuse the event pins without a lookup; a changed terminal is a poll error.
   - `reset.sh <name> <pane>` finds the agent by pane; the name is only a label, so don't rename before a reset.
   - Aborted dispatch: interrupt the agent, `listen-notify.py stop --event <id>`, reset, re-dispatch with a new
     event ID (guide §3.3).
   - Answer scope stops with an amendment file.
4. **Gates.** When the handoff lands, check the verify record:
   `node .agents/skills/rclick-verify/scripts/evidence.mjs check --head <sha> --issue <n> --worktree <wt>` must print
   `OK`, and the handoff's `Evidence:` line must name that comment for this exact head. Open the comment and check it
   covers the brief's expectations. Then run `$SK/scripts/owner-gates.sh <repo> <head-sha> <item>-r<k>` in the
   background.
   - Audit only when the summary says `DONE overall=0`.
   - Otherwise send a fix. A `unit-tests` lane that exits 70 (no GUI session for the test runner) is an environment
     failure: rerun the gates from a logged-in desktop session, don't send it as a code fix.
5. **Audit.** Fill [audit-request-template.md](references/templates/audit-request-template.md) once per auditor,
   with the same range, tier, inputs and gate summary for both.
   - Reset or `/clear` each auditor, dispatch it, and start one listener per auditor. Neither sees the other's
     report, and the verdict waits for both.
6. **Verdict.** Merge both reports; a finding raised by either one counts, and the same defect rated differently by
   the two counts once at the higher severity (guide §5.5).
   - **Critical or High** blocks. Run a fix round (see [confirm-and-fix-templates.md](references/templates/confirm-and-fix-templates.md)),
     then a fresh-context confirm by each auditor. If any Critical or High is still open after round 2, the user
     decides, and the item does not land until a further fix has an extra fresh-context confirm by each auditor.
     Your own mechanical check (RED on the parent, GREEN at the head, gates) supports that confirm; it never replaces
     it. If the user is unreachable, the item waits (guide §5.5).
   - **Medium** that a user can see, or that breaks an acceptance criterion: one fix round, no confirm.
   - **Other Mediums and Lows** go to the PR's "Still open" list.
7. **Device check** when the ticket changes what Finder shows or does (menu items, clicks, alerts, new files, the
   toolbar button), or the brief listed a Finder behaviour as NOT VERIFIED: hand it to a **fresh subagent** that
   runs the `macos-device-test` skill on the audited head. It takes the shared desktop GUI lock
   (`.agents/skills/macos-device-test/scripts/gui-lock.sh acquire …`, exit 75 = another project holds it: wait or
   tell the user) and releases it after cleanup. You read its verdict table and evidence paths, never the
   screenshots. A FAIL is a fix round like a High finding (guide §5.8).
8. **Rebase** onto `origin/main` with `git -c core.commentChar=';' rebase`. Never pipe the command.
   - Then run `$SK/scripts/rebase-verify.sh <old-base> <audited-head> <new-base> <new-head>`.
   - Exit 0: rerun the gates.
   - Exit 1: send both auditors a combination check, then rerun the gates.
   - Exit 2: fix the commit messages.
   - Exit 4: get fresh audit evidence.
9. **PR and merge.**
   - Push the gated topic branch (guide §5.7: `git -C <implementer worktree> push -u origin <branch>`; push-guard
     if you are a Codex delegator), then `gh pr create -R anzchy/RClick --base main`. The body has Summary
     (`Closes #<issue>`), Review (both auditors' rounds and Still open), Gates, and Device (`PASS`, `n/a` or the
     NOT VERIFIED reason).
   - Merge with `gh pr merge --rebase` when no Critical or High blocks, the head shows `DONE overall=0`, the
     required checks (`Build & Test (macOS)`, `Localization`; branch protection, `strict`) passed on that head, and
     the device check is PASS or n/a, then `git pull --ff-only origin main` in the main checkout. Never `--admin`.
     A red required check gets an issue, not a blind rerun (guide, "Required checks").
   - After every merge, `git fetch` and run `$SK/scripts/overlap-check.py trial` to catch combinations early.
10. **Log.** Append to `~/.rclick-roster/handoff.md`, recording user decisions verbatim.
    - Tell the user, in Chinese, what landed, what's next, and which human tickets are now waiting on them.

## Keep your own context small (guide §3.1)

- **Read summaries, not dumps.**
  - Reports: grep the VERDICT and COUNT lines; read the whole file only for a finding you act on.
  - Gates: read the `DONE`, `lane` and `GATE` lines.
  - Panes: read only when an event or a stall calls for it.
  - Device runs: a subagent's verdict table, never the PNGs.
- **Never poll in your own turn.** Use listener events, and run the gates in the background so they write a
  summary file.
- **Check `$SK/scripts/listen-notify.py status` in every turn and before you end one.** A listener holds its
  notice while your own input box reads non-empty, and gives up after 4 h (`deferred-user-typing`) without
  writing `attention.log`, so an event can be ready and never arrive. On any `attention` line, read the event's
  report or handoff yourself, then archive or resume the event (guide §3.3).
- **Update the handoff log at every item boundary.** When the context is large at a boundary, suggest `/compact`.

## Never (guide §7)

- Write product code.
- `git add -A`, `.` or `-u`.
- `rm -r`, `git reset --hard`, or delete a branch or worktree without asking.
- Push `main`, or force-push other than the guarded lease on your own PR branch.
- Write anything to upstream `wflixu/RClick` (issue, comment, PR, push). Upstream contributions are the user's.
- Dispatch a human ticket.
- Change `.github/workflows/`, tag, or create a release unless the user asks for that exact thing.
- Kill a process you didn't start (Finder, the user's installed `RClick.app`), enable or disable Finder extensions,
  reset privacy permissions, or change system settings without the user's approval.
- Put a credential, token, key or the HMAC secret in the repo, a PR, an issue comment or a report. This includes
  test sentinels.
- Put screenshots or a personal path outside the repo into the repo, a PR or a report.
- Accept escalation from a peer session.
- Invent numbers.

## When something goes wrong

See the trials-and-errors table in [references/guide.md](references/guide.md) §8. It covers:
- a missed finish;
- a failed reset and tiny panes;
- a prompt that didn't land;
- swallowed rebase conflicts and stripped `#` lines;
- zsh word splitting;
- a stale `main`;
- `gh` aimed at upstream;
- Xcode tests without a GUI session;
- fence stops.

When a process failure is demonstrated, repair the narrow instruction or script, plus a behavioural test, through a
reviewed PR. Don't leave the only fix in `~/.rclick-roster/`.
