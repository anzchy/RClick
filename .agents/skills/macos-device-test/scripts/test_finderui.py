"""Offline tests of the Finder UI driver's pure logic (finderui.py) against recorded and reconstructed AX dumps in
fixtures/. They never call AX, osascript or Finder; GUI behaviour is proven by calibrate.sh on a real desktop."""
import sys
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


if __name__ == '__main__':
    unittest.main()
