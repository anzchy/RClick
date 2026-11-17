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

// THE HONESTY RULE: a signal nobody measured is `null` and prints `--`; a measured zero is 0.
// A spine field that is ABSENT means nobody looked; an EMPTY list means someone looked and found none.
const UNMEASURED = null;

/** CHANGELOG lines (entries) that name any of the terms, case-insensitively; null when either side is missing. */
function changelogMentions(changelog, terms) {
  if (changelog === null || !Array.isArray(terms)) return UNMEASURED;
  const lower = terms.map((t) => t.toLowerCase());
  return changelog.split("\n").filter((l) => lower.some((t) => l.toLowerCase().includes(t))).length;
}

function measure(root, files, feature, changelog) {
  const read = (f) => readFileSync(path.join(root, f), "utf8");
  const code = [...new Set(feature.paths.flatMap((p) => expand(files, p)))]
    .filter((f) => CODE_EXTENSIONS.has(path.extname(f)));
  const tests = Array.isArray(feature.tests) ? [...new Set(feature.tests.flatMap((p) => expand(files, p)))] : UNMEASURED;
  return {
    codeFiles: code.length,
    codeLines: code.reduce((s, f) => s + codeLines(read(f), path.extname(f)), 0),
    testFiles: tests === UNMEASURED ? UNMEASURED : tests.length,
    testCases: tests === UNMEASURED ? UNMEASURED : tests.reduce((s, f) => s + testCases(read(f)).length, 0),
    specs: Array.isArray(feature.specs) ? feature.specs.length : UNMEASURED,
    changelog: changelogMentions(changelog, feature.changelog),
  };
}

/** A measured number, or `--` for a signal nobody measured. Never turns `--` into 0. */
const cell = (v) => (v === UNMEASURED || v === undefined ? "--" : String(v));

function render(spine, rows) {
  const out = ["# Feature metrics", "",
    "| Feature | Code files | Code lines | Test files | Test cases | Specs | CHANGELOG |",
    "|---|---:|---:|---:|---:|---:|---:|"];
  spine.features.forEach((f, i) => {
    const r = rows[i];
    const cells = [r.codeFiles, r.codeLines, r.testFiles, r.testCases, r.specs, r.changelog].map(cell);
    out.push(`| \`${f.id}\` | ${cells.join(" | ")} |`);
  });
  return out.join("\n") + "\n";
}

const PROCESSES = new Set(["app", "extension", "shared", "ipc"]);
const LIST_FIELDS = ["tests", "specs", "changelog"];

/** Shape errors: what the generator cannot measure at all. */
function shapeErrors(spine) {
  if (!spine || !Array.isArray(spine.features)) return ["the spine has no \"features\" array"];
  const errors = [];
  const seen = new Set();
  spine.features.forEach((f, i) => {
    const id = f && typeof f.id === "string" ? f.id : `#${i}`;
    if (!f || typeof f.id !== "string" || !/^[a-z0-9]+(-[a-z0-9]+)*$/.test(f.id)) errors.push(`${id}: id must be kebab-case`);
    else if (seen.has(f.id)) errors.push(`${id}: duplicate id "${f.id}"`);
    else seen.add(f.id);
    if (!f) return;
    for (const k of ["name", "area"]) if (typeof f[k] !== "string" || f[k] === "") errors.push(`${id}: ${k} must be a non-empty string`);
    if (!Array.isArray(f.process) || f.process.length === 0) errors.push(`${id}: process must be a non-empty list`);
    else for (const p of f.process) if (!PROCESSES.has(p)) errors.push(`${id}: process "${p}" is not one of ${[...PROCESSES].join(", ")}`);
    if (!Array.isArray(f.paths) || f.paths.length === 0 || f.paths.some((p) => typeof p !== "string")) {
      errors.push(`${id}: paths must be a non-empty list of repo paths`);
    }
    for (const k of LIST_FIELDS) {
      if (k in f && (!Array.isArray(f[k]) || f[k].some((p) => typeof p !== "string"))) errors.push(`${id}: ${k} must be a list of strings when present`);
    }
  });
  return errors;
}

/** Stale-spine errors: a path, test or spec entry that matches no tracked file. */
function staleErrors(spine, files) {
  const errors = [];
  for (const f of spine.features) {
    for (const k of ["paths", "tests", "specs"]) {
      for (const p of f[k] ?? []) {
        if (expand(files, p).length === 0) errors.push(`${f.id}: ${k} entry "${p}" matches no tracked file`);
      }
    }
  }
  return errors;
}

function refuse(code, headline, lines = []) {
  console.error(headline);
  for (const l of lines) console.error(`  ${l}`);
  process.exit(code);
}

function attempt(code, headline, step) {
  try {
    return step();
  } catch (err) {
    refuse(code, headline, [String(err && err.stderr ? err.stderr : err && err.message ? err.message : err).trim()]);
  }
}

function main() {
  const opts = attempt(64, "Bad invocation:", () => parseArgs(process.argv.slice(2)));
  const spine = attempt(66, `The spine ${opts.spine} is not readable JSON:`,
    () => JSON.parse(readFileSync(path.join(opts.root, opts.spine), "utf8")));
  const shape = shapeErrors(spine);
  if (shape.length) refuse(65, `${opts.spine} is malformed; nothing was written:`, shape);
  const files = attempt(66, "git cannot list the tracked files:", () => trackedFiles(opts.root));
  const stale = staleErrors(spine, files);
  if (stale.length) {
    refuse(65, `${opts.spine} is stale; nothing was written. Fix the entry, do not delete the feature:`, stale);
  }
  const changelogPath = path.join(opts.root, "CHANGELOG.md");
  const changelog = existsSync(changelogPath) ? readFileSync(changelogPath, "utf8") : null;
  const rows = spine.features.map((f) => measure(opts.root, files, f, changelog));
  mkdirSync(path.dirname(opts.out), { recursive: true });
  const tmp = `${opts.out}.tmp-${process.pid}`;
  writeFileSync(tmp, render(spine, rows));
  renameSync(tmp, opts.out);
}

main();
