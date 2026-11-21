# Register a listener for every dispatch

Every implementer or auditor dispatch, including each fix, confirm, or resumed phase, needs a listener.
A resumed phase is a NEW task ID and event. Use `<task>-<round>-<MMDD>`; never recycle a generic event name.

## Dispatch completion

Use `.agents/skills/rclick-delegator/scripts/dispatch-agent.sh` from the delegator:

```sh
.agents/skills/rclick-delegator/scripts/dispatch-agent.sh \
  --agent gpt-imple --pane <current-agent-pane> --role implementer --kind codex \
  --issue <issue> --task <new-task-id> --round <round> --prompt-file <absolute-prompt-file> \
  --worktree <absolute-agent-worktree> --branch <branch> --handoff <absolute-handoff-file>
```

For auditors use `--role auditor --report <absolute-report-file>` instead of `--worktree`, `--branch`,
and `--handoff`. Set `--kind claude|codex` for the actual agent. All named flags are required for their role.
All path arguments must be absolute and exist: prepare a new empty output file before dispatch. Prompts are
read literally from the file. The implementer's worktree must be its pane home.

The helper resolves the Claude `rclick-delegator` title, pane, terminal, and cwd from the current
`herdr pane list`; it refuses a missing or ambiguous delegator, a non-idle target, and any existing event
directory. It writes the implementer target marker, registers the listener, then resets and submits the prompt.
Only `DISPATCHED <event>` completes dispatch. The listener is registered before submission so a fast task cannot
finish before registration. Any manual dispatch must register its listener immediately after dispatch.

Claude reset uses `/clear` and requires `Context 0%`; Codex uses `reset.sh`, which handles `/new` and the
current-worktree chooser and proves a fresh session. A NEW Codex session must actually show `Working` after
submission. The helper checks both kinds for `Working`, allows at most three Enter attempts (ten reads each),
and fails with the pane tail if submission never starts. A failed dispatch requests listener stop if the start
created state; inspect any cleanup failure before another dispatch.

## Manual listener arguments and recovery

Let `SK=.agents/skills/rclick-delegator`, `E=<task>-<round>-<MMDD>`, `T=<new-task-id>`, `A=<agent-name>`,
`AP=<current-agent-pane>`, and `H=<absolute-output-file>`. Use one route and one role below. Read current
`herdr pane list` for the Claude destination `DP`, `DT`, `DCWD`; never reuse cached pane/terminal values.
For a Codex delegator, `THREAD` is its exact thread UUID, not the dispatched agent's session.

Claude delegator route, implementer:

```sh
node .agents/skills/rclick-verify/scripts/mark-target.mjs "$WT" "$WT" "$ISSUE" "$T" "$H" "$BRANCH"
"$SK/scripts/listen-notify.py" start --new --event "$E" --task "$T" \
  --route claude-pane --pane "$DP" --terminal-id "$DT" --cwd "$DCWD" \
  --agent "$A" --agent-pane "$AP" --handoff "$H" --handoff-marker "$T" \
  --poll handoff --interval 60 --idle-grace-seconds 3600 --max-minutes 3000
```

Claude delegator route, auditor:

```sh
"$SK/scripts/listen-notify.py" start --new --event "$E" --task "$T" \
  --route claude-pane --pane "$DP" --terminal-id "$DT" --cwd "$DCWD" \
  --agent "$A" --agent-pane "$AP" --handoff "$H" --handoff-marker "$T" \
  --poll report --interval 60 --idle-grace-seconds 3600 --max-minutes 3000
```

Codex delegator route, implementer (write the same target marker first):

```sh
"$SK/scripts/listen-notify.py" start --new --event "$E" --task "$T" \
  --route codex-thread --thread "$THREAD" \
  --agent "$A" --agent-pane "$AP" --handoff "$H" --handoff-marker "$T" \
  --poll handoff --interval 60 --idle-grace-seconds 3600 --max-minutes 3000
```

Codex delegator route, auditor:

```sh
"$SK/scripts/listen-notify.py" start --new --event "$E" --task "$T" \
  --route codex-thread --thread "$THREAD" \
  --agent "$A" --agent-pane "$AP" --handoff "$H" --handoff-marker "$T" \
  --poll report --interval 60 --idle-grace-seconds 3600 --max-minutes 3000
```

A new start must exit zero AND print `started`; otherwise treat registration as failed. `--new` refuses any
existing event directory atomically against other CLI starts. Omitting `--new` is only for recovery of the SAME
dispatch's deferred notification with identical arguments and pinned source identity; it may print
`already-running` or `already-delivered`. It does not dispatch a resumed phase. Use
`listen-notify.py stop --event "$E"` to abort: `stopped`/`delivered` exit zero; `uncertain` exits 3 and
`running` exits 1. A failed cleanup needs inspection, not another blind dispatch.

## Notification is not evidence

A Claude destination receives `: RCLICK_LISTENER_EVENT_<event>`; read the full `notification.txt` under
`~/.rclick-roster/herdr/delegator/listeners/<event>/`. A Codex destination receives the full queued notice.
Before proceeding, open the expected file and check its task marker, freshness, and current SHA. Require the
handoff's `Report-Task: <task>` line; for an audit require exactly one matching `Report-Task:` line AND inspect
its `COUNT` line and findings before deciding. Handoff polling only tests the marker substring plus idle/done;
report polling checks freshness and exactly one matching identity plus idle/done. Neither validates audit counts
or accepts an audit. Blocked, idle-without-report, timeout, and poll-error events also need inspection.

## Background commands and batch cleanup

Long commands run in the harness with `run_in_background` and its completion notification, without `nohup` or
`&`. If monitoring a gate summary instead, use an until-loop Monitor that waits for the summary's `DONE` line.
Monitors expire after 30 minutes: renew the Monitor or inspect the summary then. These are harness operations,
not features of `listen-notify.py`; a shell launcher exiting is not evidence that the gates finished.

End every batch with `listen-notify.py status`. It lists undelivered events; `attention` / exit 3 requires
inspection, including a `polling` event with `worker=stopped` or a parked `deferred-user-typing` notice.
Resolve uncertain delivery and cleanup errors first. After inspecting a stale entry and ensuring its worker has
ended, run `listen-notify.py archive --event "$E"`. It MOVES the entire entry to
`~/.rclick-roster/herdr/delegator/listeners-archive-<UTC-YYYYMMDD>/`, preserving evidence. It refuses a running
worker, unresolved poll cleanup, or a destination collision. Never delete listener directories.
