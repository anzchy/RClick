"""Offline tests of the calibration's fixture folder (calibration.Fixture): exclusive allocation under
$RUN_DIR/fixtures/, and a cleanup that removes only what this invocation created (audit r1 M2). No desktop call."""
import contextlib
import io
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import calibration  # noqa: E402
import finderdrive  # noqa: E402
import finderui  # noqa: E402

FILES = ('alpha.txt', 'beta.txt', 'folder a/inner.txt')


class Fixture(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='rclick-cal-run-')
        self.addCleanup(temp.cleanup)
        self.run = Path(temp.name)

    def test_two_invocations_in_the_same_second_get_their_own_folders(self):
        first, second = calibration.Fixture(self.run), calibration.Fixture(self.run)
        self.assertNotEqual(first.folder, second.folder)
        first.create(FILES)
        second.create(FILES)
        self.assertEqual(first.remove(), [])
        self.assertTrue((second.folder / 'alpha.txt').is_file())
        self.assertEqual(second.remove(), [])
        self.assertEqual(list((self.run / 'fixtures').iterdir()), [])

    def test_an_existing_folder_and_its_files_are_never_touched(self):
        earlier = self.run / 'fixtures' / 'calibration-earlier'
        earlier.mkdir(parents=True)
        (earlier / 'alpha.txt').write_text('keep\n')
        fixture = calibration.Fixture(self.run)
        fixture.create(FILES)
        fixture.remove()
        self.assertEqual((earlier / 'alpha.txt').read_text(), 'keep\n')

    def test_a_file_this_invocation_did_not_create_is_left_with_a_note(self):
        fixture = calibration.Fixture(self.run)
        fixture.create(FILES)
        (fixture.folder / 'foreign.txt').write_text('not ours\n')
        notes = fixture.remove()
        self.assertTrue((fixture.folder / 'foreign.txt').is_file())
        self.assertFalse((fixture.folder / 'alpha.txt').exists())
        self.assertEqual(len(notes), 1)
        self.assertIn(str(fixture.folder), notes[0])

    def test_a_name_that_already_exists_is_refused_not_overwritten(self):
        fixture = calibration.Fixture(self.run)
        (fixture.folder / 'alpha.txt').write_text('planted\n')
        with self.assertRaises(finderui.Refused):
            fixture.create(FILES)
        fixture.remove()
        self.assertEqual((fixture.folder / 'alpha.txt').read_text(), 'planted\n')

    def test_a_symlinked_fixtures_directory_is_refused(self):
        elsewhere = self.run / 'elsewhere'
        elsewhere.mkdir()
        (self.run / 'fixtures').symlink_to(elsewhere)
        with self.assertRaises(finderui.Environment):
            calibration.Fixture(self.run)
        self.assertEqual(list(elsewhere.iterdir()), [])

    def test_only_a_regular_file_directly_in_the_folder_can_be_adopted(self):
        fixture = calibration.Fixture(self.run)
        fixture.create(FILES)
        (fixture.folder / 'untitled.txt').write_text('')
        fixture.adopt(fixture.folder / 'untitled.txt')
        (fixture.folder / 'link.txt').symlink_to(self.run)
        for path in (fixture.folder / 'link.txt', self.run / 'outside.txt', fixture.folder / 'folder a' / 'inner.txt'):
            with self.subTest(path=path.name), self.assertRaises(finderui.Refused):
                fixture.adopt(path)
        (fixture.folder / 'link.txt').unlink()
        self.assertEqual(fixture.remove(), [])
        self.assertFalse(fixture.folder.exists())


GROUP = ['Copy Path', 'Copy File Name', 'Delete Direct', 'Terminal', 'New File']
BACKGROUND = ['Terminal', 'New File', 'Common Dirs']
LISTING = ('1|Open|true|660,237|0\n2|Get Info|true|660,259|0\n9|Copy Path|true|660,400|0\n'
           '10|Copy File Name|true|660,422|0\n11|Delete Direct{suffix}|true|660,444|0\n12|Terminal|true|660,466|0\n'
           '13|New File|true|660,488|9\ncompress: Compress \u201c%2541.txt\u201d\n'
           'rclick-group (expected): found once at items 9..13\n')


class FakeCli:
    """The calibration's process boundary (finderdrive.run) answered offline: every `ui.sh COMMAND` the calibration
    runs is recorded with its arguments and answered by `answers[COMMAND]` (exit code, stdout, stderr); any other
    process is answered by `other`."""

    def __init__(self, answers, other=None):
        self.answers, self.other, self.calls = answers, other or {}, []

    def run(self, argv, timeout=20):
        argv = [str(a) for a in argv]
        self.calls.append(argv)
        if Path(argv[0]).name == 'ui.sh':
            code, out, err = self.answers[argv[1]](argv[2:]) if callable(self.answers[argv[1]]) else self.answers[argv[1]]
            return subprocess.CompletedProcess(argv, code, out, err)
        code, out = self.other.get(Path(argv[0]).name, (99, ''))
        return subprocess.CompletedProcess(argv, code, out, '')

    def ui(self, command):
        return [call[2:] for call in self.calls if Path(call[0]).name == 'ui.sh' and call[1] == command]


class StepsDriveTheRealCli(unittest.TestCase):
    """The calibration proves the ui.sh command lines a device run uses (audit r1 F10): `ui.sh choose` for one and for
    several targets, the Option, background, submenu and close-menu paths each have a step; every menu a step opens
    is closed with `ui.sh close-menu X,Y` (fix r3 items 5 and 7)."""

    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='rclick-cal-run-')
        self.addCleanup(temp.cleanup)
        self.run = calibration.Run(temp.name, GROUP, BACKGROUND)
        self.run.fixture = calibration.Fixture(self.run.run)
        self.run.folder = self.run.fixture.folder
        self.run.fixture.create(calibration.FILES)
        self.run.point = (700, 300)
        self.addCleanup(self.run.fixture.remove)
        patcher = mock.patch.object(calibration.time, 'sleep', lambda seconds: None)
        patcher.start()
        self.addCleanup(patcher.stop)

    def step(self, cli, action):
        with mock.patch.object(finderdrive, 'run', cli.run):
            return action()

    def test_the_close_menu_step_runs_ui_sh_close_menu_on_the_menu_point_and_reads_no_menu(self):
        cli = FakeCli({'close-menu': (0, 'closed (AXCancel)\n', '')})
        with mock.patch.object(finderdrive, 'menu_open', return_value=False):
            self.step(cli, self.run.close_menu)
        self.assertEqual(cli.ui('close-menu'), [['700,300']])
        with mock.patch.object(finderdrive, 'menu_open', return_value=True), self.assertRaises(finderui.Refused):
            self.step(cli, self.run.close_menu)

    def test_the_choose_step_runs_one_ui_sh_choose_and_reads_the_pasteboard(self):
        alpha = self.run.path('alpha.txt')
        cli = FakeCli({'choose': (0, 'GUARD PASS — ok\nchose: Copy Path\n', '')}, other={'pbpaste': (0, alpha)})
        self.step(cli, self.run.choose)
        self.assertEqual(cli.ui('choose'), [['Copy Path', *sum((['--group', t] for t in GROUP), []), '--target', alpha]])
        self.assertEqual(cli.ui('open-menu'), [])

    def test_the_multi_step_needs_the_count_title_and_both_paths(self):
        paths = [self.run.path('%41.txt'), self.run.path('%2541.txt')]
        cli = FakeCli({'choose': (0, 'GUARD PASS — Compress 2 Items and selection\nchose: Copy Path\n', '')},
                      other={'pbpaste': (0, '\n'.join(reversed(paths)))})
        self.step(cli, self.run.choose_multi)
        self.assertEqual(cli.ui('choose')[0][-4:], ['--target', paths[0], '--target', paths[1]])
        cli = FakeCli({'choose': (0, 'GUARD PASS — ok\n', '')}, other={'pbpaste': (0, '\n'.join(paths))})
        with self.assertRaises(finderui.Refused):
            self.step(cli, self.run.choose_multi)
        cli = FakeCli({'choose': (0, 'GUARD PASS — Compress 2 Items\n', '')}, other={'pbpaste': (0, paths[0])})
        with self.assertRaises(finderui.Refused):
            self.step(cli, self.run.choose_multi)

    def test_the_option_step_reads_the_skip_confirmation_title_and_closes_the_menu(self):
        cli = FakeCli({'open-menu': (0, 'menu-point 700,300\n', ''),
                       'menu': (0, LISTING.format(suffix=' (skip confirmation)'), ''), 'close-menu': (0, 'closed\n', '')})
        detail = self.step(cli, self.run.option_menu)
        self.assertEqual(cli.ui('open-menu'), [['%2541.txt', '--option']])
        self.assertEqual(cli.ui('menu'), [['700,300', *sum((['--group', t] for t in GROUP), [])]])
        self.assertEqual(cli.ui('close-menu'), [['700,300']])
        self.assertIn('Delete Direct (skip confirmation)', detail)

    def test_an_option_menu_without_the_changed_title_fails(self):
        cli = FakeCli({'open-menu': (0, 'menu-point 700,300\n', ''), 'menu': (0, LISTING.format(suffix=''), ''),
                       'close-menu': (0, 'closed\n', '')})
        with self.assertRaises(finderui.Refused):
            self.step(cli, self.run.option_menu)

    def test_the_background_step_reads_the_group_and_closes_the_menu(self):
        cli = FakeCli({'open-menu': (0, 'menu-point 800,500\n', ''), 'close-menu': (0, 'closed\n', ''),
                       'menu': (0, 'rclick-group (expected): found once at items 20..22\n', '')})
        self.step(cli, self.run.background_menu)
        self.assertEqual(cli.ui('open-menu'), [['--background']])
        self.assertEqual(cli.ui('menu'), [['800,500', *sum((['--group', t] for t in BACKGROUND), [])]])
        self.assertEqual(cli.ui('close-menu'), [['800,500']])

    def test_a_background_menu_without_rclicks_group_fails_and_is_still_closed(self):
        cli = FakeCli({'open-menu': (0, 'menu-point 800,500\n', ''), 'menu': (65, '', 'REFUSED: group\n'),
                       'close-menu': (0, 'closed\n', '')})
        with self.assertRaises(finderui.Refused):
            self.step(cli, self.run.background_menu)
        self.assertEqual(cli.ui('close-menu'), [['800,500']])

    def test_background_choose_presses_new_file_txt_and_adopts_the_new_file(self):
        def choose(args):
            (self.run.folder / 'untitled.txt').write_text('')
            return 0, 'GUARD PASS — bg\nchose: New File → TXT\n', ''
        cli = FakeCli({'choose': choose})
        detail = self.step(cli, self.run.background_choose)
        self.assertEqual(cli.ui('choose'), [['New File', '--sub', 'TXT', *sum((['--group', t] for t in BACKGROUND), []),
                                             '--background', str(self.run.folder)]])
        self.assertIn('untitled.txt', detail)
        self.assertEqual(self.run.fixture.remove(), [])
        self.assertFalse(self.run.folder.exists())

    def test_background_choose_with_no_new_file_and_no_rclick_panel_fails(self):
        cli = FakeCli({'choose': (0, 'chose: New File\n', '')})
        with mock.patch.object(finderdrive, 'app_nodes', side_effect=finderui.Environment('no RClick')), \
                self.assertRaises(finderui.Refused):
            self.step(cli, self.run.background_choose)

    def test_background_choose_that_raises_rclicks_folder_panel_cancels_it(self):
        (self.run.run / 'rclick.pid').write_text('4242\n')
        panel = finderui.parse_dump((HERE / 'fixtures' / 'panel-grant.jsonl').read_text(encoding='utf-8'))
        cli = FakeCli({'choose': (0, 'chose: New File\n', '')})
        with mock.patch.object(finderdrive, 'app_nodes', return_value=panel) as nodes, \
                mock.patch.object(finderdrive, 'app_dump', return_value=''), \
                mock.patch.object(finderdrive, 'press_button') as press:
            detail = self.step(cli, self.run.background_choose)
        self.assertEqual(nodes.call_args.args[0], 4242)
        press.assert_called_once_with(4242, 'Cancel', window_text=None)
        self.assertIn('Cancel', detail)


STEP_METHODS = ('row_order', 'select_readback', 'context_menu', 'menu_read', 'rclick_group', 'close_menu', 'choose',
                'choose_multi', 'option_menu', 'background_menu', 'background_choose', 'dialog_read', 'press_button')


class TeardownAlwaysCleans(unittest.TestCase):
    """calibrate() removes its own fixture and prints the report on every failure path (audit r2 gpt M2 / opus L2): a
    transport error (osascript timed out or missing: finderui.Environment) while closing an open menu, closing the
    fixture window, stopping the calibration's osascript or removing the fixture is kept as a note, and never skips the other
    teardown calls or the report. The steps themselves are stubbed; no desktop call is made."""

    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='rclick-cal-run-')
        self.addCleanup(temp.cleanup)
        self.run_dir = Path(temp.name).resolve()  # device.run_dir resolves /var → /private/var
        self.fail_on = set()
        self.calls, self.scripts = [], []
        patches = [mock.patch.dict(os.environ, {}, clear=False),
                   mock.patch.object(calibration.time, 'sleep', lambda seconds: None),
                   mock.patch.object(finderdrive, 'require_lock', lambda: None),
                   mock.patch.object(finderdrive, 'probe_binary', lambda: Path('/usr/bin/true')),
                   mock.patch.object(finderdrive, 'require_trust', lambda: None),
                   mock.patch.object(finderdrive, 'run', self.fake_run),
                   mock.patch.object(finderdrive, 'osascript', self.fake_osascript),
                   mock.patch.object(finderdrive, 'close_menu', self.fake_close_menu),
                   mock.patch.object(calibration.Run, 'panel', lambda run, target, mode: 'stub')]
        patches += [mock.patch.object(calibration.Run, name, lambda run: 'stub') for name in STEP_METHODS]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        os.environ.pop('RUN_DIR', None)

    WINDOW = 4217  # the fixture window's id as FRONT_WINDOW_SCRIPT answers it

    def transport(self, what):
        self.calls.append(what)
        if what in self.fail_on:
            raise finderui.Environment(f'osascript timed out after 10 s ({what})')

    def fake_run(self, argv, timeout=20):
        self.transport(Path(str(argv[0])).name)
        return subprocess.CompletedProcess([str(a) for a in argv], 0, '', '')

    def fake_osascript(self, script, *args, timeout=20):
        if script == calibration.FRONT_WINDOW_SCRIPT:
            return f'{self.WINDOW}\n{self.fixture_folders()[0]}/\n'
        self.scripts.append((script, args))
        self.transport('close-window' if 'close' in script else 'osascript')
        return ''

    def fake_close_menu(self, point):
        self.transport('close-menu')
        return 'closed'

    def fixture_folders(self):
        return sorted((self.run_dir / 'fixtures').glob('calibration-*'))

    def calibrate(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            try:
                code = calibration.calibrate(self.run_dir, group=GROUP, background_group=BACKGROUND)
            except Exception as error:  # noqa: BLE001 — an escaped transport error is what the assertions catch
                code = f'raised {type(error).__name__}: {error}'
        return code, out.getvalue()

    def assert_cleaned_and_reported(self, code, out, note):
        self.assertEqual(self.fixture_folders(), [])
        self.assertIn('\n---\n', out)
        self.assertRegex(out, r'(?m)^CALIBRATION (PASS|FAIL)')
        self.assertTrue((self.run_dir / 'calibration' / 'calibration.txt').is_file())
        self.assertRegex(out, r'(?m)^note: .*' + note)
        self.assertIn(code, (finderui.OK, finderui.REFUSED, finderui.ENVIRONMENT))

    def test_the_fixture_window_is_closed_by_the_id_read_when_it_opened(self):
        """Fix r3 item 6: the device run, 2026-11-18, showed `close (every Finder window whose target is <alias>)`
        failing with -1708; the window is closed by the id read together with its folder, and only that window."""
        code, out = self.calibrate()
        self.assertEqual(code, finderui.OK, out)
        closes = [(script, args) for script, args in self.scripts if 'close' in script]
        self.assertEqual(len(closes), 1, self.scripts)
        script, args = closes[0]
        self.assertIn('Finder window id', script)
        self.assertNotIn('whose target', script)
        self.assertEqual(args, (str(self.WINDOW),))
        self.assertNotIn('front Finder window', next(s for s, _ in self.scripts if 'list view' in s))

    def test_a_front_window_reply_of_another_shape_is_refused(self):
        self.assertEqual(calibration.front_window('4217\n/Users/tester/x/\n'), (4217, '/Users/tester/x'))
        for reply in ('/Users/tester/x\n', 'missing value\n/Users/tester/x\n', '1\n2\n3\n'):
            with self.subTest(reply=reply), self.assertRaises(finderui.Refused):
                calibration.front_window(reply)

    def test_without_a_failure_the_fixture_is_removed_and_the_report_passes(self):
        code, out = self.calibrate()
        self.assertEqual(code, finderui.OK, out)
        self.assertEqual(self.fixture_folders(), [])
        self.assertNotIn('note:', out)

    def test_a_close_menu_error_in_teardown_still_closes_the_window_and_removes_the_fixture(self):
        def opened(run):
            run.menu_points.append((700, 300))
            return 'stub'
        self.fail_on = {'close-menu'}
        with mock.patch.object(calibration.Run, 'context_menu', opened):
            code, out = self.calibrate()
        self.assert_cleaned_and_reported(code, out, r'timed out after 10 s \(close-menu\)')
        self.assertEqual(code, finderui.OK, out)
        self.assertIn('close-window', self.calls)

    def test_a_close_window_error_in_teardown_still_removes_the_fixture(self):
        self.fail_on = {'close-window'}
        code, out = self.calibrate()
        self.assert_cleaned_and_reported(code, out, r'timed out after 10 s \(close-window\)')
        self.assertEqual(code, finderui.OK, out)

    def test_a_failing_stop_still_removes_the_fixture(self):
        def stop(run):
            raise finderui.Environment('osascript timed out after 10 s (stop)')
        with mock.patch.object(calibration.Run, 'stop_started', stop):
            code, out = self.calibrate()
        self.assert_cleaned_and_reported(code, out, r'timed out after 10 s \(stop\)')

    def test_a_failing_fixture_removal_still_stops_and_prints_the_report(self):
        stopped = []

        def remove(fixture):
            raise finderui.Environment('osascript timed out after 10 s (remove)')
        with mock.patch.object(calibration.Fixture, 'remove', remove), \
                mock.patch.object(calibration.Run, 'stop_started', lambda run: stopped.append(True)):
            code, out = self.calibrate()
        self.assertEqual(stopped, [True])
        self.assertIn('\n---\n', out)
        self.assertRegex(out, r'(?m)^note: .*timed out after 10 s \(remove\)')
        self.assertRegex(out, r'(?m)^CALIBRATION PASS')

    def test_close_menu_failing_after_a_failed_step_keeps_the_later_steps_and_the_report(self):
        def broken(run):
            run.menu_points.append((700, 300))
            raise finderui.Refused('the menu did not open')
        self.fail_on = {'close-menu'}
        with mock.patch.object(calibration.Run, 'context_menu', broken):
            code, out = self.calibrate()
        self.assert_cleaned_and_reported(code, out, r'timed out after 10 s \(close-menu\)')
        self.assertEqual(code, finderui.REFUSED, out)
        self.assertRegex(out, r'(?m)^FAIL context-menu — the menu did not open$')
        self.assertRegex(out, r'(?m)^PASS dialog-read — stub$')

    def test_an_interrupt_during_a_step_still_cleans_prints_the_report_and_propagates(self):
        def interrupted(run):
            raise KeyboardInterrupt
        out = io.StringIO()
        with mock.patch.object(calibration.Run, 'context_menu', interrupted), contextlib.redirect_stdout(out), \
                self.assertRaises(KeyboardInterrupt):
            calibration.calibrate(self.run_dir, group=GROUP, background_group=BACKGROUND)
        self.assertEqual(self.fixture_folders(), [])
        self.assertRegex(out.getvalue(), r'(?m)^---\n(.*\n)*FAIL context-menu — not run')


if __name__ == '__main__':
    unittest.main()
