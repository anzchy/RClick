# Feature ledger: maintenance

RClick's feature ledger has three parts. Only one of them holds numbers, and nobody types those.

| Part | File | Written by | Holds |
|---|---|---|---|
| Spine | `docs/feature-ledger/feature-map.json` | hand | one entry per feature: id, name, area, process, how it is reached, default, paths, tests, specs, issues, PRs, CHANGELOG terms |
| Metrics | `docs/feature-metrics.md` | `scripts/feature-ledger/gen-feature-ledger.mjs` | code and test sizes, test cases, last touch, commits in a window, spec and CHANGELOG counts |
| Ledger | `docs/feature-ledger.md` | hand | what each feature does, status, default, gating, tests, device status, open findings, each with its source |

## Rules

- **Never hand-edit `docs/feature-metrics.md`.** Regenerate it. A hand edit is overwritten on the next run.
- **Never copy a number into the ledger.** Cite the cell instead: *metrics `<id>` › `<column>`*. A number in prose is
  stale after the next commit.
- **`--` is not `0`.** In the spine, leave `tests`, `specs` or `changelog` out only when nobody has looked; write `[]`
  when you looked and found none. The table prints `--` for the first and `0` for the second.
- **Every ledger claim names its source**: a file, an issue, a PR, a device run id, or the CHANGELOG section. What no
  source settles is written **UNVERIFIED**, never guessed.
- **No issue-count column**, in the table or in the ledger. Features that are off by default draw no issues, so a
  count reads as evidence when it only restates the default (see the generator's header).
- **No history in blocks.** A ledger block says what is true now. History is in `git log`. When an open finding is
  fixed, delete its line in the fixing PR.
- **Device records stay outside the repo.** Cite them by run id (`i22-device-20261116e`), never by a local path.

## Who updates what, and when

| When | Who | What |
|---|---|---|
| A ticket adds, changes or removes a menu item, a Settings capability or a default | the implementer, in the same PR | the spine entry (paths, tests, specs, issues, PRs, default), the ledger block and any finding it fixes or opens, then regenerate the metrics |
| A ticket only moves or renames files | the implementer, in the same PR | the spine paths; the generator refuses to run until they match |
| Before landing a PR | the delegator | run the generator on the rebased head: a non-zero exit is a blocker; commit the regenerated `docs/feature-metrics.md` if it changed |
| A `macos-device-test` run ends | the delegator | the **Device** line of each block the run covered (PASS with the run id, or NOT VERIFIED with the reason), the "Device runs cited" table, and any finding the run found or closed |
| A full re-read of the code | whoever does it | the "Verified against" commit at the top of `docs/feature-ledger.md` |

## Commands

```bash
# Regenerate the metrics (run from the repo root, on a clean tree; commit the result)
node scripts/feature-ledger/gen-feature-ledger.mjs

# A different commit window (default 90 days, counted back from HEAD's commit date)
node scripts/feature-ledger/gen-feature-ledger.mjs --window-days=30

# The generator's own tests (fixture git repos in a temp directory)
node --test scripts/feature-ledger/*.test.mjs
```

Exit codes: `0` written; `64` bad argument; `65` stale or malformed spine (each offending entry is printed; nothing is
written); `66` the spine is not readable JSON or git failed. A `65` means fix the spine entry, not delete the feature.

A `tests` entry may name part of a shared test file: `RClickTests/ActionServiceTests.swift::delete` counts only the
test cases whose name contains `delete` (case-insensitive), and their lines. A filter that matches no case is a stale
entry.

## Not wired yet (owner follow-ups)

- The generator's tests do not run in CI (`.github/workflows/agent-tooling.yml`) or in `scripts/gates.sh`
  (`skill-tooling` lane). Both need the owner's ask.
- No freshness check: nothing fails when `docs/feature-metrics.md` is older than the spine or the code.
- No ownership check: nothing fails when a new source file belongs to no spine entry (vmark's `lint:feature-map`
  and open-pstack's feature registry both do this).
- Defaults in the spine are text; nothing compares them with `Shared/RCBase.swift` or `RClick/AppState.swift`.

## Where the design comes from

### xiaolai/vmark (adopted, adapted)

Read: `scripts/gen-feature-ledger.mjs` and its test, `scripts/check-feature-ledger-phase.sh`,
`scripts/feature-map.json`, `.claude/feature-ledger.md`.

- **Adopted:** the split into a hand-curated spine, a generated table and a hand-inspected ledger that cites the
  table; the honesty rule (`--` is not `0`); failing closed on a stale spine; no issue-count column and the reason
  for it; atomic write; strict argument parsing with distinct exit codes; the ledger's status vocabulary,
  open-findings list ("delete the line when fixed") and "unverified in place".
- **Adapted:** history follows renames from one `git log -M --name-status`, but the window is counted back from
  HEAD's commit date (vmark uses `--since` against the wall clock), so the same commit always gives the same bytes;
  vmark's generated file is untracked, this one is committed. Test files shared by several features are split with
  `file::name`, because RClick's `ActionServiceTests` covers many features.
- **Left out:** `tokei` (code lines are counted in Node, no dependency), coverage (RClick has no coverage report),
  the baseline joins (file size, mocks, dependency-cruiser, plugin coupling: none exist here), the
  `defaults.ts` flag check (RClick's defaults are spread over Swift initialisers; a follow-up), the per-file
  ownership gate, the ledger-format gate and the phase checker (`check-feature-ledger-phase.sh` serves vmark's
  multi-phase fix plan; RClick tracks phases as tickets).

### Poteto's pstack (read through `backnotprop/pstack`, `michael-denyer/pstack-claude`, `ericlitman/open-pstack`)

`poteto/pstack` is not public. `backnotprop/pstack` mirrors it (`docs/guide/08-principles.md` lists the 24
principles; `automations/benny/.../feature-map.example.md` is its user-POV feature map); `michael-denyer/pstack-claude`
ports the same 24 `principle-*` skills to Claude Code and adds formal-verification skills; `ericlitman/open-pstack`
adds a machine-readable feature registry whose unknown paths fail closed
(`.claude/skills/verify-open-pstack/features/README.md`).

Adopted, with the decision each one changed here:

| Principle | What it changed |
|---|---|
| Build the Lever | counts come from a script anyone can rerun, not from an agent reading files |
| Explain the Number | every column states its source and its limit (a shared file counts in each feature; the window is anchored to HEAD) |
| Prove It Works | the ledger's device status is the real-Finder record; unit tests are listed separately and never stand in for it |
| Encode Lessons in Structure | the stale-spine rule is an exit code, not advice |
| Boundary Discipline | the spine is validated once at load (shape, then stale paths); the measuring code trusts it |
| Make Operations Idempotent | same commit, same bytes; the write is atomic |
| Test Behavior, Not Implementation | the tests drive the command line against fixture repositories and import nothing from the generator |
| Sequence Work into Verifiable Units | one test-first slice per commit |
| Minimize Reader Load | one block shape for every feature; numbers live in one place |
| Subtract Before You Add | blocks carry no history, and a fixed finding's line is deleted, not annotated |
| Foundational Thinking, Model the Domain | the spine's shape (id, process vocabulary, `[]` vs absent) was fixed before the generator logic |
| Never Block on the Human | the open questions took their defaults and are listed in the handoff |

From pstack's feature map example, the **user-POV "how a user gets there"** field became the ledger's *Reached*
line; its driving instructions, states and gotchas already live in `.agents/skills/macos-device-test/features/`, so
the ledger links those recipe ids instead of copying them.

Left out:

| Principle or part | Why |
|---|---|
| Exhaust the Design Space | vmark is a working precedent; competing prototypes would not change the shape |
| Redesign from First Principles, Outcome-Oriented Execution, Migrate Callers Then Delete Legacy APIs | about reshaping product code; a new docs-and-script deliverable has no legacy to migrate |
| Type System Discipline | a dependency-free Node script has no type layer; shape validation at the boundary stands in |
| Separate Before Serializing Shared State | one generator run, no concurrent writers |
| Experience First | product UX; the ledger records UX, it does not design it |
| Attack the Premise, Fix Root Causes | debugging principles; they apply to the findings when someone fixes them |
| Guard the Context Window | already how the roster works (subagents for device runs); nothing to add to the ledger |
| `poteto-mode` and its playbooks, model-routing setup | RClick's delivery flow is the herdr roster with its own skills (`rclick-delegator`, `/tdd`, `rclick-verify`); a second router would compete with it |
| pstack-claude's formal-verification skills | the ledger has no concurrent state or invariant a model checker would add to the tests |
| open-pstack's ownership registry | worth having (every changed path maps to a feature, unknown paths fail closed); left for a follow-up because it needs a CI gate |
