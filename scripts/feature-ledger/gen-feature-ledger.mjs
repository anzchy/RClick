#!/usr/bin/env node
// Generates docs/feature-metrics.md, the per-feature evidence table of RClick's feature ledger.
//
// The spine (docs/feature-ledger/feature-map.json) is the one hand-typed table: it names each feature
// and the paths, tests and specs it occupies. Every number in the output is measured from the
// repository here: code and test lines, test files and cases, last touch and commits in a window
// (git, through renames), CHANGELOG mentions, linked specs. Nothing is estimated. The qualitative
// half, docs/feature-ledger.md, is written by hand and cites these cells instead of restating them.
// After xiaolai/vmark's scripts/gen-feature-ledger.mjs, adapted to a Swift app with no coverage,
// no tokei and no settings-defaults file to join.
//
// THE HONESTY RULE: a signal nobody measured prints `--`, never `0`. `0` says "measured, none";
// `--` says "nobody looked". An absent tests/specs/changelog field in the spine is `--`; an empty
// list is a deliberate 0. A missing CHANGELOG.md makes every CHANGELOG cell `--`.
//
// FAILS CLOSED: a spine paths, tests or specs entry that matches no tracked file, a test filter
// (`file::name`) that matches no test case, or a malformed entry exits 65, names each offending
// entry and writes nothing. A table that silently drops a renamed feature looks as green as one
// that works. A git failure exits 66; a bad argument exits 64.
//
// NO ISSUE-COUNT COLUMN: Hide, Unhide, AirDrop and Common Dirs are off by default, so they draw no
// issues because nobody reaches them; a count would restate the default and read as evidence.
//
// PROVENANCE: the generator measures the working tree but names HEAD's commit, so it refuses (exit 65)
// when a tracked file differs from HEAD or the spine is untracked: the named commit must contain every
// input. The output file itself is exempt, so regenerating twice is not "dirty". `--allow-dirty` is for
// a local look; its provenance line says "plus uncommitted changes (dirty)". The committed table is
// generated from a clean commit of the inputs and committed on its own (docs/agents/feature-ledger.md).
//
// SHALLOW CLONES: a `--depth` clone's oldest commit is a grafted boundary that shows every file as
// added, so Last touch and Commits read from it are wrong, not partial. The generator does not refuse
// (code, tests, specs and CHANGELOG are still measured from the tree); it prints `--` in every history
// cell and says why in the legend, which is the honesty rule applied to history nobody can read here.
//
// REPRODUCIBLE: rows keep the spine's order, the commit window counts back from HEAD's commit date
// (not the wall clock), and the only run identifier in the body is "generated from commit <sha>".
// Node 22, ES modules, no network, no dependency beyond git.
//
// Run:   node scripts/feature-ledger/gen-feature-ledger.mjs [--root=<repo>] [--out=<file>]
//            [--spine=<file>] [--window-days=<n>] [--allow-dirty]       (default window: 90 days)
// Tests: node --test scripts/feature-ledger/*.test.mjs
// Who runs it and when: docs/agents/feature-ledger.md.
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const DEFAULT_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const SPINE_REL = "docs/feature-ledger/feature-map.json";
const OUTPUT_REL = "docs/feature-metrics.md";

const PROCESSES = new Set(["app", "extension", "shared", "ipc"]);
/** Files whose test cases the generator can find; a test entry in any other format has no case count. */
const CASE_EXTENSIONS = new Set([".swift", ".js", ".mjs", ".ts", ".py"]);
const CODE_EXTENSIONS = new Set([".swift", ".m", ".h", ".mjs", ".js", ".ts", ".py", ".sh"]);

const WINDOW_DAYS = 90;
const USAGE = "usage: node scripts/feature-ledger/gen-feature-ledger.mjs [--root=<repo>] [--out=<file>] [--spine=<file>] [--window-days=<n>] [--allow-dirty]";

function parseArgs(argv) {
  const opts = { root: DEFAULT_ROOT, out: null, spine: SPINE_REL, windowDays: WINDOW_DAYS, allowDirty: false };
  for (const a of argv) {
    if (a === "--allow-dirty") { opts.allowDirty = true; continue; }
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

/**
 * Tracked paths whose working copy differs from HEAD (staged or not), except the output file itself:
 * the generator measures the working tree, so a dirty tree is not the commit the provenance line names.
 */
function dirtyPaths(root, outRel) {
  const entries = git(root, ["-c", "core.quotePath=false", "status", "--porcelain=v1", "-z", "--untracked-files=no"]).split("\0");
  const dirty = [];
  for (let i = 0; i < entries.length; i++) {
    const e = entries[i];
    if (!e) continue;
    if (e[0] === "R" || e[0] === "C") i++; // the next entry is the rename's source
    const p = e.slice(3);
    if (p !== outRel) dirty.push(p);
  }
  return dirty.sort();
}

/** The tracked files a spine path names: the file itself, or every file under the directory. */
function expand(files, rel) {
  const clean = rel.replace(/\/+$/, "");
  return files.filter((f) => f === clean || f.startsWith(clean + "/"));
}

// THE LEXICAL SCANNER. Comments and string contents are found by one left-to-right pass per file, not
// by line prefixes: a comment can open after code, code can follow a closing `*/`, Swift block comments
// nest, and a `//` or `func test…` inside a string is neither a comment nor a declaration. The scan
// returns a mask of the text with the same length and line breaks: comment characters become spaces
// and the visible characters of a string's contents become `_`. Lines and declarations are read from
// the mask, so a commented-out test is not a test and a string spanning lines is still code.
// Swift strings follow the language: a string with N leading `#` closes on `"` plus N `#`; its escape
// introducer is `\` plus N `#` (so `\#"` in `#"…"#` is an escaped quote, and a plain `\` is a letter),
// and `\(` (`\#(` with one `#`) opens an interpolation, which is code: it is scanned like any code,
// with its own strings, comments and nested interpolations, up to the `)` that balances it.
// FAILS CLOSED: a file that ends inside a string, an interpolation or a block comment is not valid
// source, and nothing read from its mask can be trusted (one stray quote hides or invents every
// declaration after it). Such a file is UNSCANNABLE: its Code lines, Test cases and Test lines print
// `--`, a `file::name` filter on it exits 65, and the legend names it with the reason. A Swift
// single-line string that reaches the end of its line is the same error.
// Limits (stated, not hidden): JavaScript `${…}` and Python f-string braces are read as string
// contents, a non-Swift single-line string ends at its line, and regular-expression literals (JavaScript
// `/…/`, Swift `/…/` and `#/…/#`) are read as code.
const LEXERS = {
  swift: { line: "//", block: true, nest: true, swift: true },
  c: { line: "//", block: true, quotes: ['"', "'"] },
  js: { line: "//", block: true, quotes: ['"', "'"], multiline: ["`"] },
  python: { hash: "anywhere", triple: ['"""', "'''"], quotes: ['"', "'"] },
  shell: { hash: "word", quotes: ['"', "'"], raw: ["'"] },
};
const LEXER_OF = { ".swift": "swift", ".m": "c", ".h": "c", ".js": "js", ".mjs": "js", ".ts": "js", ".py": "python", ".sh": "shell" };
const lexerOf = (ext) => LEXERS[LEXER_OF[ext] ?? "c"];

/**
 * The string literal that opens at `i`, or null: its opener length, its closer, whether it may span lines,
 * its escape introducer (null when it has none) and whether that introducer followed by `(` interpolates.
 */
function stringOpener(text, i, lx) {
  if (lx.swift) {
    let h = 0;
    while (text[i + h] === "#") h++;
    const hashes = "#".repeat(h);
    const swift = { escape: "\\" + hashes, interpolates: true };
    if (text.startsWith('"""', i + h)) return { len: h + 3, close: '"""' + hashes, multiline: true, ...swift };
    if (text[i + h] === '"') return { len: h + 1, close: '"' + hashes, multiline: false, ...swift };
    return null;
  }
  const plain = (q, multiline, raw = false) => ({ len: q.length, close: q, multiline, escape: raw ? null : "\\", interpolates: false });
  for (const q of lx.triple ?? []) if (text.startsWith(q, i)) return plain(q, true);
  for (const q of lx.multiline ?? []) if (text[i] === q) return plain(q, true);
  for (const q of lx.quotes ?? []) if (text[i] === q) return plain(q, false, (lx.raw ?? []).includes(q));
  return null;
}

/**
 * The text with comments blanked to spaces and string contents filled with `_` (same length, same line
 * breaks), and `problem`: null, or why the file is unscannable (the first construct found unclosed).
 */
function scan(text, ext) {
  const lx = lexerOf(ext);
  const out = text.split("");
  const n = text.length;
  let problem = null;
  const unclosed = (at, what) => {
    problem ??= `${what} that opens on line ${text.slice(0, at).split("\n").length} does not close`;
  };
  const blank = (a, b) => { for (let k = a; k < b; k++) if (out[k] !== "\n") out[k] = " "; };
  const fill = (a, b) => { for (let k = a; k < b; k++) if (!/\s/.test(out[k])) out[k] = "_"; };

  const lineCommentAt = (i) => lx.hash
    ? text[i] === "#" && (lx.hash === "anywhere" || i === 0 || /[\s;]/.test(text[i - 1]))
    : text.startsWith(lx.line, i);

  /** Blanks the block comment that opens at `i`; returns the index after it. */
  function blockComment(i) {
    let depth = 0;
    let k = i;
    while (k < n) {
      if (text.startsWith("/*", k) && (depth === 0 || lx.nest)) { depth++; k += 2; }
      else if (text.startsWith("*/", k)) { depth--; k += 2; if (depth === 0) break; }
      else k++;
    }
    if (depth > 0) unclosed(i, "a block comment");
    blank(i, Math.min(k, n));
    return Math.min(k, n);
  }

  /** Fills the string that opens at `i`, scanning its interpolations as code; returns the index after it. */
  function string(i, open) {
    let k = i + open.len;
    let from = k; // start of the contents not filled yet
    while (k < n) {
      if (text.startsWith(open.close, k)) { fill(from, k); return k + open.close.length; }
      if (text[k] === "\n" && !open.multiline) {
        if (lx.swift) unclosed(i, "a string"); // elsewhere a single-line string ending at its line is a stated limit
        break;
      }
      if (open.escape !== null && text.startsWith(open.escape, k)) {
        const after = k + open.escape.length;
        if (open.interpolates && text[after] === "(") {
          fill(from, after + 1);
          k = code(after + 1, k);
          fill(k - 1, k); // the closing parenthesis
          from = k;
          continue;
        }
        k = after + 1; // the escaped character, whatever it is
        continue;
      }
      k++;
    }
    if (k >= n) unclosed(i, "a string");
    const end = Math.min(k, n);
    fill(from, end);
    return end;
  }

  /** Scans code from `i`; inside an interpolation (opened at `opener`), up to and including the `)` that balances it. */
  function code(i, opener = null) {
    const interpolation = opener !== null;
    let depth = 0;
    let k = i;
    while (k < n) {
      if (lineCommentAt(k)) {
        const nl = text.indexOf("\n", k);
        const end = nl === -1 ? n : nl;
        blank(k, end);
        k = end;
        continue;
      }
      if (lx.block && text.startsWith("/*", k)) { k = blockComment(k); continue; }
      const open = stringOpener(text, k, lx);
      if (open) { k = string(k, open); continue; }
      if (interpolation) {
        if (text[k] === "(") depth++;
        else if (text[k] === ")") { if (depth === 0) return k + 1; depth--; }
      }
      k++;
    }
    if (interpolation) unclosed(opener, "an interpolation");
    return n;
  }

  code(0);
  return { masked: out.join(""), problem };
}

/**
 * One file read through the scanner: per line, whether it holds code (anything neither blank nor
 * comment); its test cases; and `problem`, null or why the file is unscannable.
 */
function analyse(text, ext) {
  const { masked, problem } = scan(text, ext);
  const lines = masked.split("\n");
  return { problem, flags: lines.map((l) => l.trim() !== ""), cases: testCases(text.split("\n"), lines, ext) };
}

/** Last line of the block that opens at or after `start` (masked lines): braces for Swift and JS, indentation for Python. */
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
    for (const ch of lines[i]) {
      if (ch === "{") { depth++; opened = true; } else if (ch === "}") depth--;
    }
    if (opened && depth <= 0) return i;
  }
  return lines.length - 1;
}

/**
 * Test cases in a test file, each with the line range of its declaration and body: Swift Testing `@Test`,
 * XCTest `func test…`, Python `def test_…`, node:test `test(…)`. Declarations are read from the
 * scanner's mask, so a commented-out test or a declaration inside a string does not count.
 */
function testCases(lines, masked, ext) {
  const python = ext === ".py";
  const cases = [];
  let attribute = null; // line of a pending Swift `@Test` attribute
  for (let i = 0; i < masked.length; i++) {
    const line = masked[i];
    let name = null;
    let start = i;
    if (python) {
      const m = /^\s*(?:async\s+)?def\s+(test\w*)\s*\(/.exec(line);
      if (m) name = m[1];
    } else {
      // `@Test` may follow other attributes (`@MainActor @Test func a()`); the mask hides it in text.
      if (/(?:^|[\s)])@Test\b/.test(line)) attribute ??= i;
      const swift = /\bfunc\s+(\w+)\s*\(/.exec(line);
      const js = /^\s*(?:test|it)\(\s*(["'`])/.exec(line);
      if (swift && (attribute !== null || swift[1].startsWith("test"))) {
        name = swift[1];
        start = attribute ?? i;
      } else if (js) {
        // The name is a string, so the mask hides it: read it from the original line between the quotes.
        const open = js[0].length;
        const close = line.indexOf(js[1], open);
        name = lines[i].slice(open, close === -1 ? undefined : close);
      }
      if (swift) attribute = null;
    }
    if (name === null) continue;
    cases.push({ name, start, end: blockEnd(masked, i, python) });
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

/**
 * CHANGELOG lines (entries) that name any of the terms, case-insensitively, where the term starts a word:
 * "Hide" counts "Hides" but not "Unhide" or "Chide". Null when either side is missing.
 */
function changelogMentions(changelog, terms) {
  if (changelog === null || !Array.isArray(terms)) return UNMEASURED;
  const escape = (t) => t.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const patterns = terms.map((t) => new RegExp(`(?<![\\p{L}\\p{N}_])${escape(t)}`, "iu"));
  return changelog.split("\n").filter((l) => patterns.some((p) => p.test(l))).length;
}

/** Test files, cases and lines of a feature's test entries; a file named whole and by filter counts once. */
function measureTests(entries, files, look) {
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
  // A file with no case parser (a Markdown plan, a JSON fixture) leaves cases and lines unmeasured, not 0.
  // So does a file the scanner cannot read to the end: its declarations cannot be trusted.
  if ([...perFile.keys()].some((f) => !CASE_EXTENSIONS.has(path.extname(f)) || look(f).problem !== null)) {
    return { files: perFile.size, cases: UNMEASURED, lines: UNMEASURED };
  }
  let cases = 0;
  let lines = 0;
  for (const [f, slot] of perFile) {
    const { cases: all, flags } = look(f);
    if (slot.whole) {
      cases += all.length;
      lines += flags.filter(Boolean).length;
    } else {
      const picked = all.filter((c) => slot.filters.some((x) => c.name.toLowerCase().includes(x)));
      cases += picked.length;
      lines += picked.reduce((s, c) => s + flags.slice(c.start, c.end + 1).filter(Boolean).length, 0);
    }
  }
  return { files: perFile.size, cases, lines };
}

function measure(files, feature, changelog, ctx) {
  const look = ctx.look;
  const code = [...new Set(feature.paths.flatMap((p) => expand(files, p)))]
    .filter((f) => CODE_EXTENSIONS.has(path.extname(f)));
  const owned = [...new Set(feature.paths.flatMap((p) => expand(files, p)))];
  const dirs = feature.paths.map((p) => p.replace(/\/+$/, "")).filter((p) => !files.includes(p));
  const hits = touchingCommits(ctx.history, owned, dirs);
  const tests = Array.isArray(feature.tests) ? measureTests(feature.tests, files, look) : UNMEASURED;
  const scanned = code.map(look);
  return {
    codeFiles: code.length,
    codeLines: scanned.some((a) => a.problem !== null) ? UNMEASURED : scanned.reduce((s, a) => s + a.flags.filter(Boolean).length, 0),
    testFiles: tests === UNMEASURED ? UNMEASURED : tests.files,
    testCases: tests === UNMEASURED ? UNMEASURED : tests.cases,
    testLines: tests === UNMEASURED ? UNMEASURED : tests.lines,
    lastTouch: ctx.shallow || !hits.length ? UNMEASURED : `${hits[0].sha.slice(0, 7)} ${isoDay(hits[0].time)}`,
    commits: ctx.shallow || ctx.headTime === null ? UNMEASURED : hits.filter((c) => c.time >= ctx.headTime - ctx.windowDays * 86400).length,
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
    `Generated from commit \`${opts.headSha ?? "--"}\`${opts.dirty ? " plus uncommitted changes (dirty)" : ""} by \`scripts/feature-ledger/gen-feature-ledger.mjs\` from the spine \`${opts.spine}\`.`,
    "This is the quantitative half of the feature ledger. Every cell below is measured from the repository; nothing is typed by hand or estimated.",
    "The qualitative half, `docs/feature-ledger.md`, cites these cells and never restates them. Maintenance: `docs/agents/feature-ledger.md`.",
    "",
    "**`--` means not measured; `0` means measured and none.** A spine entry with no `tests`, `specs` or `changelog` list was never linked by anyone, so those cells print `--`. An empty list is a deliberate \"looked, found none\" and prints `0`. Without a `CHANGELOG.md` every CHANGELOG cell is `--`.",
    "",
    ...(opts.unscannable.size ? ["**These files cannot be scanned, so every Code lines, Test cases and Test lines cell that includes them prints `--`:** " +
      [...opts.unscannable].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)).map(([f, why]) => `\`${f}\` (${why})`).join("; ") +
      ". Each ends inside a string, an interpolation or a comment, so nothing read from its text can be trusted.", ""] : []),
    ...(opts.shallow ? ["**This repository is a shallow clone, so every Last touch and Commits cell prints `--`.** Its oldest commit is a grafted boundary that shows every file as added, so history read from it would be wrong, not partial. Regenerate from a full clone.", ""] : []),
    "## Columns",
    "",
    "| Column | Measured from |",
    "|---|---|",
    "| Process | the spine's `process` list (where the feature runs: `app`, `extension`, `shared`, `ipc`) |",
    "| Code files | tracked files under the feature's `paths` with a code extension (" + [...CODE_EXTENSIONS].join(" ") + ") |",
    "| Code lines | non-blank lines of those files that are not only a comment. A file listed by several features counts in each: the column is how much code a reader opens, not an ownership share |",
    "| Test files | tracked files under the feature's `tests` entries |",
    "| Test cases | Swift Testing `@Test` and XCTest `func test…` declarations, Python `def test_…`, node:test `test(…)` in those files, read past comments and strings; an entry `file::name` counts only the cases whose name contains `name`. `--` when a listed file is in another format (" + [...CASE_EXTENSIONS].join(" ") + " are parsed) |",
    "| Test lines | non-blank, non-comment lines of those test files; for a `file::name` entry, only the lines of the matched cases (declaration through closing brace, or the indented body in Python); `--` when Test cases is `--` |",
    "| Last touch | the newest commit that changed one of the feature's files, through renames (`git log -M --name-status`), with its commit date |",
    `| Commits (${w} d) | commits that changed the feature's files in the ${w} days before the generating commit's date (\`--window-days\`), through renames |`,
    "| Specs | linked spec files (every one must exist, or the generator refuses) |",
    "| CHANGELOG | lines of `CHANGELOG.md` naming one of the feature's `changelog` terms, case-insensitive, where the term starts a word (`Hide` counts `Hides`, not `Unhide`). A line counts whatever sense the word has there (`Update` also counts \"Update the settings links\"), so read the cell as an upper bound |",
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
  if (!spine || typeof spine !== "object" || !Array.isArray(spine.features)) return ["the spine has no \"features\" array"];
  const errors = [];
  const seen = new Set();
  spine.features.forEach((f, i) => {
    if (f === null || typeof f !== "object" || Array.isArray(f)) {
      errors.push(`#${i}: a feature must be an object, got ${f === null ? "null" : Array.isArray(f) ? "a list" : typeof f}`);
      return;
    }
    const id = typeof f.id === "string" && f.id !== "" ? f.id : `#${i}`;
    if (typeof f.id !== "string" || !/^[a-z0-9]+(-[a-z0-9]+)*$/.test(f.id)) errors.push(`${id}: id must be kebab-case`);
    else if (seen.has(f.id)) errors.push(`${id}: duplicate id "${f.id}"`);
    else seen.add(f.id);
    for (const k of ["name", "area"]) if (typeof f[k] !== "string" || f[k] === "") errors.push(`${id}: ${k} must be a non-empty string`);
    if (!Array.isArray(f.process) || f.process.length === 0) errors.push(`${id}: process must be a non-empty list`);
    else for (const p of f.process) if (!PROCESSES.has(p)) errors.push(`${id}: process "${p}" is not one of ${[...PROCESSES].join(", ")}`);
    if (!Array.isArray(f.paths) || f.paths.length === 0 || f.paths.some((p) => typeof p !== "string")) {
      errors.push(`${id}: paths must be a non-empty list of repo paths`);
    }
    for (const k of LIST_FIELDS) {
      if (k in f && (!Array.isArray(f[k]) || f[k].some((p) => typeof p !== "string"))) errors.push(`${id}: ${k} must be a list of strings when present`);
    }
    // An empty string would match every file, every test case or every CHANGELOG line.
    for (const k of ["paths", ...LIST_FIELDS]) {
      if (!Array.isArray(f[k])) continue;
      for (const entry of f[k]) {
        if (typeof entry !== "string") continue;
        const parts = k === "tests" ? splitTestEntry(entry) : { path: entry, filter: null };
        if (parts.path.trim() === "") errors.push(`${id}: ${k} entry ${JSON.stringify(entry)} has an empty ${k === "changelog" ? "term" : "path"}`);
        else if (parts.filter !== null && parts.filter.trim() === "") errors.push(`${id}: ${k} entry ${JSON.stringify(entry)} has an empty test filter after ::`);
      }
    }
  });
  return errors;
}

/** Stale-spine errors: a path, test or spec entry that matches no tracked file. */
function staleErrors(spine, files, look) {
  const errors = [];
  for (const f of spine.features) {
    for (const k of ["paths", "tests", "specs"]) {
      for (const entry of f[k] ?? []) {
        const { path: p, filter } = k === "tests" ? splitTestEntry(entry) : { path: entry, filter: null };
        const hits = expand(files, p);
        if (hits.length === 0) errors.push(`${f.id}: ${k} entry "${entry}" matches no tracked file`);
        else if (filter !== null) {
          // A filter on an unscannable file cannot be checked either way: refuse rather than guess.
          const unscannable = hits.filter((h) => look(h).problem !== null);
          for (const h of unscannable) errors.push(`${f.id}: ${k} entry "${entry}": ${h} cannot be scanned (${look(h).problem})`);
          if (!unscannable.length && !hits.some((h) => look(h).cases.some((c) => c.name.toLowerCase().includes(filter.toLowerCase())))) {
            errors.push(`${f.id}: ${k} entry "${entry}" matches no test case`);
          }
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
  // Every file is scanned once; an unscannable one is remembered for the legend.
  const analysed = new Map();
  opts.unscannable = new Map();
  const look = (f) => {
    if (!analysed.has(f)) {
      const a = analyse(readFileSync(path.join(opts.root, f), "utf8"), path.extname(f));
      if (a.problem !== null) opts.unscannable.set(f, a.problem);
      analysed.set(f, a);
    }
    return analysed.get(f);
  };
  const stale = staleErrors(spine, files, look);
  if (stale.length) {
    refuse(65, `${opts.spine} is stale; nothing was written. Fix the entry, do not delete the feature:`, stale);
  }
  const outRel = path.relative(opts.root, opts.out).split(path.sep).join("/");
  const dirty = attempt(66, "git cannot read the working tree status:", () => dirtyPaths(opts.root, outRel));
  const spineRel = path.relative(opts.root, path.resolve(opts.root, opts.spine)).split(path.sep).join("/");
  if (!files.includes(spineRel)) dirty.push(`${spineRel} (not tracked)`);
  if (dirty.length && !opts.allowDirty) {
    refuse(65, "The working tree has uncommitted changes to tracked inputs, so it is not the commit the output would name; nothing was written. Commit the inputs first (or pass --allow-dirty for a local look; the output then says dirty):", dirty);
  }
  opts.dirty = dirty.length > 0;
  // Only a tracked CHANGELOG is an input: an untracked one is not in the commit the output names.
  const changelog = files.includes("CHANGELOG.md") ? readFileSync(path.join(opts.root, "CHANGELOG.md"), "utf8") : null;
  const history = attempt(66, "git cannot read the history:", () => readHistory(opts.root));
  const head = history.length ? attempt(66, "git cannot resolve HEAD:", () => git(opts.root, ["log", "-1", "--format=%H %ct", "HEAD"]).trim().split(" ")) : null;
  opts.headSha = head ? head[0] : null;
  const shallow = attempt(66, "git cannot tell whether the repository is shallow:",
    () => git(opts.root, ["rev-parse", "--is-shallow-repository"]).trim() === "true");
  opts.shallow = shallow;
  const ctx = { look, history, shallow, headTime: head ? Number(head[1]) : null, windowDays: opts.windowDays };
  const rows = spine.features.map((f) => measure(files, f, changelog, ctx));
  mkdirSync(path.dirname(opts.out), { recursive: true });
  const tmp = `${opts.out}.tmp-${process.pid}`;
  writeFileSync(tmp, render(spine, rows, opts));
  renameSync(tmp, opts.out);
}

main();
