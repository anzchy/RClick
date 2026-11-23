"""Offline release guards: real local Git graphs, static notes, no fake executables."""
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


if __name__ == '__main__':
    unittest.main()
