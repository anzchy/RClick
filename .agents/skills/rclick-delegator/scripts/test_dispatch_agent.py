"""Offline CLI dispatch contract: fake terminal transport, real reset and marker writer."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parent


class DispatchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.repo = self.root / 'repo'
        self.scripts = self.repo / '.agents/skills/rclick-delegator/scripts'
        self.scripts.mkdir(parents=True)
        for name in ('dispatch-agent.sh', 'reset.sh'):
            if (SCRIPTS / name).exists():
                shutil.copy2(SCRIPTS / name, self.scripts / name)
        marker = self.repo / '.agents/skills/rclick-verify/scripts'
        marker.mkdir(parents=True)
        shutil.copy2(SCRIPTS.parent.parent / 'rclick-verify/scripts/mark-target.mjs', marker)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.log = self.root / 'calls'
        self.home = self.root / 'home'
        self.home.mkdir()
        self.prompt = self.root / 'prompt.txt'
        self.prompt.write_text('Read the brief. Literal $(oops) `oops` and "quotes".\nTask: i61-test\n')
        self.report = self.root / 'report.md'
        self.report.touch()
        self.env = {**os.environ, 'HOME': str(self.home), 'PATH': str(self.bin) + os.pathsep + os.environ['PATH'],
                    'RCLICK_PYTHON': sys.executable, 'CALLS': str(self.log), 'TEST_REPO': str(self.repo),
                    'TEST_KIND': 'claude', 'TEST_ROLE': 'implementer', 'ENTERS_NEEDED': '1'}
        subprocess.run(['git', 'init', '-q', '-b', 'topic'], cwd=self.repo, check=True)
        self.write_exec(self.bin / 'sleep', '#!/bin/sh\nexit 0\n')
        self.write_exec(self.bin / 'date', '#!/bin/sh\nprintf "1120\\n"\n')
        self.write_exec(self.scripts / 'listen-notify.py', '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
with open(os.environ['CALLS'], 'a') as f: f.write(json.dumps(['listener', *sys.argv[1:]]) + '\\n')
print(os.environ.get('LISTENER_RESULT', 'started') + ' event=test')
sys.exit(int(os.environ.get('LISTENER_EXIT', '0')))
''')
        self.write_exec(self.bin / 'herdr', '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
log = Path(os.environ['CALLS'])
previous = [json.loads(s) for s in log.read_text().splitlines()] if log.exists() else []
with log.open('a') as f: f.write(json.dumps(args) + '\\n')
kind = os.environ['TEST_KIND']
repo = os.environ['TEST_REPO']
if args == ['pane', 'list']:
    print(json.dumps({'id': 'cli:pane:list', 'result': {'type': 'pane_list', 'panes': [
        {'pane_id': 'w1:p9', 'terminal_id': 'term_fresh', 'cwd': repo, 'foreground_cwd': repo,
         'agent': 'claude', 'terminal_title_stripped': 'rclick-delegator'},
        {'pane_id': 'w1:p2', 'terminal_id': 'term_worker', 'cwd': repo, 'foreground_cwd': repo,
         'agent': kind}]}}))
elif args[:2] == ['agent', 'get']:
    print(json.dumps({'result': {'type': 'agent_info', 'agent': {'pane_id': 'w1:p2',
        'terminal_id': 'term_worker', 'agent_status': 'idle'}}}))
elif args[:2] == ['pane', 'get']:
    print(json.dumps({'result': {'pane': {'agent_session': {'value': 'session'}}}}))
elif args[:2] == ['pane', 'read']:
    prompts = [i for i, c in enumerate(previous) if c[:3] == ['pane', 'send-text', 'w1:p2'] and c[3] not in ('/new', '/clear')]
    if prompts:
        enters = sum(c[:3] == ['pane', 'send-keys', 'w1:p2'] for c in previous[prompts[-1]+1:])
        print('Working (esc to interrupt)' if enters >= int(os.environ['ENTERS_NEEDED']) else 'idle: prompt waiting')
    elif kind == 'codex':
        enters = sum(c[:3] == ['pane', 'send-keys', 'w1:p2'] for c in previous)
        if enters < 2: print('Where should the new conversation run?')
        else: print('>_ OpenAI Codex (v0.167.0)\\n' + repo + '\\n› Ask Codex to do anything\\nContext 0% used')
    else: print('Context 0% used')
''')

    def write_exec(self, path, text):
        path.write_text(text)
        path.chmod(0o755)

    def args(self, kind='claude', role='implementer'):
        args = ['--agent', 'worker', '--pane', 'w1:p2', '--role', role, '--kind', kind,
                '--issue', '61', '--task', 'i61-test', '--round', 'r1', '--prompt-file', str(self.prompt)]
        return args + (['--worktree', str(self.repo), '--branch', 'topic', '--handoff', str(self.report)]
                       if role == 'implementer' else ['--report', str(self.report)])

    def run_dispatch(self, args=None, kind='claude', role='implementer', **env):
        # Missing script is a contract failure with an assertion, not a launch exception.
        script = self.scripts / 'dispatch-agent.sh'
        if not script.exists():
            return subprocess.CompletedProcess([], 127, '', 'dispatch-agent.sh does not exist')
        return subprocess.run([str(script), *(args if args is not None else self.args(kind, role))],
            capture_output=True, text=True, cwd=self.repo,
            env={**self.env, 'TEST_KIND': kind, 'TEST_ROLE': role, **env})

    def calls(self):
        return [json.loads(s) for s in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_claude_implementer_dispatches_with_target_and_pinned_listener(self):
        result = self.run_dispatch()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('DISPATCHED i61-test-r1-1120', result.stdout)
        self.assertEqual(json.loads((self.repo / '.build/rclick-verify/target-worktree').read_text()),
                         {'worktree': str(self.repo), 'branch': 'topic', 'issue': 61,
                          'task': 'i61-test', 'handoff': str(self.report)})
        self.assertEqual(self.calls(), [
            ['pane', 'list'], ['agent', 'get', 'w1:p2'],
            ['listener', 'start', '--event', 'i61-test-r1-1120', '--task', 'i61-test',
             '--route', 'claude-pane', '--pane', 'w1:p9', '--terminal-id', 'term_fresh',
             '--cwd', str(self.repo), '--agent', 'worker', '--agent-pane', 'w1:p2',
             '--handoff', str(self.report), '--handoff-marker', 'i61-test', '--poll', 'handoff',
             '--interval', '60', '--idle-grace-seconds', '3600', '--max-minutes', '3000'],
            ['pane', 'send-text', 'w1:p2', '/clear'], ['pane', 'send-keys', 'w1:p2', 'Enter'],
            ['pane', 'read', 'w1:p2', '--source', 'recent-unwrapped', '--lines', '100'],
            ['pane', 'send-text', 'w1:p2', self.prompt.read_text()],
            ['pane', 'send-keys', 'w1:p2', 'Enter'],
            ['pane', 'read', 'w1:p2', '--source', 'recent-unwrapped', '--lines', '100']])


if __name__ == '__main__':
    unittest.main()
