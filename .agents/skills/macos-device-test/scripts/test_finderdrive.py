"""Offline tests of the ui.sh / calibrate.sh command line: exit codes and refusals that happen before any AX,
AppleScript or desktop call. A fake osascript/xcrun/pgrep on PATH records any call; none may happen here."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SKILL = HERE.parent
TRAP = '#!/bin/sh\necho "$0 $*" >> "$TRAP_LOG"\nexit 99\n'


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
                     ('choose', '1,2', 'Copy Path', '--target', '/tmp/a'), ('press-button', '42', 'OK'),
                     ('grant', '42', '/tmp/x')):
            with self.subTest(args=args):
                result = self.run_script('ui.sh', *args)
                self.assertEqual(result.returncode, 70, result.stderr)
                self.assertIn('GUI lock', result.stderr)
        run = Path(self.temp.name) / 'run'
        result = self.run_script('calibrate.sh', str(run))
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
