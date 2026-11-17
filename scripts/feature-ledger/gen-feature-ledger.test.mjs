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
