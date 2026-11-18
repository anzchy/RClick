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
- **Every ledger claim names its source**: a file, an issue, a PR, or the CHANGELOG section. What no source settles is
  written **UNVERIFIED**, never guessed.
- **No issue-count column**, in the table or in the ledger. Features that are off by default draw no issues, so a
  count reads as evidence when it only restates the default (see the generator's header).
- **No history in blocks.** A ledger block says what is true now. History is in `git log`. When an open finding is
  fixed, delete its line in the fixing PR.
- **Device claims cite public evidence.** A device result is cited from what `anzchy/RClick` shows: the **Device**
  section of the PR that ran it (with its head sha) or the issue the run filed. The run id may follow in parentheses
  as a pointer, "(run `i22-device-20261116e`, private record)", never a local path. A result that only a private
  record states is written **UNVERIFIED by this ledger (private record)**. Never copy content from a private record
  into the repo; post it publicly first (the PR's Device section) and cite that.

## Who updates what, and when

| When | Who | What |
|---|---|---|
| A ticket adds, changes or removes a menu item, a Settings capability or a default | the implementer, in the same PR | the spine entry (paths, tests, specs, issues, PRs, default), the ledger block and any finding it fixes or opens, then regenerate the metrics |
| A ticket only moves or renames files | the implementer, in the same PR | the spine paths; the generator refuses to run until they match |
| Before landing a PR | the delegator | run the generator on the rebased head, clean tree: a non-zero exit is a blocker. If a measured cell changed, commit the regenerated `docs/feature-metrics.md` on its own (see Provenance) |
| A `macos-device-test` run ends | the delegator | once the result is public (the PR's Device section): the **Device** line of each block the run covered (PASS or NOT VERIFIED with the reason, citing that public evidence, run id in parentheses), the "Device runs cited" table, and any finding the run found or closed |
| A full re-read of the code | whoever does it | the "Verified against" commit at the top of `docs/feature-ledger.md` |

## Commands

```bash
# Regenerate the metrics (repo root, clean tree; commit the result on its own, see Provenance)
node scripts/feature-ledger/gen-feature-ledger.mjs

# A local look at uncommitted work (the provenance line then says "dirty"; never commit that output)
node scripts/feature-ledger/gen-feature-ledger.mjs --allow-dirty --out=/tmp/feature-metrics.md

# A different commit window (default 90 days, counted back from HEAD's commit date)
node scripts/feature-ledger/gen-feature-ledger.mjs --window-days=30

# The generator's own tests (fixture git repos in a temp directory)
node --test scripts/feature-ledger/*.test.mjs
```

Exit codes: `0` written; `64` bad argument; `65` stale or malformed spine, a test filter on an unscannable file,
uncommitted changes to tracked inputs or an untracked spine (each offending entry or path is printed; nothing is
written); `66` the spine is not readable JSON or git failed. A stale-spine `65` means fix the spine entry, not delete the feature.

In a shallow clone (`git clone --depth …`, the CI checkout default) every Last touch and Commits cell prints `--` and
the table says why: the grafted boundary commit shows every file as added. Regenerate the committed table from a full
clone. CHANGELOG terms match case-insensitively where the term starts a word (`Hide` counts `Hides`, not `Unhide`),
whatever the word means on that line, so the cell is an upper bound.

A `tests` entry may name part of a shared test file: `RClickTests/ActionServiceTests.swift::delete` counts only the
test cases whose name contains `delete` (case-insensitive), and their lines. A filter that matches no case is a stale
entry.

Code lines, test cases and test lines are read past comments and string contents by one lexical scanner (header of
`gen-feature-ledger.mjs`). For Swift it follows the language: raw strings and their `\#` escapes, and interpolation
`\( … )` read as code with its own strings and comments. A file that ends inside a string, an interpolation or a block
comment is **unscannable**: its Code lines, Test cases and Test lines cells print `--`, the legend names it with the
reason, and a `file::name` filter on it exits `65`. Fix the file (it does not compile either), not the spine.

## Provenance and freshness

`docs/feature-metrics.md` is committed (owner decision on #30). Its line "Generated from commit `<sha>`" is a claim
that the table measures that commit, so:

- **Freshness: the line must name an ancestor of HEAD whose tree contains all inputs** (the spine, every measured
  path, `CHANGELOG.md`), **and the table is that commit's table byte for byte.** Check it at the named commit, never
  at HEAD: check out the commit the line names in a full clone, regenerate, and compare the whole file, provenance
  line included (pinned by a test in `gen-feature-ledger.test.mjs`).
- **The Commits column moves with the anchor commit's date.** The window counts back from the date of the commit the
  table is generated at, so regenerating at a later commit changes Commits cells even when no measured path changed
  (one unrelated commit dated months later moves every row). That is why a check at HEAD would fail on unrelated
  PRs; regenerating the committed table (next point) is a deliberate refresh, and its diff shows the window moving.
- **Generate from a clean commit of the inputs, and commit the output separately.** Commit the spine, code and
  CHANGELOG changes first; run the generator on that clean tree (it refuses a dirty one and an untracked spine); commit
  `docs/feature-metrics.md` alone in the next commit. The line then names the input commit, the output commit's
  parent. The output file itself is exempt from the dirty check, so a second run before committing is allowed.
- A freshness check (follow-up below) regenerates at the commit the line names, never at HEAD, and compares the
  whole file.

## Not wired yet (owner follow-ups)

- The generator's tests do not run in CI (`.github/workflows/agent-tooling.yml`) or in `scripts/gates.sh`
  (`skill-tooling` lane). Both need the owner's ask.
- No freshness check: nothing fails when `docs/feature-metrics.md` does not match the commit it names. The check
  would check out that commit in a full clone, regenerate, and compare the whole file byte for byte. Whether the named
  commit is recent enough is a separate rule nobody has set.
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

All 24 principles are accounted for below: 14 adopted (Foundational Thinking and Model the Domain share a row) and
10 left out (the left-out table also lists parts that are not principles).

Adopted, with the decision each one changed here:

| Principle | What it changed |
|---|---|
| Build the Lever | counts come from a script anyone can rerun, not from an agent reading files |
| Explain the Number | every column states its source and its limit (a shared file counts in each feature; the window is anchored to HEAD; a CHANGELOG cell is an upper bound; a shallow clone prints `--` for history and says why) |
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
| Laziness Protocol | the smallest thing that does the job: one dependency-free script, no CI job or gate change in this deliverable, no defaults or ownership checker until it is asked for (follow-ups below) |

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
