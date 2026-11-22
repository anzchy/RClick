"""Offline CLI dispatch contract: fake terminal transport, real reset, injected marker writer, and no elapsed-time budgets."""
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import fixture_warmup

SCRIPTS = Path(__file__).resolve().parent
FIXTURE_BIN = SCRIPTS / 'fixtures/bin/dispatch'


def setUpModule():
    fixture_warmup.warm_up()


class DispatchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.repo = self.root / 'repo'
        self.scripts = self.repo / '.agents/skills/rclick-delegator/scripts'
        self.scripts.parent.mkdir(parents=True)
        # Link the entire production directory: reset's current and future siblings
        # stay available without creating fresh executable copies per test.
        self.scripts.symlink_to(SCRIPTS, target_is_directory=True)
        self.marker = FIXTURE_BIN / 'marker.mjs'
        self.bin = FIXTURE_BIN
        self.log = self.root / 'calls'
        self.home = self.root / 'home'
        self.home.mkdir()
        self.prompt = self.root / 'prompt.txt'
        self.prompt.write_text('Read the brief. Literal $(oops) `oops` and "quotes". Task: i61-test')
        self.report = self.root / 'report.md'
        self.report.touch()
        self.env = {**{k: v for k, v in os.environ.items() if not k.startswith('RCLICK_')}, 'HOME': str(self.home), 'PATH': str(self.bin) + os.pathsep + os.environ['PATH'],
                    'RCLICK_PYTHON': sys.executable, 'RCLICK_LISTENER': str(FIXTURE_BIN / 'listen-notify.py'), 'RCLICK_MARK_TARGET': str(self.marker), 'CALLS': str(self.log), 'TEST_REPO': str(self.repo),
                    'TEST_KIND': 'claude', 'TEST_ROLE': 'implementer', 'ENTERS_NEEDED': '1'}
        subprocess.run(['git', 'init', '-q', '-b', 'topic'], cwd=self.repo, check=True)

    def test_inherited_reset_transport_overrides_are_removed(self):
        with patch.dict(os.environ, {'RCLICK_HERDR': '/nonexistent/herdr',
                                     'RCLICK_SLEEP': '/nonexistent/sleep'}):
            isolated = DispatchTests()
            isolated.setUp()
            try:
                result = isolated.run_dispatch(kind='codex')
                self.assertEqual(result.returncode, 0, result.stderr)
            finally:
                isolated.doCleanups()

    def test_production_scripts_directory_includes_every_reset_sibling(self):
        self.assertEqual(self.scripts.resolve(), SCRIPTS)
        self.assertEqual({p.name for p in self.scripts.iterdir() if p.is_file()},
                         {p.name for p in SCRIPTS.iterdir() if p.is_file()})
        result = self.run_dispatch(kind='codex')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_static_fixtures_and_untimed_module_warmup(self):
        module = sys.modules[__name__]
        self.assertTrue(callable(getattr(module, 'setUpModule', None)))
        expected = {p for p in (SCRIPTS / 'fixtures').rglob('*')
                    if p.is_file() and os.access(p, os.X_OK)}
        self.assertTrue(expected <= set(fixture_warmup.fixture_paths()))
        with patch.object(fixture_warmup.subprocess, 'run') as run:
            module.setUpModule()
        executed = {Path(call.args[0][0]) for call in run.call_args_list}
        self.assertTrue(expected <= executed)
        self.assertTrue(all('timeout' not in call.kwargs for call in run.call_args_list))
        for name in ('herdr', 'sleep', 'date', 'listen-notify.py'):
            self.assertTrue(os.access(FIXTURE_BIN / name, os.X_OK), name)
        self.assertEqual(self.bin.resolve(), SCRIPTS / 'fixtures/bin/dispatch')

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
            ['listener', 'start', '--new', '--event', 'i61-test-r1-1120', '--task', 'i61-test',
             '--route', 'claude-pane', '--pane', 'w1:p9', '--terminal-id', 'term_fresh',
             '--cwd', str(self.repo), '--agent', 'worker', '--agent-pane', 'w1:p2',
             '--handoff', str(self.report), '--handoff-marker', 'i61-test', '--poll', 'handoff',
             '--interval', '60', '--idle-grace-seconds', '3600', '--max-minutes', '3000'],
            ['pane', 'send-text', 'w1:p2', '/clear'], ['pane', 'send-keys', 'w1:p2', 'Enter'],
            ['pane', 'read', 'w1:p2', '--source', 'recent-unwrapped', '--lines', '100'],
            ['pane', 'send-text', 'w1:p2', self.prompt.read_text()],
            ['pane', 'send-keys', 'w1:p2', 'Enter'],
            ['pane', 'read', 'w1:p2', '--source', 'recent-unwrapped', '--lines', '100'],
            ['agent', 'get', 'w1:p2']])

    def test_all_other_role_kind_combinations(self):
        for kind, role in (('codex', 'implementer'), ('claude', 'auditor'), ('codex', 'auditor')):
            with self.subTest(kind=kind, role=role):
                self.log.unlink(missing_ok=True)
                marker = self.repo / '.build/rclick-verify/target-worktree'
                marker.unlink(missing_ok=True)
                result = self.run_dispatch(kind=kind, role=role)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('DISPATCHED i61-test-r1-1120', result.stdout)
                calls = self.calls()
                listener = next(c for c in calls if c[:2] == ['listener', 'start'])
                expected = ['listener', 'start', '--new', '--event', 'i61-test-r1-1120', '--task', 'i61-test',
                    '--route', 'claude-pane', '--pane', 'w1:p9', '--terminal-id', 'term_fresh',
                    '--cwd', str(self.repo), '--agent', 'worker', '--agent-pane', 'w1:p2',
                    '--handoff', str(self.report), '--handoff-marker', 'i61-test', '--poll',
                    'report' if role == 'auditor' else 'handoff', '--interval', '60',
                    '--idle-grace-seconds', '3600', '--max-minutes', '3000']
                self.assertEqual(listener, expected)
                self.assertEqual(marker.exists(), role == 'implementer')
                reset_command = '/new' if kind == 'codex' else '/clear'
                inputs = [c for c in calls if c[:2] in (['pane', 'send-text'], ['pane', 'send-keys'])]
                self.assertEqual(inputs, [
                    ['pane', 'send-text', 'w1:p2', reset_command],
                    ['pane', 'send-keys', 'w1:p2', 'enter' if kind == 'codex' else 'Enter'],
                    *([['pane', 'send-keys', 'w1:p2', 'enter']] if kind == 'codex' else []),
                    ['pane', 'send-text', 'w1:p2', self.prompt.read_text()],
                    ['pane', 'send-keys', 'w1:p2', 'Enter']])
                prefix = [['pane', 'list'], ['agent', 'get', 'w1:p2'], expected]
                if kind == 'codex':
                    reset = [['agent', 'get', 'w1:p2'], ['pane', 'get', 'w1:p2'],
                        ['pane', 'send-text', 'w1:p2', '/new'], ['pane', 'send-keys', 'w1:p2', 'enter'],
                        ['pane', 'read', 'w1:p2'], ['pane', 'read', 'w1:p2'],
                        ['pane', 'send-keys', 'w1:p2', 'enter'], ['pane', 'get', 'w1:p2'],
                        ['pane', 'read', 'w1:p2', '--source', 'recent-unwrapped', '--lines', '2000']]
                else:
                    reset = [['pane', 'send-text', 'w1:p2', '/clear'],
                        ['pane', 'send-keys', 'w1:p2', 'Enter'],
                        ['pane', 'read', 'w1:p2', '--source', 'recent-unwrapped', '--lines', '100']]
                self.assertEqual(calls, prefix + reset + [
                    ['pane', 'send-text', 'w1:p2', self.prompt.read_text()],
                    ['pane', 'send-keys', 'w1:p2', 'Enter'],
                    ['pane', 'read', 'w1:p2', '--source', 'recent-unwrapped', '--lines', '100'],
                    *([['agent', 'get', 'w1:p2']] if kind == 'claude' else [])])

    def test_unsubmitted_clear_retries_and_failure_is_bounded(self):
        for needed, expected in (('2', 0), ('999', 1)):
            with self.subTest(needed=needed):
                self.log.unlink(missing_ok=True)
                result = self.run_dispatch(RESET_ENTERS_NEEDED=needed)
                self.assertEqual(result.returncode, expected, result.stderr)
                calls = self.calls()
                prompt = ['pane', 'send-text', 'w1:p2', self.prompt.read_text()]
                reset = calls[:calls.index(prompt)] if prompt in calls else calls
                self.assertEqual(sum(c[:2] == ['pane', 'send-keys'] for c in reset), 2 if expected == 0 else 3)
                self.assertEqual(sum(c[:2] == ['pane', 'read'] for c in reset), 11 if expected == 0 else 30)
                self.assertEqual(reset.count(['pane', 'send-text', 'w1:p2', '/clear']), 1)
                if expected:
                    self.assertIn('Claude reset did not confirm Context 0%', result.stderr)
                    self.assertIn('❯ /clear', result.stderr)
                    self.assertEqual(calls[-1], ['listener', 'stop', '--event', 'i61-test-r1-1120'])

    def test_unsubmitted_prompt_retries_enter(self):
        result = self.run_dispatch(ENTERS_NEEDED='2')
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        index = calls.index(['pane', 'send-text', 'w1:p2', self.prompt.read_text()])
        self.assertEqual(sum(c[:2] == ['pane', 'send-keys'] for c in calls[index:]), 2)
        self.assertEqual(sum(c[:2] == ['pane', 'read'] for c in calls[index:]), 11)

    def test_never_working_is_bounded_loud_and_stops_listener(self):
        result = self.run_dispatch(ENTERS_NEEDED='999')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('pane never showed Working after 3 Enter attempts', result.stderr)
        self.assertIn('idle: prompt waiting', result.stderr)
        calls = self.calls()
        index = calls.index(['pane', 'send-text', 'w1:p2', self.prompt.read_text()])
        self.assertEqual(sum(c[:2] == ['pane', 'send-keys'] for c in calls[index:]), 3)
        self.assertEqual(sum(c[:2] == ['pane', 'read'] for c in calls[index:]), 30)
        self.assertEqual(calls[-1], ['listener', 'stop', '--event', 'i61-test-r1-1120'])
        self.assertNotIn('DISPATCHED', result.stdout)

    def test_closed_stdout_after_start_preserves_successful_listener(self):
        process = subprocess.Popen([str(self.scripts / 'dispatch-agent.sh'), *self.args()],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                   cwd=self.repo, env={**self.env, 'PYTHONUNBUFFERED': '1'})
        self.assertIn('started', process.stdout.readline())
        process.stdout.close()
        stderr = process.stderr.read()
        process.stderr.close()
        process.wait()
        self.assertIn('BrokenPipeError', stderr)
        self.assertEqual(self.calls()[-1], ['agent', 'get', 'w1:p2'])
        self.assertFalse(any(c[:2] == ['listener', 'stop'] for c in self.calls()))

    def test_duplicate_directory_refused_before_any_transport(self):
        event = self.home / '.rclick-roster/herdr/delegator/listeners/i61-test-r1-1120'
        event.mkdir(parents=True)
        result = self.run_dispatch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('event already exists', result.stderr)
        self.assertEqual(self.calls(), [])

    def test_missing_and_invalid_arguments_have_usage_and_no_side_effects(self):
        for role in ('implementer', 'auditor'):
            full = self.args(role=role)
            for i in range(0, len(full), 2):
                with self.subTest(role=role, missing=full[i]):
                    result = self.run_dispatch(full[:i] + full[i+2:], role=role)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('usage:', result.stderr)
                    self.assertEqual(self.calls(), [])
            invalid = {'--agent': '', '--pane': 'p2', '--role': 'owner', '--kind': 'shell',
                       '--issue': '0', '--task': '../task', '--round': 'a/b',
                       '--prompt-file': '../prompt.txt'}
            if role == 'implementer':
                invalid.update({'--worktree': '.', '--branch': '-bad', '--handoff': '../report.md'})
            else:
                invalid['--report'] = '../report.md'
            for flag, value in invalid.items():
                with self.subTest(role=role, invalid=flag):
                    args = full.copy()
                    args[args.index(flag)+1] = value
                    result = self.run_dispatch(args, role=role)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('usage:', result.stderr)
                    self.assertEqual(self.calls(), [])
            for flag in ('--prompt-file', '--worktree', '--handoff', '--report'):
                if flag not in full:
                    continue
                args = full.copy()
                args[args.index(flag)+1] = str(self.root / 'absent')
                result = self.run_dispatch(args, role=role)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.calls(), [])

    def test_start_without_started_sends_nothing(self):
        for response, code in (('already-delivered', '0'), ('launch failed', '1')):
            with self.subTest(response=response):
                self.log.unlink(missing_ok=True)
                result = self.run_dispatch(LISTENER_RESULT=response, LISTENER_EXIT=code)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('DISPATCHED', result.stdout)
                self.assertFalse(any(c[:2] == ['pane', 'send-text'] for c in self.calls()))

    def test_missing_start_ack_stops_a_worker_that_created_state(self):
        for code in ('0', '1'):
            with self.subTest(code=code):
                self.log.unlink(missing_ok=True)
                event = self.home / '.rclick-roster/herdr/delegator/listeners/i61-test-r1-1120'
                if event.exists():
                    event.rmdir()
                result = self.run_dispatch(LISTENER_RESULT='launch lost acknowledgement',
                                           LISTENER_EXIT=code, CREATE_EVENT='1')
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.calls()[-1], ['listener', 'stop', '--event', 'i61-test-r1-1120'])
                self.assertFalse(any(c[:2] == ['pane', 'send-text'] for c in self.calls()))

    def test_claude_context_bar_proves_freshness_but_nonzero_context_does_not(self):
        result = self.run_dispatch(CLAUDE_FOOTER='  Context ░░░░░░ 0%')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('DISPATCHED', result.stdout)
        self.log.unlink()
        result = self.run_dispatch(CLAUDE_FOOTER='  Context █░░░░░ 14%')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Claude reset did not confirm Context 0%', result.stderr)
        self.assertNotIn(['pane', 'send-text', 'w1:p2', self.prompt.read_text()], self.calls())
        self.assertEqual(self.calls()[-1], ['listener', 'stop', '--event', 'i61-test-r1-1120'])

    def test_claude_working_status_confirms_a_spinner_with_a_different_verb(self):
        result = self.run_dispatch(CLAUDE_SPINNER='1')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('DISPATCHED i61-test-r1-1120', result.stdout)
        self.assertEqual(self.calls()[-1], ['agent', 'get', 'w1:p2'])

    def test_working_metadata_requires_claude_and_the_pinned_terminal(self):
        result = self.run_dispatch(CLAUDE_SPINNER='1', WORKING_TERMINAL='term_replaced')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('changed pane/terminal identity', result.stderr)
        self.assertEqual(self.calls()[-1], ['listener', 'stop', '--event', 'i61-test-r1-1120'])
        self.log.unlink()
        result = self.run_dispatch(kind='codex', SCREEN='✻ Thinking… (1s · ↓ 12 tokens)\n❯\nContext 1% used')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('never showed Working', result.stderr)
        self.assertEqual(self.calls()[-1], ['listener', 'stop', '--event', 'i61-test-r1-1120'])

    def test_waiting_composer_and_transcript_are_not_live_status(self):
        screens = [
            '────────────────────\n› Read the brief\n  Working directory: current worktree\n────────────────────\nContext 0% used',
            '• Working (1s • esc to interrupt)\nOld transcript\n\n› Ask Codex to do anything\nContext 0% used',
            '• Working (1s • esc to interrupt)\n────────────────────\n› Read the brief\n────────────────────\nContext 0% used',
        ]
        for screen in screens:
            with self.subTest(screen=screen):
                self.log.unlink(missing_ok=True)
                result = self.run_dispatch(kind='codex', SCREEN=screen, ENTERS_NEEDED='999')
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn('DISPATCHED', result.stdout)
                calls = self.calls()
                index = calls.index(['pane', 'send-text', 'w1:p2', self.prompt.read_text()])
                self.assertEqual(sum(c[:2] == ['pane', 'send-keys'] for c in calls[index:]), 3)
                self.assertIn('pane tail:', result.stderr)
                self.assertEqual(calls[-1], ['listener', 'stop', '--event', 'i61-test-r1-1120'])

    def test_cancellation_after_start_stops_owned_listener(self):
        for sig in ('SIGINT', 'SIGTERM'):
            with self.subTest(signal=sig):
                self.log.unlink(missing_ok=True)
                event = self.home / '.rclick-roster/herdr/delegator/listeners/i61-test-r1-1120'
                if event.exists():
                    event.rmdir()
                result = self.run_dispatch(SEND_SIGNAL=sig, CREATE_EVENT='1')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(['listener', 'stop', '--event', 'i61-test-r1-1120'], self.calls())
                event = self.home / '.rclick-roster/herdr/delegator/listeners/i61-test-r1-1120'
                event.rmdir()

    def test_malformed_working_metadata_fails_and_stops_listener(self):
        result = self.run_dispatch(MALFORMED_AGENT='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('invalid agent record', result.stderr)
        self.assertEqual(self.calls()[-1], ['listener', 'stop', '--event', 'i61-test-r1-1120'])

    def test_racing_duplicate_refusal_does_not_stop_foreign_listener(self):
        result = self.run_dispatch(LISTENER_RESULT='event already exists', LISTENER_EXIT='2', CREATE_EVENT='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c[:2] == ['listener', 'stop'] for c in self.calls()))


    def test_claude_older_zero_context_is_not_reset_completion(self):
        result = self.run_dispatch(CLAUDE_FOOTER='Context 0% used\nEarlier transcript\nContext 14% used')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn(['pane', 'send-text', 'w1:p2', self.prompt.read_text()], self.calls())
        self.assertEqual(self.calls()[-1], ['listener', 'stop', '--event', 'i61-test-r1-1120'])


    def test_captured_claude_fresh_screen_is_accepted(self):
        screen = (SCRIPTS / 'fixtures/claude-screens/idle-fresh.ansi').read_text()
        result = self.run_dispatch(CLAUDE_RESET_SCREEN=screen)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


    def test_real_claude_reset_layout_and_fail_closed_variants(self):
        fresh = (SCRIPTS / 'fixtures/claude-screens/claude-fresh-after-clear.txt').read_text()
        result = self.run_dispatch(CLAUDE_RESET_SCREEN=fresh)
        self.assertEqual(result.returncode, 0, result.stderr)
        rejected = [fresh.replace('0%', '3%'), fresh.replace('❯\n', '❯ pending\n'),
                    fresh.replace('❯ /clear', 'Earlier transcript\n❯ /clear')]
        rejected += [(SCRIPTS / ('fixtures/claude-screens/claude-working-' + n + '.txt')).read_text()
                     for n in ('1', '2')]
        for screen in rejected:
            with self.subTest(screen=screen):
                self.log.unlink(missing_ok=True)
                result = self.run_dispatch(CLAUDE_RESET_SCREEN=screen)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn(['pane', 'send-text', 'w1:p2', self.prompt.read_text()], self.calls())
                self.assertEqual(self.calls()[-1], ['listener', 'stop', '--event', 'i61-test-r1-1120'])

    def test_prompt_strips_one_final_newline_and_refuses_all_other_newlines(self):
        self.prompt.write_text('Read the brief. Task i61-test\n')
        result = self.run_dispatch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(['pane', 'send-text', 'w1:p2', 'Read the brief. Task i61-test'], self.calls())
        for prompt in ('Read\nthe brief', 'Read the brief\n\n', 'Read\rthe brief'):
            with self.subTest(prompt=prompt):
                self.log.unlink(missing_ok=True)
                self.prompt.write_text(prompt)
                result = self.run_dispatch()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('one line', result.stderr)
                self.assertEqual(self.calls(), [])


    def test_marker_writer_is_injected_without_timed_git_probes(self):
        result = self.run_dispatch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.repo / 'marker-used').exists())



if __name__ == '__main__':
    unittest.main()
