"""Offline tests of the Finder UI driver's pure logic (finderui.py) against recorded and reconstructed AX dumps in
fixtures/. They never call AX, osascript or Finder; GUI behaviour is proven by calibrate.sh on a real desktop."""
import sys
import unicodedata
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import finderui  # noqa: E402

FIXTURES = HERE / 'fixtures'


def dump(name):
    return finderui.parse_dump((FIXTURES / name).read_text(encoding='utf-8'))


class Rows(unittest.TestCase):
    # Display order recorded through AX in run i5-device-20261117d (ax-row-order.txt); the AX tree in the fixture is
    # in the order AppleScript's `items` returned, which is NOT what the user sees.
    DISPLAY = ['%41.txt', '%44ocuments', '%2541.txt', '%2544ocuments', 'alpha.txt', '项目 资料', 'zeta.txt']
    APPLESCRIPT = ['%2541.txt', '%2544ocuments', '%41.txt', '%44ocuments', 'alpha.txt', '项目 资料', 'zeta.txt']

    def test_rows_come_in_display_order_not_applescript_order(self):
        rows = finderui.list_rows(dump('finder-window-display-order.jsonl'))
        self.assertEqual([row.name for row in rows], self.DISPLAY)
        self.assertNotEqual([row.name for row in rows], self.APPLESCRIPT)
        self.assertEqual([row.index for row in rows], [1, 2, 3, 4, 5, 6, 7])

    def test_sidebar_rows_are_not_file_rows(self):
        rows = finderui.list_rows(dump('finder-window-display-order.jsonl'))
        self.assertNotIn('Downloads', [row.name for row in rows])
        self.assertEqual([row.name for row in rows].count('alpha.txt'), 1)


class FindRow(unittest.TestCase):
    def setUp(self):
        self.rows = finderui.list_rows(dump('finder-window-display-order.jsonl'))

    def test_exact_name_gives_the_name_cell_centre_and_display_index(self):
        row = finderui.find_row(self.rows, '%2541.txt')
        self.assertEqual((row.index, row.point), (3, (620, 225)))

    def test_a_sibling_name_is_not_a_match(self):
        # `%41.txt` and `%2541.txt` differ only by percent-encoding: substring or decoded matches would pick both.
        self.assertEqual(finderui.find_row(self.rows, '%41.txt').index, 1)
        for name in ('41.txt', '%41', 'ALPHA.TXT', 'alpha.txt '):
            with self.subTest(name=name), self.assertRaisesRegex(finderui.Refused, 'no row named'):
                finderui.find_row(self.rows, name)

    def test_decomposed_unicode_matches_its_composed_form(self):
        self.assertEqual(finderui.find_row(self.rows, '项目 资料').index, 6)
        nodes = dump('finder-window-display-order.jsonl')
        for node in nodes:
            if node.get('value') == 'alpha.txt':
                node['value'] = unicodedata.normalize('NFD', 'café.txt')
        rows = finderui.list_rows(nodes)
        self.assertEqual(finderui.find_row(rows, unicodedata.normalize('NFC', 'café.txt')).index, 5)

    def test_a_duplicate_name_is_refused(self):
        rows = finderui.list_rows(dump('finder-window-duplicate-name.jsonl'))
        with self.assertRaisesRegex(finderui.Refused, '2 rows named'):
            finderui.find_row(rows, 'inner.txt')

    def test_a_row_scrolled_out_of_view_is_refused(self):
        with self.assertRaisesRegex(finderui.Refused, 'not visible'):
            finderui.find_row(self.rows, 'zeta.txt')


if __name__ == '__main__':
    unittest.main()
