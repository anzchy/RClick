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

const PROCESSES = new Set(["app", "extension", "shared", "ipc"]);
const CODE_EXTENSIONS = new Set([".swift", ".m", ".h", ".mjs", ".js", ".ts", ".py", ".sh"]);
const HASH_COMMENT = new Set([".py", ".sh"]);

const WINDOW_DAYS = 90;
const USAGE = "usage: node scripts/feature-ledger/gen-feature-ledger.mjs [--root=<repo>] [--out=<file>] [--spine=<file>] [--window-days=<n>]";

function parseArgs(argv) {
  const opts = { root: DEFAULT_ROOT, out: null, spine: SPINE_REL, windowDays: WINDOW_DAYS };
  for (const a of argv) {
    const m = /^--(root|out|spine|window-days)=(.+)$/.exec(a);
    if (!m) throw new Error(`unknown argument ${JSON.stringify(a)}\n${USAGE}`);
    if (m[1] === "window-days") {
      if (!/^[1-9][0-9]*$/.test(m[2])) throw new Error(`--window-days needs a positive whole number of days, got ${JSON.stringify(m[2])}\n${USAGE}`);
      opts.windowDays = Number(m[2]);
    } else opts[m[1]] = m[2];
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

const stripStrings = (line) => line.replace(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`(?:[^`\\]|\\.)*`/g, '""');

/** Last line of the block that opens at or after `start`: braces for Swift and JS, indentation for Python. */
function blockEnd(lines, start, python) {
  if (python) {
    const indent = lines[start].search(/\S/);
    let end = start;
    for (let i = start + 1; i < lines.length; i++) {
      if (lines[i].trim() === "") continue;
      if (lines[i].search(/\S/) <= indent) break;
      end = i;
    }
    return end;
  }
  let depth = 0;
  let opened = false;
  for (let i = start; i < lines.length; i++) {
    for (const ch of stripStrings(lines[i])) {
      if (ch === "{") { depth++; opened = true; } else if (ch === "}") depth--;
    }
    if (opened && depth <= 0) return i;
  }
  return lines.length - 1;
}

/**
 * Test cases in a test file, each with the line range of its declaration and body: Swift Testing `@Test`,
 * XCTest `func test…`, Python `def test_…`, node:test `test(…)`.
 */
function testCases(text, ext) {
  const lines = text.split("\n");
  const python = ext === ".py";
  const cases = [];
  let attribute = null; // line of a pending Swift `@Test` attribute
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    let name = null;
    let start = i;
    if (python) {
      const m = /^\s*(?:async\s+)?def\s+(test\w*)\s*\(/.exec(line);
      if (m) name = m[1];
    } else {
      if (/^\s*@Test\b/.test(line)) attribute ??= i;
      const swift = /\bfunc\s+(\w+)\s*\(/.exec(line);
      const js = /^\s*(?:test|it)\(\s*(["'`])(.*?)\1/.exec(line);
      if (swift && (attribute !== null || swift[1].startsWith("test"))) {
        name = swift[1];
        start = attribute ?? i;
      } else if (js) name = js[2];
      if (swift) attribute = null;
    }
    if (name === null) continue;
    const end = blockEnd(lines, i, python);
    cases.push({ name, lines: lines.slice(start, end + 1).join("\n") });
  }
  return cases;
}

/** `file::name` splits a shared test file by case name; a bare entry takes the whole file. */
function splitTestEntry(entry) {
  const at = entry.indexOf("::");
  return at === -1 ? { path: entry, filter: null } : { path: entry.slice(0, at), filter: entry.slice(at + 2) };
}

/** Every commit, newest first, with its commit time and its name-status entries (renames detected). */
function readHistory(root) {
  const raw = git(root, ["-c", "core.quotePath=false", "log", "-M", "--name-status", "--format=%x01%H %ct"]);
  const commits = [];
  for (const block of raw.split("\x01").slice(1)) {
    const [head, ...lines] = block.split("\n");
    const [sha, ct] = head.split(" ");
    const changes = lines.filter(Boolean).map((l) => {
      const [status, ...names] = l.split("\t");
      return { status: status[0], names };
    });
    commits.push({ sha, time: Number(ct), changes });
  }
  return commits;
}

/**
 * Commits that touched a feature, newest first, following renames backwards: a file the feature owns
 * today brings its earlier names along, so a rename does not reset the feature's history.
 */
function touchingCommits(history, currentFiles, dirPrefixes) {
  const names = new Set(currentFiles);
  const owns = (n) => names.has(n) || dirPrefixes.some((d) => n.startsWith(d + "/"));
  const hits = [];
  for (const c of history) {
    let touched = false;
    for (const ch of c.changes) {
      if (ch.status === "R" && ch.names.length === 2) {
        const [from, to] = ch.names;
        if (owns(to) || owns(from)) {
          touched = true;
          names.add(from);
        }
      } else if (ch.names.some(owns)) touched = true;
    }
    if (touched) hits.push(c);
  }
  return hits;
}

const isoDay = (t) => new Date(t * 1000).toISOString().slice(0, 10);

// THE HONESTY RULE: a signal nobody measured is `null` and prints `--`; a measured zero is 0.
// A spine field that is ABSENT means nobody looked; an EMPTY list means someone looked and found none.
const UNMEASURED = null;

/** CHANGELOG lines (entries) that name any of the terms, case-insensitively; null when either side is missing. */
function changelogMentions(changelog, terms) {
  if (changelog === null || !Array.isArray(terms)) return UNMEASURED;
  const lower = terms.map((t) => t.toLowerCase());
  return changelog.split("\n").filter((l) => lower.some((t) => l.toLowerCase().includes(t))).length;
}

/** Test files, cases and lines of a feature's test entries; a file named whole and by filter counts once. */
function measureTests(entries, files, read) {
  const perFile = new Map();
  for (const e of entries) {
    const { path: p, filter } = splitTestEntry(e);
    for (const f of expand(files, p)) {
      const slot = perFile.get(f) ?? { whole: false, filters: [] };
      if (filter === null) slot.whole = true;
      else slot.filters.push(filter.toLowerCase());
      perFile.set(f, slot);
    }
  }
  let cases = 0;
  let lines = 0;
  for (const [f, slot] of perFile) {
    const text = read(f);
    const ext = path.extname(f);
    const all = testCases(text, ext);
    if (slot.whole) {
      cases += all.length;
      lines += codeLines(text, ext);
    } else {
      const picked = all.filter((c) => slot.filters.some((x) => c.name.toLowerCase().includes(x)));
      cases += picked.length;
      lines += picked.reduce((s, c) => s + codeLines(c.lines, ext), 0);
    }
  }
  return { files: perFile.size, cases, lines };
}

function measure(root, files, feature, changelog, ctx) {
  const read = (f) => readFileSync(path.join(root, f), "utf8");
  const code = [...new Set(feature.paths.flatMap((p) => expand(files, p)))]
    .filter((f) => CODE_EXTENSIONS.has(path.extname(f)));
  const owned = [...new Set(feature.paths.flatMap((p) => expand(files, p)))];
  const dirs = feature.paths.map((p) => p.replace(/\/+$/, "")).filter((p) => !files.includes(p));
  const hits = touchingCommits(ctx.history, owned, dirs);
  const tests = Array.isArray(feature.tests) ? measureTests(feature.tests, files, read) : UNMEASURED;
  return {
    codeFiles: code.length,
    codeLines: code.reduce((s, f) => s + codeLines(read(f), path.extname(f)), 0),
    testFiles: tests === UNMEASURED ? UNMEASURED : tests.files,
    testCases: tests === UNMEASURED ? UNMEASURED : tests.cases,
    testLines: tests === UNMEASURED ? UNMEASURED : tests.lines,
    lastTouch: hits.length ? `${hits[0].sha.slice(0, 7)} ${isoDay(hits[0].time)}` : UNMEASURED,
    commits: ctx.headTime === null ? UNMEASURED : hits.filter((c) => c.time >= ctx.headTime - ctx.windowDays * 86400).length,
    specs: Array.isArray(feature.specs) ? feature.specs.length : UNMEASURED,
    changelog: changelogMentions(changelog, feature.changelog),
  };
}

/** A measured number, or `--` for a signal nobody measured. Never turns `--` into 0. */
const cell = (v) => (v === UNMEASURED || v === undefined ? "--" : String(v));

const escapeCell = (text) => String(text).replace(/\|/g, "\\|").replace(/\n/g, " ");

function render(spine, rows, opts) {
  const w = opts.windowDays;
  const out = [
    "<!-- GENERATED FILE. Do not edit by hand: run `node scripts/feature-ledger/gen-feature-ledger.mjs`. -->",
    "# RClick feature metrics",
    "",
    `Generated from commit \`${opts.headSha ?? "--"}\` by \`scripts/feature-ledger/gen-feature-ledger.mjs\` from the spine \`${opts.spine}\`.`,
    "This is the quantitative half of the feature ledger. Every cell below is measured from the repository; nothing is typed by hand or estimated.",
    "The qualitative half, `docs/feature-ledger.md`, cites these cells and never restates them. Maintenance: `docs/agents/feature-ledger.md`.",
    "",
    "**`--` means not measured; `0` means measured and none.** A spine entry with no `tests`, `specs` or `changelog` list was never linked by anyone, so those cells print `--`. An empty list is a deliberate \"looked, found none\" and prints `0`. Without a `CHANGELOG.md` every CHANGELOG cell is `--`.",
    "",
    "## Columns",
    "",
    "| Column | Measured from |",
    "|---|---|",
    "| Process | the spine's `process` list (where the feature runs: `app`, `extension`, `shared`, `ipc`) |",
    "| Code files | tracked files under the feature's `paths` with a code extension (" + [...CODE_EXTENSIONS].join(" ") + ") |",
    "| Code lines | non-blank lines of those files that are not only a comment. A file listed by several features counts in each: the column is how much code a reader opens, not an ownership share |",
    "| Test files | tracked files under the feature's `tests` entries |",
    "| Test cases | Swift Testing `@Test` and XCTest `func test…` declarations, Python `def test_…`, node:test `test(…)` in those files; an entry `file::name` counts only the cases whose name contains `name` |",
    "| Test lines | non-blank, non-comment lines of those test files; for a `file::name` entry, only the lines of the matched cases (declaration through closing brace, or the indented body in Python) |",
    "| Last touch | the newest commit that changed one of the feature's files, through renames (`git log -M --name-status`), with its commit date |",
    `| Commits (${w} d) | commits that changed the feature's files in the ${w} days before the generating commit's date (\`--window-days\`), through renames |`,
    "| Specs | linked spec files (every one must exist, or the generator refuses) |",
    "| CHANGELOG | lines of `CHANGELOG.md` naming one of the feature's `changelog` terms, case-insensitive |",
    "",
    "There is no issue-count column: a feature that is off by default (Hide, Unhide, AirDrop, Common Dirs) draws no issues because nobody reaches it, so a low count would restate the default and read as evidence. Issues are linked in the spine and discussed in the ledger.",
    "",
    "## Features per process",
    "",
    "| Process | Features |",
    "|---|---:|",
  ];
  for (const p of PROCESSES) out.push(`| ${p} | ${spine.features.filter((f) => f.process.includes(p)).length} |`);
  out.push("", "## Metrics", "",
    `| Feature | Name | Area | Process | Code files | Code lines | Test files | Test cases | Test lines | Last touch | Commits (${w} d) | Specs | CHANGELOG |`,
    "|---|---|---|---|---:|---:|---:|---:|---:|---|---:|---:|---:|");
  spine.features.forEach((f, i) => {
    const r = rows[i];
    const cells = [r.codeFiles, r.codeLines, r.testFiles, r.testCases, r.testLines, r.lastTouch, r.commits, r.specs, r.changelog].map(cell);
    out.push(`| \`${f.id}\` | ${escapeCell(f.name)} | ${escapeCell(f.area)} | ${f.process.join(", ")} | ${cells.join(" | ")} |`);
  });
  return out.join("\n") + "\n";
}

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
function staleErrors(spine, files, read) {
  const errors = [];
  for (const f of spine.features) {
    for (const k of ["paths", "tests", "specs"]) {
      for (const entry of f[k] ?? []) {
        const { path: p, filter } = k === "tests" ? splitTestEntry(entry) : { path: entry, filter: null };
        const hits = expand(files, p);
        if (hits.length === 0) errors.push(`${f.id}: ${k} entry "${entry}" matches no tracked file`);
        else if (filter !== null && !hits.some((h) => testCases(read(h), path.extname(h)).some((c) => c.name.toLowerCase().includes(filter.toLowerCase())))) {
          errors.push(`${f.id}: ${k} entry "${entry}" matches no test case`);
        }
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
  const stale = staleErrors(spine, files, (f) => readFileSync(path.join(opts.root, f), "utf8"));
  if (stale.length) {
    refuse(65, `${opts.spine} is stale; nothing was written. Fix the entry, do not delete the feature:`, stale);
  }
  const changelogPath = path.join(opts.root, "CHANGELOG.md");
  const changelog = existsSync(changelogPath) ? readFileSync(changelogPath, "utf8") : null;
  const history = attempt(66, "git cannot read the history:", () => readHistory(opts.root));
  const head = history.length ? attempt(66, "git cannot resolve HEAD:", () => git(opts.root, ["log", "-1", "--format=%H %ct", "HEAD"]).trim().split(" ")) : null;
  opts.headSha = head ? head[0] : null;
  const ctx = { history, headTime: head ? Number(head[1]) : null, windowDays: opts.windowDays };
  const rows = spine.features.map((f) => measure(opts.root, files, f, changelog, ctx));
  mkdirSync(path.dirname(opts.out), { recursive: true });
  const tmp = `${opts.out}.tmp-${process.pid}`;
  writeFileSync(tmp, render(spine, rows, opts));
  renameSync(tmp, opts.out);
}

main();
