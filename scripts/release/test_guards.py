"""Offline release guards: real local Git graphs, static notes, no fake executables."""
import os
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
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                 'commit', '-q', '--allow-empty', '-m', 'main')
        self.main = self.git('rev-parse', 'HEAD').strip()
        self.git('update-ref', 'refs/remotes/origin/main', self.main)
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
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
        result = self.check('ready')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('PASS', result.stdout)

    def test_missing(self):
        result = self.check('missing')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('missing', result.stderr)

    def test_unfinished_words(self):
        for version in ('pending', 'tbd'):
            with self.subTest(version=version):
                result = self.check(version)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('unfinished', result.stderr)


if __name__ == '__main__':
    unittest.main()
