# Codex worktree roles

`.codex/rules/rclick.rules` holds the shared safety restrictions. Codex prefix rules can't see which role an agent
has, or any option that comes after the remote. A ban that only checks the third token would miss
`git push origin --force`, so **direct `git push` is forbidden in every role**. The appointed delegator uses
`scripts/codex-rules/push-guard.py` instead.
- It accepts only the current topic branch and exactly one approved `origin` push URL
  (`https://github.com/anzchy/RClick.git` or `git@github.com:anzchy/RClick.git`).
- It takes an optional exact lease OID for an authorized rebase push.
- It passes the validated URL straight to Git, so extra push URLs on the remote can't become extra destinations.
- It never accepts arbitrary Git options or refspecs.

## Role overlays

Each worktree gets a local, git-ignored `.codex/rules/rclick-role.rules`. For implementors and auditors it adds PR
bans and issue-edit bans (from `restricted-role.rules`); an implementor's only GitHub write is its `rclick-verify`
evidence comment (`gh issue comment`). Auditors also get `auditor-role.rules`, which forbids `gh issue comment`,
PR comments and reviews, and `gh api`, leaving `gh issue view` to read the evidence. Their `push-guard.py` calls
fail the guard's own role check. The delegator
overlay only declares the role, so it can't override a forbidden common rule. The role marker is a workflow
guardrail, not authentication against an agent that edits its own files.

Before starting Codex in **every** new worktree:

```sh
scripts/codex-rules/install-role.py --worktree /absolute/worktree --role implementor
```

- Use `auditor` for audit worktrees.
- If you omit the role, it defaults to implementor.
- Only the appointed delegator may be given `--role delegator`, and only with the user's explicit authorization.
- A missing overlay means provisioning isn't finished; don't launch agents until it's installed.

The installer writes atomically, rejects unknown roles and symlink targets, and never changes the common rules.

## Checks

```sh
/opt/homebrew/bin/python3 -m unittest discover -s scripts/codex-rules -p 'test_*.py'
for c in 'git push origin HEAD' 'git add -A' 'git status'; do
  codex execpolicy check -r .codex/rules/rclick.rules -r scripts/codex-rules/restricted-role.rules ${=c}
done
```

- `execpolicy check` receives the commands as data and never runs them.
- The Python tests mock the final push and exercise the guard's branch, role, remote and lease checks.
- Project-local rules load only when the project's `.codex/` layer is trusted.
- Existing sessions must restart to pick up changed rules.

Confirm both of these in a restarted delegator session, without an actual remote write:
1. A direct `git push --dry-run origin HEAD` is rejected by the common rule.
2. The guard's `--dry-run` succeeds on a topic branch.

A successful guard run alone does not prove that the common rule loaded.

## Pushing

- Ordinary topic push: `scripts/codex-rules/push-guard.py`.
- After rebasing your own unmerged PR branch: read the exact current remote tip, then run
  `scripts/codex-rules/push-guard.py --expected-remote-oid <full-oid>`. Never use this on `main`.
