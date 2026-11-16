import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';

// The workflow and job the preflight mirrors. Only the shapes below are accepted; anything else fails closed (exit 2),
// so a workflow edit cannot silently change what the host runs.
export const WORKFLOW_PATH = '.github/workflows/agent-tooling.yml';
export const DEFAULT_JOB = 'agent-tooling';
export const CHECKOUT_REF = '${{ github.event.pull_request.head.sha || github.sha }}';
export const NODE_VERSION = '22';
export const PYTHON_VERSION = "'3.10'";
export const PROVISION_STEP = 'Install test tools';
export const PROVISION_COMMANDS = ['sudo apt-get update', 'sudo apt-get install --no-install-recommends -y zsh'];

export class WorkflowError extends Error {
  constructor(message) { super(message); this.exitCode = 2; }
}

export function parseWorkflow(source, job = DEFAULT_JOB) {
  if (!/^[A-Za-z0-9_-]+$/.test(job)) throw new WorkflowError('invalid job name');
  const lines = source.split(/\r?\n/);
  const start = lines.findIndex(line => line === `  ${job}:`);
  if (start < 0 || lines.indexOf(`  ${job}:`, start + 1) >= 0) throw new WorkflowError(`job ${job} missing or duplicate`);
  const endOffset = lines.slice(start + 1).findIndex(line => /^  [\w-]+:\s*$/.test(line));
  const section = lines.slice(start + 1, endOffset < 0 ? undefined : start + 1 + endOffset);
  const stepsAt = section.findIndex(line => /^    steps:\s*$/.test(line));
  if (stepsAt < 0) throw new WorkflowError(`job ${job} missing steps`);
  const steps = [];
  let current = null;
  let block = false;
  let inWith = false;
  for (const line of section.slice(stepsAt + 1)) {
    if (/^\s*(?:#.*)?$/.test(line)) {
      if (block) current.run += '\n';
      continue;
    }
    if (/^      - /.test(line)) {
      if (current) steps.push(finalize(current));
      const match = line.match(/^      - name:\s*(.+)$/);
      if (!match) throw new WorkflowError('unsupported step: expected name');
      current = { name: match[1].trim(), with: {} };
      block = false;
      inWith = false;
      continue;
    }
    if (!current) throw new WorkflowError(`unsupported line before the first step: ${line.trim()}`);
    if (block && /^          /.test(line)) {
      current.run += `${line.slice(10)}\n`;
      continue;
    }
    block = false;
    if (inWith && /^          /.test(line)) {
      const match = line.match(/^          ([\w-]+):\s*(.*)$/);
      if (!match) throw new WorkflowError('unsupported with entry');
      if (Object.hasOwn(current.with, match[1])) throw new WorkflowError(`duplicate with key ${match[1]}`);
      current.with[match[1]] = match[2];
      continue;
    }
    inWith = false;
    const match = line.match(/^        ([\w-]+):\s*(.*)$/);
    if (!match) throw new WorkflowError(`unsupported step line ${line.trim()}`);
    const [, key, value] = match;
    if (!['name', 'uses', 'with', 'working-directory', 'run'].includes(key)) throw new WorkflowError(`unsupported step key ${key}`);
    if (key === 'name' || key === 'working-directory' && Object.hasOwn(current, 'cwd') || key === 'with' && current.hadWith || Object.hasOwn(current, key) && key !== 'with') throw new WorkflowError(`duplicate step key ${key}`);
    if (key === 'with') {
      if (value) throw new WorkflowError('unsupported inline with');
      current.hadWith = true;
      inWith = true;
    } else if (key === 'run') {
      if (value.startsWith('>')) throw new WorkflowError('folded run is unsupported');
      if (value.startsWith('|') && value !== '|') throw new WorkflowError('unsupported run block style');
      if (value.startsWith('"') || value.startsWith("'")) throw new WorkflowError('quoted run is unsupported');
      if (value === '|') { current.run = ''; block = true; }
      else if (value) current.run = value;
      else throw new WorkflowError('empty run');
    } else if (key === 'working-directory') current.cwd = value;
    else current[key] = value;
  }
  if (current) steps.push(finalize(current));
  if (!steps.length || steps.filter(step => step.kind === 'run').length === 0) throw new WorkflowError(`job ${job} has no runnable steps`);
  if (new Set(steps.map(step => step.name)).size !== steps.length) throw new WorkflowError('duplicate step name');
  const commands = steps.map(({ name, kind, run, cwd }) => ({ name, kind, run, cwd }));
  const workflowSha256 = createHash('sha256').update(JSON.stringify(commands)).digest('hex');
  return { job, steps, workflowSha256 };
}

function onlyKeys(step, keys) { return Object.keys(step.with).every(key => keys.includes(key)); }

function finalize(step) {
  if (!step.name || /[\r\n=:]/.test(step.name)) throw new WorkflowError('invalid step name');
  if (step.uses && step.run) throw new WorkflowError(`step ${step.name} has uses and run`);
  if (step.uses) {
    if (step.cwd) throw new WorkflowError(`unsupported working-directory on uses step ${step.name}`);
    if (step.uses.startsWith('actions/checkout@')) {
      if (step.with.path !== 'pr-head' || step.with.ref !== CHECKOUT_REF || step.with['fetch-depth'] !== '0' || !onlyKeys(step, ['ref', 'path', 'fetch-depth'])) throw new WorkflowError(`unsupported checkout mapping ${step.name}`);
      step.kind = 'checkout';
    } else if (step.uses.startsWith('actions/setup-node@')) {
      if (step.with['node-version'] !== NODE_VERSION || !onlyKeys(step, ['node-version'])) throw new WorkflowError(`unsupported setup-node mapping ${step.name}`);
      step.kind = 'setup-node';
    } else if (step.uses.startsWith('actions/setup-python@')) {
      // env-check.sh holds the host to the same minor version.
      if (step.with['python-version'] !== PYTHON_VERSION || !onlyKeys(step, ['python-version'])) throw new WorkflowError(`unsupported setup-python mapping ${step.name}`);
      step.kind = 'setup-python';
    } else throw new WorkflowError(`unsupported uses ${step.uses}`);
    return step;
  }
  if (!step.run) throw new WorkflowError(`step ${step.name} missing run`);
  if (step.run.includes('${{')) throw new WorkflowError(`unsupported run expression in step ${step.name}`);
  if (step.cwd?.includes('${{')) throw new WorkflowError(`unsupported working-directory expression in step ${step.name}`);
  if (step.name === PROVISION_STEP && !step.cwd) {
    // The host has no sudo; env-check.sh verifies the same tools are already installed.
    const commands = step.run.trim().split('\n').map(line => line.trim()).filter(Boolean);
    if (commands.length !== PROVISION_COMMANDS.length || commands.some((command, i) => command !== PROVISION_COMMANDS[i])) throw new WorkflowError('unsupported provision mapping');
    step.kind = 'provision';
  } else if (step.cwd === 'pr-head') step.kind = 'run';
  else throw new WorkflowError(`unsupported working-directory in step ${step.name}`);
  if (Object.keys(step.with).length) throw new WorkflowError(`unsupported with on run step ${step.name}`);
  return step;
}

export function workflowAt(repo, sha, job = DEFAULT_JOB) {
  if (!/^[a-f0-9]{40}$/.test(sha)) throw new WorkflowError('expected full commit SHA');
  const result = spawnSync('git', ['show', `${sha}:${WORKFLOW_PATH}`], { cwd: repo, encoding: 'utf8' });
  if (result.error || result.status !== 0) throw new WorkflowError(`git show workflow: ${result.error?.message ?? result.stderr}`);
  return parseWorkflow(result.stdout, job);
}
