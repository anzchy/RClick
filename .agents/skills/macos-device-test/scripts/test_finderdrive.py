"""Offline tests of the ui.sh / calibrate.sh command line: exit codes and refusals that happen before any AX,
AppleScript or desktop call. A fake osascript/xcrun/pgrep on PATH records any call; none may happen here."""
import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
SKILL = HERE.parent
TRAP = '#!/bin/sh\necho "$0 $*" >> "$TRAP_LOG"\nexit 99\n'
sys.path.insert(0, str(HERE))
import finderdrive  # noqa: E402

FIXTURES = HERE / 'fixtures'
DIR = '/tmp/rclick-cal'
ACQUISITION = '0b6f2c1e-8d3a-4f5b-9c7d-1e2f3a4b5c6d'
LOCK_ENV = {'RCLICK_GUI_LOCK_BATCH': 'i32-cal', 'RCLICK_GUI_LOCK_ACQUISITION_ID': ACQUISITION}
HELD = ('HELD:\n  project=rclick\n  session=rclick-delegator\n  batch=i32-cal\n  start=2026-11-18T01:00:00+0800\n'
        '  pid=4242\n  expected_minutes=30\n  purpose=device run\n  acquisition_id=' + ACQUISITION + '\n')
FINDER = 415
GROUP = ('--group', 'Copy Path', '--group', 'Copy File Name', '--group', 'Delete Direct', '--group', 'Terminal',
         '--group', 'New File')


def fixture(name):
    return (FIXTURES / name).read_text(encoding='utf-8')


def top_titles(menu_text):
    nodes = [json.loads(line) for line in menu_text.splitlines() if line.strip()]
    return [node['title'] for node in sorted(nodes, key=lambda n: n['path']) if len(node['path']) == 1]


class FakeDesktop:
    """The process boundary of finderdrive (`run`, `spawn`) answered offline: gui-lock.sh, pgrep, osascript and
    axprobe. An axprobe menu session answers a press the way axprobe.swift does: it compares the request's owner pid
    and full top-level title list with the menu that is open NOW and exits 65 (nothing pressed) on a difference."""

    def __init__(self, menu, selection, front=DIR, menu_pid=FINDER):
        self.menu, self.selection, self.front, self.menu_pid = menu, list(selection), front, menu_pid
        self.calls, self.requests, self.pressed = [], [], []
        self.menu_at_press = None  # the menu open when the press arrives (None: unchanged)
        self.selection_at_check = None

    def completed(self, argv, out='', code=0, err=''):
        return subprocess.CompletedProcess(argv, code, out, err)

    def run(self, argv, timeout=20):
        argv = [str(a) for a in argv]
        name = Path(argv[0]).name
        self.calls.append(argv)
        if name == 'gui-lock.sh':
            return self.completed(argv, HELD)
        if name == 'pgrep':
            return self.completed(argv, f'{FINDER}\n')
        if name == 'axprobe':
            if argv[1] == 'trusted':
                return self.completed(argv, 'true\n')
            if argv[1] == 'menu-at':
                return self.completed(argv, self.menu)
            return self.completed(argv, '', 64, f'fake axprobe: {argv[1]} not expected')
        if name == 'osascript':
            script = argv[2]
            if 'selection as alias list' in script:
                paths = self.selection if self.selection_at_check is None else self.selection_at_check
                return self.completed(argv, f'{len(paths)}\n' + ''.join(p + '\n' for p in paths) + '\n')
            if 'front Finder window' in script:
                return self.completed(argv, self.front + '/\n')
            return self.completed(argv, '\n')
        return self.completed(argv, '', 99, f'fake desktop: unexpected {name}')

    def spawn(self, argv):
        argv = [str(a) for a in argv]
        self.calls.append(argv)
        return FakeSession(self, argv)


class FakeSession:
    def __init__(self, desktop, argv):
        self.desktop, self.returncode = desktop, None
        lines = [json.dumps({'session': {'pid': desktop.menu_pid}})] + [
            line for line in desktop.menu.splitlines() if line.strip()] + [json.dumps({'end': True})]
        self.stdout = io.BytesIO(('\n'.join(lines) + '\n').encode())

    def communicate(self, input=None, timeout=None):
        request = json.loads(input.decode())
        self.desktop.requests.append(request)
        if 'abort' in request:
            self.returncode = 0
            return b'aborted\n', b''
        now = self.desktop.menu_at_press or self.desktop.menu
        if request.get('pid') != self.desktop.menu_pid or request.get('titles') != top_titles(now):
            self.returncode = 65
            return b'', b'axprobe: the menu changed since it was verified: nothing pressed\n'
        self.desktop.pressed.append(request)
        self.returncode = 0
        return b'press ok\n', b''

    def kill(self):
        self.returncode = -9

    def wait(self, timeout=None):
        return self.returncode


def drive(desktop, *argv):
    """finderdrive.main with only the process boundary replaced; returns (exit code, stdout, stderr)."""
    out, err = io.StringIO(), io.StringIO()
    with mock.patch.dict(os.environ, LOCK_ENV), mock.patch.object(finderdrive, 'run', desktop.run), \
            mock.patch.object(finderdrive, 'spawn', desktop.spawn, create=True), \
            mock.patch.object(finderdrive, 'probe_binary', lambda: Path('/fake/axprobe')), \
            mock.patch.object(finderdrive.time, 'sleep', lambda seconds: None), \
            contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = finderdrive.main(list(argv))
    return code, out.getvalue(), err.getvalue()


class ChooseAtTheActingBoundary(unittest.TestCase):
    """`choose` decides and presses inside ONE axprobe menu session: the press request carries the verified owner pid
    and title list, and the selection is read again inside that session (audit r1 F2)."""
    ALPHA = DIR + '/alpha.txt'

    def test_a_verified_menu_is_pressed_with_its_identity(self):
        desktop = FakeDesktop(fixture('menu-file-alpha.jsonl'), [self.ALPHA])
        code, out, err = drive(desktop, 'choose', '660,237', 'Copy Path', '--target', self.ALPHA, *GROUP)
        self.assertEqual(code, 0, err)
        self.assertEqual(len(desktop.pressed), 1)
        request = desktop.pressed[0]
        self.assertEqual((request['press'], request['title'], request['pid']), ([27], 'Copy Path', FINDER))
        self.assertEqual(request['titles'], top_titles(fixture('menu-file-alpha.jsonl')))
        self.assertIn('chose: Copy Path', out)

    def test_a_menu_replaced_by_the_siblings_before_the_press_is_not_pressed(self):
        desktop = FakeDesktop(fixture('menu-file-alpha.jsonl'), [self.ALPHA])
        desktop.menu_at_press = fixture('menu-file-sibling-option.jsonl')  # same Copy Path at the same index
        code, _, err = drive(desktop, 'choose', '660,237', 'Copy Path', '--target', self.ALPHA, *GROUP)
        self.assertEqual(code, 65, err)
        self.assertEqual(desktop.pressed, [])
        self.assertIn('nothing pressed', err)

    def test_a_guard_pass_does_not_carry_over_to_a_later_choose(self):
        desktop = FakeDesktop(fixture('menu-file-alpha.jsonl'), [self.ALPHA])
        self.assertEqual(drive(desktop, 'guard', '660,237', self.ALPHA)[0], 0)
        desktop.menu = fixture('menu-file-sibling-option.jsonl')  # another row's menu now at the point
        code, _, err = drive(desktop, 'choose', '660,237', 'Copy Path', '--target', self.ALPHA, *GROUP)
        self.assertEqual(code, 65, err)
        self.assertEqual(desktop.pressed, [])

    def test_a_selection_changed_inside_the_session_is_not_pressed(self):
        desktop = FakeDesktop(fixture('menu-file-alpha.jsonl'), [self.ALPHA])
        desktop.selection_at_check = [DIR + '/%41.txt']
        code, _, err = drive(desktop, 'choose', '660,237', 'Copy Path', '--target', self.ALPHA, *GROUP)
        self.assertEqual(code, 65, err)
        self.assertEqual(desktop.pressed, [])
        self.assertIn('selection', err)

    def test_a_menu_owned_by_another_process_is_not_pressed(self):
        desktop = FakeDesktop(fixture('menu-file-alpha.jsonl'), [self.ALPHA], menu_pid=999)
        code, _, err = drive(desktop, 'choose', '660,237', 'Copy Path', '--target', self.ALPHA, *GROUP)
        self.assertEqual(code, 65, err)
        self.assertEqual(desktop.pressed, [])
        self.assertIn('not Finder', err)


class CommandLine(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='rclick-ui-')
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        self.bin, self.home, self.log = base / 'bin', base / 'home', base / 'calls.log'
        self.bin.mkdir()
        self.home.mkdir()
        for tool in ('osascript', 'xcrun', 'pgrep', 'swiftc', 'open'):
            (self.bin / tool).write_text(TRAP)
            (self.bin / tool).chmod(0o755)

    def run_script(self, script, *args):
        env = dict(os.environ, PATH=f'{self.bin}:/usr/bin:/bin', HOME=str(self.home), TRAP_LOG=str(self.log))
        return subprocess.run([str(HERE / script), *args], capture_output=True, text=True, env=env, timeout=60)

    def assert_no_desktop_call(self):
        self.assertFalse(self.log.exists(), self.log.read_text() if self.log.exists() else '')

    def test_help_lists_every_command_and_the_exit_codes(self):
        result = self.run_script('ui.sh', '--help')
        self.assertEqual(result.returncode, 0, result.stderr)
        for word in ('rows', 'select PATH', 'open-menu NAME', 'menu X,Y', 'guard X,Y', 'choose X,Y', 'dialog PID',
                     'press-button PID', 'grant PID FOLDER', '64 usage', '65 refused', '70 environment'):
            self.assertIn(word, result.stdout)
        self.assert_no_desktop_call()

    def test_usage_errors_exit_64_without_touching_the_desktop(self):
        for args in ((), ('bogus',), ('select', 'relative.txt'), ('choose', '620,225', 'Copy Path'),
                     ('grant', 'Finder', '/tmp/x'), ('menu', 'x')):
            with self.subTest(args=args):
                result = self.run_script('ui.sh', *args)
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertIn('usage error', result.stderr)
        self.assert_no_desktop_call()

    def test_acting_without_the_rclick_gui_lock_exits_70_and_acts_on_nothing(self):
        for args in (('select', '/tmp/a.txt'), ('open-menu', 'alpha.txt'), ('guard', '1,2', '/tmp/a'),
                     ('choose', '1,2', 'Copy Path', '--target', '/tmp/a', '--group', 'Copy Path'), ('press-button', '42', 'OK'),
                     ('grant', '42', '/tmp/x')):
            with self.subTest(args=args):
                result = self.run_script('ui.sh', *args)
                self.assertEqual(result.returncode, 70, result.stderr)
                self.assertIn('GUI lock', result.stderr)
        run = Path(self.temp.name) / 'run'
        result = self.run_script('calibrate.sh', str(run), '--group', 'Copy Path')
        self.assertEqual(result.returncode, 70, result.stderr)
        self.assertFalse(run.exists())
        self.assert_no_desktop_call()

    def test_calibration_dry_run_prints_every_step_and_creates_nothing(self):
        run = Path(self.temp.name) / 'run'
        result = self.run_script('calibrate.sh', str(run), '--dry-run')
        self.assertEqual(result.returncode, 0, result.stderr)
        for step in ('row-order', 'select-readback', 'context-menu', 'menu-read', 'guard', 'choose', 'dialog-read',
                     'press-button', 'panel-grant-row', 'panel-grant-current'):
            self.assertIn(f'step {step}:', result.stdout)
        self.assertFalse(run.exists())
        self.assertEqual(self.run_script('calibrate.sh', 'relative-run', '--dry-run').returncode, 64)
        self.assert_no_desktop_call()


class WhitespaceIsIdentity(unittest.TestCase):
    """`alpha.txt` and `alpha.txt ` are distinct files; neither the guard nor the press may take one for the other
    (audit r1 F1). Driven through finderdrive.main with the process boundary replaced."""
    ALPHA, SPACED = DIR + '/alpha.txt', DIR + '/alpha.txt '

    def two_items_menu(self):
        return fixture('menu-file-alpha.jsonl').replace('Compress “alpha.txt”', 'Compress 2 Items')

    def test_choose_with_the_spaced_target_on_the_unspaced_selection_presses_nothing(self):
        desktop = FakeDesktop(fixture('menu-file-alpha.jsonl'), [self.ALPHA])
        code, _, err = drive(desktop, 'choose', '660,237', 'Delete Direct', '--target', self.SPACED, *GROUP)
        self.assertEqual(code, 65, err)
        self.assertEqual(desktop.pressed, [])
        self.assertEqual(desktop.requests, [{'abort': True}])

    def test_choose_with_n_targets_compares_each_path_exactly(self):
        desktop = FakeDesktop(self.two_items_menu(), [self.ALPHA, DIR + '/b.txt'])
        code, _, err = drive(desktop, 'choose', '660,237', 'Delete Direct', '--target', self.SPACED,
                             '--target', DIR + '/b.txt', *GROUP)
        self.assertEqual(code, 65, err)
        self.assertEqual(desktop.pressed, [])

    def test_guard_refuses_the_spaced_target(self):
        desktop = FakeDesktop(fixture('menu-file-alpha.jsonl'), [self.ALPHA])
        code, _, err = drive(desktop, 'guard', '660,237', self.SPACED)
        self.assertEqual(code, 65, err)

    def test_a_spaced_name_round_trips_and_is_pressed(self):
        menu = fixture('menu-file-alpha.jsonl').replace('Compress “alpha.txt”', 'Compress “alpha.txt ”')
        desktop = FakeDesktop(menu, [self.SPACED])
        code, out, err = drive(desktop, 'choose', '660,237', 'Copy Path', '--target', self.SPACED, *GROUP)
        self.assertEqual(code, 0, err)
        self.assertIn("'/tmp/rclick-cal/alpha.txt '", out)
        self.assertEqual(len(desktop.pressed), 1)

    def test_a_selected_path_with_a_line_break_is_refused(self):
        desktop = FakeDesktop(fixture('menu-file-alpha.jsonl'), [DIR + '/alpha\n.txt'])
        code, _, err = drive(desktop, 'choose', '660,237', 'Copy Path', '--target', self.ALPHA, *GROUP)
        self.assertEqual(code, 65, err)
        self.assertEqual(desktop.pressed, [])


class Source(unittest.TestCase):
    def test_no_personal_path_in_the_skill(self):
        marker = '/' + 'Users' + '/'  # split so this file does not match itself
        home = str(Path.home())
        for path in SKILL.rglob('*'):
            if path.is_file() and '__pycache__' not in path.parts:
                text = path.read_text(encoding='utf-8', errors='replace')
                with self.subTest(path=path.relative_to(SKILL)):
                    self.assertNotIn(marker, text)
                    if len(home) > 1:
                        self.assertNotIn(home, text)

    @unittest.skipUnless(Path('/usr/bin/xcrun').exists(), 'needs the Xcode toolchain (the Mac gate lane has it)')
    def test_axprobe_type_checks(self):
        result = subprocess.run(['/usr/bin/xcrun', 'swiftc', '-typecheck', str(HERE / 'axprobe.swift')],
                                capture_output=True, text=True, timeout=300)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
