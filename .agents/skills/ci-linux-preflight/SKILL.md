---
name: ci-linux-preflight
description: Run the supplementary Agent tooling Linux preflight on the shared Linux host before pushing changes to RClick's agent tooling (.agents/**, scripts/**, .codex/**, the agent-tooling workflow), or reproduce a Linux-only Agent tooling failure. Prints one supplementary PR line; GitHub checks remain binding. Not for the Xcode build, RClickTests or anything Finder-visible (those are macOS-only).
---

# Linux CI preflight

Run this before pushing a change under `.agents/**`, `scripts/**`, `.codex/**` or
`.github/workflows/agent-tooling.yml`, when GitHub's Agent tooling job fails but the Mac passes, and again after a
rebase that touches those paths. Its result is supplementary PR evidence. GitHub checks are the only binding result.

| CI job | GitHub runner | Linux preflight |
|---|---|---|
| Agent tooling (`agent-tooling.yml`: delegator scripts, Codex role rules, rclick-verify, this skill) | `ubuntu-latest` | yes. About 1 min of steps on the 2-vCPU host (56 s measured, peak RSS about 60 MB) |
| Build & Test (`pr-build.yml`) | `macos-latest` | no: `scripts/gates.sh` on the Mac covers it |
| Release (`release.yml`) | `macos-latest` | no |
| macos-device-test tests | none (Mac-only) | no: they drive screencapture, osascript, pluginkit and the desktop GUI lock |

## Run

1. Run the local tests and commit. Pass that exact head SHA:
   `.agents/skills/ci-linux-preflight/scripts/preflight.sh <full-sha> [--step-timeout s] [--deadline s]`.
   - It refuses tracked dirt unless `--allow-dirty` is passed directly to `preflight.mjs run`.
   - It tests the commit itself, as the job does with the PR head, not a merge result.
   - Run only a commit you wrote or reviewed.
2. The SSH alias defaults to `mado-ci-linux`; `RCLICK_LINUX_HOST` overrides it. Set the alias up in your own
   `~/.ssh/config`, never in the repo.
   - The host is an unprivileged account with no sudo, shared with picsee's preflight.
   - The script bundles the commit through a temporary ref, sends it with `rsync`, checks it out detached on the host
     and verifies `HEAD`.
   - `env-check.sh` stands in for checkout, setup-node, setup-python and `Install test tools`. It requires node 22,
     Python 3.10 (the workflow's version), git ≥ 2.36, zsh, procps and no passwordless sudo. The `sudo apt-get`
     command never runs.
   - Only `working-directory: pr-head` steps run, in workflow order, under `bash -e` with `env -i`, an empty temp
     `HOME`, and `PATH=/opt/node/bin:/usr/local/bin:/usr/bin:/bin`.
3. Each attempt writes an immutable private summary at `~/.rclick-roster/ci-linux/<sha>/<UTC>-summary.txt`, plus a
   private raw log and a `latest` symlink.
   - The summary holds the ordered step inventory and, per step, the exit code, duration, peak RSS (or `unknown`),
     Node TAP totals, Python unittest totals and the host versions.
   - Every run step must report totals: a complete TAP footer, `Ran N tests … OK`, or both. A step with none, or a
     `python3 -m unittest` step without its totals, is NOT VERIFIED.
   - On the host, the run takes `~/ci/.lock`, the same lock picsee uses, so the host runs one suite at a time. If the
     lock is held, the result is NOT VERIFIED `busy`: try again later.
   - It runs in a unique `~/ci/rclick-run.*` directory with a cleanup trap, a per-step timeout (default 600 s) and a
     whole-run deadline (default 1200 s). Stale-directory cleanup touches only `rclick-run.*`.
4. Check the summary: `node .agents/skills/ci-linux-preflight/scripts/preflight.mjs summary-check <summary>
   --expect-head <full-sha>`.
   - The checker rejects a missing or duplicate `DONE`, missing totals, a stale head or a changed workflow.
   - It prints the PR line only for the expected head.
5. Put the line in the PR body outside the Gates section:
   `Linux-Preflight (supplementary; GitHub required checks remain binding): <sha7> agent-tooling PASS|FAIL|TIMEOUT|NOT VERIFIED <details>`.
   Refresh or drop it on every re-push. A Linux pass never explains away a red GitHub check.

Exit codes: 0 PASS, 1 FAIL or TIMEOUT, 75 NOT VERIFIED (unreachable, transfer failure, busy, environment mismatch,
unproven totals), 2 usage or an unsupported workflow shape.

The host runs Ubuntu 22.04; `ubuntu-latest` is 24.04. Host timings are diagnostic and do not claim parity with CI.
**An unreachable or busy host gives NOT VERIFIED and never blocks a merge.**

## Keep the workflow parseable

`scripts/workflow.mjs` accepts only the shapes `agent-tooling.yml` uses now and fails closed (exit 2) on anything
else, so a workflow edit cannot silently change what the host runs.
- Steps take no `env`, `shell`, `if` or `continue-on-error`.
- `run: |` blocks are literal, with no `${{ }}` expressions.
- The checkout, setup-node and setup-python steps and `Install test tools` stay exactly as they are.

When you change the Python version or the provision commands, update `workflow.mjs`, `env-check.sh` and the tests
together (`tests/preflight.test.mjs` pins all three).

## Never

- Treat the Linux pass as binding, skip a GitHub check, or merge with `--admin` because of it.
- Add a self-hosted runner, or change CI just to suit this preflight.
- Put an IP address, a key path or a personal host path in the repo, or edit `~/.ssh/config` from a script.
- Use `StrictHostKeyChecking=no`.
- Clone from GitHub on the host; send the commit bundle.
- Run a fork PR head, or any commit you haven't written or reviewed.
- Store tokens or credentials on the host, or bind test listeners outside loopback.
- Touch picsee's `~/ci/run.*` directories or its `~/.picsee/` summaries.
