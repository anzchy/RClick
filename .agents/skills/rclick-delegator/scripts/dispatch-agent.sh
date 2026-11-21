#!/bin/sh
# Python is embedded so dispatch remains one portable entry point next to reset/listen.
rclick_python=${RCLICK_PYTHON:-}
if [ -z "$rclick_python" ]; then
  if [ -x /opt/homebrew/bin/python3 ]; then rclick_python=/opt/homebrew/bin/python3; else rclick_python=python3; fi
fi
exec "$rclick_python" - "$0" "$@" <<'PY'
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

scripts = Path(sys.argv.pop(1)).resolve().parent
parser = argparse.ArgumentParser(description='Register, reset and submit one fresh roster task.')
for name in ('agent', 'pane', 'issue', 'task', 'round', 'prompt-file'):
    parser.add_argument('--' + name, required=True)
parser.add_argument('--role', required=True, choices=('implementer', 'auditor'))
parser.add_argument('--kind', required=True, choices=('claude', 'codex'))
for name in ('worktree', 'branch', 'handoff', 'report'):
    parser.add_argument('--' + name)
args = parser.parse_args()


def refuse(message):
    parser.error(message)


def existing_path(value, label, directory=False):
    if not value or not Path(value).is_absolute() or '\n' in value or '\r' in value:
        refuse(label + ' must be an absolute existing path')
    path = Path(value)
    if not (path.is_dir() if directory else path.is_file()):
        refuse(label + ' must be an absolute existing ' + ('directory' if directory else 'file'))
    return path.resolve()


def run(argv):
    result = subprocess.run([str(a) for a in argv], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError('command failed: ' + str(argv[0]) + '\n' + result.stdout + result.stderr)
    return result.stdout


def read_pane():
    return run(['herdr', 'pane', 'read', args.pane, '--source', 'recent-unwrapped', '--lines', '100'])


def send_keys():
    run(['herdr', 'pane', 'send-keys', args.pane, 'Enter'])


for name in ('agent', 'task', 'round'):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', getattr(args, name)):
        refuse('--' + name + ' must be a non-empty ID (letters, numbers, dot, underscore, hyphen)')
if not re.fullmatch(r'w[0-9]+:p[0-9]+', args.pane):
    refuse('--pane must be a herdr pane ID')
if not re.fullmatch(r'[1-9][0-9]*', args.issue):
    refuse('--issue must be a positive integer')
prompt_file = existing_path(args.prompt_file, '--prompt-file')
prompt = prompt_file.read_text()
if not prompt.strip() or '\0' in prompt:
    refuse('--prompt-file must contain non-empty text without NUL')
if args.role == 'implementer':
    worktree = existing_path(args.worktree, '--worktree', directory=True)
    output = existing_path(args.handoff, '--handoff')
    if not args.branch or args.report:
        refuse('implementer requires --branch and --handoff, without --report')
    if subprocess.run(['git', 'check-ref-format', '--branch', args.branch], capture_output=True).returncode:
        refuse('--branch must be a valid branch name')
else:
    output = existing_path(args.report, '--report')
    if any((args.worktree, args.branch, args.handoff)):
        refuse('auditor requires --report, without implementer flags')

event = args.task + '-' + args.round + '-' + run(['date', '+%m%d']).strip()
if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}', event):
    refuse('derived event ID is invalid or exceeds 128 characters')
event_dir = Path.home() / '.rclick-roster/herdr/delegator/listeners' / event
if event_dir.exists():
    refuse('event already exists; use a NEW task and event: ' + event)

started = False
listener_attempted = False
try:
    envelope = json.loads(run(['herdr', 'pane', 'list']))
    if envelope.get('id') != 'cli:pane:list' or envelope['result']['type'] != 'pane_list' or 'error' in envelope:
        raise RuntimeError('invalid pane list envelope')
    panes = envelope['result']['panes']
    owners = [p for p in panes if p.get('agent') == 'claude' and
              p.get('terminal_title_stripped') == 'rclick-delegator']
    targets = [p for p in panes if p.get('pane_id') == args.pane]
    if len(owners) != 1 or len(targets) != 1 or owners[0]['pane_id'] == args.pane:
        raise RuntimeError('delegator or target pane missing, ambiguous, or the same pane')
    owner, target = owners[0], targets[0]
    cwd = existing_path(owner.get('cwd'), 'delegator cwd', directory=True)
    target_cwd = existing_path(target.get('cwd'), 'target cwd', directory=True)
    if owner.get('foreground_cwd') != str(cwd) or not re.fullmatch(r'term_[A-Za-z0-9_-]+', owner.get('terminal_id', '')):
        raise RuntimeError('delegator terminal/cwd identity is invalid')
    if target.get('agent') != args.kind or target.get('foreground_cwd') != str(target_cwd):
        raise RuntimeError('target kind/cwd does not match the pane')
    if args.role == 'implementer' and target_cwd != worktree:
        raise RuntimeError('--worktree must be the agent pane home')
    agent = json.loads(run(['herdr', 'agent', 'get', args.pane]))['result']['agent']
    if agent.get('agent_status') not in ('idle', 'done'):
        raise RuntimeError('target pane is not idle/done')
    if args.role == 'implementer':
        run(['node', scripts.parent.parent / 'rclick-verify/scripts/mark-target.mjs',
             worktree, worktree, args.issue, args.task, output, args.branch])
    listener = [sys.executable, scripts / 'listen-notify.py']
    listener_attempted = True
    response = run([*listener, 'start', '--new', '--event', event, '--task', args.task,
                    '--route', 'claude-pane', '--pane', owner['pane_id'], '--terminal-id', owner['terminal_id'],
                    '--cwd', cwd, '--agent', args.agent, '--agent-pane', args.pane,
                    '--handoff', output, '--handoff-marker', args.task,
                    '--poll', 'handoff' if args.role == 'implementer' else 'report',
                    '--interval', '60', '--idle-grace-seconds', '3600', '--max-minutes', '3000'])
    # A zero exit with already-delivered/already-running is NOT a new registration.
    if not re.search(r'^started\b', response, re.MULTILINE):
        raise RuntimeError('listener start did not print started: ' + response)
    started = True
    print(response, end='', flush=True)
    if args.kind == 'codex':
        print(run([scripts / 'reset.sh', args.agent, args.pane]), end='', flush=True)
    else:
        run(['herdr', 'pane', 'send-text', args.pane, '/clear'])
        send_keys()
        for attempt in range(20):
            run(['sleep', '0.25'])
            screen = read_pane()
            if re.search(r'^\s*Context\s+(?:[█░]+\s+)?0%\s*(?:used)?\s*$', screen, re.MULTILINE):
                break
        else:
            raise RuntimeError('Claude reset did not confirm Context 0%\n' + screen[-4000:])
    run(['herdr', 'pane', 'send-text', args.pane, prompt])
    # Each Enter gets ten reads to become Working; at most three submissions.
    for submission in range(3):
        send_keys()
        for attempt in range(10):
            run(['sleep', '0.25'])
            screen = read_pane()
            working = bool(re.search(r'^\s*(?:[•✻✽✶✳⏺]\s*)?Working\b', screen, re.IGNORECASE | re.MULTILINE))
            if not working and args.kind == 'claude':
                # Claude's reliable status covers spinner verbs such as Thinking.
                # Codex metadata can be stale: it must show visible Working instead.
                info = json.loads(run(['herdr', 'agent', 'get', args.pane]))['result']
                record = info['agent']
                if (info.get('type') != 'agent_info' or record.get('pane_id') != args.pane
                        or record.get('terminal_id') != target.get('terminal_id')):
                    raise RuntimeError('Claude working status has a changed pane/terminal identity')
                working = record.get('agent_status') == 'working'
            if working:
                print('DISPATCHED ' + event)
                sys.exit(0)
    raise RuntimeError('pane never showed Working after 3 Enter attempts; pane tail:\n' + screen[-4000:])
except (RuntimeError, OSError, ValueError, KeyError, TypeError) as error:
    print('FAIL dispatch: ' + str(error), file=sys.stderr)
    if started or (listener_attempted and event_dir.exists() and 'event already exists' not in str(error)):
        try:
            print(run([*listener, 'stop', '--event', event]), end='', file=sys.stderr)
        except (RuntimeError, OSError) as stop_error:
            print('FAIL listener cleanup: ' + str(stop_error), file=sys.stderr)
    sys.exit(1)
PY
