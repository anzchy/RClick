// The summary is the preflight's only output contract: one key=value line each, ending in a single DONE.
// checkSummary re-derives the verdict from the per-step fields, so a hand-edited or truncated file is refused.
const PREFIX = 'Linux-Preflight (supplementary; GitHub required checks remain binding):';
const FACTS = ['distro', 'kernel', 'sh_target', 'node', 'git', 'python3', 'zsh', 'procps'];
const COUNTS = ['tests', 'pass', 'fail', 'skip', 'todo', 'cancelled'];
const STEP_KEYS = ['exit', 'secs', 'peak_rss_kb', ...COUNTS, 'tap_footer', 'python_tests', 'python_skip', 'python_result'];
const UNITTEST = /python3 -m unittest/;

export function mappedKind(kind) {
  return kind === 'checkout' ? 'bundle-checked' : kind === 'run' ? null : 'provision-checked';
}

export function blankSummary(head, workflow, outcome = 'NOT VERIFIED', reason = '') {
  return {
    head, workflow_sha256: workflow.workflowSha256, steps_total: workflow.steps.length,
    steps_run: 0, outcome, reason, secs: '0.0', peak_rss_kb: 'unknown',
    facts: Object.fromEntries(FACTS.map(key => [key, 'unknown'])),
    steps: workflow.steps.map(step => ({ name: step.name,
      kind: mappedKind(step.kind) ?? 'not-run',
      exit: step.kind === 'run' ? 'not-run' : '0', secs: '0.0', peak_rss_kb: 'unknown',
      tests: 0, pass: 0, fail: 0, skip: 0, todo: 0, cancelled: 0,
      tap_footer: 'not-applicable', python_tests: 0, python_skip: 0, python_result: 'unknown' })),
    failed: [],
  };
}

// Why a successful step's output does not prove what it ran, or null. Every run step must report totals:
// a complete Node TAP footer, Python unittest totals, or both; a `python3 -m unittest` command needs its totals.
export function accountingIssue(step, run) {
  if (step.tap_footer === 'partial') return `incomplete TAP footer ${step.name}`;
  if (step.tap_footer === 'complete') {
    if (Number(step.tests) === 0) return `zero Node tests ${step.name}`;
    const sum = COUNTS.slice(1).reduce((total, key) => total + Number(step[key]), 0);
    if (sum !== Number(step.tests)) return `TAP totals mismatch ${step.name}`;
  }
  const python = Number(step.python_tests) > 0 && step.python_result === 'OK';
  if (UNITTEST.test(run) && !python) return `missing Python unittest totals ${step.name}`;
  if (step.tap_footer !== 'complete' && !python) return `missing test totals ${step.name}`;
  return null;
}

export function serializeSummary(summary) {
  const lines = [
    `head=${summary.head}`, `workflow_sha256=${summary.workflow_sha256}`,
    `steps_total=${summary.steps_total}`, `steps_run=${summary.steps_run}`,
    `outcome=${summary.outcome}`,
  ];
  if (summary.reason) lines.push(`reason=${clean(summary.reason)}`);
  lines.push(`secs=${summary.secs}`, `peak_rss_kb=${summary.peak_rss_kb}`);
  for (const key of FACTS) lines.push(`${key}=${clean(summary.facts[key] ?? 'unknown')}`);
  for (const step of summary.steps) {
    const prefix = `step:${step.name}`;
    lines.push(`${prefix}=${step.kind}`);
    for (const key of STEP_KEYS) lines.push(`${prefix}:${key}=${step[key]}`);
  }
  for (const name of summary.failed) lines.push(`failed:${clean(name)}`);
  lines.push('DONE');
  return `${lines.join('\n')}\n`;
}

function clean(value) { return String(value).replace(/[\r\n]/g, ' ').trim(); }

export function checkSummary(raw, expectedHead, workflow) {
  if (!/^[a-f0-9]{40}$/.test(expectedHead)) throw Error('expected full head SHA');
  const lines = raw.split(/\r?\n/);
  if (lines.at(-1) === '') lines.pop();
  if (lines.at(-1) !== 'DONE' || lines.filter(line => line === 'DONE').length !== 1) throw Error('summary missing or duplicate DONE');
  const fields = new Map();
  const failed = [];
  for (const line of lines.slice(0, -1)) {
    if (line.startsWith('failed:')) { failed.push(line.slice(7)); continue; }
    const index = line.indexOf('=');
    if (index < 1) throw Error(`invalid summary line ${line}`);
    const key = line.slice(0, index);
    if (fields.has(key)) throw Error(`duplicate summary key ${key}`);
    fields.set(key, line.slice(index + 1));
  }
  const inventory = lines.filter(line => /^step:[^:=]+=/.test(line)).map(line => line.slice(5, line.indexOf('=')));
  if (inventory.length !== workflow.steps.length || inventory.some((name, index) => name !== workflow.steps[index].name)) throw Error('step inventory order mismatch');
  function requireField(key) { if (!fields.has(key)) throw Error(`missing ${key}`); return fields.get(key); }
  if (requireField('head') !== expectedHead) throw Error('summary head mismatch');
  if (requireField('workflow_sha256') !== workflow.workflowSha256) throw Error('workflow hash mismatch');
  if (Number(requireField('steps_total')) !== workflow.steps.length) throw Error('step inventory length mismatch');
  const outcome = requireField('outcome');
  if (!['PASS', 'FAIL', 'TIMEOUT', 'NOT VERIFIED'].includes(outcome)) throw Error('invalid outcome');
  if (outcome === 'NOT VERIFIED' && !requireField('reason')) throw Error('missing reason');
  for (const key of ['secs', 'peak_rss_kb']) validateMetric(requireField(key), key);
  for (const key of FACTS) requireField(key);
  let runCount = 0;
  let total = 0; let pass = 0; let fail = 0; let skip = 0; let todo = 0; let cancelled = 0;
  let issue = null;
  let badStep = null; let timeoutStep = null;
  for (const step of workflow.steps) {
    const prefix = `step:${step.name}`;
    const kind = requireField(prefix);
    const expectedKind = mappedKind(step.kind);
    if (expectedKind && kind !== expectedKind || !expectedKind && !['run', 'not-run'].includes(kind)) throw Error(`invalid step inventory ${step.name}`);
    const record = { name: step.name };
    for (const key of STEP_KEYS) record[key] = requireField(`${prefix}:${key}`);
    if (kind === 'run') {
      if (!/^\d+$/.test(record.exit)) throw Error(`invalid exit ${step.name}`);
      runCount++;
      if (Number(record.exit) !== 0) badStep ??= step.name;
      if ([124, 137].includes(Number(record.exit))) timeoutStep ??= step.name;
    } else if (kind === 'not-run') {
      if (record.exit !== 'not-run') throw Error(`invalid not-run exit ${step.name}`);
    } else if (record.exit !== '0') throw Error(`invalid mapped exit ${step.name}`);
    validateMetric(record.secs, `${prefix}:secs`);
    validateMetric(record.peak_rss_kb, `${prefix}:peak_rss_kb`);
    for (const key of [...COUNTS, 'python_tests', 'python_skip']) if (!/^\d+$/.test(record[key])) throw Error(`invalid ${prefix}:${key}`);
    if (!['complete', 'partial', 'absent', 'not-applicable'].includes(record.tap_footer)) throw Error(`invalid TAP footer ${step.name}`);
    if (!['OK', 'FAILED', 'unknown'].includes(record.python_result)) throw Error(`invalid python result ${step.name}`);
    if (kind === 'run' && record.exit === '0') issue ??= accountingIssue(record, step.run);
    total += Number(record.tests) + Number(record.python_tests);
    pass += Number(record.pass) + (record.python_result === 'OK' ? Number(record.python_tests) - Number(record.python_skip) : 0);
    fail += Number(record.fail);
    skip += Number(record.skip) + Number(record.python_skip);
    todo += Number(record.todo);
    cancelled += Number(record.cancelled);
  }
  if (Number(requireField('steps_run')) !== runCount) throw Error('steps_run mismatch');
  if (issue && outcome !== 'NOT VERIFIED' && outcome !== 'TIMEOUT') throw Error(issue);
  if (outcome === 'PASS' && (runCount !== workflow.steps.filter(step => step.kind === 'run').length || badStep || fail || cancelled || !total)) throw Error('inconsistent PASS');
  if (outcome === 'FAIL' && !badStep && !fail && !cancelled) throw Error('inconsistent FAIL');
  if (outcome === 'TIMEOUT' && !timeoutStep && requireField('reason') !== 'whole run deadline reached') throw Error('inconsistent TIMEOUT');
  const counts = `${pass}/${total} (${skip} skip${todo ? `, ${todo} todo` : ''})`;
  const detail = outcome === 'PASS' ? counts :
    outcome === 'NOT VERIFIED' ? clean(requireField('reason')) :
    `${outcome === 'TIMEOUT' ? timeoutStep ?? requireField('reason') : badStep ?? failed[0] ?? 'test failure'}; ${counts}`;
  return `${PREFIX} ${expectedHead.slice(0, 7)} agent-tooling ${outcome} ${detail}`;
}

function validateMetric(value, key) {
  const pattern = key.endsWith('secs') ? /^\d+(?:\.\d+)?$/ : /^(?:\d+|unknown)$/;
  if (!pattern.test(value)) throw Error(`invalid ${key}`);
}
