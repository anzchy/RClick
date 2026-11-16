// The completion ladder shared by the evidence writer and the manual `evidence.mjs check`.
// Names match scripts/gates.sh lanes, plus `diffcheck` (`git diff --check <merge-base>..HEAD`).
export const MANDATORY_GATES = Object.freeze(['diffcheck', 'build', 'unit-tests', 'localization', 'skill-tooling']);

// A Codex sandboxed pane may be unable to run hosted XCTest (no GUI session, or the test runner never connects).
// `scripts/gates.sh --lane unit-tests` exits 70 in that case. Such a run is recorded as NOT VERIFIED with a reason;
// the delegator's owner-gates run in the desktop session is the binding result. Only exit 70 qualifies: a test
// failure (1) or any other non-zero exit stays a failure whatever the reason says.
export const NOT_VERIFIABLE = Object.freeze(['unit-tests']);
export const ENVIRONMENT_EXIT = 70;

const notVerifiedEscape = g => NOT_VERIFIABLE.includes(g.name) && g.exitCode === ENVIRONMENT_EXIT && typeof g.notVerified === 'string' && g.notVerified.trim() !== '';

export function notVerifiedGates(gates) {
  return Array.isArray(gates) ? gates.filter(g => g && notVerifiedEscape(g)) : [];
}

export function gateVerdict(gates) {
  const problems = [];
  if (!Array.isArray(gates)) return { complete: false, problems: ['missing gate list'] };
  const byName = new Map();
  for (const gate of gates) {
    if (!gate || typeof gate.name !== 'string' || !Number.isInteger(gate.exitCode)) {
      problems.push('invalid gate entry'); continue;
    }
    if (byName.has(gate.name)) problems.push(`duplicate ${gate.name}`);
    byName.set(gate.name, gate);
  }
  for (const name of MANDATORY_GATES) {
    const gate = byName.get(name);
    if (!gate) problems.push(`missing ${name}`);
    else if (gate.exitCode !== 0 && !notVerifiedEscape(gate)) problems.push(`failed ${name}: ${gate.exitCode}`);
  }
  return { complete: problems.length === 0, problems };
}
