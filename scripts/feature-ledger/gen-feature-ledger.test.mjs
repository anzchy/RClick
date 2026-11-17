// Tests for the feature-ledger generator, through its only public seam: the command line.
//
// Each test builds a tiny git repository in a temporary directory (a spine, a few source files,
// a test file, a CHANGELOG), runs `gen-feature-ledger.mjs --root=<fixture> --out=<file>`, and
// reads the Markdown table it wrote. Nothing here imports a helper from the generator.
//
// Run: node --test scripts/feature-ledger/*.test.mjs

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync, execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync, renameSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const GENERATOR = path.join(path.dirname(fileURLToPath(import.meta.url)), "gen-feature-ledger.mjs");

// Fixed dates so the fixture history, and so the output, is the same on every machine.
const DAY = 86400;
const T0 = 1_700_000_000; // 2023-11-14T22:13:20Z

function git(root, args, when) {
  const env = { ...process.env, GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_SYSTEM: "/dev/null" };
  if (when !== undefined) {
    env.GIT_AUTHOR_DATE = `@${when} +0000`;
    env.GIT_COMMITTER_DATE = `@${when} +0000`;
  }
  return execFileSync("git", ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
    "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main", ...args], { cwd: root, env, encoding: "utf8" }).trim();
}

function put(root, rel, text) {
  const p = path.join(root, rel);
  mkdirSync(path.dirname(p), { recursive: true });
  writeFileSync(p, text);
}

function commitAll(root, message, when) {
  git(root, ["add", "-A"]);
  git(root, ["commit", "-q", "-m", message], when);
}

const SPINE_REL = "docs/feature-ledger/feature-map.json";

function writeSpine(root, features) {
  put(root, SPINE_REL, JSON.stringify({ features }, null, 2) + "\n");
}

/** A fresh fixture repository with one commit. Returns its root. */
function fixture(files, features, when = T0) {
  const root = mkdtempSync(path.join(tmpdir(), "feature-ledger-"));
  git(root, ["init", "-q"]);
  for (const [rel, text] of Object.entries(files)) put(root, rel, text);
  writeSpine(root, features);
  commitAll(root, "fixture", when);
  return root;
}

function generate(root, extra = []) {
  const out = path.join(root, "out", "feature-metrics.md");
  const r = spawnSync(process.execPath, [GENERATOR, `--root=${root}`, `--out=${out}`, ...extra], { encoding: "utf8" });
  return { status: r.status, stdout: r.stdout, stderr: r.stderr, out, text: existsSync(out) ? readFileSync(out, "utf8") : null };
}

/** The cells of the metrics table, keyed by column header, for the row whose first cell is `id`. */
function row(text, id) {
  const lines = text.split("\n");
  const headerAt = lines.findIndex((l) => /^\| Feature \|/.test(l));
  assert.notEqual(headerAt, -1, `no metrics table in:\n${text}`);
  const cells = (l) => l.split("|").slice(1, -1).map((c) => c.trim());
  const header = cells(lines[headerAt]);
  const hit = lines.slice(headerAt + 2).find((l) => l.startsWith("|") && cells(l)[0] === `\`${id}\``);
  assert.ok(hit, `no row for ${id} in:\n${text}`);
  return Object.fromEntries(cells(hit).map((c, i) => [header[i], c]));
}

const SWIFT_SOURCE = [
  "// A header comment that is not code",
  "import Foundation",
  "",
  "/* a block comment",
  "   still a comment */",
  "struct Copier {",
  "    func copy() {}",
  "}",
  "",
].join("\n");

const SWIFT_TESTS = [
  "import Testing",
  "",
  "struct CopierTests {",
  "    @Test func copiesOnePath() {",
  "        #expect(true)",
  "    }",
  "",
  "    @Test(arguments: [1, 2]) func copiesManyPaths(n: Int) {",
  "        #expect(n > 0)",
  "    }",
  "}",
  "",
].join("\n");

test("a measured feature reports its code lines and test cases", () => {
  const root = fixture(
    { "App/Copier.swift": SWIFT_SOURCE, "AppTests/CopierTests.swift": SWIFT_TESTS },
    [{ id: "copy", name: "Copy", area: "Menu", process: ["app"], paths: ["App/Copier.swift"],
      tests: ["AppTests/CopierTests.swift"], specs: [], changelog: [] }],
  );
  const r = generate(root);
  assert.equal(r.status, 0, r.stderr);
  const cells = row(r.text, "copy");
  assert.equal(cells["Code files"], "1");
  assert.equal(cells["Code lines"], "4"); // import, struct, func, closing brace
  assert.equal(cells["Test files"], "1");
  assert.equal(cells["Test cases"], "2");
  rmSync(root, { recursive: true, force: true });
});

test("an unmeasured signal prints -- and a measured zero prints 0", () => {
  const root = fixture(
    { "App/Copier.swift": SWIFT_SOURCE, "App/Hider.swift": SWIFT_SOURCE, "CHANGELOG.md": "# Changelog\n- Added Copy\n" },
    [
      // Inspected: no tests exist, no spec exists, the CHANGELOG term matches nothing.
      { id: "inspected", name: "Inspected", area: "Menu", process: ["app"], paths: ["App/Copier.swift"],
        tests: [], specs: [], changelog: ["Paste"] },
      // Nobody linked tests, specs or CHANGELOG terms: those signals were not measured.
      { id: "unlooked", name: "Unlooked", area: "Menu", process: ["app"], paths: ["App/Hider.swift"] },
    ],
  );
  const r = generate(root);
  assert.equal(r.status, 0, r.stderr);
  const inspected = row(r.text, "inspected");
  const unlooked = row(r.text, "unlooked");
  for (const col of ["Test files", "Test cases", "Specs", "CHANGELOG"]) {
    assert.equal(inspected[col], "0", `${col} of an inspected feature`);
    assert.equal(unlooked[col], "--", `${col} of an unlooked feature`);
    assert.notEqual(unlooked[col], "0", `${col}: -- must never collapse to 0`);
  }
  rmSync(root, { recursive: true, force: true });
});

test("a missing CHANGELOG makes every CHANGELOG cell --, never 0", () => {
  const root = fixture(
    { "App/Copier.swift": SWIFT_SOURCE },
    [{ id: "copy", name: "Copy", area: "Menu", process: ["app"], paths: ["App/Copier.swift"],
      tests: [], specs: [], changelog: ["Copy"] }],
  );
  const r = generate(root);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(row(r.text, "copy")["CHANGELOG"], "--");
  rmSync(root, { recursive: true, force: true });
});

test("a spine path that matches nothing fails closed and names the entry", () => {
  const root = fixture(
    { "App/Copier.swift": SWIFT_SOURCE, "AppTests/CopierTests.swift": SWIFT_TESTS },
    [
      { id: "copy", name: "Copy", area: "Menu", process: ["app"], paths: ["App/Copier.swift"],
        tests: ["AppTests/CopierTests.swift"], specs: [] },
      { id: "moved", name: "Moved", area: "Menu", process: ["app"], paths: ["App/Gone.swift"],
        tests: ["AppTests/GoneTests.swift"], specs: ["specs/gone.md"] },
    ],
  );
  const r = generate(root);
  assert.notEqual(r.status, 0, "a stale spine must not exit 0");
  assert.equal(r.status, 65);
  for (const stale of ["App/Gone.swift", "AppTests/GoneTests.swift", "specs/gone.md"]) {
    assert.match(r.stderr, new RegExp(`moved.*${stale.replace(/\./g, "\\.")}`), `stderr names ${stale}`);
  }
  assert.doesNotMatch(r.stderr, /App\/Copier\.swift/, "a live path is not reported");
  assert.equal(r.text, null, "nothing is written from a stale spine");
  rmSync(root, { recursive: true, force: true });
});

test("a file renamed away from its spine path makes the spine stale", () => {
  const root = fixture(
    { "App/Copier.swift": SWIFT_SOURCE },
    [{ id: "copy", name: "Copy", area: "Menu", process: ["app"], paths: ["App/Copier.swift"] }],
  );
  assert.equal(generate(root).status, 0);
  git(root, ["mv", "App/Copier.swift", "App/PathCopier.swift"]);
  git(root, ["commit", "-q", "-m", "rename"], T0 + DAY);
  const r = generate(root);
  assert.equal(r.status, 65);
  assert.match(r.stderr, /copy.*App\/Copier\.swift/);
  rmSync(root, { recursive: true, force: true });
});

test("a malformed spine entry is refused", () => {
  const root = fixture(
    { "App/Copier.swift": SWIFT_SOURCE },
    [
      { id: "copy", name: "Copy", area: "Menu", process: ["app"], paths: ["App/Copier.swift"] },
      { id: "copy", name: "Twin", area: "Menu", process: ["daemon"], paths: [] },
    ],
  );
  const r = generate(root);
  assert.equal(r.status, 65);
  assert.match(r.stderr, /duplicate id "copy"/);
  assert.match(r.stderr, /process "daemon"/);
  assert.match(r.stderr, /paths/);
  rmSync(root, { recursive: true, force: true });
});

test("history follows renames: last touch and commits in the window", () => {
  const root = fixture(
    { "App/Copier.swift": SWIFT_SOURCE, "App/Other.swift": SWIFT_SOURCE },
    [{ id: "copy", name: "Copy", area: "Menu", process: ["app"], paths: ["App/PathCopier.swift"] }],
    T0, // created (the spine names the post-rename path, so add the spine after the rename below)
  );
  put(root, "App/Copier.swift", SWIFT_SOURCE + "// edit 1\n");
  commitAll(root, "edit before the rename", T0 + 10 * DAY);
  git(root, ["mv", "App/Copier.swift", "App/PathCopier.swift"]);
  commitAll(root, "rename", T0 + 20 * DAY);
  put(root, "App/Other.swift", SWIFT_SOURCE + "// unrelated\n");
  commitAll(root, "unrelated", T0 + 150 * DAY);
  put(root, "App/PathCopier.swift", SWIFT_SOURCE + "// edit 2\n");
  commitAll(root, "edit after the rename", T0 + 200 * DAY);
  const head = git(root, ["rev-parse", "--short=7", "HEAD"]);

  const wide = generate(root, ["--window-days=365"]);
  assert.equal(wide.status, 0, wide.stderr);
  const w = row(wide.text, "copy");
  assert.equal(w["Commits (365 d)"], "4"); // create, edit 1, rename, edit 2; not the unrelated commit
  assert.equal(w["Last touch"], `${head} 2024-06-01`);

  const narrow = generate(root); // default window: 90 days before HEAD's commit date
  assert.equal(narrow.status, 0, narrow.stderr);
  assert.equal(row(narrow.text, "copy")["Commits (90 d)"], "1");
  rmSync(root, { recursive: true, force: true });
});

test("a bad --window-days is a usage error", () => {
  const root = fixture({ "App/Copier.swift": SWIFT_SOURCE },
    [{ id: "copy", name: "Copy", area: "Menu", process: ["app"], paths: ["App/Copier.swift"] }]);
  const r = generate(root, ["--window-days=soon"]);
  assert.equal(r.status, 64);
  assert.equal(r.text, null);
  rmSync(root, { recursive: true, force: true });
});

test("the output is reproducible: same commit, same bytes, and only the commit identifies the run", () => {
  const root = fixture(
    { "App/Copier.swift": SWIFT_SOURCE, "App/Hider.swift": SWIFT_SOURCE, "AppTests/CopierTests.swift": SWIFT_TESTS },
    [
      { id: "hide", name: "Hide", area: "Menu", process: ["app"], paths: ["App/Hider.swift"] },
      { id: "copy", name: "Copy", area: "Menu", process: ["extension", "shared"], paths: ["App"],
        tests: ["AppTests/CopierTests.swift"] },
    ],
  );
  const sha = git(root, ["rev-parse", "HEAD"]);
  const first = generate(root);
  assert.equal(first.status, 0, first.stderr);
  renameSync(first.out, first.out + ".first");
  const second = generate(root);
  assert.equal(second.status, 0, second.stderr);
  assert.equal(second.text, readFileSync(first.out + ".first", "utf8"), "two runs differ");
  assert.match(second.text, new RegExp(`generated from commit \`${sha}\``, "i"));
  assert.doesNotMatch(second.text, /\d{2}:\d{2}:\d{2}/, "no wall-clock time in the body");
  assert.doesNotMatch(second.text, new RegExp(new Date().toISOString().slice(0, 10)), "no run date in the body");
  // Rows keep the spine's order, and carry the spine's process.
  assert.ok(second.text.indexOf("`hide`") < second.text.indexOf("`copy`"), "rows follow the spine order");
  assert.equal(row(second.text, "copy")["Process"], "extension, shared");
  rmSync(root, { recursive: true, force: true });
});
