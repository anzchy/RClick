// Behavioral tests for ci-linux-preflight, adapted from picsee's scripts/agents/ci-linux-preflight.test.mjs.
// Every run goes through a fake ssh/rsync/flock/timeout in a temporary HOME: no network, no real host.
import test, { describe } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, cpSync, readdirSync, readlinkSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { parseWorkflow, workflowAt, PYTHON_VERSION } from '../scripts/workflow.mjs';
import { checkSummary } from '../scripts/summary.mjs';

const root = resolve(import.meta.dirname, '../../../..');
const skill = join(root, '.agents/skills/ci-linux-preflight/scripts');
const tool = join(skill, 'preflight.mjs');
const realGit = spawnSync('/usr/bin/which', ['git'], { encoding: 'utf8' }).stdout.trim();
const realPython = spawnSync('/usr/bin/which', ['python3'], { encoding: 'utf8' }).stdout.trim();
const exec = (cmd, args, options = {}) => spawnSync(cmd, args, { encoding: 'utf8', ...options });
const run = (args, options = {}) => exec(process.execPath, [tool, ...args], options);
const runAsync = (args, options = {}) => new Promise(done => {
  const child = spawn(process.execPath, [tool, ...args], options);
  let stdout = ''; let stderr = '';
  child.stdout.on('data', data => { stdout += data; });
  child.stderr.on('data', data => { stderr += data; });
  child.on('close', status => done({ status, stdout, stderr }));
});
const footer = (tests, pass, fail = 0, skipped = 0, todo = 0, cancelled = 0) =>
  [`# tests ${tests}`, `# pass ${pass}`, `# fail ${fail}`, `# cancelled ${cancelled}`, `# skipped ${skipped}`, `# todo ${todo}`];
const tapStep = lines => `printf '%s\\n' ${lines.map(line => `'${line}'`).join(' ')} && : 'node --test'`;
const tap = `test "$CI" = true && test "$GITHUB_ACTIONS" = true && test "$LANG" = C.UTF-8 && test "$PATH" = /opt/node/bin:/usr/local/bin:/usr/bin:/bin && test -z "\${FAKE_SECRET:-}" && ${tapStep(footer(1, 1))}`;
const pythonStep = 'python3 -m unittest sample_test.py';
const SAMPLE = {
  pass: 'self.assertTrue(True)',
  fail: "self.fail('broken')",
  skip: "self.skipTest('not here')",
};

function fixture(first = pythonStep, second = tap, sample = 'pass') {
  const base = mkdtempSync(join(tmpdir(), 'rclick-preflight-'));
  const repo = join(base, 'repo');
  const hostHome = join(base, 'host');
  const bin = join(base, 'bin');
  mkdirSync(join(repo, '.github/workflows'), { recursive: true });
  mkdirSync(join(repo, '.agents/skills/ci-linux-preflight'), { recursive: true });
  mkdirSync(hostHome);
  mkdirSync(bin);
  cpSync(skill, join(repo, '.agents/skills/ci-linux-preflight/scripts'), { recursive: true });
  // The integration fixture controls the preflight result; env-check itself is tested below.
  writeFileSync(join(repo, '.agents/skills/ci-linux-preflight/scripts/env-check.sh'),
    '#!/bin/bash\nif [ "${FAKE_ENV_CHECK_FAIL:-}" = 1 ]; then echo "fixture environment mismatch" >&2; exit 1; fi\nexit 0\n');
  const workflow = [
    'jobs:', '  agent-tooling:', '    name: Agent tooling', '    runs-on: ubuntu-latest', '    steps:',
    '      - name: Checkout PR head', '        uses: actions/checkout@abc', '        with:',
    '          ref: ${{ github.event.pull_request.head.sha || github.sha }}', '          path: pr-head', '          fetch-depth: 0',
    '      - name: Set up Node', '        uses: actions/setup-node@abc', '        with:', '          node-version: 22',
    '      - name: Set up Python', '        uses: actions/setup-python@abc', '        with:', `          python-version: ${PYTHON_VERSION}`,
    '      - name: Install test tools', '        run: |', '          sudo apt-get update',
    '          sudo apt-get install --no-install-recommends -y zsh',
    '      - name: Python tests', '        working-directory: pr-head', `        run: ${first}`,
    '      - name: Node totals', '        working-directory: pr-head', `        run: ${second}`, '',
  ].join('\n');
  writeFileSync(join(repo, '.github/workflows/agent-tooling.yml'), workflow);
  writeFileSync(join(repo, 'sample_test.py'), `import unittest\nclass Sample(unittest.TestCase):\n def test_case(self):\n  ${SAMPLE[sample]}\n`);
  for (const [name, body] of Object.entries({
    node: `#!/bin/sh\nif [ "$1" = "--version" ]; then echo v22.23.5; else exec "$REAL_NODE" "$@"; fi\n`,
    git: `#!/bin/sh\nif [ "$1" = "--version" ]; then echo "git version \${FAKE_GIT_VERSION:-2.56.1}"; exit; fi\nif [ "$FAKE_REMOTE_WRONG_HEAD" = 1 ]; then case "$*" in *'rev-parse HEAD'*) printf '%040d\\n' 0; exit;; esac; fi\nexec "$REAL_GIT" "$@"\n`,
    python3: `#!/bin/sh\nif [ "$1" = "--version" ]; then echo "Python \${FAKE_PYTHON_VERSION:-3.14.10}"; else exec "$REAL_PYTHON" "$@"; fi\n`,
    zsh: `#!/bin/sh\nif [ "$1" = "--version" ]; then echo 'zsh 5.8'; else exec /bin/zsh "$@"; fi\n`,
    ps: `#!/bin/sh\nif [ "$1" = "--version" ]; then echo 'ps from procps-ng 3.3.17'; else exec /bin/ps "$@"; fi\n`,
    sudo: `#!/bin/sh\nexit 1\n`,
    flock: `#!/bin/sh\nif [ "${'$'}FAKE_BUSY" = 1 ]; then exit 1; fi\nexit 0\n`,
    timeout: `#!/usr/bin/env node\nconst {spawnSync}=require('node:child_process');const a=process.argv.slice(2);a.shift();const seconds=Number(a.shift());const cmd=a.shift();const r=spawnSync(cmd,a,{stdio:'inherit',timeout:seconds*1000});process.exit(r.error?.code==='ETIMEDOUT'?124:r.status??75);\n`,
    rsync: `#!/bin/sh\nif [ "$FAKE_RSYNC_FAIL" = 1 ]; then echo 'transfer failed' >&2; exit 1; fi\ncp "$3" "\${4#*:}"\n`,
    ssh: `#!/bin/bash\nset -o pipefail\nprintf '%s\\n' "$*" >> "$FAKE_CALLS"\ntmp=$(mktemp)\ncat > "$tmp"\ncat "$tmp" >> "$FAKE_INPUTS"\nif [ "$FAKE_SSH_FAIL" = 1 ]; then echo unreachable >&2; exit 1; fi\nif [ "$FAKE_NO_BIN_ZSH" = 1 ]; then sed 's#/bin/zsh#/missing-zsh#g' "$tmp" > "$tmp.nozsh"; mv "$tmp.nozsh" "$tmp"; fi\nfor item in "$@"; do last=$item; done\nsed "s#export PATH=/opt/node/bin:/usr/local/bin:/usr/bin:/bin#export PATH=$FAKE_BIN:/usr/local/bin:/usr/bin:/bin#g" "$tmp" | HOME="$FAKE_HOST_HOME" PATH="$FAKE_BIN:$PATH" /bin/bash -c "$last"\nstatus=$?\nrm -f "$tmp"\nexit $status\n`,
  })) writeFileSync(join(bin, name), body, { mode: 0o755 });
  for (const args of [['init', '-q'], ['config', 'user.name', 'Fixture'], ['config', 'user.email', 'fixture@example.test'], ['add', '.github/workflows/agent-tooling.yml', '.agents/skills/ci-linux-preflight/scripts', 'sample_test.py'], ['commit', '-qm', 'fixture']]) {
    const result = exec(realGit, args, { cwd: repo });
    assert.equal(result.status, 0, result.stderr);
  }
  const sha = exec(realGit, ['rev-parse', 'HEAD'], { cwd: repo }).stdout.trim();
  const calls = join(base, 'calls.txt');
  const inputs = join(base, 'inputs.txt');
  const env = { ...process.env, PATH: `${bin}:${process.env.PATH}`, HOME: base, REAL_NODE: process.execPath, REAL_GIT: realGit, REAL_PYTHON: realPython, FAKE_HOST_HOME: hostHome, FAKE_BIN: bin, FAKE_CALLS: calls, FAKE_INPUTS: inputs, RCLICK_LINUX_HOST: '' };
  return { base, repo, hostHome, bin, calls, inputs, sha, env };
}
function summaryPath(result) { return result.stdout.match(/^Summary: (.+)$/m)?.[1]; }
function runFixture(f, args = [], env = {}) { return run(['run', f.sha, '--repo', f.repo, ...args], { env: { ...f.env, ...env } }); }
function runFixtureAsync(f, args = [], env = {}) { return runAsync(['run', f.sha, '--repo', f.repo, ...args], { env: { ...f.env, ...env } }); }
function remoteAsync(f, head, args = [], { stepTimeout = 3, deadline = 5 } = {}) {
  return runAsync(['remote', f.repo, head, 'agent-tooling', workflowAt(f.repo, head).workflowSha256, String(stepTimeout), String(deadline), ...args], { env: f.env });
}
function leftoverRunDirs(f) { return readdirSync(join(f.hostHome, 'ci')).filter(name => name.startsWith('rclick-run.')); }

describe('ci-linux-preflight', { concurrency: true }, () => {
test('real Agent tooling workflow maps cleanly and rejects unsupported YAML', () => {
  const real = parseWorkflow(readFileSync(join(root, '.github/workflows/agent-tooling.yml'), 'utf8'));
  assert.deepEqual(real.steps.map(step => step.kind), ['checkout', 'setup-node', 'setup-python', 'provision', 'run', 'run', 'run']);
  assert.ok(real.steps.filter(step => step.kind === 'run').every(step => step.cwd === 'pr-head'));
  assert.ok(real.steps.some(step => /rclick-delegator\/scripts/.test(step.run ?? '')));
  assert.ok(!real.steps.some(step => /macos-device-test/.test(step.run ?? '')), 'macos-device-test tests are Mac-only');
  // env-check.sh holds the host to the same Python minor as setup-python.
  const minor = PYTHON_VERSION.replaceAll("'", '');
  assert.match(readFileSync(join(skill, 'env-check.sh'), 'utf8'), new RegExp(`'Python ${minor.replace('.', '\\.')}\\.'`));
  for (const fragment of ['env:', 'shell: bash', 'run: >', 'if: true', 'continue-on-error: true', 'timeout-minutes: 1']) {
    const source = `jobs:\n  agent-tooling:\n    steps:\n      - name: Test\n        working-directory: pr-head\n        ${fragment}\n        run: echo ok\n`;
    assert.throws(() => parseWorkflow(source), /unsupported|folded|duplicate/i, fragment);
  }
  assert.throws(() => parseWorkflow(`jobs:\n  agent-tooling:\n    steps:\n      - name: Test\n        working-directory: pr-head\n        run: echo \${{ secrets.X }}\n`), /expression/);
  const wrongPython = readFileSync(join(root, '.github/workflows/agent-tooling.yml'), 'utf8').replace("python-version: '3.14'", "python-version: '3.12'");
  assert.throws(() => parseWorkflow(wrongPython), /setup-python mapping/);
});

test('fake SSH runs the remote script, copies the bundle, records an isolated summary and cleans the run dir', async () => {
  const f = fixture();
  const result = await runFixtureAsync(f, [], { FAKE_SECRET: 'must-not-reach-step' });
  assert.equal(result.status, 0, result.stderr + result.stdout);
  const body = readFileSync(summaryPath(result), 'utf8');
  assert.match(body, new RegExp(`head=${f.sha}`));
  assert.match(body, /steps_total=6\nsteps_run=2\noutcome=PASS/);
  assert.match(body, /step:Install test tools=provision-checked/);
  assert.match(body, /step:Set up Python=provision-checked/);
  assert.match(body, /step:Node totals:tests=1/);
  assert.match(body, /step:Python tests:python_tests=1\nstep:Python tests:python_skip=0\nstep:Python tests:python_result=OK/);
  assert.match(body, /step:Python tests:tap_footer=absent/);
  assert.match(body, /python3=Python 3\.14\.10/);
  assert.match(result.stdout, /Linux-Preflight \(supplementary; GitHub required checks remain binding\): \w{7} agent-tooling PASS 2\/2 \(0 skip\)/);
  const summary = summaryPath(result);
  assert.ok(summary.startsWith(join(f.base, '.rclick-roster/ci-linux', f.sha)));
  assert.equal(readlinkSync(join(resolve(summary, '..'), 'latest')), summary.split('/').at(-1));
  assert.equal(statSync(summary.replace('-summary.txt', '-raw.log')).mode & 0o777, 0o600);
  const calls = readFileSync(f.calls, 'utf8').trim().split('\n');
  assert.ok(calls.every(call => call.includes('mado-ci-linux')));
  assert.ok(calls.every(call => ['-a', '-x', 'BatchMode=yes', 'ConnectTimeout=10', 'ServerAliveInterval=15', 'ServerAliveCountMax=4'].every(option => call.includes(option))));
  assert.ok(calls.every(call => !call.includes('StrictHostKeyChecking=no')));
  const inputs = readFileSync(f.inputs, 'utf8');
  assert.doesNotMatch(inputs, /sudo apt-get/);
  assert.match(inputs, /-name 'rclick-run\.\*'/, 'stale-dir cleanup is limited to RClick run dirs');
  assert.deepEqual(leftoverRunDirs(f), []);
  const workflowFile = join(f.repo, '.github/workflows/agent-tooling.yml');
  writeFileSync(workflowFile, readFileSync(workflowFile, 'utf8').replace(`run: ${tap}`, 'run: exit 7'));
  assert.notEqual(parseWorkflow(readFileSync(workflowFile, 'utf8')).workflowSha256, workflowAt(f.repo, f.sha).workflowSha256);
  assert.equal(runFixture(f).status, 2, 'tracked dirt must be refused before transfer');
  exec(realGit, ['add', '.github/workflows/agent-tooling.yml'], { cwd: f.repo });
  exec(realGit, ['commit', '-qm', 'edit command'], { cwd: f.repo });
  const editedHead = exec(realGit, ['rev-parse', 'HEAD'], { cwd: f.repo }).stdout.trim();
  const edited = await remoteAsync(f, editedHead);
  assert.equal(edited.status, 1, edited.stderr + edited.stdout);
  assert.match(edited.stdout, /step:Node totals:exit=7/);
  assert.match(edited.stdout, /outcome=FAIL/);
  assert.match(checkSummary(edited.stdout, editedHead, workflowAt(f.repo, editedHead)), /agent-tooling FAIL Node totals/);
});

test('Node and Python totals add up in the PR line, skips included', async () => {
  const f = fixture(pythonStep, tapStep(footer(897, 871, 0, 26)), 'skip');
  const result = await runFixtureAsync(f);
  assert.equal(result.status, 0, result.stderr + result.stdout);
  const body = readFileSync(summaryPath(result), 'utf8');
  for (const [key, value] of Object.entries({ tests: 897, pass: 871, fail: 0, skip: 26, todo: 0, cancelled: 0 })) {
    assert.match(body, new RegExp(`step:Node totals:${key}=${value}\\n`));
  }
  assert.match(body, /step:Python tests:python_skip=1\n/);
  assert.match(result.stdout, /agent-tooling PASS 871\/898 \(27 skip\)/);
  const compensated = body.replace('step:Node totals:pass=871', 'step:Node totals:pass=872');
  assert.throws(() => checkSummary(compensated, f.sha, workflowAt(f.repo, f.sha)), /TAP totals mismatch/);
  for (const key of ['skip', 'todo', 'cancelled', 'python_skip']) {
    const field = key === 'python_skip' ? 'step:Python tests:python_skip' : `step:Node totals:${key}`;
    const missingField = body.replace(new RegExp(`^${field}=.*\\n`, 'm'), '');
    assert.throws(() => checkSummary(missingField, f.sha, workflowAt(f.repo, f.sha)), new RegExp(`missing ${field}`));
  }
});

test('a partial Node footer, or a step with no totals at all, is NOT VERIFIED', async () => {
  const complete = footer(1, 1);
  for (const missing of complete) {
    const result = await runFixtureAsync(fixture(undefined, tapStep(complete.filter(line => line !== missing))));
    assert.equal(result.status, 75, `${missing}\n${result.stderr}${result.stdout}`);
    assert.match(readFileSync(summaryPath(result), 'utf8'), /outcome=NOT VERIFIED\nreason=incomplete TAP footer Node totals/);
  }
  const silent = await runFixtureAsync(fixture(undefined, "echo 'no runner output'"));
  assert.equal(silent.status, 75, silent.stderr + silent.stdout);
  assert.match(readFileSync(summaryPath(silent), 'utf8'), /reason=missing test totals Node totals/);
});

test('a unittest command without unittest totals is NOT VERIFIED even with a TAP footer', async () => {
  const f = fixture(`: python3 -m unittest && ${tapStep(footer(1, 1))}`);
  const result = await remoteAsync(f, f.sha);
  assert.equal(result.status, 75, result.stderr + result.stdout);
  assert.match(result.stdout, /outcome=NOT VERIFIED\nreason=missing Python unittest totals Python tests/);
});

test('zero Node tests are NOT VERIFIED, cancelled tests fail, and todo appears only when positive', async () => {
  const zero = await runFixtureAsync(fixture(undefined, tapStep(footer(0, 0))));
  assert.equal(zero.status, 75, zero.stderr + zero.stdout);
  assert.match(readFileSync(summaryPath(zero), 'utf8'), /reason=zero Node tests Node totals/);
  const cancelled = await runFixtureAsync(fixture(undefined, tapStep(footer(2, 1, 0, 0, 0, 1))));
  assert.equal(cancelled.status, 1, cancelled.stderr + cancelled.stdout);
  assert.match(readFileSync(summaryPath(cancelled), 'utf8'), /step:Node totals:cancelled=1/);
  assert.match(cancelled.stdout, /agent-tooling FAIL/);
  const todo = await runFixtureAsync(fixture(undefined, tapStep(footer(3, 2, 0, 0, 1))));
  assert.equal(todo.status, 0, todo.stderr + todo.stdout);
  assert.match(readFileSync(summaryPath(todo), 'utf8'), /step:Node totals:todo=1/);
  assert.match(todo.stdout, /agent-tooling PASS 3\/4 \(0 skip, 1 todo\)/);
});

test('a Python failure before Node yields FAIL, keeps the failed name, and cleans the remote directory', async () => {
  const f = fixture(undefined, undefined, 'fail');
  const result = await runFixtureAsync(f);
  assert.equal(result.status, 1, result.stderr + result.stdout);
  const body = readFileSync(summaryPath(result), 'utf8');
  assert.match(body, /outcome=FAIL/);
  assert.match(body, /step:Python tests:exit=1/);
  assert.match(body, /step:Python tests:python_result=FAILED/);
  assert.match(body, /step:Node totals=not-run/);
  assert.match(body, /failed:test_case/);
  assert.match(result.stdout, /agent-tooling FAIL Python tests/);
  assert.deepEqual(leftoverRunDirs(f), []);
});

test('ordinary nonzero exits stay FAIL across missing, partial and inconsistent TAP output', async () => {
  const cases = [
    [2, 'exit 2'],
    [42, `printf '%s\\n' 'not ok 1 - marker_failure' '# tests 1' && exit 42`, 'marker_failure'],
    [42, `${tapStep(footer(2, 1))}; exit 42`],
    [75, 'exit 75'],
    [127, 'exit 127'],
  ];
  for (const [code, second, failedName] of cases) {
    const f = fixture(undefined, second);
    // These cases classify exits, so leave headroom for a loaded host; deadlines are tested separately.
    const result = await remoteAsync(f, f.sha, [], { stepTimeout: 30, deadline: 60 });
    assert.equal(result.status, 1, `${code}: ${result.stderr}${result.stdout}`);
    assert.match(result.stdout, /outcome=FAIL/);
    assert.match(result.stdout, new RegExp(`step:Node totals:exit=${code}\\n`));
    if (failedName) assert.match(result.stdout, new RegExp(`failed:${failedName}\\n`));
    assert.match(checkSummary(result.stdout, f.sha, workflowAt(f.repo, f.sha)), /agent-tooling FAIL Node totals/);
  }
});

test('a successful step with a complete but inconsistent footer stays NOT VERIFIED', async () => {
  const result = await runFixtureAsync(fixture(undefined, tapStep(footer(2, 1))));
  assert.equal(result.status, 75, result.stderr + result.stdout);
  assert.match(readFileSync(summaryPath(result), 'utf8'), /outcome=NOT VERIFIED\nreason=TAP totals mismatch Node totals/);
});

test('remote checkout refuses a mismatched SHA before executing steps', () => {
  const f = fixture();
  const runDir = join(f.hostHome, 'ci', 'rclick-run.WRONG');
  mkdirSync(runDir, { recursive: true });
  const ref = `refs/preflight/${f.sha}`;
  exec(realGit, ['update-ref', ref, f.sha], { cwd: f.repo });
  exec(realGit, ['bundle', 'create', join(runDir, 'head.bundle'), ref], { cwd: f.repo });
  exec(realGit, ['update-ref', '-d', ref], { cwd: f.repo });
  const script = readFileSync(join(skill, 'remote-run.sh'), 'utf8')
    .replace('export PATH=/opt/node/bin:/usr/local/bin:/usr/bin:/bin', `export PATH=${f.bin}:/usr/local/bin:/usr/bin:/bin`);
  const result = exec('/bin/bash', ['-s', '--', runDir, f.sha, 'agent-tooling', workflowAt(f.repo, f.sha).workflowSha256, '2', '30'],
    { input: script, env: { ...f.env, HOME: f.hostHome, FAKE_REMOTE_WRONG_HEAD: '1' } });
  assert.equal(result.status, 75, result.stderr + result.stdout);
  assert.match(result.stderr, /checkout head mismatch/);
  assert.deepEqual(leftoverRunDirs(f), []);
});

test('unreachable host, transfer failure and a busy lock are NOT VERIFIED with exit 75 and separate attempts', async () => {
  const f = fixture();
  const unreachable = await runFixtureAsync(f, [], { FAKE_SSH_FAIL: '1' });
  assert.equal(unreachable.status, 75);
  assert.match(readFileSync(summaryPath(unreachable), 'utf8'), /outcome=NOT VERIFIED\nreason=remote setup:/);
  const transfer = await runFixtureAsync(f, [], { FAKE_RSYNC_FAIL: '1' });
  assert.equal(transfer.status, 75);
  assert.match(readFileSync(summaryPath(transfer), 'utf8'), /outcome=NOT VERIFIED\nreason=bundle transfer:/);
  const busy = await runFixtureAsync(f, [], { FAKE_BUSY: '1' });
  assert.equal(busy.status, 75, busy.stderr);
  assert.match(readFileSync(summaryPath(busy), 'utf8'), /outcome=NOT VERIFIED\nreason=busy/);
  assert.match(busy.stdout, /agent-tooling NOT VERIFIED busy/);
  assert.equal(new Set([summaryPath(unreachable), summaryPath(transfer), summaryPath(busy)]).size, 3);
});

test('step timeout is TIMEOUT; the checker refuses truncation, duplicate DONE, a wrong head and missing totals', async () => {
  const f = fixture('sleep 1.2');
  const hash = workflowAt(f.repo, f.sha).workflowSha256;
  const result = await runAsync(['remote', f.repo, f.sha, 'agent-tooling', hash, '1', '3', '--time-bin', '/nonexistent-gnu-time'], { env: f.env });
  assert.equal(result.status, 1, result.stderr + result.stdout);
  const body = result.stdout;
  assert.match(body, /outcome=TIMEOUT/);
  assert.match(body, /step:Python tests:exit=124/);
  assert.match(body, /step:Python tests:peak_rss_kb=unknown/);
  const path = join(f.base, 'summary.txt');
  writeFileSync(path, body);
  const checked = run(['summary-check', path, '--expect-head', f.sha, '--repo', f.repo]);
  assert.equal(checked.status, 0, checked.stderr);
  assert.match(checked.stdout, /agent-tooling TIMEOUT Python tests/);
  const workflow = workflowAt(f.repo, f.sha);
  const reordered = body.split('\n');
  const first = reordered.findIndex(line => line === 'step:Checkout PR head=bundle-checked');
  const second = reordered.findIndex(line => line === 'step:Set up Node=provision-checked');
  [reordered[first], reordered[second]] = [reordered[second], reordered[first]];
  for (const invalid of [body.replace(/DONE\n$/, ''), `${body}DONE\n`, body.replace(`head=${f.sha}`, `head=${'a'.repeat(40)}`), body.replace(/^step:Python tests:tests=.*\n/m, ''), body.replace('steps_total=6\n', 'steps_total=6\nsteps_total=6\n'), reordered.join('\n')]) assert.throws(() => checkSummary(invalid, f.sha, workflow));
  assert.notEqual(run(['summary-check', path, '--expect-head', 'b'.repeat(40), '--repo', f.repo]).status, 0);
});

test('the whole-run deadline bounds a step even when its step timeout is longer', async () => {
  const f = fixture('sleep 2');
  // Keep setup scheduling from exhausting the budget before the step; the child timer stays real.
  const clock = join(f.base, 'clock.cjs');
  writeFileSync(clock, 'Date.now = () => 0;\n');
  f.env.NODE_OPTIONS = `--require ${JSON.stringify(clock)}`;
  const timeout = join(f.bin, 'timeout');
  const timeoutSeconds = join(f.base, 'timeout-seconds');
  writeFileSync(timeout, readFileSync(timeout, 'utf8').replace('const r=spawnSync',
    `require('node:fs').writeFileSync(${JSON.stringify(timeoutSeconds)}, String(seconds));const r=spawnSync`));
  const result = await remoteAsync(f, f.sha, [], { stepTimeout: 30, deadline: 1 });
  assert.equal(readFileSync(timeoutSeconds, 'utf8'), '1', 'the step must run with the whole-run budget, not its 30s timeout');
  assert.equal(result.status, 1, result.stderr + result.stdout);
  assert.match(result.stdout, /outcome=TIMEOUT/);
  assert.match(result.stdout, /step:Python tests:exit=124/);
  assert.match(result.stdout, /step:Node totals=not-run/);
  assert.match(checkSummary(result.stdout, f.sha, workflowAt(f.repo, f.sha)), /agent-tooling TIMEOUT Python tests/);
});

test('environment mismatch and an unsupported workflow fail closed', async () => {
  const f = fixture();
  const check = join(skill, 'env-check.sh');
  const oldGit = exec('/bin/bash', [check], { env: { ...f.env, FAKE_GIT_VERSION: '2.34.1' } });
  assert.notEqual(oldGit.status, 0);
  assert.match(oldGit.stdout, /git.*2\.34\.1.*FAIL/);
  const newPython = exec('/bin/bash', [check], { env: { ...f.env, FAKE_PYTHON_VERSION: '3.12.3' } });
  assert.notEqual(newPython.status, 0);
  assert.match(newPython.stdout, /python3 Python 3\.12\.3 FAIL/);
  writeFileSync(join(f.bin, 'sudo'), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
  const privileged = exec('/bin/bash', [check], { env: f.env });
  assert.notEqual(privileged.status, 0);
  assert.match(privileged.stdout, /sudo passwordless FAIL/);
  const bad = fixture();
  const workflow = join(bad.repo, '.github/workflows/agent-tooling.yml');
  writeFileSync(workflow, readFileSync(workflow, 'utf8').replace('working-directory: pr-head', 'working-directory: pr-head\n        shell: bash'));
  exec(realGit, ['add', '.github/workflows/agent-tooling.yml'], { cwd: bad.repo });
  exec(realGit, ['commit', '-qm', 'unsupported'], { cwd: bad.repo });
  const head = exec(realGit, ['rev-parse', 'HEAD'], { cwd: bad.repo }).stdout.trim();
  assert.equal(run(['run', head, '--repo', bad.repo], { env: bad.env }).status, 2);
});

test('the environment check runs with bash and reports the actual mismatch', async () => {
  const f = fixture();
  const check = join(skill, 'env-check.sh');
  const syntax = exec('/bin/bash', ['-n', check]);
  assert.equal(syntax.status, 0, syntax.stderr);
  assert.doesNotMatch(readFileSync(join(skill, 'remote-run.sh'), 'utf8'), /\/bin\/zsh/);
  const healthy = exec('/bin/bash', [check], { env: f.env });
  assert.equal(healthy.status, 0, healthy.stderr + healthy.stdout);
  const withoutBinZsh = await runFixtureAsync(f, [], { FAKE_NO_BIN_ZSH: '1' });
  assert.equal(withoutBinZsh.status, 0, withoutBinZsh.stderr + withoutBinZsh.stdout);
  const failed = await runFixtureAsync(f, [], { FAKE_ENV_CHECK_FAIL: '1' });
  assert.equal(failed.status, 75, failed.stderr + failed.stdout);
  assert.match(readFileSync(summaryPath(failed), 'utf8'), /outcome=NOT VERIFIED\nreason=environment mismatch\n/);
});

test('the fake SSH outcome does not depend on passwordless sudo on the test machine', async () => {
  const f = fixture();
  writeFileSync(join(f.bin, 'sudo'), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
  const result = await runFixtureAsync(f);
  assert.equal(result.status, 0, result.stderr + result.stdout);
  assert.match(readFileSync(summaryPath(result), 'utf8'), /outcome=PASS/);
});
});
