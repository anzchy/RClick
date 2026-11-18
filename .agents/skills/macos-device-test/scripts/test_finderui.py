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
        self.assertEqual(finderui.find_row(rows, unicodedata.normalize('NFD', 'café.txt')).index, 5)
        for node in nodes:
            if node.get('value') == unicodedata.normalize('NFD', 'café.txt'):
                node['value'] = unicodedata.normalize('NFC', 'café.txt')
        rows = finderui.list_rows(nodes)
        self.assertEqual(finderui.find_row(rows, unicodedata.normalize('NFD', 'café.txt')).index, 5)

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

    def test_selection_readback_drops_only_the_folder_slash_and_the_line_terminators(self):
        self.assertEqual(finderui.parse_selection('3\n/tmp/rclick-cal/%2544ocuments/\n/tmp/rclick-cal/a b.txt\n'
                                                  '/tmp/rclick-cal/alpha.txt \n\n'),
                         ['/tmp/rclick-cal/%2544ocuments', '/tmp/rclick-cal/a b.txt', '/tmp/rclick-cal/alpha.txt '])
        self.assertEqual(finderui.parse_selection('0\n\n'), [])
        with self.assertRaisesRegex(finderui.Refused, 'line break'):
            finderui.parse_selection('1\n/tmp/rclick-cal/a\nb.txt\n\n')
        with self.assertRaises(finderui.Environment):
            finderui.parse_selection('')

    def test_whitespace_in_a_path_is_significant(self):
        # `alpha.txt` and `alpha.txt ` are two valid, distinct files (audit r1 F1).
        alpha, spaced = self.DIR + '/alpha.txt', self.DIR + '/alpha.txt '
        with self.assertRaisesRegex(finderui.Refused, 'selection'):
            finderui.check_guard([spaced], [alpha], self.items('menu-file-alpha.jsonl'))
        with self.assertRaisesRegex(finderui.Refused, 'selection'):
            finderui.check_guard([alpha], [' ' + alpha[1:]], self.items('menu-file-alpha.jsonl'))
        nodes = dump('menu-file-alpha.jsonl')
        for node in nodes:
            if node.get('title') == 'Compress “alpha.txt”':
                node['title'] = 'Compress 2 Items'
        two = finderui.menu_items(nodes)
        with self.assertRaisesRegex(finderui.Refused, 'selection'):
            finderui.check_guard([spaced, self.DIR + '/b.txt'], [alpha, self.DIR + '/b.txt'], two)
        with self.assertRaisesRegex(finderui.Refused, 'front Finder window'):
            finderui.check_guard([], [], [i for i in two if not i.title.startswith('Compress')],
                                 background=self.DIR + ' ', front=self.DIR)

    def test_a_path_that_cannot_be_read_back_exactly_is_refused(self):
        with self.assertRaisesRegex(finderui.Refused, 'line break'):
            finderui.check_guard([self.DIR + '/a\nb.txt'], [self.DIR + '/a\nb.txt'], self.items('menu-file-alpha.jsonl'))

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
    GROUP = Menu.RCLICK

    def setUp(self):
        self.items = finderui.menu_items(dump('menu-file-alpha.jsonl'))

    def test_item_is_taken_from_rclicks_group_not_from_another_extension(self):
        item, sub = finderui.find_group_item(self.items, 'Copy Path', group=self.GROUP)
        # Another extension's `Copy Path` sits further down (y 982); RClick's is the one after Quick Actions.
        self.assertEqual((item.index, item.point, sub), (27, (565, 598), None))

    def test_submenu_item_is_addressed_inside_rclicks_new_file(self):
        item, sub = finderui.find_group_item(self.items, 'New File', sub='TXT', group=self.GROUP)
        self.assertEqual((item.index, sub), (31, (31, 0, 0)))
        with self.assertRaisesRegex(finderui.Refused, 'no submenu item'):
            finderui.find_group_item(self.items, 'New File', sub='RTF', group=self.GROUP)  # only the other extension's New File has RTF

    def test_a_title_outside_the_group_is_refused(self):
        for title in ('Move file to...', 'Compress “alpha.txt”', 'Hide'):
            with self.subTest(title=title), self.assertRaisesRegex(finderui.Refused, "not in RClick's group"):
                finderui.find_group_item(self.items, title, group=self.GROUP)

    def test_a_disabled_item_is_refused(self):
        nodes = dump('menu-file-alpha.jsonl')
        for node in nodes:
            if node.get('title') == 'Copy File Name':
                node['enabled'] = False
        with self.assertRaisesRegex(finderui.Refused, 'disabled'):
            finderui.find_group_item(finderui.menu_items(nodes), 'Copy File Name', group=self.GROUP)


class GroupIdentity(unittest.TestCase):
    """RClick's group is identified by positive evidence: the run of exactly the expected titles (`--group`, RClick's
    configured top-level items in order) after the last `Quick Actions`, found once (audit r1 M3, opus L2)."""
    GROUP = Menu.RCLICK

    def setUp(self):
        self.items = finderui.menu_items(dump('menu-file-alpha.jsonl'))
        self.other_copy = next(item for item in self.items if item.title == 'Copy Path' and item.point[1] > 900)

    def test_another_extensions_copy_path_before_rclicks_group_is_not_taken(self):
        quick = [item.title for item in self.items].index('Quick Actions')
        items = self.items[:quick + 1] + [self.other_copy] + [i for i in self.items[quick + 1:] if i is not self.other_copy]
        item, _ = finderui.find_group_item(items, 'Copy Path', group=self.GROUP)
        self.assertEqual(item.point, (565, 598))  # RClick's, not the other extension's (565, 982)
        self.assertEqual([i.title for i in finderui.rclick_group(items, expected=self.GROUP)], self.GROUP)

    def test_without_the_expected_group_choose_has_no_positive_evidence(self):
        with self.assertRaisesRegex(finderui.Usage, '--group'):
            finderui.find_group_item(self.items, 'Copy Path')

    def test_the_expected_group_twice_is_ambiguous(self):
        twice = self.items + [item for item in self.items if item.title in self.GROUP and item.point[1] < 700]
        with self.assertRaisesRegex(finderui.Refused, '2 runs'):
            finderui.find_group_item(twice, 'Copy Path', group=self.GROUP)

    def test_an_expected_group_that_is_not_in_the_menu_is_refused(self):
        with self.assertRaisesRegex(finderui.Refused, 'not found'):
            finderui.find_group_item(self.items, 'Copy Path', group=['Copy Path', 'Hide', 'New File'])

    def test_the_skip_confirmation_title_matches_its_base_title_in_the_group(self):
        items = finderui.menu_items(dump('menu-file-sibling-option.jsonl'))
        item, _ = finderui.find_group_item(items, 'Delete Direct (skip confirmation)', group=self.GROUP)
        self.assertEqual(item.title, 'Delete Direct (skip confirmation)')

    def test_the_group_follows_the_last_quick_actions(self):
        # A second `Quick Actions` (e.g. another extension's submenu) with a look-alike run before Finder's own.
        decoy = finderui.MenuItem(90, 'Quick Actions', True, (565, 100), (90,), [])
        fakes = [finderui.MenuItem(91 + i, title, True, (565, 120 + i), (91 + i,), [])
                 for i, title in enumerate(self.GROUP)]
        items = [decoy] + fakes + self.items
        self.assertEqual(finderui.find_group_item(items, 'Copy Path', group=self.GROUP)[0].point, (565, 598))
        self.assertEqual(finderui.rclick_group(items)[0].point, (565, 598))


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


class PanelGrant(unittest.TestCase):
    # The panel shows /tmp/run/fixtures (location pop-up `fixtures`, rows with AXURL); the sidebar also lists a
    # `rclick-cal` favourite. The file list, the pop-up and the AXURL values are ASSUMED (fixtures/README.md).
    def setUp(self):
        self.nodes = dump('panel-grant.jsonl')

    def test_target_row_in_the_file_list_is_selected_not_the_sidebar_favourite(self):
        plan = finderui.panel_plan(self.nodes, '/tmp/run/fixtures/rclick-cal')
        self.assertEqual((plan.mode, plan.row_path, plan.button_path), ('row', (0, 0, 1, 0, 0), (0, 4)))

    def test_the_folder_the_panel_already_shows_is_granted_without_a_row(self):
        plan = finderui.panel_plan(self.nodes, '/tmp/run/fixtures/')
        self.assertEqual((plan.mode, plan.row_path, plan.button_path), ('current', None, (0, 4)))

    def test_a_same_named_folder_under_another_parent_is_refused(self):
        with self.assertRaisesRegex(finderui.Refused, "panel shows 'fixtures'"):
            finderui.panel_plan(self.nodes, '/tmp/elsewhere/rclick-cal')

    def without(self, role):
        return [node for node in self.nodes if node['role'] != role]

    def test_a_different_full_path_with_the_same_basenames_is_refused(self):
        # audit r1 F3: only basenames were compared, so all three were granted as if they were the shown folder.
        with self.assertRaisesRegex(finderui.Refused, "panel shows 'fixtures'"):
            finderui.panel_plan(self.nodes, '/tmp/other/fixtures/rclick-cal')
        with self.assertRaisesRegex(finderui.Refused, "panel shows 'fixtures'"):
            finderui.panel_plan(self.nodes, '/tmp/other/fixtures')
        with self.assertRaisesRegex(finderui.Refused, "panel shows 'fixtures'"):
            finderui.panel_plan(self.without('AXPopUpButton'), '/tmp/other/fixtures/rclick-cal')

    def test_the_full_path_comes_from_the_rows_urls_not_the_pop_up(self):
        plan = finderui.panel_plan(self.without('AXPopUpButton'), '/tmp/run/fixtures/rclick-cal')
        self.assertEqual((plan.mode, plan.location), ('row', '/tmp/run/fixtures'))

    def test_a_panel_whose_location_cannot_be_established_is_refused(self):
        nodes = [dict(node, url=None) for node in self.nodes]
        with self.assertRaisesRegex(finderui.Refused, 'full location'):
            finderui.panel_plan(nodes, '/tmp/run/fixtures/rclick-cal')
        nodes = [dict(node, value='elsewhere') if node['role'] == 'AXPopUpButton' else node for node in self.nodes]
        with self.assertRaisesRegex(finderui.Refused, 'pop-up'):
            finderui.panel_plan(nodes, '/tmp/run/fixtures/rclick-cal')

    def selected(self, *paths):
        return [dict(node, selected=tuple(node['path']) in paths) if node['role'] == 'AXRow' else node
                for node in self.nodes]

    def test_current_mode_needs_no_selected_row(self):
        # An NSOpenPanel returns the selected subfolder, not the folder it shows.
        with self.assertRaisesRegex(finderui.Refused, 'selected'):
            finderui.panel_plan(self.selected((0, 0, 1, 0, 2)), '/tmp/run/fixtures')
        self.assertEqual(finderui.panel_ready(self.nodes, '/tmp/run/fixtures').mode, 'current')

    def test_row_mode_is_ready_only_when_the_target_is_the_one_selected_row(self):
        self.assertEqual(finderui.panel_ready(self.selected((0, 0, 1, 0, 0)), '/tmp/run/fixtures/rclick-cal').row_path,
                         (0, 0, 1, 0, 0))
        for rows in ((), ((0, 0, 1, 0, 2),), ((0, 0, 1, 0, 0), (0, 0, 1, 0, 2))):
            with self.subTest(selected=rows), self.assertRaisesRegex(finderui.Refused, 'selected'):
                finderui.panel_ready(self.selected(*rows), '/tmp/run/fixtures/rclick-cal')

    def test_a_folder_that_is_not_listed_is_refused(self):
        with self.assertRaisesRegex(finderui.Refused, 'no row'):
            finderui.panel_plan(self.nodes, '/tmp/run/fixtures/missing')

    def test_a_panel_without_the_button_is_refused(self):
        with self.assertRaisesRegex(finderui.Refused, "button titled 'Choose'"):
            finderui.panel_plan(self.nodes, '/tmp/run/fixtures/rclick-cal', button='Choose')

    def test_relative_folder_is_refused(self):
        with self.assertRaisesRegex(finderui.Usage, 'absolute'):
            finderui.panel_plan(self.nodes, 'fixtures/rclick-cal')


class ProcessAllowList(unittest.TestCase):
    """press-button and grant press only in RClick (its rclick.pid), RClick's FinderSyncExt, Finder or an osascript
    the calibration started; never in a system or privacy prompt (audit r1 opus M3). Process table recorded with
    `ps -axo pid=,comm=` on the test Mac (build paths replaced; RClick, osascript and the other extension added)."""

    def setUp(self):
        self.table = finderui.parse_process_table((FIXTURES / 'process-table.txt').read_text(encoding='utf-8'))

    def test_the_table_maps_pids_to_full_executable_paths(self):
        self.assertEqual(self.table[562], '/System/Applications/System Settings.app/Contents/MacOS/System Settings')
        self.assertEqual(len(self.table), 10)

    def test_rclick_its_extension_finder_and_the_calibration_osascript_are_allowed(self):
        self.assertEqual(finderui.allowed_process(415, self.table), 'Finder')
        self.assertEqual(finderui.allowed_process(2087, self.table), 'FinderSyncExt')
        self.assertEqual(finderui.allowed_process(28075, self.table, rclick_pid=28075), 'RClick')
        self.assertEqual(finderui.allowed_process(50001, self.table, extra_pids={50001}), 'calibration osascript')

    def test_system_and_privacy_prompts_and_unbound_processes_are_refused(self):
        for pid, kwargs in ((92997, {}), (27725, {}), (3610, {}), (562, {}), (85839, {}), (60606, {}),
                            (28075, {}), (50001, {}), (92997, {'rclick_pid': 92997}), (1234, {})):
            with self.subTest(pid=pid, **{k: str(v) for k, v in kwargs.items()}):
                with self.assertRaises(finderui.Refused):
                    finderui.allowed_process(pid, self.table, **kwargs)


class Arguments(unittest.TestCase):
    def test_commands_parse_into_their_options(self):
        args = finderui.parse_args(['open-menu', '%2541.txt', '--option'])
        self.assertEqual((args.command, args.name, args.option), ('open-menu', '%2541.txt', True))
        args = finderui.parse_args(['choose', '620,225', 'New File', '--sub', 'TXT', '--target', '/tmp/a b.txt',
                                    '--group', 'Copy Path', '--group', 'New File'])
        self.assertEqual((args.point, args.title, args.sub, args.target), ((620, 225), 'New File', 'TXT', ['/tmp/a b.txt']))
        self.assertEqual(args.group, ['Copy Path', 'New File'])
        args = finderui.parse_args(['guard', '620,225', '--background', '/tmp/rclick-cal'])
        self.assertEqual((args.targets, args.background), ([], '/tmp/rclick-cal'))
        args = finderui.parse_args(['press-button', '4242', 'Delete', '--window-text', 'Permanently delete'])
        self.assertEqual((args.pid, args.title, args.window_text), (4242, 'Delete', 'Permanently delete'))

    def test_bad_arguments_are_usage_errors(self):
        for argv in ([], ['bogus'], ['menu', 'a,b'], ['menu', '620'], ['select', 'alpha.txt'],
                     ['guard', '620,225'], ['guard', '620,225', '/tmp/a', '--background', '/tmp'],
                     ['choose', '620,225', 'Copy Path'], ['choose', '620,225', 'Copy Path', '--target', '/tmp/a'],
                     ['dialog', 'Finder'], ['grant', '4242', 'fixtures'],
                     ['open-menu'], ['calibrate', 'relative/run']):
            with self.subTest(argv=argv), self.assertRaises(finderui.Usage):
                finderui.parse_args(argv)

    def test_menu_probe_points_start_right_below_the_click(self):
        # A context menu opens to the lower right of the click unless a screen edge flips it.
        self.assertEqual(finderui.probe_points((620, 225)), [(660, 237), (660, 213), (580, 237), (580, 213)])


class Calibration(unittest.TestCase):
    def all_pass(self):
        return [(step, 'PASS', 'ok') for step, _ in finderui.CALIBRATION_STEPS]

    def test_every_helper_has_a_calibration_step(self):
        steps = [step for step, _ in finderui.CALIBRATION_STEPS]
        for step in ('accessibility', 'gui-lock', 'row-order', 'select-readback', 'context-menu', 'menu-read',
                     'rclick-group', 'guard', 'choose', 'dialog-read', 'press-button', 'panel-grant-row',
                     'panel-grant-current'):
            self.assertIn(step, steps)

    def test_all_pass_prints_one_line_per_helper_and_exits_zero(self):
        lines, code = finderui.calibration_report(self.all_pass())
        self.assertEqual(code, 0)
        self.assertEqual(len(lines), len(finderui.CALIBRATION_STEPS) + 1)
        self.assertTrue(lines[-1].startswith('CALIBRATION PASS'))

    def test_a_failed_helper_is_named_with_the_command_to_distrust(self):
        results = self.all_pass()
        results[[r[0] for r in results].index('context-menu')] = ('context-menu', 'FAIL', 'no menu opened')
        results[[r[0] for r in results].index('choose')] = ('choose', 'SKIP', 'needs the context menu')
        lines, code = finderui.calibration_report(results)
        self.assertEqual(code, 65)
        self.assertIn('FAIL context-menu — no menu opened', lines)
        self.assertEqual(lines[-1], 'CALIBRATION FAIL — distrust: ui.sh open-menu, ui.sh choose')

    def test_an_environment_failure_exits_seventy(self):
        results = [(step, 'FAIL', 'not trusted') if step == 'accessibility' else (step, 'SKIP', 'blocked')
                   for step, _ in finderui.CALIBRATION_STEPS]
        lines, code = finderui.calibration_report(results)
        self.assertEqual(code, 70)
        self.assertEqual(lines[-1], 'CALIBRATION FAIL — environment (accessibility): fix it and rerun; '
                                    'distrust: every ui.sh command')

    def test_a_missing_step_result_is_a_failure_not_a_pass(self):
        lines, code = finderui.calibration_report(self.all_pass()[:-1])
        self.assertEqual(code, 65)
        self.assertIn('not run', lines[-2])



class Lock(unittest.TestCase):
    """`gui-lock.sh status` must show ONE complete owner record of THIS run's acquisition (batch and acquisition id
    exported from `gui-lock.sh acquire`). The record's pid is the short-lived acquire process (gui-lock.sh protocol),
    so the acquisition id, not pid liveness, tells this run's lock from a stale or another session's lock."""
    ID = '0b6f2c1e-8d3a-4f5b-9c7d-1e2f3a4b5c6d'
    HELD = ('HELD:\n  project=rclick\n  session=rclick-delegator\n  batch=i32-cal\n  start=2026-11-18T01:00:00+0800\n'
            '  pid=4242\n  expected_minutes=30\n  purpose=device run\n  acquisition_id=' + ID + '\n')

    def refused(self, status, batch='i32-cal', acquisition=ID):
        with self.assertRaisesRegex(finderui.Environment, 'GUI lock'):
            finderui.check_lock(status, batch, acquisition)

    def test_gui_lock_must_be_held_by_this_rclick_run(self):
        # Before this fix: lock_held_by_rclick(held) was True for any HELD + project=rclick record.
        self.assertIsNone(finderui.check_lock(self.HELD, 'i32-cal', self.ID))
        self.refused('FREE\n')
        self.refused(self.HELD.replace('project=rclick', 'project=picsee'))

    def test_near_miss_owner_records_are_refused(self):
        for name, status in (
                ('substring project', self.HELD.replace('project=rclick', 'project=rclick-old')),
                ('no HELD header', self.HELD.replace('HELD:\n', 'LOCKED:\n')),
                ('two projects', self.HELD.replace('HELD:\n', 'HELD:\n  project=picsee\n')),
                ('missing fields', 'HELD:\n  project=rclick\n  batch=i32-cal\n  acquisition_id=' + self.ID + '\n'),
                ('unknown line', self.HELD + '  note=x\n'),
                ('invalid lock path', 'HELD:\n  (invalid lock path; do not start GUI work)\n'),
                ('owner line without indent', self.HELD.replace('  purpose=', 'purpose=')),
                ('non-numeric pid', self.HELD.replace('pid=4242', 'pid=x'))):
            with self.subTest(name):
                self.refused(status)

    def test_another_run_or_a_stale_acquisition_is_refused(self):
        self.refused(self.HELD, batch='i31-cal')  # another rclick session's live lock
        self.refused(self.HELD, acquisition='5d1c0e2a-6b7f-4a8e-9d0c-2f3e4a5b6c7d')  # a crashed run's stale lock
        self.refused(self.HELD, batch='', acquisition='')  # the caller did not export its acquisition


if __name__ == '__main__':
    unittest.main()
