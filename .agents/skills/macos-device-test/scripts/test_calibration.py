"""Offline tests of the calibration's fixture folder (calibration.Fixture): exclusive allocation under
$RUN_DIR/fixtures/, and a cleanup that removes only what this invocation created (audit r1 M2). No desktop call."""
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
    """The calibration proves the ui.sh command lines a device run uses (audit r1 F10): the guard step runs
    `ui.sh guard`, not the pure function; the Option, background, submenu and close-menu paths each have a step."""

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

    def test_the_guard_step_runs_ui_sh_guard_for_the_target_and_the_sibling(self):
        def guard(args):
            return (0, 'GUARD PASS \u2014 ok\n', '') if args[1].endswith('/%2541.txt') else (65, '', 'REFUSED: sibling\n')
        cli = FakeCli({'guard': guard})
        detail = self.step(cli, self.run.guard)
        self.assertEqual(cli.ui('guard'), [['700,300', self.run.path('%2541.txt')], ['700,300', self.run.path('%41.txt')]])
        self.assertIn('REFUSED: sibling', detail)

    def test_a_guard_cli_that_accepts_the_sibling_fails_the_step(self):
        cli = FakeCli({'guard': (0, 'GUARD PASS \u2014 ok\n', '')})
        with self.assertRaises(finderui.Refused):
            self.step(cli, self.run.guard)

    def test_the_choose_step_runs_ui_sh_choose_and_reads_the_pasteboard(self):
        alpha = self.run.path('alpha.txt')
        cli = FakeCli({'open-menu': (0, 'row: 3 alpha.txt 600,215\nmenu-point 640,227\n', ''),
                       'choose': (0, 'GUARD PASS \u2014 ok\nchose: Copy Path\n', '')},
                      other={'pbpaste': (0, alpha)})
        self.step(cli, self.run.choose)
        self.assertEqual(cli.ui('open-menu'), [['alpha.txt']])
        self.assertEqual(cli.ui('choose'), [['640,227', 'Copy Path', *sum((['--group', t] for t in GROUP), []),
                                             '--target', alpha]])

    def test_the_option_step_reads_the_skip_confirmation_title(self):
        cli = FakeCli({'open-menu': (0, 'menu-point 700,300\n', ''),
                       'menu': (0, LISTING.format(suffix=' (skip confirmation)'), ''), 'close-menu': (0, 'escaped\n', '')})
        detail = self.step(cli, self.run.option_menu)
        self.assertEqual(cli.ui('open-menu'), [['%2541.txt', '--option']])
        self.assertEqual(cli.ui('menu'), [['700,300', *sum((['--group', t] for t in GROUP), [])]])
        self.assertEqual(len(cli.ui('close-menu')), 1)
        self.assertIn('Delete Direct (skip confirmation)', detail)

    def test_an_option_menu_without_the_changed_title_fails(self):
        cli = FakeCli({'open-menu': (0, 'menu-point 700,300\n', ''), 'menu': (0, LISTING.format(suffix=''), ''),
                       'close-menu': (0, 'escaped\n', '')})
        with self.assertRaises(finderui.Refused):
            self.step(cli, self.run.option_menu)

    def test_the_background_step_guards_the_fixture_folder(self):
        cli = FakeCli({'open-menu': (0, 'menu-point 800,500\n', ''), 'guard': (0, 'GUARD PASS \u2014 bg\n', ''),
                       'menu': (0, 'rclick-group (expected): found once at items 20..22\n', '')})
        self.step(cli, self.run.background_menu)
        self.assertEqual(cli.ui('open-menu'), [['--background']])
        self.assertEqual(cli.ui('guard'), [['800,500', '--background', str(self.run.folder)]])
        self.assertEqual(cli.ui('menu'), [['800,500', *sum((['--group', t] for t in BACKGROUND), [])]])

    def test_a_refused_background_guard_fails_the_step(self):
        cli = FakeCli({'open-menu': (0, 'menu-point 800,500\n', ''), 'guard': (65, '', 'REFUSED: selection\n'),
                       'menu': (0, '', '')})
        with self.assertRaises(finderui.Refused):
            self.step(cli, self.run.background_menu)

    def test_background_choose_presses_new_file_txt_and_adopts_the_new_file(self):
        def choose(args):
            (self.run.folder / 'untitled.txt').write_text('')
            return 0, 'GUARD PASS \u2014 bg\nchose: New File \u2192 TXT\n', ''
        cli = FakeCli({'open-menu': (0, 'menu-point 800,500\n', ''), 'choose': choose})
        detail = self.step(cli, self.run.background_choose)
        self.assertEqual(cli.ui('choose'), [['800,500', 'New File', '--sub', 'TXT',
                                             *sum((['--group', t] for t in BACKGROUND), []),
                                             '--background', str(self.run.folder)]])
        self.assertIn('untitled.txt', detail)
        self.assertEqual(self.run.fixture.remove(), [])
        self.assertFalse(self.run.folder.exists())

    def test_background_choose_with_no_new_file_and_no_rclick_panel_fails(self):
        cli = FakeCli({'open-menu': (0, 'menu-point 800,500\n', ''), 'choose': (0, 'chose: New File\n', '')})
        with mock.patch.object(finderdrive, 'app_nodes', side_effect=finderui.Environment('no RClick')), \
                self.assertRaises(finderui.Refused):
            self.step(cli, self.run.background_choose)

    def test_background_choose_that_raises_rclicks_folder_panel_cancels_it(self):
        (self.run.run / 'rclick.pid').write_text('4242\n')
        panel = finderui.parse_dump((HERE / 'fixtures' / 'panel-grant.jsonl').read_text(encoding='utf-8'))
        cli = FakeCli({'open-menu': (0, 'menu-point 800,500\n', ''), 'choose': (0, 'chose: New File\n', '')})
        with mock.patch.object(finderdrive, 'app_nodes', return_value=panel) as nodes, \
                mock.patch.object(finderdrive, 'app_dump', return_value=''), \
                mock.patch.object(finderdrive, 'press_button') as press:
            detail = self.step(cli, self.run.background_choose)
        self.assertEqual(nodes.call_args.args[0], 4242)
        press.assert_called_once_with(4242, 'Cancel', window_text=None)
        self.assertIn('Cancel', detail)

    def test_the_close_menu_step_runs_ui_sh_close_menu_and_reads_no_menu(self):
        self.run.background_point = (800, 500)
        cli = FakeCli({'close-menu': (0, 'escaped\n', '')})
        with mock.patch.object(finderdrive, 'read_menu', side_effect=finderui.Refused('no menu')):
            self.step(cli, self.run.close_menu)
        self.assertEqual(cli.ui('close-menu'), [[]])
        with mock.patch.object(finderdrive, 'read_menu', return_value=['still open']), \
                self.assertRaises(finderui.Refused):
            self.step(cli, self.run.close_menu)


if __name__ == '__main__':
    unittest.main()
