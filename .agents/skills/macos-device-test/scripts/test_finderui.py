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


class Menu(unittest.TestCase):
    RCLICK = ['Copy Path', 'Copy File Name', 'Delete Direct', 'Terminal', 'New File']

    def test_compress_title_is_finders_own_item_only(self):
        items = finderui.menu_items(dump('menu-file-alpha.jsonl'))
        # The alternate item repeats the title; another extension's `Compress to "alpha.txt.zip"` is not Finder's.
        self.assertEqual(finderui.compress_titles(items), ['Compress “alpha.txt”'])

    def test_rclick_group_follows_quick_actions_and_stops_at_the_next_extension(self):
        items = finderui.menu_items(dump('menu-file-alpha.jsonl'))
        group = finderui.rclick_group(items)
        self.assertEqual([item.title for item in group], self.RCLICK)
        self.assertEqual(group[0].point, (565, 598))
        new_file = group[-1]
        self.assertEqual([title for title, _ in new_file.sub],
                         ['TXT', 'Markdown', 'DOCX', 'PPTX', 'XLSX', 'Pages', 'Keynote', 'Numbers'])

    def test_option_title_belongs_to_the_group(self):
        items = finderui.menu_items(dump('menu-file-sibling-option.jsonl'))
        self.assertEqual([item.title for item in finderui.rclick_group(items)],
                         ['Copy Path', 'Copy File Name', 'Delete Direct (skip confirmation)', 'Terminal', 'New File'])

    def test_a_user_added_open_with_app_needs_also(self):
        nodes = dump('menu-file-alpha.jsonl')
        for node in nodes:
            if node.get('title') == 'Terminal':
                node['title'] = 'Visual Studio Code'
        items = finderui.menu_items(nodes)
        self.assertEqual([item.title for item in finderui.rclick_group(items)],
                         ['Copy Path', 'Copy File Name', 'Delete Direct'])
        self.assertEqual([item.title for item in finderui.rclick_group(items, also=['Visual Studio Code'])],
                         ['Copy Path', 'Copy File Name', 'Delete Direct', 'Visual Studio Code', 'New File'])


class Guard(unittest.TestCase):
    DIR = '/tmp/rclick-cal'

    def items(self, name):
        return finderui.menu_items(dump(name))

    def test_selection_readback_drops_the_folder_slash_and_blank_lines(self):
        self.assertEqual(finderui.parse_selection('/tmp/rclick-cal/%2544ocuments/\n/tmp/rclick-cal/a b.txt\n\n'),
                         ['/tmp/rclick-cal/%2544ocuments', '/tmp/rclick-cal/a b.txt'])
        self.assertEqual(finderui.parse_selection(''), [])

    def test_matching_title_and_selection_pass(self):
        target = self.DIR + '/alpha.txt'
        reason = finderui.check_guard([target], [target], self.items('menu-file-alpha.jsonl'))
        self.assertIn('Compress “alpha.txt”', reason)

    def test_compress_title_naming_the_sibling_is_refused_even_when_the_selection_matches(self):
        # i5-device-20261117b: the click landed on `%41.txt` while `%2541.txt` was the target.
        target = self.DIR + '/%2541.txt'
        with self.assertRaisesRegex(finderui.Refused, 'Compress “%41.txt”'):
            finderui.check_guard([target], [target], self.items('menu-file-sibling-option.jsonl'))

    def test_selection_of_another_item_is_refused(self):
        with self.assertRaisesRegex(finderui.Refused, 'selection'):
            finderui.check_guard([self.DIR + '/alpha.txt'], [self.DIR + '/%41.txt'], self.items('menu-file-alpha.jsonl'))
        with self.assertRaisesRegex(finderui.Refused, 'selection'):
            finderui.check_guard([self.DIR + '/alpha.txt'], [self.DIR + '/alpha.txt', self.DIR + '/beta.txt'],
                                 self.items('menu-file-alpha.jsonl'))

    def test_a_menu_without_finders_compress_item_is_refused(self):
        items = [item for item in self.items('menu-file-alpha.jsonl') if not item.title.startswith('Compress “')]
        target = self.DIR + '/alpha.txt'
        with self.assertRaisesRegex(finderui.Refused, 'no Finder Compress item'):
            finderui.check_guard([target], [target], items)

    def test_multi_selection_needs_the_item_count_title_and_the_same_set(self):
        targets = [self.DIR + '/a.txt', self.DIR + '/b.txt']
        nodes = dump('menu-file-alpha.jsonl')
        for node in nodes:
            if node.get('title') == 'Compress “alpha.txt”':
                node['title'] = 'Compress 2 Items'
        items = finderui.menu_items(nodes)
        self.assertIn('Compress 2 Items', finderui.check_guard(targets, list(reversed(targets)), items))
        with self.assertRaisesRegex(finderui.Refused, 'Compress 3 Items'):
            finderui.check_guard(targets + [self.DIR + '/c.txt'], targets + [self.DIR + '/c.txt'], items)

    def test_background_menu_needs_no_selection_and_the_front_window_folder(self):
        items = [item for item in self.items('menu-file-alpha.jsonl') if not item.title.startswith('Compress')]
        self.assertIn('background', finderui.check_guard([], [], items, background=self.DIR, front=self.DIR + '/'))
        with self.assertRaisesRegex(finderui.Refused, 'front Finder window'):
            finderui.check_guard([], [], items, background=self.DIR, front='/tmp/other')
        with self.assertRaisesRegex(finderui.Refused, 'selection'):
            finderui.check_guard([], [self.DIR + '/alpha.txt'], items, background=self.DIR, front=self.DIR)
        with self.assertRaisesRegex(finderui.Refused, 'Compress'):
            finderui.check_guard([], [], self.items('menu-file-alpha.jsonl'), background=self.DIR, front=self.DIR)


class Choose(unittest.TestCase):
    def setUp(self):
        self.items = finderui.menu_items(dump('menu-file-alpha.jsonl'))

    def test_item_is_taken_from_rclicks_group_not_from_another_extension(self):
        item, sub = finderui.find_group_item(self.items, 'Copy Path')
        # Another extension's `Copy Path` sits further down (y 982); RClick's is the one after Quick Actions.
        self.assertEqual((item.index, item.point, sub), (27, (565, 598), None))

    def test_submenu_item_is_addressed_inside_rclicks_new_file(self):
        item, sub = finderui.find_group_item(self.items, 'New File', sub='TXT')
        self.assertEqual((item.index, sub), (31, (31, 0, 0)))
        with self.assertRaisesRegex(finderui.Refused, 'no submenu item'):
            finderui.find_group_item(self.items, 'New File', sub='RTF')  # only the other extension's New File has RTF

    def test_a_title_outside_the_group_is_refused(self):
        for title in ('Move file to...', 'Compress “alpha.txt”', 'Hide'):
            with self.subTest(title=title), self.assertRaisesRegex(finderui.Refused, "not in RClick's group"):
                finderui.find_group_item(self.items, title)

    def test_a_disabled_item_is_refused(self):
        nodes = dump('menu-file-alpha.jsonl')
        for node in nodes:
            if node.get('title') == 'Copy File Name':
                node['enabled'] = False
        with self.assertRaisesRegex(finderui.Refused, 'disabled'):
            finderui.find_group_item(finderui.menu_items(nodes), 'Copy File Name')


class Dialogs(unittest.TestCase):
    def setUp(self):
        self.nodes = dump('dialog-delete-confirm.jsonl')

    def test_reader_returns_each_windows_texts_and_buttons(self):
        alert, settings = finderui.dialog_windows(self.nodes)
        self.assertEqual(alert.texts[0], 'Permanently delete “%2544ocuments”?')
        self.assertIn('Tip: hold Option while choosing this action to skip the confirmation.', alert.texts[1])
        self.assertEqual([title for title, _ in alert.buttons], ['Cancel', 'Delete'])
        self.assertEqual(settings.title, 'General')

    def test_button_is_found_by_exact_title(self):
        self.assertEqual(finderui.find_button(self.nodes, 'Delete'), (0, 4))
        with self.assertRaisesRegex(finderui.Refused, 'no window has a button'):
            finderui.find_button(self.nodes, 'delete')

    def test_a_button_in_two_windows_needs_the_window_text(self):
        self.nodes.append(dict(path=(1, 9), role='AXButton', title='Cancel', value=None, desc='', subrole='',
                               enabled=True, selected=None, frame=[0, 0, 10, 10]))
        with self.assertRaisesRegex(finderui.Refused, '2 windows'):
            finderui.find_button(self.nodes, 'Cancel')
        self.assertEqual(finderui.find_button(self.nodes, 'Cancel', window_text='Permanently delete'), (0, 3))

    def test_window_text_that_does_not_match_is_refused(self):
        with self.assertRaisesRegex(finderui.Refused, 'no window has a button'):
            finderui.find_button(self.nodes, 'Manage…', window_text='Permanently delete')


if __name__ == '__main__':
    unittest.main()
