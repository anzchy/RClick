"""Offline contract tests for device.py; they never launch RClick, touch the desktop or signal a process."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import device  # noqa: E402

APP = '/tmp/rclick-device-test/RClick.app'
OURS = f'+    cn.wflixu.RClick.FinderSyncExt(2.3.4)\tC450DFED-A86A-4A86-B94B-DF8130980AFE\t2026-11-10 05:21:11 +0000\t{APP}/Contents/PlugIns/FinderSyncExt.appex\n'
FOREIGN = '     cn.wflixu.RClick.FinderSyncExt(2.3.1)\tD450DFED-A86A-4A86-B94B-DF8130980AFE\t2026-10-14 05:21:11 +0000\t/Applications/RClick.app/Contents/PlugIns/FinderSyncExt.appex\n'


def good_data():
    return dict(
        expectedSHA='abcdef12', recordedSHA='abcdef12', hashesMatch=True, errors={},
        bundleID=device.APP_ID, extBundleID=device.EXT_ID, signatureValid=True, sandbox=True,
        processMatches=True, fresh=True, alone=True, log='... launch decision: hintClick=false ...',
        extensions=device.parse_pluginkit(OURS), extProcesses=[f'{APP}/Contents/PlugIns/FinderSyncExt.appex/Contents/MacOS/FinderSyncExt'],
        appPath=APP, accessibility=True, machineMatches=True)


class Pluginkit(unittest.TestCase):
    def test_parses_flags_version_and_path(self):
        [entry] = device.parse_pluginkit(OURS)
        self.assertEqual(entry, dict(flags='+', id=device.EXT_ID, version='2.3.4',
                                     path=f'{APP}/Contents/PlugIns/FinderSyncExt.appex'))

    def test_undecided_entry_has_empty_flags(self):
        [entry] = device.parse_pluginkit(FOREIGN)
        self.assertEqual(entry['flags'], '')

    def test_empty_output_means_unregistered(self):
        self.assertEqual(device.parse_pluginkit('\n'), [])

    def test_unrecognised_line_fails_closed(self):
        with self.assertRaises(RuntimeError):
            device.parse_pluginkit('garbage without parentheses\n')


class Verdicts(unittest.TestCase):
    def verdict(self, **changes):
        data = good_data()
        data.update(changes)
        lines, passed = device.verdicts(data)
        return {line.split()[1]: line for line in lines}, passed

    def test_all_good_passes_every_check_in_order(self):
        lines, passed = device.verdicts(good_data())
        self.assertTrue(passed)
        self.assertEqual([line.split()[1] for line in lines], list(device.CHECKS))
        self.assertTrue(all(line.startswith('PASS ') for line in lines))

    def test_a_second_registration_from_another_copy_fails(self):
        lines, passed = self.verdict(extensions=device.parse_pluginkit(OURS + FOREIGN))
        self.assertFalse(passed)
        self.assertIn('/Applications/RClick.app', lines['extension-registered'])

    def test_disabled_extension_fails_and_names_system_settings(self):
        lines, passed = self.verdict(extensions=device.parse_pluginkit(OURS.replace('+    ', '-    ', 1)))
        self.assertFalse(passed)
        self.assertTrue(lines['extension-enabled'].startswith('FAIL'))
        self.assertIn('System Settings', lines['extension-enabled'])

    def test_extension_process_from_another_bundle_fails(self):
        lines, passed = self.verdict(extProcesses=['/Applications/RClick.app/Contents/PlugIns/FinderSyncExt.appex/Contents/MacOS/FinderSyncExt'])
        self.assertFalse(passed)
        self.assertTrue(lines['extension-process'].startswith('FAIL'))

    def test_build_sha_must_match_the_expected_sha(self):
        lines, passed = self.verdict(expectedSHA='12345678')
        self.assertFalse(passed)
        self.assertTrue(lines['bundle-hash'].startswith('FAIL'))

    def test_missing_accessibility_fails_without_suggesting_a_settings_change_by_the_run(self):
        lines, passed = self.verdict(accessibility=False)
        self.assertFalse(passed)
        self.assertIn('never changes privacy settings', lines['accessibility'])

    def test_collection_error_overrides_a_good_value(self):
        lines, passed = self.verdict(errors={'single-instance': 'pgrep process query failed'})
        self.assertFalse(passed)
        self.assertEqual(lines['single-instance'], 'FAIL single-instance — pgrep process query failed')

    def test_doctor_fixture_mode_prints_one_line_per_check(self):
        with tempfile.TemporaryDirectory() as folder:
            fixture = Path(folder) / 'obs.json'
            fixture.write_text(json.dumps(good_data()))
            result = subprocess.run([sys.executable, str(HERE / 'device.py'), 'doctor', '--fixture', str(fixture)],
                                    capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(result.stdout.splitlines()), len(device.CHECKS))


class Signing(unittest.TestCase):
    def test_signing_must_be_chosen_explicitly(self):
        with self.assertRaises(RuntimeError):
            device.signing_settings('')

    def test_adhoc_and_team_forms(self):
        self.assertIn('CODE_SIGN_IDENTITY=-', device.signing_settings('adhoc'))
        self.assertIn('DEVELOPMENT_TEAM=ABCDE12345', device.signing_settings('team:ABCDE12345'))

    def test_malformed_team_is_refused(self):
        for value in ('team:', 'team:abc', 'team:ABCDE12345; rm -rf /', 'GRT84NAK4T'):
            with self.assertRaises(RuntimeError, msg=value):
                device.signing_settings(value)


def completed(returncode, stdout='', stderr=''):
    return subprocess.CompletedProcess([], returncode, stdout, stderr)


class ProcessQuery(unittest.TestCase):
    def test_exit_one_without_output_means_none_running(self):
        with patch.object(device, 'command', return_value=completed(1)):
            self.assertEqual(device.running(), [])

    def test_query_failures_fail_closed(self):
        for result in (completed(2, stderr='boom'), completed(0, 'abc\n'), completed(0, '12\n12\n'),
                       completed(0, '1\n'), completed(0, '12\n', 'warning'), completed(1, '', 'denied')):
            with patch.object(device, 'command', return_value=result), self.assertRaises(RuntimeError):
                device.running()

    def test_launch_refuses_when_another_rclick_runs_and_never_opens_it(self):
        with tempfile.TemporaryDirectory() as folder, \
                patch.object(device, 'running', return_value=[4242]), \
                patch.object(device.subprocess, 'Popen') as popen, \
                patch.object(device.os, 'kill') as kill:
            with self.assertRaisesRegex(RuntimeError, 'another RClick is running'):
                device.launch(Path(folder))
        popen.assert_not_called()
        kill.assert_not_called()

    def test_build_refuses_when_another_rclick_runs(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(device, 'running', return_value=[4242]):
            with self.assertRaisesRegex(RuntimeError, 'another RClick is running'):
                device.build(Path(folder))


class Ownership(unittest.TestCase):
    def test_cleanup_without_a_record_signals_nothing_and_retires(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(device.os, 'kill') as kill:
            run = Path(folder)
            with self.assertRaises(RuntimeError):
                device.cleanup(run)
            self.assertTrue((run / 'retired').exists())
        kill.assert_not_called()

    def test_pause_refuses_a_pid_whose_birth_changed(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(device.os, 'kill') as kill:
            run = Path(folder)
            app = run / 'RClick.app'
            (run / 'bundle.path').write_text(str(app) + '\n')
            (run / 'rclick.pid').write_text('4242\n')
            record = dict(pid=4242, executable=str(app / 'Contents/MacOS/RClick'), birth='Mon Nov 16 10:00:00 2026')
            (run / 'process.json').write_text(json.dumps(record))
            other = dict(record, birth='Mon Nov 16 11:00:00 2026')
            with patch.object(device, 'process_snapshot', return_value=other):
                with self.assertRaisesRegex(RuntimeError, 'refusing signal'):
                    device.pause(run)
        kill.assert_not_called()

    def test_adopt_requires_a_retired_source_and_one_process_from_its_bundle(self):
        with tempfile.TemporaryDirectory() as folder:
            source, new = Path(folder) / 'a', Path(folder) / 'b'
            source.mkdir()
            app = source / 'RClick.app'
            (source / 'bundle.path').write_text(str(app) + '\n')
            (source / 'build.json').write_text('{}')
            with self.assertRaisesRegex(RuntimeError, 'not retired'):
                device.adopt(new, str(source))
            (source / 'retired').write_text('x')
            new.mkdir()
            exe = (app / 'Contents/MacOS/RClick').resolve()
            with patch.object(device, 'running', return_value=[11, 12]), \
                    patch.object(device, 'executable', side_effect=lambda p: exe if p == 11 else Path('/Applications/RClick.app/Contents/MacOS/RClick')):
                with self.assertRaisesRegex(RuntimeError, 'different bundle'):
                    device.adopt(new, str(source))
            with patch.object(device, 'running', return_value=[]):
                with self.assertRaisesRegex(RuntimeError, 'found 0'):
                    device.adopt(new, str(source))
            self.assertFalse((new / 'process.json').exists())

    def test_retired_record_cannot_drive_anything(self):
        with tempfile.TemporaryDirectory() as folder:
            run = Path(folder)
            (run / 'retired').write_text('x')
            with self.assertRaisesRegex(RuntimeError, 'retired'):
                device.recorded_identity(run)

    def test_run_directory_inside_the_worktree_is_refused(self):
        with self.assertRaisesRegex(RuntimeError, 'outside the worktree'):
            device.run_dir(str(device.ROOT / 'evidence'))


class Inputs(unittest.TestCase):
    def test_build_inputs_cover_both_targets_and_skip_user_state(self):
        self.assertTrue(device.is_input('RClick/AppState.swift'))
        self.assertTrue(device.is_input('FinderSyncExt/FinderSyncExt.swift'))
        self.assertTrue(device.is_input('Shared/Messager.swift'))
        self.assertTrue(device.is_input('RClick.xcodeproj/project.pbxproj'))
        self.assertFalse(device.is_input('RClick.xcodeproj/xcuserdata/jack.xcuserdatad/x.plist'))
        self.assertFalse(device.is_input('docs/validation/x.md'))
        self.assertFalse(device.is_input('.agents/skills/macos-device-test/SKILL.md'))
        self.assertFalse(device.is_input('RClick/.DS_Store'))

    def test_root_is_the_repository(self):
        self.assertTrue((device.ROOT / 'RClick.xcodeproj').is_dir())


if __name__ == '__main__':
    unittest.main()
