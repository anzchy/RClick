#!/usr/bin/env node
// Generates docs/feature-metrics.md, the per-feature evidence table of RClick's feature ledger.
// See docs/agents/feature-ledger.md for who runs it and when.
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const DEFAULT_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const SPINE_REL = "docs/feature-ledger/feature-map.json";
const OUTPUT_REL = "docs/feature-metrics.md";

const CODE_EXTENSIONS = new Set([".swift", ".m", ".h", ".mjs", ".js", ".ts", ".py", ".sh"]);
const HASH_COMMENT = new Set([".py", ".sh"]);

function parseArgs(argv) {
  const opts = { root: DEFAULT_ROOT, out: null, spine: SPINE_REL };
  for (const a of argv) {
    const m = /^--(root|out|spine)=(.+)$/.exec(a);
    if (!m) throw new Error(`unknown argument ${JSON.stringify(a)}`);
    opts[m[1]] = m[2];
  }
  opts.root = path.resolve(opts.root);
  opts.out = path.resolve(opts.root, opts.out ?? OUTPUT_REL);
  return opts;
}

function git(root, args) {
  return execFileSync("git", args, { cwd: root, encoding: "utf8", maxBuffer: 256 * 1024 * 1024 });
}

/** Tracked files that are present on disk, sorted. */
function trackedFiles(root) {
  return git(root, ["ls-files", "-z"]).split("\0").filter((f) => f && existsSync(path.join(root, f))).sort();
}

/** The tracked files a spine path names: the file itself, or every file under the directory. */
function expand(files, rel) {
  const clean = rel.replace(/\/+$/, "");
  return files.filter((f) => f === clean || f.startsWith(clean + "/"));
}

/** Lines that are neither blank nor only a comment. */
function codeLines(text, ext) {
  let n = 0;
  let inBlock = false;
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (inBlock) {
      if (line.includes("*/")) inBlock = false;
      continue;
    }
    if (line === "") continue;
    if (HASH_COMMENT.has(ext)) {
      if (line.startsWith("#")) continue;
    } else {
      if (line.startsWith("//")) continue;
      if (line.startsWith("/*")) {
        if (!line.includes("*/")) inBlock = true;
        continue;
      }
    }
    n++;
  }
  return n;
}

/** Test case names in a test file: Swift Testing `@Test`, XCTest `func test…`, Python `def test_…`, node:test `test(`. */
function testCases(text) {
  const names = [];
  const swift = /@Test\b(?:\([^)]*\))?[\s\S]*?\bfunc\s+(\w+)/g;
  for (const m of text.matchAll(swift)) names.push(m[1]);
  for (const m of text.matchAll(/\bfunc\s+(test\w*)\s*\(/g)) if (!names.includes(m[1])) names.push(m[1]);
  for (const m of text.matchAll(/^\s*def\s+(test\w*)\s*\(/gm)) names.push(m[1]);
  for (const m of text.matchAll(/^\s*(?:test|it)\(\s*(["'`])(.*?)\1/gm)) names.push(m[2]);
  return names;
}

function measure(root, files, feature) {
  const read = (f) => readFileSync(path.join(root, f), "utf8");
  const code = [...new Set(feature.paths.flatMap((p) => expand(files, p)))]
    .filter((f) => CODE_EXTENSIONS.has(path.extname(f)));
  const tests = [...new Set(feature.tests.flatMap((p) => expand(files, p)))];
  return {
    codeFiles: code.length,
    codeLines: code.reduce((s, f) => s + codeLines(read(f), path.extname(f)), 0),
    testFiles: tests.length,
    testCases: tests.reduce((s, f) => s + testCases(read(f)).length, 0),
  };
}

function render(spine, rows) {
  const out = ["# Feature metrics", "", "| Feature | Code files | Code lines | Test files | Test cases |", "|---|---:|---:|---:|---:|"];
  spine.features.forEach((f, i) => {
    const r = rows[i];
    out.push(`| \`${f.id}\` | ${r.codeFiles} | ${r.codeLines} | ${r.testFiles} | ${r.testCases} |`);
  });
  return out.join("\n") + "\n";
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  const spine = JSON.parse(readFileSync(path.join(opts.root, opts.spine), "utf8"));
  const files = trackedFiles(opts.root);
  const rows = spine.features.map((f) => measure(opts.root, files, f));
  mkdirSync(path.dirname(opts.out), { recursive: true });
  const tmp = `${opts.out}.tmp-${process.pid}`;
  writeFileSync(tmp, render(spine, rows));
  renameSync(tmp, opts.out);
}

main();
