"""Offline release guards: real local Git graphs, static notes, and fake notarytool submissions."""
import json
import os
import sys
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
SCRIPTS = Path(os.environ.get('RELEASE_GUARD_DIR', ROOT))


class TagGuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.git('init', '-q')
        self.git('-c', 'commit.gpgsign=false', '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                 'commit', '-q', '--allow-empty', '-m', 'main')
        self.main = self.git('rev-parse', 'HEAD').strip()
        self.git('update-ref', 'refs/remotes/origin/main', self.main)
        self.git('-c', 'commit.gpgsign=false', '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                 'commit', '-q', '--allow-empty', '-m', 'off main')
        self.off_main = self.git('rev-parse', 'HEAD').strip()

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.repo, text=True)

    def check(self, tag, version='2.3.5', commit=None, main='origin/main'):
        return subprocess.run(['sh', str(SCRIPTS / 'validate-tag.sh'), tag, version,
                               commit or self.main, main], cwd=self.repo,
                              text=True, capture_output=True)

    def test_good_tag_and_ancestor(self):
        result = self.check('v2.3.5')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('PASS', result.stdout)
        # Reachability permits an earlier main commit, not just its current tip.
        self.git('update-ref', 'refs/remotes/origin/main', self.off_main)
        self.assertEqual(self.check('v2.3.5').returncode, 0)

    def test_bad_tags(self):
        for tag in ('2.3.5', 'v2.3.5-beta', 'v2.3.5.1', 'v2.3', 'v2.x.5',
                    'v2.3.5\n', 'v2.3.5\nv9.9.9', ' v2.3.5'):
            with self.subTest(tag=tag):
                result = self.check(tag, tag.removeprefix('v'))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('numeric', result.stderr)

    def test_leading_zeros_are_literal(self):
        self.assertEqual(self.check('v02.3.5', '02.3.5').returncode, 0)
        self.assertNotEqual(self.check('v02.3.5').returncode, 0)

    def test_version_mismatch(self):
        result = self.check('v2.3.4')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('project', result.stderr)

    def test_off_main(self):
        result = self.check('v2.3.5', commit=self.off_main)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('reachable', result.stderr)

    def test_missing_ref_or_commit(self):
        for kwargs in ({'main': 'missing'}, {'commit': 'missing'}):
            with self.subTest(kwargs=kwargs):
                self.assertNotEqual(self.check('v2.3.5', **kwargs).returncode, 0)


class NotesGuardTests(unittest.TestCase):
    def check(self, version):
        return subprocess.run(['sh', str(SCRIPTS / 'check-notes.sh'), version,
                               str(ROOT / 'fixtures')], text=True, capture_output=True)

    def test_ready(self):
        result = self.check('2.3.5')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('PASS', result.stdout)

    def test_invalid_version(self):
        for version in ('../2.3.5', '2.3.5/../2.3.5', 'ready', '2.3.5\n'):
            with self.subTest(version=version):
                result = self.check(version)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('version must be numeric', result.stderr)

    def test_empty_or_whitespace(self):
        for version in ('2.3.8', '2.3.9'):
            with self.subTest(version=version):
                result = self.check(version)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('no non-whitespace content', result.stderr)

    def test_missing(self):
        result = self.check('2.3.10')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Release notes missing:', result.stderr)

    @unittest.skipIf(hasattr(os, 'geteuid') and os.geteuid() == 0,
                     'root bypasses chmod(000) file read restrictions')
    def test_read_error(self):
        # Only a plain data file is created; no executable fixtures.
        with tempfile.TemporaryDirectory() as directory:
            notes = Path(directory) / '2.3.5-notes.md'
            notes.write_text('# Ready notes\n')
            notes.chmod(0)
            try:
                result = subprocess.run(
                    ['sh', str(SCRIPTS / 'check-notes.sh'), '2.3.5', directory],
                    text=True, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Cannot read release notes:', result.stderr)
                self.assertNotIn('PASS', result.stdout)
            finally:
                notes.chmod(0o600)

    def test_owner_tested_sha_placeholder(self):
        result = self.check('2.3.11')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('OWNER_TESTED_SHA7', result.stderr)

    def test_unfinished_words(self):
        for version in ('2.3.6', '2.3.7'):
            with self.subTest(version=version):
                result = self.check(version)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('unfinished', result.stderr)


class ProjectVersionTests(unittest.TestCase):
    def check(self, data):
        return subprocess.run([sys.executable, str(SCRIPTS / 'project-version.py')],
                              input=data, capture_output=True)

    @unittest.skipUnless(sys.platform == 'darwin',
                         'real OpenStep pbxproj conversion requires macOS plutil; XML fixtures run everywhere')
    def test_real_project(self):
        data = subprocess.check_output(['plutil', '-convert', 'xml1', '-o', '-',
                                        str(ROOT.parents[1] / 'RClick.xcodeproj/project.pbxproj')])
        result = self.check(data)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b'2.3.5\n')

    def test_multiple_targets_and_configurations(self):
        result = self.check((ROOT / 'fixtures/multi-target.pbxproj').read_bytes())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b'2.3.5\n')

    def test_zero_or_conflicting_matches(self):
        for fixture in ('zero-target', 'conflicting-targets', 'zero-release', 'conflicting-releases'):
            with self.subTest(fixture=fixture):
                result = self.check((ROOT / f'fixtures/{fixture}.pbxproj').read_bytes())
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(b'Cannot determine app Release MARKETING_VERSION:', result.stderr)
                self.assertEqual(result.stdout, b'')


class NotarizationTests(unittest.TestCase):
    credentials = {'APPLE_ID': 'fixture-owner@example.invalid',
                   'APPLE_APP_SPECIFIC_PASSWORD': 'fixture-password-unique',
                   'APPLE_TEAM_ID': 'FIXTURETEAM'}

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.artifact = self.directory / 'RClick fixture.zip'
        self.artifact.write_bytes(b'offline artifact')
        self.calls_file = self.directory / 'calls.jsonl'
        fake = self.directory / 'xcrun'
        fake.write_text(f'#!{sys.executable}\n' + '''import json, os, sys
from pathlib import Path
args = sys.argv[1:]
names = ('APPLE_ID', 'APPLE_APP_SPECIFIC_PASSWORD', 'APPLE_TEAM_ID')
record = {'tool': Path(sys.argv[0]).name, 'argv': args,
          'credential_env': {name: os.environ[name] for name in names if name in os.environ},
          'umask': oct(os.umask(0o077))}
with open(os.environ['CALLS_FILE'], 'a') as calls:
    calls.write(json.dumps(record) + '\\n')
if args[:2] == ['notarytool', 'submit']:
    if os.environ.get('FAKE_MALFORMED'):
        print('not JSON')
    else:
        print(json.dumps({'id': 'submission-fixture', 'status': os.environ.get('FAKE_STATUS', 'Accepted'),
                          'message': args[args.index('--password') + 1]}))
    print(args[args.index('--apple-id') + 1], file=sys.stderr)
    sys.exit(int(os.environ.get('FAKE_SUBMIT_EXIT', '0')))
if args[:2] == ['notarytool', 'log']:
    print('Fixture notary log: invalid signature; ' + args[args.index('--password') + 1])
    print(args[args.index('--apple-id') + 1], file=sys.stderr)
    sys.exit(int(os.environ.get('FAKE_LOG_EXIT', '0')))
''')
        fake.chmod(0o700)
        (self.directory / 'spctl').write_bytes(fake.read_bytes())
        (self.directory / 'spctl').chmod(0o700)
        self.env = {**os.environ, **self.credentials,
                    'PATH': str(self.directory) + os.pathsep + os.environ['PATH'],
                    'CALLS_FILE': str(self.calls_file)}
        for name in ('FAKE_STATUS', 'FAKE_MALFORMED', 'FAKE_SUBMIT_EXIT', 'FAKE_LOG_EXIT'):
            self.env.pop(name, None)

    def run_notary(self, **overrides):
        result = subprocess.run(['bash', '-x', str(SCRIPTS / 'notarize.sh'), str(self.artifact)],
                                env={**self.env, **overrides}, text=True, capture_output=True)
        for value in self.credentials.values():
            self.assertNotIn(value, result.stdout + result.stderr)
        return result

    def calls(self):
        return [json.loads(line) for line in self.calls_file.read_text().splitlines()]

    def test_accepted_submission(self):
        result = self.run_notary()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('submission-fixture: Accepted', result.stdout)
        calls = self.calls()
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]['argv'], ['notarytool', 'submit', str(self.artifact),
                         '--wait', '--timeout', '1h', '--output-format', 'json',
                         '--apple-id', self.credentials['APPLE_ID'],
                         '--password', self.credentials['APPLE_APP_SPECIFIC_PASSWORD'],
                         '--team-id', self.credentials['APPLE_TEAM_ID']])
        self.assertEqual(calls[0]['credential_env'], {})
        self.assertEqual(calls[0]['umask'], '0o77')

    def test_invalid_fails_and_prints_log_even_if_submit_exits_nonzero(self):
        for code in ('0', '65'):
            with self.subTest(submit_exit=code):
                self.calls_file.unlink(missing_ok=True)
                result = self.run_notary(FAKE_STATUS='Invalid', FAKE_SUBMIT_EXIT=code)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Fixture notary log: invalid signature', result.stderr)
                self.assertEqual([call['argv'][:2] for call in self.calls()],
                                 [['notarytool', 'submit'], ['notarytool', 'log']])
                self.assertTrue(all(call['credential_env'] == {} for call in self.calls()))

    def test_log_failure_does_not_hide_rejection(self):
        result = self.run_notary(FAKE_STATUS='Invalid', FAKE_LOG_EXIT='69')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Fixture notary log:', result.stderr)
        self.assertIn('notarytool log failed (exit 69)', result.stderr)

    def test_json_escaped_credentials_are_redacted(self):
        password = 'fixture-"quoted\\password\nsecret'
        self.credentials = {**self.credentials, 'APPLE_APP_SPECIFIC_PASSWORD': password}
        self.env.update(self.credentials)
        result = self.run_notary(FAKE_STATUS='Invalid')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(json.dumps(password)[1:-1], result.stdout + result.stderr)

    def test_missing_environment_fails_before_submission(self):
        for name in self.credentials:
            for empty in (False, True):
                with self.subTest(name=name, empty=empty):
                    env = self.env.copy()
                    if empty:
                        env[name] = ''
                    else:
                        env.pop(name)
                    result = subprocess.run(['bash', str(SCRIPTS / 'notarize.sh'), str(self.artifact)],
                                            env=env, text=True, capture_output=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(name, result.stderr)
                    self.assertFalse(self.calls_file.exists())
                    for value in self.credentials.values():
                        self.assertNotIn(value, result.stdout + result.stderr)

    def test_malformed_or_nonaccepted_response_fails_closed(self):
        for overrides in ({'FAKE_MALFORMED': '1'}, {'FAKE_STATUS': 'In Progress'},
                          {'FAKE_STATUS': ''}, {'FAKE_SUBMIT_EXIT': '65'}):
            with self.subTest(overrides=overrides):
                result = self.run_notary(**overrides)
                self.assertNotEqual(result.returncode, 0)

    def test_missing_artifact_fails_before_submission(self):
        self.artifact.unlink()
        result = self.run_notary()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('usage:', result.stderr)
        self.assertFalse(self.calls_file.exists())

    def test_workflow_clears_credentials_before_stapling_and_assessment(self):
        workflow = (ROOT.parents[1] / '.github/workflows/release.yml').read_text()
        for name in ('Notarize', 'Notarize DMG'):
            with self.subTest(step=name):
                self.calls_file.unlink(missing_ok=True)
                block = workflow.split(f'      - name: {name}\n', 1)[1].split('      #', 1)[0]
                commands = '\n'.join(line[10:] for line in block.split('        run: |\n')[1].splitlines())
                if name == 'Notarize':
                    staple = workflow.split('      - name: Staple\n', 1)[1].split('      #', 1)[0]
                    commands += '\n' + '\n'.join(line[10:] for line in staple.split('        run: |\n')[1].splitlines())
                result = subprocess.run(['bash', '-e', '-c', commands], cwd=ROOT.parents[1],
                                        env={**self.env, 'NOTARIZE_ZIP': str(self.artifact),
                                             'DMG_NAME': str(self.artifact), 'APP_PATH': str(self.artifact)},
                                        text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = self.calls()
                self.assertEqual(calls[0]['argv'][:2], ['notarytool', 'submit'])
                self.assertEqual(calls[1]['argv'][:2], ['stapler', 'staple'])
                self.assertEqual(calls[2]['argv'][:2], ['stapler', 'validate'])
                self.assertEqual(calls[3]['tool'], 'spctl')
                self.assertTrue(all(call['credential_env'] == {} for call in calls))
                for call in calls[1:]:
                    for value in self.credentials.values():
                        self.assertNotIn(value, json.dumps(call))
                for value in self.credentials.values():
                    self.assertNotIn(value, result.stdout + result.stderr)

    def test_workflow_rejection_stops_before_stapling_and_assessment(self):
        workflow = (ROOT.parents[1] / '.github/workflows/release.yml').read_text()
        for name in ('Notarize', 'Notarize DMG'):
            with self.subTest(step=name):
                self.calls_file.unlink(missing_ok=True)
                block = workflow.split(f'      - name: {name}\n', 1)[1].split('      #', 1)[0]
                commands = '\n'.join(line[10:] for line in block.split('        run: |\n')[1].splitlines())
                if name == 'Notarize':
                    staple = workflow.split('      - name: Staple\n', 1)[1].split('      #', 1)[0]
                    commands += '\n' + '\n'.join(line[10:] for line in staple.split('        run: |\n')[1].splitlines())
                result = subprocess.run(['bash', '-e', '-c', commands], cwd=ROOT.parents[1],
                                        env={**self.env, 'FAKE_STATUS': 'Invalid',
                                             'NOTARIZE_ZIP': str(self.artifact),
                                             'DMG_NAME': str(self.artifact), 'APP_PATH': str(self.artifact)},
                                        text=True, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                calls = self.calls()
                self.assertEqual([call['argv'][:2] for call in calls],
                                 [['notarytool', 'submit'], ['notarytool', 'log']])
                self.assertFalse(any(call['tool'] == 'spctl' or call['argv'][:1] == ['stapler']
                                     for call in calls))

    def test_workflow_uses_apple_id_for_both_artifacts(self):
        workflow = (ROOT.parents[1] / '.github/workflows/release.yml').read_text()
        for name, artifact in (('Notarize', 'NOTARIZE_ZIP'), ('Notarize DMG', 'DMG_NAME')):
            block = workflow.split(f'      - name: {name}\n', 1)[1].split('      #', 1)[0]
            with self.subTest(step=name):
                self.assertIn('APPLE_ID: ${{ secrets.APPLE_ID }}', block)
                self.assertIn('APPLE_APP_SPECIFIC_PASSWORD: ${{ secrets.APPLE_APP_SPECIFIC_PASSWORD }}', block)
                self.assertIn('APPLE_TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}', block)
                self.assertIn(f'bash scripts/release/notarize.sh "${artifact}"', block)
                self.assertIn('unset APPLE_ID APPLE_APP_SPECIFIC_PASSWORD APPLE_TEAM_ID', block)
        for obsolete in ('NOTARY_KEY_ID', 'NOTARY_ISSUER_ID', 'NOTARY_PRIVATE_KEY', 'AuthKey_'):
            self.assertNotIn(obsolete, workflow)


if __name__ == '__main__':
    unittest.main()
