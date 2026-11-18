"""Offline tests of the calibration's fixture folder (calibration.Fixture): exclusive allocation under
$RUN_DIR/fixtures/, and a cleanup that removes only what this invocation created (audit r1 M2). No desktop call."""
import os
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import calibration  # noqa: E402
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


if __name__ == '__main__':
    unittest.main()
