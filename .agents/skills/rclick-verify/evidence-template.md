# rclick-verify evidence

`scripts/evidence.mjs render|post` builds the issue comment from a JSON input. Fill the input; don't hand-write the
comment. Input shape:

```json
{
  "issue": 12,
  "task": "i12-20261116-a",
  "branch": "feat/i12-copy-path-quoting",
  "head": "<40-char head SHA>",
  "base": "<40-char merge-base SHA>",
  "toolchain": "Xcode 26.6 (17F113) / Swift 6.2",
  "machine": "Mac mini (Apple silicon), macOS 26.x",
  "sandbox": "n/a | Codex workspace-write",
  "gates": [
    { "name": "diffcheck", "command": "git diff --check <base7>..HEAD", "exitCode": 0, "keyLine": "no output" },
    { "name": "build", "command": "scripts/gates.sh --lane build", "exitCode": 0, "keyLine": "GATE build PASS (warnings: 4; base: 4)" },
    { "name": "unit-tests", "command": "scripts/gates.sh --lane unit-tests", "exitCode": 0, "keyLine": "GATE unit-tests PASS (tests: 61 passed, 0 failed; base: 58)" },
    { "name": "localization", "command": "scripts/gates.sh --lane localization", "exitCode": 0, "keyLine": "GATE localization PASS" },
    { "name": "skill-tooling", "command": "scripts/gates.sh --lane skill-tooling", "exitCode": 0, "keyLine": "GATE skill-tooling SKIP (no tooling tests)" }
  ],
  "integrity": "Counts 58 → 61. Hits: none. RED: testCopyPathQuotesSpaces failed at <sha7> (XCTAssertEqual failed: …).",
  "byType": [
    { "behavior": "Copy Path quotes a path with spaces", "expected": "one quoted path per line", "actual": "as expected (ClipboardTests)", "result": "PASS" }
  ],
  "notVerified": ["Menu in Finder: needs a macos-device-test run (steps in the handoff)"]
}
```

A Codex pane that cannot run hosted tests records
`{ "name": "unit-tests", …, "exitCode": 70, "notVerified": "<the environment line from gates.sh>" }`.

Rendered comment (what auditors read):

```markdown
<!-- rclick-verify issue=<N> task=<task> head=<40-char SHA> -->
### rclick-verify: #<N> · `<task>` · `<branch>` @ `<sha7>`

Toolchain: …; machine: …; sandbox (Codex): …

#### Gates
- `<command>` → exit <code>; <decisive line>

#### Test integrity
<counts, every hit explained, the RED>

#### Checks by change type
| Behaviour (brief) | Expected | Seen | Result |
|---|---|---|---|

#### NOT VERIFIED
- <item>: <reason>   (or "none")
```
