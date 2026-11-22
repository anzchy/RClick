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
import signal
import subprocess
import sys

scripts = Path(sys.argv.pop(1)).resolve().parent
parser = argparse.ArgumentParser(description='Register, reset and submit one fresh roster task.')
parser.add_argument('--check-fresh', action='store_true', help='Read a Claude pane once without dispatching.')
for name in ('agent', 'issue', 'task', 'round', 'prompt-file'):
    parser.add_argument('--' + name)
parser.add_argument('--pane', required=True)
parser.add_argument('--role', choices=('implementer', 'auditor'))
parser.add_argument('--kind', required=True, choices=('claude', 'codex'))
for name in ('worktree', 'branch', 'handoff', 'report'):
    parser.add_argument('--' + name)
args = parser.parse_args()


def refuse(message):
    parser.error(message)


def existing_path(value, label, directory=False):
    if not isinstance(value, str) or not value or not Path(value).is_absolute() or '\n' in value or '\r' in value:
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
    screen = run(['herdr', 'pane', 'read', args.pane, '--source', 'recent-unwrapped', '--lines', '100'])
    return re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', screen).replace('\xa0', ' ')


def send_keys():
    run(['herdr', 'pane', 'send-keys', args.pane, 'Enter'])


def claude_separator(line):
    # Agent panes label the upper rule; its width is terminal-dependent.
    return bool(re.fullmatch(r'[─━]+(?: [A-Za-z0-9._-]+ [─━]+)?', line))


def claude_notice(line):
    return line.startswith(('⚠ ', '✘ Auto-update failed'))


def claude_freshness_reason(screen):
    """An empty composer and zero footer must bound a transcript-free welcome."""
    lines = [line.strip() for line in screen.splitlines() if line.strip()]
    welcomes = [i for i, line in enumerate(lines) if 'Claude Code' in line]
    if not welcomes:
        return 'missing Claude Code welcome banner'
    composers = [i for i, line in enumerate(lines) if line.startswith('❯')]
    if not composers or lines[composers[-1]] != '❯' and not lines[composers[-1]].startswith('❯ Try '):
        return 'missing empty composer'
    composer, welcome = composers[-1], welcomes[-1]

    if composer == 0 or composer + 1 >= len(lines) or not all(
            claude_separator(lines[i]) for i in (composer - 1, composer + 1)):
        return 'empty composer is not between separators'
    if welcome >= composer:
        return 'welcome banner is not above composer'
    footers = [i for i, line in enumerate(lines) if re.match(r'^Context\s', line)]
    if not footers or footers[-1] <= composer + 1:
        return 'missing Context footer below composer'
    footer = footers[-1]
    if not re.fullmatch(r'Context\s+(?:[█░▒▓▏▎▍▌▋▊▉]+\s+)?0%\s*(?:used)?', lines[footer]):
        return 'Context footer is not zero'
    # Accept HUD model/cwd and permission hints, never arbitrary newer output.
    if any(not re.fullmatch(r'\[[^]\n]+\]\s*│.*', line)
           for line in lines[composer + 2:footer]):
        return 'unexpected content before Context footer'
    if any(not line.startswith(('⏵⏵ ', '? for shortcuts')) for line in lines[footer + 1:]):
        return 'unexpected content after Context footer'
    region = lines[welcome + 1:composer - 1]
    echoes = [i for i, line in enumerate(region) if line == '❯ /clear']
    # Banner metadata is recognizable by its model/billing or cwd syntax.
    # It is allowed only before the echo, never as transcript after /clear.
    before = region[:echoes[-1]] if echoes else region
    after = region[echoes[-1] + 1:] if echoes else []
    for line in before:
        if claude_separator(line) or claude_notice(line):
            continue
        metadata = re.sub(r'^[▐▛█▝▜▀▟▙▘▗▖ ]*', '', line)
        if re.match(r'(?:Opus|Sonnet|Haiku) [0-9].* · ', metadata):
            continue
        if metadata.startswith(('~/', '/', '@rclick-')):
            continue
        return 'unexpected content between welcome and composer'
    if any(not (claude_separator(line) or claude_notice(line)) for line in after):
        return 'transcript content after /clear'
    return ''


def fresh_claude(screen):
    return not claude_freshness_reason(screen)


def live_status(screen):
    # Inspect the activity block immediately above the LAST composer.
    # A status-looking transcript line or anything inside the composer is not evidence.
    lines = screen.splitlines()
    glyph = '›' if args.kind == 'codex' else '❯'
    composers = [i for i, line in enumerate(lines) if line.lstrip().startswith(glyph)]
    if not composers:
        return False
    index = composers[-1]
    empty = (glyph, glyph + ' Ask Codex to do anything') if args.kind == 'codex' else (glyph,)
    if lines[index].strip() not in empty or len(lines) - index > 10:
        return False
    below = [line.strip() for line in lines[index + 1:] if line.strip()]
    # Continuation text must never remain in the composer.
    if below and not (re.fullmatch(r'[─━]+', below[0]) or
                      (args.kind == 'codex' and 'Context' in below[0])):
        return False
    above = [line.strip() for line in lines[:index] if line.strip()]
    if above and (claude_separator(above[-1]) if args.kind == 'claude'
                  else re.fullmatch(r'[─━]+', above[-1])):
        above.pop()
    if not above:
        return False
    if args.kind == 'codex':
        return bool(re.fullmatch(r'• Working \([0-9]+(?:[smh]|ms)(?: [0-9]+[smh])* • esc to interrupt\)', above[-1]))
    # Claude can render a tool tip or todo below its spinner. Walk only these
    # continuation rows, never across user/tool history or a fresh welcome.
    while above and (claude_notice(above[-1]) or
                     re.match(r'^(?:⎿|[☐☑□✓])(?:\s|$)', above[-1])):
        above.pop()
    return bool(above and re.fullmatch(
        r'[✻✽✶✳✢·] .+…(?: \([0-9]+(?:[smh]|ms)(?: [0-9]+[smh])*'
        r'(?: · [↑↓↕] [0-9.,kK]+ tokens(?: · .+)?)?\))?', above[-1]))


if not re.fullmatch(r'w[0-9]+:p[0-9]+', args.pane):
    refuse('--pane must be a herdr pane ID')
if args.check_fresh:
    if args.kind != 'claude':
        refuse('--check-fresh supports --kind claude only')
    try:
        reason = claude_freshness_reason(read_pane())
    except (RuntimeError, OSError) as error:
        reason = str(error).replace('\n', ' ')
    print('NOT-FRESH: ' + reason if reason else 'FRESH')
    sys.exit(1 if reason else 0)
for name in ('agent', 'issue', 'task', 'round', 'prompt_file', 'role'):
    if getattr(args, name) is None:
        refuse('--' + name.replace('_', '-') + ' is required for dispatch')


for name in ('agent', 'task', 'round'):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', getattr(args, name)):
        refuse('--' + name + ' must be a non-empty ID (letters, numbers, dot, underscore, hyphen)')
if not re.fullmatch(r'[1-9][0-9]*', args.issue):
    refuse('--issue must be a positive integer')
prompt_file = existing_path(args.prompt_file, '--prompt-file')
with prompt_file.open(newline='') as source:
    prompt = source.read()
if prompt.endswith('\n'):
    prompt = prompt[:-1]
if '\n' in prompt or '\r' in prompt:
    refuse('--prompt-file must be one line; long instructions belong in the brief file the prompt points at')
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

def object_value(value, label):
    if not isinstance(value, dict):
        raise RuntimeError('invalid ' + label + ': expected an object')
    return value


def agent_info():
    envelope = object_value(json.loads(run(['herdr', 'agent', 'get', args.pane])), 'agent envelope')
    info = object_value(envelope.get('result'), 'agent result')
    record = object_value(info.get('agent'), 'agent record')
    if info.get('type') != 'agent_info':
        raise RuntimeError('invalid agent result type')
    return record


def confirm_started(screen, target):
    # A layout mismatch is not evidence that a submitted task failed to start.
    # Require the same pinned pane/terminal for the independent metadata proof.
    envelope = object_value(json.loads(run(['herdr', 'pane', 'get', args.pane])), 'pane envelope')
    info = object_value(envelope.get('result'), 'pane result')
    pane = object_value(info.get('pane'), 'pane record')
    if pane.get('pane_id') != args.pane or pane.get('terminal_id') != target.get('terminal_id'):
        raise RuntimeError('start confirmation has a changed pane/terminal identity')
    status = pane.get('agent_status')
    if isinstance(status, dict):
        status = status.get('value')
    if status == 'working':
        return 'confirmed working pane status'
    # A fresh reset preceded this send. Match this exact prompt echo, so an old
    # spinner or a prompt still sitting in the composer cannot prove startup.
    glyph = '❯' if args.kind == 'claude' else '›'
    lines = [line.strip() for line in screen.splitlines()]
    echoes = [i for i, line in enumerate(lines) if line == glyph + ' ' + prompt]
    if echoes:
        for line in lines[echoes[-1] + 1:]:
            if args.kind == 'claude' and (line.startswith('⏺ ') or re.fullmatch(
                    r'[✻✽✶✳✢·] .+…(?: \([^)]+\))?', line)):
                return 'confirmed activity after submitted prompt echo'
            if args.kind == 'codex' and re.fullmatch(
                    r'• Working \([0-9]+(?:[smh]|ms)(?: [0-9]+[smh])* • esc to interrupt\)', line):
                return 'confirmed activity after submitted prompt echo'
    return ''


def terminate(signum, frame):
    raise SystemExit('terminated by signal ' + str(signum))


signal.signal(signal.SIGTERM, terminate)
started = False
succeeded = False
listener_attempted = False
prompt_sent = False
screen = ''
failure = ''
listener = [sys.executable, os.environ.get('RCLICK_LISTENER', scripts / 'listen-notify.py')]
try:
    envelope = object_value(json.loads(run(['herdr', 'pane', 'list'])), 'pane envelope')
    result = object_value(envelope.get('result'), 'pane result')
    if envelope.get('id') != 'cli:pane:list' or result.get('type') != 'pane_list' or 'error' in envelope:
        raise RuntimeError('invalid pane list envelope')
    panes = result.get('panes')
    if not isinstance(panes, list) or any(not isinstance(p, dict) for p in panes):
        raise RuntimeError('invalid pane records')
    owners = [p for p in panes if p.get('agent') == 'claude' and
              p.get('terminal_title_stripped') == 'rclick-delegator']
    targets = [p for p in panes if p.get('pane_id') == args.pane]
    if len(owners) != 1 or len(targets) != 1 or owners[0]['pane_id'] == args.pane:
        raise RuntimeError('delegator or target pane missing, ambiguous, or the same pane')
    owner, target = owners[0], targets[0]
    cwd = existing_path(owner.get('cwd'), 'delegator cwd', directory=True)
    target_cwd = existing_path(target.get('cwd'), 'target cwd', directory=True)
    if owner.get('foreground_cwd') != str(cwd) or not isinstance(owner.get('terminal_id'), str) or not re.fullmatch(r'term_[A-Za-z0-9_-]+', owner['terminal_id']):
        raise RuntimeError('delegator terminal/cwd identity is invalid')
    if target.get('agent') != args.kind or target.get('foreground_cwd') != str(target_cwd):
        raise RuntimeError('target kind/cwd does not match the pane')
    if args.role == 'implementer' and target_cwd != worktree:
        raise RuntimeError('--worktree must be the agent pane home')
    agent = agent_info()
    if agent.get('agent_status') not in ('idle', 'done'):
        raise RuntimeError('target pane is not idle/done')
    if args.role == 'implementer':
        run(['node', os.environ.get('RCLICK_MARK_TARGET', scripts.parent.parent / 'rclick-verify/scripts/mark-target.mjs'),
             worktree, worktree, args.issue, args.task, output, args.branch])
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
        for submission in range(3):
            send_keys()
            for attempt in range(10):
                run(['sleep', '0.25'])
                screen = read_pane()
                if fresh_claude(screen):
                    break
            else:
                continue
            break
        else:
            raise RuntimeError('Claude reset did not confirm Context 0% after 3 Enter attempts: '
                               + claude_freshness_reason(screen) + '; pane tail:\n' + screen[-4000:])
    run(['herdr', 'pane', 'send-text', args.pane, prompt])
    prompt_sent = True
    # Each Enter gets ten reads to become Working; at most three submissions.
    for submission in range(3):
        send_keys()
        for attempt in range(10):
            run(['sleep', '0.25'])
            screen = read_pane()
            working = live_status(screen)
            if working and args.kind == 'claude':
                # Claude's reliable status covers spinner verbs such as Thinking.
                # Codex metadata can be stale: it must show visible Working instead.
                record = agent_info()
                if (record.get('pane_id') != args.pane
                        or record.get('terminal_id') != target.get('terminal_id')):
                    raise RuntimeError('Claude working status has a changed pane/terminal identity')
                working = record.get('agent_status') == 'working'
            if working:
                succeeded = True
                print('DISPATCHED ' + event)
                sys.exit(0)
    raise RuntimeError('pane never showed Working after 3 Enter attempts; pane tail:\n' + screen[-4000:])
except BaseException as error:
    if succeeded:
        raise
    failure = str(error)
    if prompt_sent and isinstance(error, Exception) and 'changed pane/terminal identity' not in failure:
        try:
            confirmation = confirm_started(screen, target)
        except Exception as confirmation_error:
            failure += '; start confirmation failed: ' + str(confirmation_error)
        else:
            if confirmation:
                succeeded = True
                print('WARNING dispatch: screen classifier did not match; ' + confirmation
                      + '; pane tail:\n' + screen[-4000:], file=sys.stderr)
                print('DISPATCHED ' + event)
                sys.exit(0)
    print('FAIL dispatch: ' + (failure or type(error).__name__), file=sys.stderr)
    sys.exit(1)
finally:
    if not succeeded and (started or (listener_attempted and event_dir.exists()
                                     and 'event already exists' not in failure)):
        # Do not let a second catchable termination interrupt the owned cleanup.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        try:
            print(run([*listener, 'stop', '--event', event]), end='', file=sys.stderr)
        except BaseException as stop_error:
            print('FAIL listener cleanup: ' + str(stop_error), file=sys.stderr)
PY
