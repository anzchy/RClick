"""Offline tests of the ui.sh / calibrate.sh command line: exit codes and refusals that happen before any AX,
AppleScript or desktop call. A fake osascript/xcrun/pgrep on PATH records any call; none may happen here."""
import contextlib
import io
import json
import os
import stat
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
import finderui  # noqa: E402

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
        self.windows, self.acted, self.after_act = fixture('dialog-delete-confirm.jsonl'), [], []
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
        if name == 'ps':
            pid = argv[argv.index('-p') + 1]
            line = next((l for l in fixture('process-table.txt').splitlines() if l.split()[0] == pid), '')
            return self.completed(argv, line + '\n' if line else '', 0 if line else 1)
        if name == 'axprobe':
            if argv[1] == 'trusted':
                return self.completed(argv, 'true\n')
            if argv[1] == 'menu-at':
                return self.completed(argv, self.menu)
            if argv[1] == 'dump':
                return self.completed(argv, self.windows)
            if argv[1] == 'act':
                self.acted.append(argv[2:])
                if self.after_act:
                    self.windows = self.after_act.pop(0)
                return self.completed(argv, f'{argv[4]} ok\n')
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

    def test_help_after_a_command_prints_the_usage_once_and_exits_zero(self):
        for script, args in (('calibrate.sh', ('--help',)), ('ui.sh', ('choose', '--help')),
                             ('ui.sh', ('close-menu', '-h'))):
            with self.subTest(script=script, args=args):
                result = self.run_script(script, *args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(result.stdout.startswith('usage: ui.sh COMMAND'), result.stdout[:80])
                self.assertEqual(result.stdout.count('usage:'), 1, result.stdout)
                self.assertIn('calibrate RUN_DIR', result.stdout)
        self.assert_no_desktop_call()

    def test_usage_errors_exit_64_without_touching_the_desktop(self):
        for args in ((), ('bogus',), ('select', 'relative.txt'), ('choose', '620,225', 'Copy Path'),
                     ('grant', 'Finder', '/tmp/x'), ('menu', 'x'),
                     ('choose', '620,225', 'Copy Path', '--target', '/tmp/a', '--group', 'Copy Path')):
            with self.subTest(args=args):
                result = self.run_script('ui.sh', *args)
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertIn('usage error', result.stderr)
        self.assert_no_desktop_call()

    def test_acting_without_the_rclick_gui_lock_exits_70_and_acts_on_nothing(self):
        for args in (('select', '/tmp/a.txt'), ('open-menu', 'alpha.txt'), ('guard', '1,2', '/tmp/a'),
                     ('choose', '1,2', 'Copy Path', '--target', '/tmp/a', '--group', 'Copy Path', '--group', 'New File'),
                     ('press-button', '42', 'OK'),
                     ('grant', '42', '/tmp/x'), ('close-menu',), ('open-menu', '--background')):
            with self.subTest(args=args):
                result = self.run_script('ui.sh', *args)
                self.assertEqual(result.returncode, 70, result.stderr)
                self.assertIn('GUI lock', result.stderr)
        run = Path(self.temp.name) / 'run'
        result = self.run_script('calibrate.sh', str(run), '--group', 'Copy Path', '--group', 'New File',
                                 '--background-group', 'Terminal', '--background-group', 'New File')
        self.assertEqual(result.returncode, 70, result.stderr)
        self.assertFalse(run.exists())
        self.assert_no_desktop_call()

    def test_calibration_dry_run_prints_every_step_and_creates_nothing(self):
        run = Path(self.temp.name) / 'run'
        result = self.run_script('calibrate.sh', str(run), '--dry-run')
        self.assertEqual(result.returncode, 0, result.stderr)
        for step in ('row-order', 'select-readback', 'context-menu', 'menu-read', 'guard', 'choose', 'dialog-read',
                     'press-button', 'panel-grant-row', 'panel-grant-current', 'option-menu', 'background-menu',
                     'background-choose', 'close-menu'):
            self.assertIn(f'step {step}:', result.stdout)
        self.assertIn("NOT covered: RClick's own sandboxed folder panel", result.stdout)
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


class AxprobeCache(unittest.TestCase):
    """axprobe runs with the host terminal's Accessibility trust, so its cached executable must be one only this user
    could have written: a 0700 directory under ~/Library/Caches, lstat-checked before every reuse (audit r1 M1/M6)."""

    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='rclick-axcache-')
        self.addCleanup(temp.cleanup)
        self.home, self.tmpdir = Path(temp.name) / 'home', Path(temp.name) / 'tmp'
        self.home.mkdir()
        self.tmpdir.mkdir()
        self.compiles = []
        for patch in (mock.patch.dict(os.environ, HOME=str(self.home), TMPDIR=str(self.tmpdir)),
                      mock.patch.object(finderdrive, 'run', self.fake_run)):
            patch.start()
            self.addCleanup(patch.stop)

    def fake_run(self, argv, timeout=20):
        argv = [str(a) for a in argv]
        out = Path(argv[argv.index('-o') + 1])
        out.write_text('#!/bin/sh\n')
        self.compiles.append(argv)
        return subprocess.CompletedProcess(argv, 0, '', '')

    def test_compiles_once_into_a_private_cache_under_library_caches(self):
        binary = finderdrive.probe_binary()
        cache = self.home / 'Library' / 'Caches' / 'rclick-axprobe'
        self.assertTrue(binary.is_relative_to(cache), binary)
        self.assertEqual(cache.stat().st_mode & 0o777, 0o700)
        self.assertEqual(binary.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(finderdrive.probe_binary(), binary)
        self.assertEqual(len(self.compiles), 1)
        self.assertEqual(list(self.tmpdir.iterdir()), [])  # $TMPDIR is never used

    def test_a_planted_symlink_to_an_admissible_file_is_refused(self):
        # The link's target passes every other check (same user, regular, 0700), so only lstat refuses it
        # (audit r2 gpt M3: a link to root-owned /bin/sh was refused by the owner check even through os.stat).
        binary = finderdrive.probe_binary()
        admissible = self.home / 'admissible'
        admissible.write_text('#!/bin/sh\n')
        admissible.chmod(0o700)
        binary.unlink()
        binary.symlink_to(admissible)
        with self.assertRaisesRegex(finderdrive.ui.Environment, 'axprobe cache'):
            finderdrive.probe_binary()

    def test_a_binary_owned_by_another_user_is_refused(self):
        binary = finderdrive.probe_binary()
        real_lstat = os.lstat

        def foreign(path, *args, **kwargs):
            info = real_lstat(path, *args, **kwargs)
            if Path(path) != binary:
                return info
            fields = list(info)
            fields[stat.ST_UID] = os.getuid() + 1
            return os.stat_result(fields)

        with mock.patch.object(finderdrive.os, 'lstat', foreign), \
                self.assertRaisesRegex(finderdrive.ui.Environment, 'axprobe cache'):
            finderdrive.probe_binary()

    def test_a_cache_others_can_write_is_refused(self):
        binary = finderdrive.probe_binary()
        for target, mode in ((binary, 0o775), (binary.parent, 0o777), (binary.parent.parent, 0o757)):
            with self.subTest(target=target.name, mode=oct(mode)):
                target.chmod(mode)
                with self.assertRaisesRegex(finderdrive.ui.Environment, 'axprobe cache'):
                    finderdrive.probe_binary()
                target.chmod(0o700)

    def test_a_symlinked_cache_directory_is_refused(self):
        caches = self.home / 'Library' / 'Caches'
        caches.mkdir(parents=True)
        elsewhere = self.home / 'elsewhere'
        elsewhere.mkdir(mode=0o700)
        (caches / 'rclick-axprobe').symlink_to(elsewhere)
        with self.assertRaisesRegex(finderdrive.ui.Environment, 'axprobe cache'):
            finderdrive.probe_binary()

    def test_an_ancestor_link_or_writable_ancestor_is_refused_before_anything_is_written(self):
        # audit r2 gpt M1: ~/Library/Caches linked elsewhere was followed by mkdir(parents=True). Every ancestor the
        # cache relies on (home, ~/Library, ~/Library/Caches) is lstat-checked; nothing is compiled or created.
        for ancestor in ('Library', 'Library/Caches'):
            with self.subTest(link=ancestor):
                self.reset_home()
                elsewhere = self.home.parent / 'elsewhere'
                elsewhere.mkdir(mode=0o700)
                link = self.home / ancestor
                link.parent.mkdir(parents=True, exist_ok=True)
                link.symlink_to(elsewhere)
                with self.assertRaisesRegex(finderdrive.ui.Environment, 'axprobe cache'):
                    finderdrive.probe_binary()
                self.assertEqual((self.compiles, list(elsewhere.iterdir())), ([], []))
        for ancestor, mode in (('', 0o770), ('Library', 0o702), ('Library/Caches', 0o720)):
            with self.subTest(writable=ancestor or 'home', mode=oct(mode)):
                self.reset_home()
                (self.home / 'Library' / 'Caches').mkdir(parents=True, mode=0o700)
                (self.home / ancestor).chmod(mode)
                with self.assertRaisesRegex(finderdrive.ui.Environment, 'axprobe cache'):
                    finderdrive.probe_binary()
                self.assertEqual((self.compiles, list((self.home / 'Library' / 'Caches').iterdir())), ([], []))

    def reset_home(self):
        for path in sorted(self.home.parent.rglob('*'), reverse=True):
            if path != self.tmpdir:
                if path.is_dir() and not path.is_symlink():
                    path.chmod(0o700)
                    path.rmdir()
                else:
                    path.unlink()
        self.home.mkdir(mode=0o700)
        self.compiles.clear()


@unittest.skipUnless(Path('/usr/bin/xcrun').exists(), 'needs the Xcode toolchain (the Mac gate lane has it)')
class AxprobeNeedsTheLock(unittest.TestCase):
    """axprobe's acting commands check the GUI lock themselves (the driver's strict check), so calling the compiled
    helper directly cannot bypass it; the refusal comes before any AX call (audit r1 F4). Compiles the real axprobe
    into a temporary HOME; no AX action is reached."""

    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='rclick-axlock-')
        cls.home = Path(cls.temp.name)
        with mock.patch.dict(os.environ, HOME=str(cls.home)):
            cls.binary = finderdrive.probe_binary()

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def axprobe(self, *args, **env):
        environment = dict(os.environ, HOME=str(self.home), **env)
        for key in LOCK_ENV:
            environment.pop(key, None)
        environment.update(env)
        return subprocess.run([str(self.binary), *args], capture_output=True, text=True, env=environment, timeout=60)

    def acting_calls(self):
        return (('act', str(os.getpid()), '0', 'select', 'AXRow', 'alpha.txt'),
                ('menu-session', '-10000', '-10000', '3'))

    def test_acting_without_the_lock_is_refused_before_any_ax_call(self):
        for args in self.acting_calls():
            with self.subTest(command=args[0]):
                result = self.axprobe(*args)
                self.assertEqual(result.returncode, 70, result.stderr)
                self.assertIn('GUI lock', result.stderr)

    def test_another_projects_lock_is_refused(self):
        lock = self.home / '.cache' / 'desktop-gui.lock'
        lock.mkdir(parents=True)
        self.addCleanup(lambda: (lock / 'owner').unlink() or lock.rmdir())
        (lock / 'owner').write_text(HELD.split('\n', 1)[1].replace('  ', '').replace('project=rclick', 'project=picsee'))
        for args in self.acting_calls():
            with self.subTest(command=args[0]):
                result = self.axprobe(*args, **LOCK_ENV)
                self.assertEqual(result.returncode, 70, result.stderr)
                self.assertIn("project 'picsee'", result.stderr)


class PressOnlyInAllowedProcesses(unittest.TestCase):
    """`press-button` acts only in an allowed process (finderui.allowed_process); the RClick pid comes from
    $RUN_DIR/rclick.pid (audit r1 opus M3)."""

    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='rclick-run-')
        self.addCleanup(temp.cleanup)
        self.run_dir = Path(temp.name)
        (self.run_dir / 'rclick.pid').write_text('28075\n')

    def press(self, pid):
        desktop = FakeDesktop(fixture('menu-file-alpha.jsonl'), [])
        with mock.patch.dict(os.environ, RUN_DIR=str(self.run_dir)):
            code, out, err = drive(desktop, 'press-button', str(pid), 'Cancel', '--window-text', 'Permanently delete')
        return code, err, desktop

    def test_the_rclick_pid_of_this_run_is_pressed(self):
        code, err, desktop = self.press(28075)
        self.assertEqual(code, 0, err)
        self.assertEqual(desktop.acted, [['28075', '0.3', 'press', 'AXButton', 'Cancel']])

    def test_a_privacy_prompt_or_another_app_is_never_pressed(self):
        for pid in (92997, 3610, 562, 60606):
            with self.subTest(pid=pid):
                code, err, desktop = self.press(pid)
                self.assertEqual(code, 65, err)
                self.assertEqual(desktop.acted, [])
                self.assertNotIn(['dump'], [call[1:2] for call in desktop.calls if Path(call[0]).name == 'axprobe'])


class GrantByFullPath(unittest.TestCase):
    """`grant` through finderdrive.main: the full path is established before anything is selected, and the selection
    is read again before the button is pressed (audit r1 F3). The panel structure is ASSUMED (fixtures/README.md)."""

    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='rclick-run-')
        self.addCleanup(temp.cleanup)
        self.run_dir = Path(temp.name)
        (self.run_dir / 'rclick.pid').write_text('28075\n')
        self.panel = fixture('panel-grant.jsonl')

    def with_selected(self, *paths):
        lines = []
        for line in self.panel.splitlines():
            node = json.loads(line)
            if node['role'] == 'AXRow':
                node['selected'] = node['path'] in [list(p) for p in paths]
            lines.append(json.dumps(node, ensure_ascii=False))
        return '\n'.join(lines) + '\n'

    def grant(self, desktop, pid, folder):
        desktop.windows = self.panel
        with mock.patch.dict(os.environ, RUN_DIR=str(self.run_dir)):
            return drive(desktop, 'grant', str(pid), folder)

    def test_the_target_row_is_selected_read_back_and_granted(self):
        desktop = FakeDesktop('', [])
        desktop.after_act = [self.with_selected((0, 0, 1, 0, 0)), '']
        code, out, err = self.grant(desktop, 28075, '/tmp/run/fixtures/rclick-cal')
        self.assertEqual(code, 0, err)
        self.assertEqual([call[2] for call in desktop.acted], ['select', 'press'])
        self.assertIn('granted: /tmp/run/fixtures/rclick-cal (row mode; verified', out)

    def test_an_equal_basename_elsewhere_selects_and_presses_nothing(self):
        desktop = FakeDesktop('', [])
        code, _, err = self.grant(desktop, 28075, '/tmp/other/fixtures/rclick-cal')
        self.assertEqual(code, 65, err)
        self.assertEqual(desktop.acted, [])

    def test_another_row_selected_after_the_select_is_not_pressed(self):
        desktop = FakeDesktop('', [])
        desktop.after_act = [self.with_selected((0, 0, 1, 0, 2))]
        code, _, err = self.grant(desktop, 28075, '/tmp/run/fixtures/rclick-cal')
        self.assertEqual(code, 65, err)
        self.assertEqual([call[2] for call in desktop.acted], ['select'])

    def test_a_panel_in_a_process_that_is_not_allowed_is_not_touched(self):
        desktop = FakeDesktop('', [])
        code, _, err = self.grant(desktop, 92997, '/tmp/run/fixtures/rclick-cal')
        self.assertEqual(code, 65, err)
        self.assertEqual(desktop.acted, [])


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
        # axprobe.swift is compiled as main.swift with the generated driver.swift (finderdrive.probe_binary).
        with tempfile.TemporaryDirectory(prefix='rclick-axcheck-') as build:
            (Path(build) / 'main.swift').write_bytes((HERE / 'axprobe.swift').read_bytes())
            (Path(build) / 'driver.swift').write_text('let driverScript = "finderdrive.py"\n')
            result = subprocess.run(['/usr/bin/xcrun', 'swiftc', '-typecheck', str(Path(build) / 'main.swift'),
                                     str(Path(build) / 'driver.swift')], capture_output=True, text=True, timeout=300)
        self.assertEqual(result.returncode, 0, result.stderr)


class CloseMenuAndBackground(unittest.TestCase):
    """`ui.sh close-menu` (Esc only while Finder is frontmost, under the lock: audit r1 L4) and `ui.sh open-menu
    --background` (right-click the empty list below the rows, nothing selected: audit r1 F10)."""

    def desktop(self, frontmost=True, selection=()):
        window = fixture('finder-window-display-order.jsonl')
        hidden = [json.loads(l) for l in window.splitlines() if l.strip()]
        hidden = next(n['path'] for n in hidden if n['role'] == 'AXRow' and n['frame'][1] == 890)
        lines = [l for l in window.splitlines() if l.strip() and json.loads(l)['path'][:len(hidden)] != hidden]
        desktop = FakeDesktop(fixture('menu-file-alpha.jsonl'), selection)
        desktop.windows = '\n'.join(lines) + '\n'
        desktop.frontmost = frontmost
        desktop.clicks = []
        original = desktop.run

        def run(argv, timeout=20):
            argv = [str(a) for a in argv]
            if Path(argv[0]).name == 'rightclick.sh':
                desktop.calls.append(argv)
                desktop.clicks.append(argv[1:])
                return desktop.completed(argv, 'right-clicked\n')
            if Path(argv[0]).name == 'osascript' and 'key code 53' in argv[2]:
                desktop.calls.append(argv)
                return desktop.completed(argv, 'escaped\n' if desktop.frontmost else 'skipped: Finder is not frontmost\n')
            return original(argv, timeout)
        desktop.run = run
        return desktop

    def escapes(self, desktop):
        return [c for c in desktop.calls if c[0] == 'osascript' and 'key code 53' in c[2]]

    def test_close_menu_sends_esc_through_the_frontmost_check(self):
        desktop = self.desktop()
        code, out, err = drive(desktop, 'close-menu')
        self.assertEqual(code, 0, err)
        self.assertEqual(len(self.escapes(desktop)), 1)
        self.assertIn('frontmost is true', self.escapes(desktop)[0][2])
        self.assertIn('escaped', out)

    def test_close_menu_refuses_when_finder_is_not_frontmost(self):
        desktop = self.desktop(frontmost=False)
        code, _, err = drive(desktop, 'close-menu')
        self.assertEqual(code, 65, err)
        self.assertIn('not frontmost', err)

    def test_open_menu_background_right_clicks_below_the_rows(self):
        desktop = self.desktop()
        code, out, err = drive(desktop, 'open-menu', '--background')
        self.assertEqual(code, 0, err)
        self.assertEqual(len(desktop.clicks), 1)
        x, y = map(int, desktop.clicks[0][:2])
        self.assertGreater(y, 295)  # below the lowest row (275 + 20)
        self.assertGreater(x, 480)  # right of the sidebar
        self.assertIn('menu-point ', out)

    def test_open_menu_background_with_a_selection_left_clicks_nothing(self):
        desktop = self.desktop(selection=[DIR + '/alpha.txt'])
        code, _, err = drive(desktop, 'open-menu', '--background')
        self.assertEqual(code, 65, err)
        self.assertEqual(desktop.clicks, [])

    def test_open_menu_needs_a_name_or_background_not_both(self):
        for argv in (['open-menu'], ['open-menu', 'alpha.txt', '--background']):
            with self.subTest(argv=argv), self.assertRaises(finderui.Usage):
                finderui.parse_args(argv)


if __name__ == '__main__':
    unittest.main()
