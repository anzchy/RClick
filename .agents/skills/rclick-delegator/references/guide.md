# Delegator guide (RClick herdr roster): full reference

This is the long reference behind `SKILL.md`. Helpers are under `.agents/skills/rclick-delegator/scripts/`
(`$SK/scripts/`). It was adapted from the clay roster's delegator guide (itself adapted from the Mado roster's),
keeping the herdr control, blind-audit and merge discipline. From Mado it keeps device validation through the
`macos-device-test` skill and the shared desktop GUI lock; it drops the feature ledger, UI parity, the doc gardener,
the heavy lock and the TDD receipts.

`CLAUDE.md`, the ticket and its parent spec on `anzchy/RClick`, `specs/`, `GLOSSARY.md`, `docs/adr/` and
`docs/agents/audit-dimensions.md` stay authoritative. Where this guide disagrees with them, they win and this guide
needs fixing.

Machine-local state (briefs, reports, gate logs, the handoff log) lives under `~/.rclick-roster/` and is **never
committed**.

---

## 1. The role in one page

The delegator turns ready tickets on `anzchy/RClick` (issues labelled `ready-for-agent`, usually sub-issues of a
spec written with `/to-spec` and `/to-tickets`) into merged, audited work. It **does not write product code**. Code
goes to the implementer, verdicts come from the two auditors. The delegator itself:

1. Picks the next ready ticket and decides its tier.
2. Writes the **brief** for the implementer, dispatches it and answers scope questions.
3. Checks the implementer's `rclick-verify` record, reruns the gates itself (`owner-gates.sh`) and writes **audit
   requests** for both auditors, blind and in parallel, each in a fresh context.
4. Merges the two verdicts, writes fix briefs, and decides between a confirm round and Still open.
5. Hands Finder-visible changes to a fresh subagent for a `macos-device-test` run.
6. Rebases, reruns the gates, opens the PR on the fork and merges it with `gh pr merge --rebase` once everything
   passes.
7. Routes **human tickets** (`ready-for-human`) to the user; never to a pane.
8. Keeps the user informed, asks only for genuine decisions, and records every user decision verbatim (commit
   body, the issue, the handoff log).

Merge authority: merge without asking when the merged audit shows no blocking Critical/High, the owner gates pass
at the PR head, both required checks passed, and the device check is PASS or n/a.

**Required checks.** Branch protection on `anzchy/RClick` `main` requires `Build & Test (macOS)` and `Localization`
(`.github/workflows/pr-build.yml`), with `strict` on: the PR head must contain the current `main`, so rebase and
let the checks rerun when `main` moved. Both checks and the delegator's `owner-gates.sh` summary at the PR head must
pass; neither replaces the other. A red required check gets an issue, not a blind rerun: rerun once only when the
failure is clearly infrastructure (runner lost, download failed) and say so in the PR. `enforce_admins` is off so
the owner can sync `main` from upstream; never use an admin bypass (`gh pr merge --admin`) to land roster work.

The fork's `Agent tooling` workflow (`agent-tooling.yml`, Linux) runs only when `.agents/**`, `scripts/**` or
`.codex/**` change, so it is not a required check (a path-filtered required check would hang other PRs as pending);
when it ran, red blocks the merge the same way. The `Linux-Preflight` line (`ci-linux-preflight`, §5.7) is
supplementary only: it never overrides a GitHub check, and an unreachable or busy host is NOT VERIFIED, which never
blocks a merge.

**Fork and upstream.** `origin` is the fork `anzchy/RClick`: issues, PRs and merges happen there. `upstream` is
`wflixu/RClick`, read-only for the roster. `gh` picks `upstream` unless `gh repo set-default anzchy/RClick` ran in
that clone or worktree, so setup runs it everywhere and commands that write pass `-R anzchy/RClick`. Offering a
change upstream is a separate step the user starts.

---

## 2. Machine, session and roster

- **Repo:** main checkout `~/Documents/mac-app/RClick` (remote `anzchy/RClick`), one worktree per pane under
  `~/Documents/mac-app/RClick-wt/`.
- **Machine:** the Mac mini. Xcode 26+ and a logged-in desktop session are needed for `xcodebuild test` and device
  runs.
- **Terminal multiplexer:** herdr, session `rclick`. Pane IDs are stable until a pane is closed; always read the
  real IDs from `herdr pane list` (the IDs below are the suggested layout).

| Pane | Name | Agent / model | Worktree | Role |
|---|---|---|---|---|
| p1 | rclick-delegator | Claude Code, Opus | main checkout | delegator |
| p2 | gpt-imple | Codex `gpt-6.1-sol`, effort `medium` | `RClick-wt/gpt-imple` | implementer |
| p3 | opus-auditor | Claude Code, `--agent rclick-opus-auditor --model opus` | `RClick-wt/opus-auditor` (detached) | auditor |
| p4 | gpt-auditor | Codex `gpt-6.1-sol`, effort `high` | `RClick-wt/gpt-auditor` (detached) | auditor |

**Slots:** one implementation item in flight. The next item is briefed after the current one merges, or after the
user parks it. Both auditors take every item; merge an item's verdict only when both of its reports are in.

**Panes that are too small.** A 2–3 row pane leaves `herdr pane read` empty and makes `reset.sh` report
`FAIL … no context line after 30s` even if the reset worked. Run `herdr pane zoom <pane>`, then read again.

### Python runtime

Every roster Python script runs under Homebrew's `/opt/homebrew/bin/python3`. The macOS `/usr/bin/python3` (3.9)
comes first on this Mac's `PATH` and is too old for some of them. The scripts' shebangs name the Homebrew
interpreter, and `reset.sh` / `rebase-verify.sh` / the shell pollers use it for their inline Python, so call the
scripts directly (`$SK/scripts/x.py`, `scripts/codex-rules/x.py`), not through `python3`. Set
`RCLICK_PYTHON=<interpreter>` to override it in the shell scripts. Run the script tests with the same interpreter:

```sh
/opt/homebrew/bin/python3 -m unittest discover -s .agents/skills/rclick-delegator/scripts -p 'test_*.py'
/opt/homebrew/bin/python3 -m unittest discover -s scripts/codex-rules -p 'test_*.py'
```

### Shell aliases

herdr starts agents by typing `codex …` / `claude …` into the pane's shell, so an alias on those names adds its
flags to the roster's (an aliased `--sandbox` makes Codex refuse a second `-s`). Keep `codex` and `claude`
unaliased; personal shortcuts go under other names .

### First-time setup

```sh
cd ~/Documents/mac-app/RClick && git fetch origin && gh repo set-default anzchy/RClick
git worktree add --detach ../RClick-wt/gpt-imple origin/main
for n in opus-auditor gpt-auditor; do git worktree add --detach ../RClick-wt/$n origin/main; done
for n in gpt-imple opus-auditor gpt-auditor; do (cd ../RClick-wt/$n && gh repo set-default anzchy/RClick); done
scripts/codex-rules/install-role.py --worktree ~/Documents/mac-app/RClick-wt/gpt-imple --role implementor
scripts/codex-rules/install-role.py --worktree ~/Documents/mac-app/RClick-wt/gpt-auditor --role auditor
scripts/codex-rules/install-role.py --worktree ~/Documents/mac-app/RClick --role delegator   # only with the user's authorization
mkdir -p ~/.rclick-roster/herdr/{delegator,gpt-imple,opus-auditor,gpt-auditor} ~/.rclick-roster/gates
cp .agents/skills/rclick-delegator/references/templates/audit-brief.md ~/.rclick-roster/herdr/delegator/
```

The implementer worktree starts detached; each brief's first command creates the ticket branch from `origin/main`.
Each worktree keeps its own DerivedData under `.build/` (`scripts/gates.sh`), so builds never share a folder.

---

## 3. herdr cheat sheet

```sh
herdr pane list                               # all panes, agent kind, status, cwd
herdr pane read <pane> | tail -30             # visible screen
herdr pane zoom <pane>                        # toggle zoom (fixes tiny panes)
herdr pane send-text <pane> '/clear'          # type text…
herdr pane send-keys <pane> Enter             # …and submit it (send-text alone does not submit)
herdr pane send-keys <pane> Escape            # interrupt a Codex turn (context is kept)
herdr pane send-keys <pane> shift+left        # open a pending Codex sub-agent question
herdr pane split <pane> --direction down      # new pane; returns its pane_id
herdr agent start <name> --kind <codex|claude> --pane <id> -- <agent args>
herdr agent prompt <name> '<text>'            # send a whole prompt to a named agent
herdr agent get <name>                        # JSON incl. agent_status
```

Queueing a follow-up while a Codex agent works: `send-text`, then `send-keys Tab` twice.

### 3.1 Keep the delegator's context small

In the Mado roster about 85% of all Claude tokens went to delegator turns re-reading a 400–850k context; every
extra round on any item is multiplied by that.

| Instead of | Do |
|---|---|
| `cat` of a report, handoff or log | `grep -n 'VERDICT\|COUNT\|^  [CHML][0-9]'` for reports, the `DONE`/`lane` lines for gate summaries; read the full file only for a finding you act on |
| Polling panes or gates in your turn | listener events (§3.3); `owner-gates.sh` in the background with a summary file |
| Re-reading the same brief or handoff after each event | note the facts you need in the handoff log once |
| Carrying a finished item's detail forward | at each item boundary (merge, pause, user decision) update the handoff log, then tell the user if it is a good moment for `/compact` |

### 3.2 Status is unreliable for Codex

herdr's `agent_status` can be stale for Codex. For a Codex task with a unique report, use the listener's report
mode (§3.3): it requires both a fresh report with exactly one `Report-Task: <task ID>` line and herdr idle/done, so
a scrolled pane showing old activity cannot prevent detection. For tasks without a report, use the idle listener
with the same explicit route as §3.3 (busy while the screen shows "esc to interrupt", idle on two reads of
"Worked for …"):

```sh
$SK/scripts/listen-notify.py start \
  --event '<unique event ID>' --task '<task ID>' \
  --route codex-thread --thread '<exact delegator Codex thread UUID>' \
  --agent '<source name>' --agent-pane '<source pane_id>' \
  --handoff "$HOME/.rclick-roster/herdr/<source name>/<task ID>-handoff.md" \
  --poll idle --interval 60 --max-minutes 600
```

For Claude panes herdr status is reliable; use `--poll handoff` with a round marker.

### 3.3 Durable listener notification

A bare poller can finish after the delegator's turn ends and leave only a local log. Immediately after every
implementation, fix, audit or confirm dispatch, start the attached listener with a fresh event and round ID and an
**explicit delegator route**:

```sh
$SK/scripts/listen-notify.py start \
  --event 'i12-implementation-r1-head-<sha7>' \
  --task 'i12-implementation-r1' \
  --route codex-thread --thread '<exact delegator Codex thread UUID>' \
  --agent 'gpt-imple' --agent-pane '<source pane_id>' \
  --handoff "$HOME/.rclick-roster/herdr/gpt-imple/i12-handoff.md" \
  --handoff-marker 'i12-implementation-r1' \
  --poll report --interval 30 --idle-grace-seconds 180 --max-minutes 3000
```

For a Claude delegator replace the two route arguments with the pinned pane destination, copied from a fresh
`herdr pane list` (literal absolute cwd spelling):

```sh
  --route claude-pane --pane '<delegator pane_id>' --terminal-id '<terminal_id>' --cwd '/Users/…/RClick'
```

All three poll modes retry a failed or timed-out `herdr agent get` on the next tick. Five consecutive failures
produce a poll-error; a successful observation resets the count. Invalid envelopes and terminal mismatches
remain immediate poll-errors. The watch deadline still applies during retries.

What the listener guarantees, and what it doesn't:
- Report mode completes only on a fresh report (modified after registration) with exactly one
  `Report-Task: <task ID>` line equal to `--task` and `--handoff-marker`, plus herdr idle/done. Idle without a fresh
  report for the grace period queues `missing-handoff`; a blocked status queues at once. None of these means
  acceptance.
- A Claude route writes the full notice to `~/.rclick-roster/herdr/delegator/listeners/<event>/notification.txt` and
  sends only the shell-inert token `: RCLICK_LISTENER_EVENT_<event>`, after checking pane identity before and after.
  It holds while the user is typing or a dialog is open in the box (state `waiting-user-typing`, later
  `deferred-user-typing`), and logs long holds to `~/.rclick-roster/herdr/delegator/attention.log`.
- `delivery-uncertain` is never replayed automatically: inspect the pane and event, then use a new event ID only
  after reconciling by hand. A Codex event becomes uncertain when a `codex queue` attempt started but timed out or
  failed (it may have been accepted), or when the queue returned 0 and the receipt could not be written (it is not
  sent again). After a timeout the worker keeps the event uncertain while it retries; a later success makes it
  `delivered`. A queue receipt proves transport, not that the turn read it; the delegator ACKs after
  checking pane, report, task identity and SHA.
- Run `listen-notify.py status` at each loop and before ending a turn; exit 3 means an event needs attention.
  Resume a deferred event with the identical `start` command; it reuses the pinned source pane and terminal
  without resolving the name. 
- To abort a dispatch, interrupt the agent, stop its listener with `listen-notify.py stop --event <id>`, reset,
  and re-dispatch with a new event ID. `stop` signals nothing. It writes `stop-requested` in the event dir and
  waits up to `--wait-seconds` (default 30) for the worker, which ends its own poll group and records `stopped`.
  A send already under way finishes first. `stop` prints and exits with the real outcome:
  `stopped … previous=<state>` (0), `delivered` (0, the notice was sent), `uncertain` (3, check the pane before
  the new event), or `running … worker pid N` (1, the worker did not answer; the request stays). A worker that is
  already gone gets `stopped` only if there is no receipt and no uncertain send. A stop that lands after a Codex
  attempt that may have been accepted ends the retries and reports `uncertain event=X: … an attempt may have been
  delivered …` (3). `status` lists `stopped` without attention, unless the worker could not confirm that its poll
  group ended (`cleanup_error=`, attention). A stopped event can't be resumed; an unknown event exits 2; a delivered event is left as it is.
- Every dispatch or rearm gets a new `--event` and matching `--task`; reusing an event with a different agent,
  task, destination, poll argv or report path is rejected.

Before relying on a new host, run one probe event the user authorizes, confirm the delegator visibly receives it,
ACK it, then continue. Never let the helper accept an audit, merge or advance a lifecycle unattended.

---

## 4. Starting and resetting agents (fresh context per item)

Every new work item starts in a **fresh conversation**. Fix rounds for the same item may continue in the same
conversation, but reset it if its context is above ~80%; the fix brief must then list what to read first.

| Agent | Start | Reset before a new item |
|---|---|---|
| gpt-imple | `herdr agent start gpt-imple --kind codex --pane <p2> -- -m gpt-6.1-sol -c model_reasoning_effort="medium" -s danger-full-access --disable multi_agent` (role overlay installed first) | `$SK/scripts/reset.sh gpt-imple <p2>` |
| opus-auditor | `herdr agent start opus-auditor --kind claude --pane <p3> -- --agent rclick-opus-auditor --model opus --dangerously-skip-permissions` | `/clear` + Enter, confirm `Context 0%` |
| gpt-auditor | `herdr agent start gpt-auditor --kind codex --pane <p4> -- -m gpt-6.1-sol -c model_reasoning_effort="high" -s workspace-write --add-dir ~/.rclick-roster/herdr/gpt-auditor --disable multi_agent` (auditor overlay installed first; no network: the sandbox allowlists domains and GitHub is not on the list) | `$SK/scripts/reset.sh gpt-auditor <p4>` |

Notes:
- `reset.sh <name> <pane>` reads the agent through the pane (`herdr agent get <pane>`), like the listeners, so it works after herdr has lost the name; `<name>` only labels its messages. Don't rename the pane
  before a reset. A refused reset prints the pane's real status, or herdr's lookup error.
- `reset.sh` sends `/new`, then Enter twice (Codex's "Where should the new conversation run?" chooser), and waits
  for a fresh Codex title over an empty transcript with a `Context 0% used` footer, or a changed pane session ID.
  Timers: `RCLICK_RESET_CONTEXT_SECS` (default 30), `RCLICK_RESET_POLL_SECS` (default 0.25). Zoom first if the pane is
  tiny. If the next prompt "didn't land" (still 0% and idle after 20 s), send it again.
- Codex may stop at "Update available" or "Trust this folder?" before its composer; `herdr agent start` then
  returns `agent_not_ready`. Read the pane and answer the dialog (update: option 2 "Skip", not Escape; trust: once
  per worktree at setup). See §8.
- Start every Codex pane with `--disable multi_agent`. With sub-agents on, a sub-agent's question waits in the pane
  behind `Shift+←` until someone answers it, so the pane stalls on the user. Every brief and audit request also
  carries the no-questions rule (brief template, "Open questions"; audit request template).
- `/clear` does not reload `.claude/agents/rclick-opus-auditor.md`: after a change to it lands, move
  `RClick-wt/opus-auditor` to the new main and restart the pane.
- The gpt-auditor sandbox can write only its report folder and scratch. It can read the code and run `git`, but an
  `xcodebuild` run there usually fails (DerivedData and the test runner need more than the sandbox allows), so the
  owner-gates logs are its build and test evidence; audit-brief.md says so. It cannot reach GitHub either, so the
  delegator saves each evidence comment verbatim into its folder (§5.4); the auditor overlay forbids every GitHub
  write and `gh api`. Network drops show `ECONNRESET` (Claude) or "Reconnecting…" (Codex): check the network,
  `Escape`, then prompt "resume where you left off".
- gpt-imple runs with `-s danger-full-access` so `xcodebuild test` can start the test host. If a gate still exits
  70 in its pane (no test result: the runner never connected), it records NOT VERIFIED and the delegator's
  owner-gates run, from the logged-in desktop session, is binding.
- `--dangerously-skip-permissions` and `-s danger-full-access` follow the Mado and clay rosters and are the
  user's call; the Codex role overlays and `CLAUDE.md` rules are the guardrails.

---

## 5. Work item lifecycle

```
ready ticket → brief → dispatch → (scope questions / amendments) → handoff
  → verify record + owner gates → two blind audits → merged verdict → fix round (± confirm)
  → device check (Finder-visible changes) → rebase → gates → PR → merge → close ticket → handoff log
```

Risk tier decides depth (both auditors on every tier):

| Tier | Typical RClick scope | Audit |
|---|---|---|
| Low | docs, README, CHANGELOG, specs, localization-only string fixes, roster scripts and skills | both auditors, one blind round; severity policy §5.5 |
| Medium | ordinary app behaviour: settings views, menu config building (`MenuService`), copy path/name, open with app, new-file templates, common folders, icons | both auditors; one fix round for user-visible/AC Mediums, no confirm |
| High | IPC (`Shared/Messager.swift`, `MessageSecurity`, any message or payload change), security-scoped access (`BookmarkManager`, `PermissionService`), Delete Direct and every action that removes, hides or rewrites user files, `Updater` / `SingleInstanceGuard` / launch at login, SwiftData model or migration changes | both auditors; every C/H gets a fresh-context confirm by each auditor; at most 2 auditor rounds, then the user decides |

Raise the tier if a change touches the extension's liveness rules (heartbeat, `lastMainActivity`, the click-time
ack), entitlements or sandboxing, the shared App Group container, or anything that could log a path, key or the
HMAC secret.

### 5.1 Picking the next ticket

**Ready now** is a query, never a stored list:

```sh
gh issue list -R anzchy/RClick --state open --label ready-for-agent --search "-is:blocked -has:sub-issue" --json number,title
```

It excludes specs (which have sub-issues) and every ticket with an open blocker. Then drop tickets that overlap in
files with a branch not yet merged (`overlap-check.py claim`), and pick the lowest issue number unless the user set
an order. Before briefing, check that the target isn't already done on `origin/main` (`git log -S`). Human tickets
(`ready-for-human`) are never dispatched: when one becomes unblocked, tell the user what it needs and which agent
tickets it gates.

### 5.2 Brief

Copy `references/templates/brief-template.md` to `~/.rclick-roster/herdr/gpt-imple/<item>-brief.md` and fill it
(`<item>` is `i<issue>`, e.g. `i12`). Fill the brief's `## Verify (rclick-verify)` section: which `rclick-verify` §3
checks apply (IPC on both sides, both catalogs, concurrency, security-scoped access, destructive actions, SwiftData
migration), and the Finder expectations: per behaviour, the selection and trigger (items, container, sidebar,
toolbar), the menu entry, and what must happen on disk, on the clipboard or on screen. Expectations come from the
ticket's acceptance criteria and the spec, not from the implementation. Read the code before writing ownership
fences: a fence that leaves no room for a needed hook makes the implementer stop. An IPC change owns both sides
(`Shared/Messager.swift`, the app's handler and `FinderSyncExt/FinderSyncExt.swift`) in one brief; never split a
message change across items. Before dispatch run `$SK/scripts/overlap-check.py claim -- <the brief's "You own"
paths>`: a shared code file with an unmerged branch means wait for that branch, or base the new branch on it only
when it is close to merge.

Dispatch with a one-line prompt that points at the file:

```sh
herdr agent prompt gpt-imple 'New task: issue #12. Read and follow ~/.rclick-roster/herdr/gpt-imple/i12-brief.md. Task ID i12-implementation-r1. Do not push.'
```

then start a listener event (§3.3).

### 5.3 During implementation

- **Scope stops.** The implementer stops at a fence and proposes a minimal change. If it is reasonable, approve it in
  `~/.rclick-roster/herdr/<impl>/<item>-scope-amendment-<n>.md`, prompt "approved, see file", and list it in the audit
  requests.
- **Fixture-only test mistakes** (a wrong fake, a path spelling): approve if no assertion changes; disclose in the
  handoff.
- **Codex sub-agent questions** block the turn: `shift+left`, pick, Enter.
- **Network stalls:** `Escape`, then "resume where you left off", listing the commits made so far.

### 5.4 Verify record, owner gates and audit requests

First check the implementer's verify record for the handed-off head:

```sh
node .agents/skills/rclick-verify/scripts/evidence.mjs check --head <full-sha> --issue <n> --worktree ~/Documents/mac-app/RClick-wt/gpt-imple
```

It must print `OK head=… issue=… comment=…`. Then open the comment it names (`gh issue view <n> --comments`): it
covers the brief's expectations, and a missing run has a NOT VERIFIED reason; otherwise send it back. Re-scrub it
yourself: no personal path, no key-like string, no sentinel from `scripts/test-secrets.txt` if that file exists. If
something sensitive got posted, tell the user and ask before deleting or editing the comment.

Then rerun the gates yourself in the background:

```sh
$SK/scripts/owner-gates.sh ~/Documents/mac-app/RClick <head-sha> i12-r1 &
```

It exports the exact commit to a scratch directory (no worktree is touched), runs `scripts/gates.sh` there (unsigned
Xcode build, `RClickTests`, the localization check, the roster tooling tests; DerivedData stays inside the scratch
tree), copies its `GATE` / `GATES` lines, runs the sentinel-secret grep when `scripts/test-secrets.txt` exists, and
writes `~/.rclick-roster/gates/i12-r1-summary.txt` ending in `DONE overall=<0|1>`. `overall=1` means a lane failed:
send it back as a fix before auditing, unless the `unit-tests` lane failed for the environment (exit 70: run it again
from a logged-in desktop session). A summary without `DONE` is no evidence. With less than 8 GiB free under
`$TMPDIR` or `$HOME` (`RCLICK_GATES_MIN_FREE_GIB`) it refuses before exporting, writing `refused: low disk …` and
`DONE overall=1`: tell the user and ask them to free space; never delete anything to make room yourself.

Save the evidence comment verbatim for gpt-auditor, whose sandbox cannot reach GitHub:
`gh api repos/anzchy/RClick/issues/comments/<id> --jq .body > ~/.rclick-roster/herdr/gpt-auditor/<item>-evidence-<round>.md`
(the issue comment stays the source of truth; opus-auditor reads it with `gh issue view`). Then write one request
per auditor from `references/templates/audit-request-template.md`:
`~/.rclick-roster/herdr/delegator/<item>-audit-r1-<auditor>.md`. Reports go to
`~/.rclick-roster/herdr/<auditor>/<item>-audit-r1.md` with exactly one `Report-Task:` line. Reset `gpt-auditor` and
`/clear` `opus-auditor` before every audit and confirm. Both get the same range, tier, quoted acceptance criteria,
quoted spec decisions and gate summary, at the same time; neither sees the other's report. Start one listener event
per auditor.

**Confirm requests** list each finding in scope with its requested fix, the fix diff range, any rebase, and "Still
open (do not re-judge)". They ask for CLOSED/PARTIAL/OPEN per finding plus any new C/H. Reset each auditor first.

**Challenge mode** (one auditor rules on a finding only the other raised) is available; prefer counter-proof or a
fix, then the fresh-context confirm, inside the 2-round cap.

### 5.5 Applying the verdict and severity policy

Merge both verdicts (a finding raised by either counts).
- **Same issue, two ratings:** when both auditors describe the same defect under different IDs or severities, it is
  one finding at the **higher** severity; name both IDs in the merged verdict and the fix brief, and tell the
  auditor who rated it lower that it is judged fresh at the merged severity.
- **Critical/High** blocks. Fix round, then a fresh-context confirm by **each** auditor. At most **2 auditor rounds**
  per item: round 1 is the blind audit, round 2 the confirm. If any Critical/High is still open (or newly raised)
  after round 2, do not brief another fix or confirm: report the open findings, their traces and the options to the
  user, who decides whether to continue.
- **Past the cap, a confirm is never skipped.** An item with a Critical/High still open after round 2 does not land
  until the user has decided and every further fix round ends with a fresh-context confirm by **each** auditor (an
  extra round beyond the cap). If the user cannot be reached, the item waits; brief nothing on a default. The
  delegator's own mechanical check (each new test RED on the fix's parent, GREEN at the head, the owner gates) is supporting evidence for the confirm request, never a substitute for it: it shows the named bug is caught,
  not that the fix introduced nothing new.
- **Medium** that a user can see or that breaks an acceptance criterion: one fix round, no confirm. Other Mediums go
  to the PR's "Still open" and a follow-up issue.
- **Low:** fold in only the cheap, obvious ones; the rest go to Still open.
- **Accepted limitation:** something that cannot be fixed in this item (history that isn't rewritten, an
  unverifiable environment, a deliberate ruling) is recorded once as an accepted limitation with its reason. It goes
  straight to the PR's Still open list and confirm requests list it under "Accepted limitations (do not re-raise)".
- A user-authorised extra round beyond the cap is recorded verbatim in the handoff log and named in the confirm
  request.

### 5.6 Rebase onto main

Never pipe `git rebase`; check its exit status. Run git with `-c core.commentChar=';'` so the message cleanup on
`--continue` keeps body lines that start with `#` (issue references). Any conflict: resolve deliberately, or send it
back to the implementer.

After a rebase run `$SK/scripts/rebase-verify.sh <old-base> <audited-head> <new-base> <new-head>`. A verdict covers
a patch, not a SHA:
- `CODE same` (exit 0): the verdicts carry over; rerun the gates.
- `CODE differ` (exit 1): the combination is new. Send both auditors a quick combination check of the resolved
  hunks, then rerun the gates.
- `MESSAGES differ` (exit 2): fix the messages before pushing.
- Empty comparison (exit 4): no evidence to carry forward; obtain fresh audit evidence.

(The scripts still exclude Mado's `docs/feature-ledger.*` paths and report a `LEDGER` class; RClick has no such
files, so both are inert.)

**Catch combinations early.** After every merge to main: `git fetch`, then `$SK/scripts/overlap-check.py trial`.
`OVERLAP` or `CODE` → rebase that branch now while it is small, then the rebase-verify and combination-check path;
`EMPTY … UNCOMMITTED` is invisible to the check, so tell its implementer what changed on main; `MERGED` → its
worktree can be cleaned (ask first; pane-home worktrees stay).

### 5.7 PR and merge

PR body sections: **Summary** (what and why, `Closes #<issue>`); **Review** (both auditors' rounds plus a
**Still open** list); **Gates** (the owner-gates summary lines at the PR head); **Device** (`PASS run=<id>`, `n/a`
with the reason, or NOT VERIFIED with the reason); the attribution line. When the item touches `.agents/**`,
`scripts/**`, `.codex/**` or `.github/workflows/agent-tooling.yml`, run `ci-linux-preflight` at the PR head and put
its `Linux-Preflight (supplementary; GitHub required checks remain binding): …` line after Gates, outside it; refresh
or drop it on every re-push. Its FAIL is a finding to fix like a red check; its NOT VERIFIED is recorded, not waited
on. Add a `CHANGELOG.md` `[Unreleased]` line in
the item itself (the implementer's commit) for every user-visible change.

Push the reviewed topic branch from the implementer's worktree, after the gates at that exact head:

```sh
git -C ~/Documents/mac-app/RClick-wt/gpt-imple push -u origin <branch>
git -C … push --force-with-lease=<branch>:<full-old-oid> origin <branch>   # only after rebasing that PR branch
```

Never push `main`, never a branch you haven't gated, never a plain `--force`, never to `upstream`.
`scripts/codex-rules/push-guard.py` is the guard for a Codex delegator: the Codex rules forbid direct `git push` for
every role, and the guard pushes only the branch checked out in a worktree provisioned with `--role delegator`. A
Claude delegator pushes with `git` directly, because the implementer's branch is checked out in the implementer's
worktree, where the guard won't run.

Then `gh pr create -R anzchy/RClick --base main --head <branch>`, rerun `owner-gates.sh` on the exact PR head if
anything changed, and `gh pr merge <P> -R anzchy/RClick --rebase` (authorised when there is no blocking C/H,
`DONE overall=0` at the head, the required checks `Build & Test (macOS)` and `Localization` passed on that head,
`Agent tooling` is not red when it ran, and the device check is PASS or n/a; never `--admin`; the Linux-Preflight
line is never a merge condition);
`git pull --ff-only origin main` in the main checkout. Confirm the ticket closed (the `Closes` line), then run
`overlap-check.py trial` (§5.6) and update the handoff log. Ask the user before removing the merged branch's worktree
(the pane-home worktree stays).

### 5.8 Device check (Finder-visible changes)

Unit tests can't show a Finder menu. When a ticket changes what Finder shows or does (menu entries or their order,
click results, alerts, new files and their rename, hide/unhide, the toolbar button, the "RClick is not running" or
"did not respond" hints), or the evidence lists such a behaviour as NOT VERIFIED, run a device check on the audited
head before the PR:

- Spawn a **fresh subagent** with a brief: run ID, head SHA, the behaviours and expectations from the ticket, and
  "follow `.agents/skills/macos-device-test/SKILL.md`, including the GUI lock rule; reply with a verdict table
  (behaviour, expected, seen, PASS/FAIL) and the evidence paths". You read its table, never the screenshots.
- The desktop is shared with other projects on this Mac. The subagent takes the lock first:
  `.agents/skills/macos-device-test/scripts/gui-lock.sh acquire <run-id> <minutes> "<purpose>"`. Exit 75 means
  another project holds it: no GUI at all; wait (`gui-lock.sh wait …`) or tell the user. It releases with the
  `acquisition_id` from its `ACQUIRED` line only after cleanup, aborted runs included.
- The run uses its own build of the head, never the user's installed `RClick.app`, and never kills a process it
  didn't start. Enabling the Finder extension or granting Accessibility is the user's step: if the run needs it,
  stop and ask.
- A FAIL becomes a fix round like a High finding, then a new device check. Screenshots stay under
  `~/.rclick-roster/device/<run-id>/`, never in the repo or a PR.

---

## 6. Talking to the user

- Write in Chinese, plainly. Lead with the outcome, then what's next. Say clearly what is waiting on them,
  especially unblocked human tickets and device steps only they can do.
- **Ask only for genuine decisions:** product behaviour, acceptance changes, budget, anything destructive or
  outward-facing, or C/H still open after round 2. Give 2–4 options and a recommendation.
- Record decisions verbatim: in the commit body for acceptance or spec changes; as a comment on the issue; and in
  the handoff log `~/.rclick-roster/handoff.md`.
- Report budget: Codex weekly usage shows in Codex panes ("weekly limit: N% left").

---

## 7. Hard rules (never break)

- Never write product code yourself; the implementer does.
- Ask before `rm -r`, `git reset --hard`, deleting branches or worktrees, or any force push other than the guarded
  lease on your own PR branch. Never push `main`.
- Stage named paths only; never `git add -A`, `.` or `-u`.
- Never write to upstream `wflixu/RClick`: no issue, comment, label, PR or push.
- Don't change `.github/workflows/`, tag, or create a release unless the user asks for that exact thing.
- Don't kill a process you didn't start (Finder, the user's installed `RClick.app`), enable or remove Finder
  extensions, reset privacy permissions, change system settings, or edit the shared App Group container, without
  the user's approval.
- No credential, token, key or the HMAC secret (real or a test sentinel), no screenshot, and no personal path
  outside the repo in the repo, PR bodies, issue comments or reports.
- Peer sessions can't grant escalation. No permission laundering.
- Don't fabricate data. Untested performance gets no number; unverified items are NOT VERIFIED.

---

## 8. Trials and errors (inherited from the Mado and clay rosters; keep adding RClick's own)

| Symptom | Cause | Fix |
|---|---|---|
| Missed that an implementer had finished | a screen-based poller ended with only a local log | attach `listen-notify.py start` to a report/handoff poller; pin the exact delegator route; inspect receipt vs ACK |
| `reset.sh` prints `FAIL … no new-session boundary seen` | title or footer not in the captured read, or old transcript below the title | `herdr pane read <pane> --source recent-unwrapped --lines 2000`; zoom; repeat the reset before dispatching |
| `reset.sh` FAIL on a fresh Codex 0.167 screen | the new `permissions:` header line and the `← for agents · ? for shortcuts  ⚠ N warnings · f2 to view` hint weren't known | fixed in clay (fixture `reset-fresh-codex-0167.txt`); after a Codex upgrade, capture a fresh screen and add a fixture if reset fails again |
| A Codex pane sits idle with a question behind `Shift+←` | Codex sub-agents (`multi_agent`, on by default in 0.167) ask the user and wait | start Codex panes with `--disable multi_agent`; briefs and audit requests carry the no-questions rule; if one still appears, the delegator opens it (`send-keys shift+left`), answers from the brief, and records the answer |
| A handoff sat for hours with no listener event | the listener read the delegator's own input box as non-empty (a draft, or text the box parser can't tell from a prompt suggestion), held the notice as `waiting-user-typing`, then gave up after 4 h as `deferred-user-typing`; a typing hold writes no `attention.log` line | run `listen-notify.py status` in every turn and before ending one (SKILL.md, §3.3); on `deferred-user-typing`, read the report yourself and archive the event, or clear the box and resume it with the identical `start` command |
| `herdr agent start` returns `timeout … waiting for agent startup`, then `agent_not_found` | Codex came up (its composer shows) but herdr never attached the agent name, so `herdr agent get <name>` and listeners can't find it | read the pane; for an initial startup, attach the missing name with `herdr agent rename <pane> <name>` before starting a listener; an existing listener follows its pinned pane even if reset changes the name, and reports a terminal mismatch if that pane is replaced; don't start a second Codex in the pane |
| `reset.sh` printed `FAIL reset <name>: status , not idle` and the next prompt went into the old session | an older version looked the agent up by name, and herdr loses the name after a reset plus a dispatched prompt | it now reads `herdr agent get <pane>`; no rename before a reset. A refusal names the pane's status or the lookup error |
| A dispatch had to be aborted and its listener was still polling | older `listen-notify.py` had no way to stop an event | interrupt the agent, `listen-notify.py stop --event <id>`, reset, re-dispatch with a new event ID; never kill a listener by PID. Known limit: if the worker itself was SIGKILLed mid-poll, its poll group runs on to the poll's own `--max-minutes`; nothing is delivered |
| `herdr agent start` returns `agent_not_ready` | Codex shows "Update available" or "Trust this folder?" before the composer | read the pane; trust each worktree once at setup; for the update prompt choose "Skip" (option 2) explicitly, not Escape (an Escape once ran the update); better, set `check_for_update_on_startup = false` in `~/.codex/config.toml` (the user's file: ask) |
| The auditors read old rules | `~/.rclick-roster/herdr/delegator/audit-brief.md` is a copy, stale after a template change merged | refresh it before every audit or confirm dispatch (SKILL "Start of a session" step 3) |
| A command separator like `===` failed | same `=word` expansion as above | use `----` as a separator in commands |
| `xcodebuild`: `no space left on device` | the disk was nearly full | owner-gates refuses below 8 GiB; ask the user to free space, never delete to make room |
| `gh issue list` showed someone else's issues, or a comment landed on `wflixu/RClick` | `gh` picked the `upstream` remote because the clone had no default | `gh repo set-default anzchy/RClick` in every clone and worktree (§2 setup); pass `-R anzchy/RClick` on writes; if something landed upstream, tell the user, don't delete it yourself |
| `unit-tests` lane exits 70, `FAIL environment: no test result` | `xcodebuild test` ran without a GUI session or inside a sandbox, and the test host never connected | not a code failure: rerun owner-gates from the logged-in desktop session; the implementer records NOT VERIFIED |
| A Finder menu change passed every test but looked wrong in Finder | unit tests can't render the FinderSync menu | §5.8 device check for every Finder-visible change |
| Evidence lines looked condensed or reformatted | the interactive shell wraps `xcodebuild`/`grep` in output-shortening tools | capture with `command xcodebuild` / `command grep` (rclick-verify rules) |
| Prompt sent right after a reset or `/clear` "didn't land" | chooser still open or the pane redrawing | confirm `Context 0%`, check for "esc to interrupt" after ~20 s, resend |
| A mid-rebase commit swallowed the implementer's message | `git rebase … \| tail` hid the conflict | never pipe a rebase; check its exit code |
| Rebased commits lost their `#<issue>` body lines | `rebase --continue` cleanup strips `#` lines | `git -c core.commentChar=';' rebase …`; check with `rebase-verify.sh` |
| A rebase looked clean but the merged code was wrong | the conflict resolution created a new combination nobody audited | `rebase-verify.sh` exit 1 → quick combination check by both auditors before gates |
| A loop over `for f in $c` broke | zsh doesn't word-split unquoted variables | use `${=c}`, or compare the whole string |
| A later step ran on a detached HEAD | a `git switch` in a chain failed and the chain went on | end every step of a multi-step command with `\|\| exit 1` |
| Base looked old / wrong diff range | the main checkout's local `main` is stale | always use `origin/main` after `git fetch` |
| Listener fired but the agent had not finished | a model-capacity or TLS drop made the pane idle | read the pane; prompt "resume …"; rearm a fresh listener event |
| A brief's target was already done | brief written from an older head | check `git log -S` on `origin/main` before briefing |
| Implementer stopped at a fence | fences didn't allow a needed hook | read the code before writing fences; approve minimal amendments in a file |
| `codex` refuses to start: `--sandbox` cannot be used multiple times | a shell alias on `codex` already passes `--sandbox` | keep `codex`/`claude` unaliased (§2 Shell aliases) |
| `permission denied` running a roster script | the executable bit was lost | `chmod +x` it and land the mode change through a PR |
| Script tests fail with the real `herdr` | `~/.zshenv` puts the real `herdr` before the tests' fake one for `#!/bin/zsh` scripts | roster zsh scripts start `#!/bin/zsh -f` + `emulate -R zsh`; tests run them through the shebang, never `zsh <script>` |
| `git show $sha:path` read the wrong thing (a false leak alarm) | zsh treats `:s`, `:h`, `:t`, `:r`, `:e`, `:a` after `$var` as modifiers | brace it: `"${sha}:path"`  |
| `echo ====` fails with `=== not found` | a word starting with `=` expands to a command's path | quote it |
| `no matches found: --include=*` | zsh errors on a glob that matches nothing | quote the glob, or `*(N)` to allow an empty match |
| An old prompt was resent in a Codex pane | the Up key recalls Codex's own input history | never send Up to a Codex pane; dialogs are answered with Enter/Escape or the option number |
| Listener showed `polling` for hours, nothing arrived | the poll command could not start and the supervisor died silently | fixed in clay (prompt `poll-error`); if it recurs, run the poll argv by hand and rearm with a new event |

Known at install (2026-11-16): all script tests pass under `/opt/homebrew/bin/python3` (202 delegator: scripts,
overlap and listener; plus the codex-rules tests). The listener tests take about 3 minutes.

When a process failure is demonstrated, repair the narrow instruction or script plus a behavioural test through a
reviewed PR; do not leave the only fix in `~/.rclick-roster/`.

---

## 9. Where state lives

| What | Where |
|---|---|
| Specs and tickets | GitHub `anzchy/RClick` issues (specs have sub-issues) |
| Glossary, ADRs, specs, audit dimensions | repo `GLOSSARY.md`, `docs/adr/`, `specs/`, `docs/agents/audit-dimensions.md` |
| Session handoff log (append every milestone and decision) | `~/.rclick-roster/handoff.md` |
| Briefs, requests, PR bodies | `~/.rclick-roster/herdr/delegator/`, `~/.rclick-roster/herdr/<agent>/` |
| Audit reports | `~/.rclick-roster/herdr/{gpt,opus}-auditor/<item>-audit-r<n>.md`, `-confirm-r<n>.md` |
| Gate summaries and logs | `~/.rclick-roster/gates/` |
| Verify records | `.build/rclick-verify/<head>.json` in the implementer's worktree (ignored by git) |
| Device runs | `~/.rclick-roster/device/<run-id>/` |
| Listener events | `~/.rclick-roster/herdr/delegator/listeners/<event>/` |
| Delegator scripts and templates | `.agents/skills/rclick-delegator/`, the `rclick-verify` skill and the `macos-device-test` skill (`.claude/skills` is a symlink to `.agents/skills`); the auditors' rules file is installed at `~/.rclick-roster/herdr/delegator/audit-brief.md` |
| Codex role rules | `.codex/rules/rclick.rules` (common, committed), `.codex/rules/rclick-role.rules` (per worktree, ignored), `scripts/codex-rules/` |

When in doubt, read the handoff log's latest entries, `gh pr list`, the ready-now query, `herdr pane list` and each
busy pane's screen before acting.

### Live herdr status schema

`herdr agent get <name>` returns `result.type = agent_info` and the named agent in `result.agent`, with `name` and
`agent_status`. Report polling validates this envelope and the exact agent name; malformed or mismatched responses
become `poll-error`, never completion. A queue receipt for `poll-error` means monitoring stopped and needs
repair/rearming, not that the task finished.
