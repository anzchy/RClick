"""Offline tests of the ui.sh / calibrate.sh command line: exit codes and refusals that happen before any AX,
AppleScript or desktop call. A fake osascript/xcrun/pgrep on PATH records any call; none may happen here."""
import collections
import contextlib
import io
import json
import os
import re
import signal
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
SKILL = HERE.parent
TRAP = '#!/bin/sh\necho "$0 $*" >> "$TRAP_LOG"\nexit 99\n'
sys.path.insert(0, str(HERE))
import finderdrive  # noqa: E402
import finderui  # noqa: E402

FIXTURES = HERE / 'fixtures'
DIR = '/tmp/rclick-cal'
ACQUISITION = '0b6f2c1e-8d3a-4f5b-9c7d-1e2f3a4b5c6d'
LOCK_ENV = {'RCLICK_GUI_LOCK_BATCH': 'i32-cal', 'RCLICK_GUI_LOCK_ACQUISITION_ID': ACQUISITION}
HELD = ('HELD:\n  project=rclick\n  session=rclick-delegator\n  batch=i32-cal\n  start=2026-11-18T01:00:00+0800\n'
        '  pid=4242\n  expected_minutes=30\n  purpose=device run\n  acquisition_id=' + ACQUISITION + '\n')
FINDER = 415
GROUP = ('--group', 'Copy Path', '--group', 'Copy File Name', '--group', 'Delete Direct', '--group', 'Terminal',
         '--group', 'New File')


def fixture(name):
    return (FIXTURES / name).read_text(encoding='utf-8')


def top_titles(menu_text):
    nodes = [json.loads(line) for line in menu_text.splitlines() if line.strip()]
    return [node['title'] for node in sorted(nodes, key=lambda n: n['path']) if len(node['path']) == 1]


FOLDER = '/Users/tester/runs/run-1/fixtures/calibration-x1y2z3'  # the folder of fixtures/finder-window-calibration.jsonl
TIMEOUT = 'osascript timed out after 20 s'


def menu_for(template, selection, folder):
    """The menu Finder opens for `selection` (fixtures/menu-file-alpha.jsonl with its Compress title rewritten): one
    item names it, N items count them, an empty selection (window background) has no Compress item."""
    lines = []
    for line in template.splitlines():
        if not line.strip():
            continue
        node = json.loads(line)
        if node.get('title', '').startswith('Compress '):
            if not selection:
                continue
            node['title'] = (f'Compress “{selection[0].rsplit("/", 1)[-1]}”' if len(selection) == 1
                             else f'Compress {len(selection)} Items')
        lines.append(json.dumps(node, ensure_ascii=False))
    return '\n'.join(lines) + '\n'


FakeRow = collections.namedtuple('FakeRow', 'url name frame')


def inside(frame, point):
    x, y, width, height = frame
    return x <= point[0] < x + width and y <= point[1] < y + height


class FakeDesktop:
    """The process boundary of finderdrive (`run`, `spawn`, `executable_of`) answered offline as Finder does on the
    device (run of 2026-11-18): while a Finder context menu is open, every AppleScript call to Finder times out (the
    fake raises what finderdrive.run raises on a timeout) and System Events' frontmost check does not see Finder;
    System Events still answers. A right-click opens the menu of the row under the point (selecting it first when it
    was not selected) or the window-background menu; the menu stays open until AXCancel (menu-cancel, or a session
    abort), an Esc to Finder or a press. An axprobe menu session answers a press the way axprobe.swift does: it
    compares the request's owner pid and full top-level title list with the menu open NOW and exits 65 on a
    difference. `menu_delay` menu-at polls answer "no menu" before a fresh menu shows (a cold first menu).

    HID modifier state (device run, 2026-11-18): `hid_flags` is CGEventSourceFlagsState of the HID system. The fake
    `rightclick.sh X Y option` sets the Option bit and never clears it (the script of 09eee72 did exactly that; the
    script's own release is checked by Source tests); only `modifiers.sh release option` clears it. A menu is built
    from the state at the click: with Option set, Delete Direct reads `Delete Direct (skip confirmation)`, also on a
    plain click, as on the device."""
    OPTION = 0x80000

    def __init__(self, menu=None, selection=(), menu_pid=FINDER, folder=FOLDER, window=None):
        self.template = menu or fixture('menu-file-alpha.jsonl')
        self.fixed_menu = None  # a menu text to show whatever the selection (a menu of another row)
        self.selection, self.menu_pid, self.folder = list(selection), menu_pid, folder
        self.window = (window or fixture('finder-window-calibration.jsonl')).replace(FOLDER, folder)
        self.ax_selection = None  # AX rows marked selected, when they differ from the AppleScript selection
        self.selection_reply = None  # what SELECTION_SCRIPT answers, when it differs from self.selection
        self.deselect_works = True
        self.menu = None  # the open menu's dump, or None
        self.menu_delay, self.polls_left = 0, 0
        self.cancel_works = self.esc_works = True
        self.menu_at_press = None
        self.cancelled = []  # owner pid of every menu a cancel (AXCancel) closed
        self.menu_at_errors = 0  # menu-at answers an AX error (exit 70) this many times while a menu is open
        self.abort_hangs = self.session_fails = False  # a session abort times out; a session ends with an AX error
        self.before_click = None  # called (desktop, x, y) as a right-click lands, before Finder handles it
        self.before_dump = None  # called (desktop, n) before the n-th dump of the Finder window (1-based)
        self.finder_dumps = 0
        self.window_error_with_menu = None  # what axprobe answers for the Finder window while a menu is open
        self.calls, self.requests, self.pressed, self.clicks, self.timeouts, self.keys = [], [], [], [], [], []
        self.windows, self.acted, self.after_act = fixture('dialog-delete-confirm.jsonl'), [], []
        self.hid_flags = 0x20000000  # the non-modifier bit the device showed beside Option; no key held
        self.release_works = True
        self.releases = []  # the modifier names of every `modifiers.sh release`
        self.during_click = None  # called (desktop) inside rightclick.sh after the flags were posted: may raise
        self.click_code = 0  # rightclick.sh's exit code (after it posted its events)

    def completed(self, argv, out='', code=0, err=''):
        return subprocess.CompletedProcess(argv, code, out, err)

    def finder_window(self):
        chosen = self.selection if self.ax_selection is None else self.ax_selection
        lines = []
        for line in self.window.splitlines():
            if not line.strip():
                continue
            node = json.loads(line)
            if node['role'] == 'AXRow' and node['path'][:4] == [0, 0, 2, 0]:
                url = next((json.loads(l)['url'] for l in self.window.splitlines() if l.strip()
                            and json.loads(l)['path'][:len(node['path'])] == node['path'] and json.loads(l)['url']), None)
                node['selected'] = url is not None and url in chosen
            lines.append(json.dumps(node, ensure_ascii=False))
        return '\n'.join(lines) + '\n'

    def rows(self):
        """The window's file rows as (url, name, frame), read from the dump itself rather than through finderui, so
        the fake does not depend on the code it tests."""
        nodes = [json.loads(line) for line in self.window.splitlines() if line.strip()]
        rows = []
        for node in nodes:
            if node['role'] == 'AXRow' and node['path'][:4] == [0, 0, 2, 0]:
                url = next((n['url'] for n in nodes if n['path'][:len(node['path'])] == node['path'] and n['url']), None)
                if url:
                    rows.append(FakeRow(url, url.rsplit('/', 1)[-1], tuple(node['frame'])))
        return rows

    def right_click(self, x, y, option):
        self.clicks.append((x, y, option))
        if option:
            self.hid_flags |= self.OPTION
        if self.before_click:
            self.before_click(self, x, y)
        hit = next((row for row in self.rows() if inside(row.frame, (x, y))), None)
        if hit is None:
            self.selection = []
        elif hit.url not in self.selection:
            self.selection = [hit.url]
        menu = self.fixed_menu or menu_for(self.template, sorted(self.selection), self.folder)
        if self.hid_flags & self.OPTION:
            menu = menu.replace('"Delete Direct"', '"Delete Direct (skip confirmation)"')
        self.menu, self.polls_left = menu, self.menu_delay

    def menu_shows(self):
        if self.menu is None:
            return False
        if self.polls_left:
            self.polls_left -= 1
            return False
        return True

    def osascript(self, argv):
        script, args = argv[2], argv[3:]
        if 'application "Finder"' in script:
            if self.menu is not None:
                self.timeouts.append(script)
                raise finderui.Environment(TIMEOUT)
            if 'select chosen' in script:
                self.selection = list(args)
            elif 'set selection to {}' in script:
                if self.deselect_works:
                    self.selection = []
            elif 'selection as alias list' in script:
                paths = self.selection if self.selection_reply is None else self.selection_reply
                return self.completed(argv, f'{len(paths)}\n' + ''.join(p + '\n' for p in paths) + '\n')
            elif 'front Finder window' in script:
                return self.completed(argv, self.folder + '/\n')
            return self.completed(argv, '\n')
        if 'key code 53' in script:
            self.keys.append(script)
            if 'frontmost is true' in script:  # the old frontmost check: System Events did not see Finder in front
                return self.completed(argv, 'skipped: Finder is not frontmost\n' if self.menu else 'escaped\n')
            if self.menu is not None and self.esc_works:
                self.menu = None
            return self.completed(argv, '\n')
        return self.completed(argv, '\n')  # System Events: bring Finder to the front

    def axprobe(self, argv):
        command = argv[1]
        if command == 'trusted':
            return self.completed(argv, 'true\n')
        if command == 'menu-at':
            if self.menu is not None and self.menu_at_errors:
                self.menu_at_errors -= 1
                return self.completed(argv, '', 70, 'axprobe: cannot read the element at the point: AXError -25204\n')
            if self.menu_shows():
                return self.completed(argv, self.menu)
            return self.completed(argv, '', 65, f'axprobe: no menu at {argv[2]},{argv[3]} (found AXTextField)\n')
        if command == 'menu-cancel':
            if self.menu is None:
                return self.completed(argv, '', 65, 'axprobe: no menu\n')
            if int(argv[4]) != self.menu_pid:
                return self.completed(argv, '', 65, f'axprobe: the menu belongs to pid {self.menu_pid}\n')
            if not self.cancel_works:
                return self.completed(argv, '', 70, 'axprobe: AXCancel on the menu failed\n')
            self.cancelled.append(self.menu_pid)
            self.menu = None
            return self.completed(argv, 'cancelled\n')
        if command == 'dump':
            if argv[2] == str(FINDER) and argv[3] == '0':
                self.finder_dumps += 1
                if self.before_dump:
                    self.before_dump(self, self.finder_dumps)
                if self.menu is not None and self.window_error_with_menu:
                    return self.completed(argv, '', 70, self.window_error_with_menu)
                return self.completed(argv, self.finder_window())
            return self.completed(argv, self.windows)
        if command == 'act':
            self.acted.append(argv[2:])
            if argv[2] == str(FINDER) and argv[4] == 'select':
                self.selection = [row.url for row in self.rows() if row.name == argv[6]]
            elif self.after_act:
                self.windows = self.after_act.pop(0)
            return self.completed(argv, f'{argv[4]} ok\n')
        return self.completed(argv, '', 64, f'fake axprobe: {command} not expected')

    def run(self, argv, timeout=20):
        argv = [str(a) for a in argv]
        name = Path(argv[0]).name
        self.calls.append(argv)
        if name == 'gui-lock.sh':
            return self.completed(argv, HELD)
        if name == 'pgrep':
            return self.completed(argv, f'{FINDER}\n')
        if name == 'rightclick.sh':
            self.right_click(int(argv[1]), int(argv[2]), argv[3:] == ['option'])
            if self.during_click:
                self.during_click(self)
            return self.completed(argv, 'right-clicked\n' if not self.click_code else '', self.click_code,
                                  'rightclick.sh: osascript failed\n' if self.click_code else '')
        if name == 'modifiers.sh':
            return self.modifiers(argv)
        if name == 'axprobe':
            return self.axprobe(argv)
        if name == 'osascript':
            return self.osascript(argv)
        return self.completed(argv, '', 99, f'fake desktop: unexpected {name}')

    def modifiers(self, argv):
        if argv[1:] == ['state']:
            return self.completed(argv, f'flags=0x{self.hid_flags:x}\n')
        if argv[1] == 'release' and argv[2:]:
            self.releases.append(argv[2:])
            if self.release_works and 'option' in argv[2:]:
                self.hid_flags &= ~self.OPTION
            return self.completed(argv, f'flags=0x{self.hid_flags:x}\n')
        return self.completed(argv, '', 2, 'usage: modifiers.sh state | release MODIFIER...\n')

    def executable_of(self, pid):
        """The resolved executable of pid from the recorded capture (fixtures/process-table.txt)."""
        for line in fixture('process-table.txt').splitlines():
            if line and not line.startswith('#') and line.split('\t')[0] == str(pid):
                return line.split('\t')[2]
        return None

    def spawn(self, argv):
        argv = [str(a) for a in argv]
        self.calls.append(argv)
        return FakeSession(self, argv)


class FakeSession:
    """`axprobe menu-session X Y DEPTH OWNER` as axprobe.swift answers it. Every cancel (abort, no decision, a press
    refused) is a REAL cancel of the desktop's menu, made only when OWNER owns it (cancelOwned); an older argv
    without OWNER is answered as the axprobe of that argv did: it cancelled whatever menu it held."""

    def __init__(self, desktop, argv):
        self.desktop, self.returncode = desktop, None
        self.owner = int(argv[5]) if len(argv) > 5 else None
        if desktop.session_fails:
            self.stdout = io.BytesIO(b'')
            self.ended = (b'', b'axprobe: cannot read the menu\'s owner pid\n', 70)
            return
        if not desktop.menu_shows():
            self.stdout = io.BytesIO(b'')
            self.ended = (b'', b'axprobe: no menu at the point (found AXTextField)\n', 65)
            return
        self.ended = None
        lines = [json.dumps({'session': {'pid': desktop.menu_pid}})] + [
            line for line in desktop.menu.splitlines() if line.strip()] + [json.dumps({'end': True})]
        self.stdout = io.BytesIO(('\n'.join(lines) + '\n').encode())

    def cancel(self):
        if self.owner is not None and self.owner != self.desktop.menu_pid:
            return 'left open'
        if self.desktop.cancel_works:
            self.desktop.cancelled.append(self.desktop.menu_pid)
            self.desktop.menu = None
        return 'menu cancelled'

    def communicate(self, input=None, timeout=None):
        if self.ended:
            out, err, self.returncode = self.ended
            return out, err
        if input is None:
            self.returncode = 65
            return b'', f'axprobe: no decision from the driver: nothing pressed; {self.cancel()}\n'.encode()
        request = json.loads(input.decode())
        self.desktop.requests.append(request)
        if 'abandon' in request:
            self.returncode = 0
            return b'abandoned: menu left as it is\n', b''
        if 'abort' in request and self.desktop.abort_hangs:
            raise subprocess.TimeoutExpired('axprobe menu-session', timeout)
        if 'abort' in request:
            self.returncode = 0
            return f'aborted: {self.cancel()}\n'.encode(), b''
        now = self.desktop.menu_at_press or self.desktop.menu
        if request.get('pid') != self.desktop.menu_pid or self.owner not in (None, self.desktop.menu_pid):
            self.returncode = 65
            return b'', b"axprobe: the menu's owner changed since it was verified: nothing pressed\n"
        if request.get('titles') != top_titles(now):
            self.returncode = 65
            self.cancel()
            return b'', b'axprobe: the menu changed since it was verified: nothing pressed\n'
        self.desktop.pressed.append(request)
        self.desktop.menu = None  # a pressed menu closes
        self.returncode = 0
        return b'press ok\n', b''

    def kill(self):
        self.returncode = -9

    def wait(self, timeout=None):
        return self.returncode


def drive(desktop, *argv):
    """finderdrive.main with only the process boundary replaced; returns (exit code, stdout, stderr)."""
    out, err = io.StringIO(), io.StringIO()
    with mock.patch.dict(os.environ, LOCK_ENV), mock.patch.object(finderdrive, 'run', desktop.run), \
            mock.patch.object(finderdrive, 'spawn', desktop.spawn, create=True), \
            mock.patch.object(finderdrive, 'executable_of', desktop.executable_of, create=True), \
            mock.patch.object(finderdrive, 'probe_binary', lambda: Path('/fake/axprobe')), \
            mock.patch.object(finderdrive.time, 'sleep', lambda seconds: None), \
            contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = finderdrive.main(list(argv))
    return code, out.getvalue(), err.getvalue()


class ChooseAtTheActingBoundary(unittest.TestCase):
    """`choose` is ONE process from selection to press (fix r3 items 1 and 7): it selects the target through
    AppleScript BEFORE the menu opens, verifies the row's full path and the selected rows through AX, right-clicks,
    and decides and presses inside one axprobe menu session, with no Finder AppleScript while the menu is open
    (the device run of 2026-11-18 saw every such call time out). Every refusal closes the menu."""
    ALPHA = FOLDER + '/alpha.txt'

    def choose(self, desktop, *extra, title='Copy Path', targets=(ALPHA,)):
        args = [arg for target in targets for arg in ('--target', target)]
        return drive(desktop, 'choose', title, *args, *GROUP, *extra)

    def assert_clean_refusal(self, desktop, code, err):
        self.assertEqual(code, 65, err)
        self.assertEqual(desktop.pressed, [])
        self.assertIsNone(desktop.menu, 'the menu was left open')
        self.assertEqual(desktop.timeouts, [])

    def test_a_verified_menu_is_pressed_with_its_identity_and_no_finder_applescript_while_it_is_open(self):
        desktop = FakeDesktop()
        code, out, err = self.choose(desktop)
        self.assertEqual(code, 0, err)
        self.assertEqual(desktop.timeouts, [])
        self.assertEqual(len(desktop.clicks), 1)
        self.assertEqual(desktop.clicks[0][:2], (318, 415))  # alpha.txt's name field centre in the recorded dump
        self.assertEqual(len(desktop.pressed), 1)
        request = desktop.pressed[0]
        self.assertEqual((request['press'], request['title'], request['pid']), ([27], 'Copy Path', FINDER))
        self.assertIn('Compress “alpha.txt”', out)
        self.assertIn('chose: Copy Path', out)

    def test_several_targets_need_every_row_and_the_count_title(self):
        targets = (FOLDER + '/%41.txt', FOLDER + '/%2541.txt')
        desktop = FakeDesktop()
        code, out, err = self.choose(desktop, targets=targets)
        self.assertEqual(code, 0, err)
        self.assertIn('Compress 2 Items', out)
        self.assertEqual(desktop.timeouts, [])

    def test_a_menu_replaced_by_the_siblings_before_the_press_is_not_pressed(self):
        desktop = FakeDesktop()
        desktop.menu_at_press = fixture('menu-file-sibling-option.jsonl')  # same Copy Path at the same index
        code, _, err = self.choose(desktop)
        self.assert_clean_refusal(desktop, code, err)
        self.assertIn('nothing pressed', err)

    def test_the_menu_of_another_row_is_refused_and_closed(self):
        desktop = FakeDesktop()
        desktop.fixed_menu = fixture('menu-file-sibling-option.jsonl')  # Compress “%41.txt” for the alpha.txt click
        code, _, err = self.choose(desktop)
        self.assert_clean_refusal(desktop, code, err)
        self.assertIn('Compress “%41.txt”', err)

    def test_a_selection_ax_does_not_confirm_is_not_clicked(self):
        # AppleScript reads back the target, but AX marks another row selected (or none): nothing is clicked.
        for shown in ([FOLDER + "/%41.txt"], [], [self.ALPHA, FOLDER + '/beta.txt']):
            with self.subTest(ax=shown):
                desktop = FakeDesktop()
                desktop.ax_selection = shown
                code, _, err = self.choose(desktop)
                self.assertEqual(code, 65, err)
                self.assertEqual(desktop.clicks, [])
                self.assertIn('selection (AX)', err)

    def test_a_row_whose_full_path_is_not_the_target_is_not_clicked(self):
        # Same name, another folder: the basename alone (all a Compress title carries) would pass.
        desktop = FakeDesktop()
        code, _, err = self.choose(desktop, targets=('/tmp/elsewhere/alpha.txt',))
        self.assertEqual(code, 65, err)
        self.assertEqual(desktop.clicks, [])
        self.assertIn('not the target', err)

    def test_a_menu_owned_by_another_process_is_not_pressed_and_is_left_open(self):
        # audit r3 gpt F2: the refusal aborted the session and axprobe AXCancelled the foreign menu with no owner check.
        desktop = FakeDesktop(menu_pid=999)
        code, _, err = self.choose(desktop)
        self.assertEqual(code, 65, err)
        self.assertEqual(desktop.pressed, [])
        self.assertIn('not Finder', err)
        self.assertEqual(desktop.keys, [], 'an Esc was sent to a menu of another process')
        self.assertEqual(desktop.cancelled, [], 'a menu of another process was cancelled')
        self.assertIsNotNone(desktop.menu, 'the menu of another process was closed')

    def test_the_session_is_told_finders_pid_so_axprobe_can_check_the_owner_before_any_cancel(self):
        desktop = FakeDesktop()
        desktop.fixed_menu = fixture('menu-file-sibling-option.jsonl')  # a refusal: the session is aborted
        code, _, err = self.choose(desktop)
        self.assertEqual(code, 65, err)
        sessions = [call for call in desktop.calls if call[1:2] == ['menu-session']]
        self.assertEqual([call[5:] for call in sessions], [[str(FINDER)]])
        self.assertEqual(desktop.cancelled, [FINDER])

    def test_a_slow_first_menu_is_waited_for(self):
        desktop = FakeDesktop()
        desktop.menu_delay = 8  # two full probe rounds answer "no menu" first
        code, _, err = self.choose(desktop)
        self.assertEqual(code, 0, err)
        self.assertEqual(len(desktop.pressed), 1)

    def test_a_menu_that_never_shows_names_what_axprobe_found(self):
        desktop = FakeDesktop()
        desktop.menu_delay = 10 ** 6
        code, _, err = self.choose(desktop)
        self.assertEqual(code, 65, err)
        self.assertEqual(desktop.pressed, [])
        self.assertIn('found AXTextField', err)

    def test_a_refusal_closes_the_menu_with_esc_when_axcancel_does_not(self):
        desktop = FakeDesktop()
        desktop.fixed_menu = fixture('menu-file-sibling-option.jsonl')
        desktop.cancel_works = False
        code, _, err = self.choose(desktop)
        self.assertEqual(code, 65, err)
        self.assertIsNone(desktop.menu)
        self.assertEqual(len(desktop.keys), 1)
        self.assertNotIn('frontmost', desktop.keys[0])

    def test_a_menu_that_cannot_be_closed_is_reported(self):
        desktop = FakeDesktop()
        desktop.fixed_menu = fixture('menu-file-sibling-option.jsonl')
        desktop.cancel_works = desktop.esc_works = False
        code, _, err = self.choose(desktop)
        self.assertEqual(code, 65, err)
        self.assertEqual(desktop.pressed, [])
        self.assertIn('could not be closed', err)
        self.assertIn('close it by hand', err)

    def test_the_standalone_guard_is_gone(self):
        desktop = FakeDesktop()
        code, _, err = drive(desktop, 'guard', '660,237', self.ALPHA)
        self.assertEqual(code, 64, err)
        self.assertEqual(desktop.calls, [])

    def test_option_is_held_on_the_click_that_opens_the_menu(self):
        desktop = FakeDesktop()
        code, out, err = self.choose(desktop, '--option', title='Delete Direct (skip confirmation)')
        self.assertEqual(code, 0, err)
        self.assertTrue(desktop.clicks[0][2])
        self.assertEqual(desktop.pressed[0]['title'], 'Delete Direct (skip confirmation)')


def row_at(desktop, x, y):
    return next(row.url for row in desktop.rows() if inside(row.frame, (x, y)))


def shifted(window, dy):
    """The window dump with every file-list row (and what it holds) moved down by `dy` points."""
    lines = []
    for line in window.splitlines():
        if line.strip():
            node = json.loads(line)
            if len(node['path']) > 4 and node['path'][:4] == [0, 0, 2, 0] and node['frame']:
                node['frame'][1] += dy
            lines.append(json.dumps(node, ensure_ascii=False))
    return '\n'.join(lines) + '\n'


class TheMenuIsBoundToTheVerifiedRows(unittest.TestCase):
    """After the menu opens and BEFORE the press, inside the held session, the front Finder window is read again
    through AX (no AppleScript) and must still hold exactly what was verified before the click (audit r3 gpt F1 /
    opus M3): the selected rows' AXURL set is the target set and the clicked row is where it was; for a background
    menu, the front folder. A Compress title proves only a basename or a count, so a change after the last read
    before the click (another window in front with an equal name, or a same-size selection that keeps the clicked
    row) passed every check and the press acted on other files."""
    ALPHA, BETA, PCT41 = FOLDER + '/alpha.txt', FOLDER + '/beta.txt', FOLDER + '/%41.txt'

    def assert_refused_unpressed(self, desktop, code, err):
        self.assertEqual(code, 65, err)
        self.assertEqual(desktop.pressed, [])
        self.assertEqual(len(desktop.clicks), 1)
        self.assertTrue(desktop.menu is None, 'the Finder menu was left open: ' + err)
        self.assertEqual(desktop.cancelled, [FINDER])
        self.assertEqual(desktop.timeouts, [])
        self.assertIn('with the menu open', err)

    def test_a_same_size_selection_that_keeps_the_clicked_row_is_not_pressed(self):
        # {alpha, beta} verified; as the click lands the selection is {clicked row, %41}: Finder's menu still says
        # `Compress 2 Items` and the clicked row is still selected.
        def change(desktop, x, y):
            clicked = row_at(desktop, x, y)
            desktop.selection = [clicked, self.PCT41]

        desktop = FakeDesktop()
        desktop.before_click = change
        code, _, err = drive(desktop, 'choose', 'Copy Path', '--target', self.ALPHA, '--target', self.BETA, *GROUP)
        self.assert_refused_unpressed(desktop, code, err)
        self.assertIn('%41.txt', err)

    def test_a_same_basename_row_of_another_window_is_not_pressed(self):
        # As the click lands another window comes to the front with its own alpha.txt at the same place: Finder's menu
        # is `Compress “alpha.txt”` for /tmp/other-window/alpha.txt. Option: the skip-confirmation delete.
        def change(desktop, x, y):
            desktop.window = desktop.window.replace(FOLDER, '/tmp/other-window')
            desktop.selection = []

        desktop = FakeDesktop()
        desktop.before_click = change
        code, _, err = drive(desktop, 'choose', 'Delete Direct (skip confirmation)', '--option', '--target',
                             self.ALPHA, *GROUP)
        self.assert_refused_unpressed(desktop, code, err)
        self.assertIn('/tmp/other-window/alpha.txt', err)

    def test_another_front_folder_behind_a_background_menu_is_not_pressed(self):
        def change(desktop, x, y):
            desktop.window = desktop.window.replace(FOLDER, '/tmp/other-window')

        desktop = FakeDesktop()
        desktop.before_click = change
        code, _, err = drive(desktop, 'choose', 'New File', '--sub', 'TXT', *GROUP, '--background', FOLDER)
        self.assert_refused_unpressed(desktop, code, err)
        self.assertIn('/tmp/other-window', err)

    def test_a_window_that_cannot_be_read_with_the_menu_open_is_refused_not_pressed(self):
        # Whether Finder answers AX for its window while its menu is open is UNVERIFIED on a device: if it does not,
        # nothing is pressed (the calibration's choose step then fails and says so).
        desktop = FakeDesktop()
        desktop.window_error_with_menu = 'axprobe: cannot read the windows of pid 415: AXError -25204\n'
        code, _, err = drive(desktop, 'choose', 'Copy Path', '--target', self.ALPHA, *GROUP)
        self.assert_refused_unpressed(desktop, code, err)
        self.assertIn('AXError -25204', err)

    def test_the_verified_menu_is_pressed_after_the_window_was_read_again_with_it_open(self):
        reads = []
        desktop = FakeDesktop()
        desktop.before_dump = lambda desktop, n: reads.append(desktop.menu is not None)
        code, out, err = drive(desktop, 'choose', 'Copy Path', '--target', self.ALPHA, *GROUP)
        self.assertEqual(code, 0, err)
        self.assertEqual(len(desktop.pressed), 1)
        self.assertEqual(reads[-1], True, 'the window was not read with the menu open')
        self.assertIn('with the menu open', out)

    def test_a_clicked_row_found_elsewhere_with_the_menu_open_is_not_pressed(self):
        # Same files, same selection, but the clicked row is no longer under the click point (another window of the
        # same folder in front, or the list scrolled): the menu is not proven to be the clicked row's.
        def move(desktop, n):
            if desktop.menu is not None:
                desktop.window = shifted(desktop.window, 6)

        desktop = FakeDesktop()
        desktop.before_dump = move
        code, _, err = drive(desktop, 'choose', 'Copy Path', '--target', self.ALPHA, *GROUP)
        self.assert_refused_unpressed(desktop, code, err)
        self.assertIn('not at the click point', err)

    def test_a_row_that_moves_between_the_two_reads_before_the_click_is_not_clicked(self):
        # audit r3 opus M4: the "row did not move" re-read had no test.
        def move(desktop, n):
            if n == 2:
                desktop.window = shifted(desktop.window, 6)

        desktop = FakeDesktop()
        desktop.before_dump = move
        code, _, err = drive(desktop, 'choose', 'Copy Path', '--target', self.ALPHA, *GROUP)
        self.assertEqual(code, 65, err)
        self.assertEqual((desktop.clicks, desktop.pressed), ([], []))
        self.assertIn('moved', err)


class CleanupFromTheClickOnward(unittest.TestCase):
    """Every failure after this process's right-click closes the menu that click opened (audit r3 gpt F3 / opus M2):
    an AX or transport error before the session exists, a session that cannot start, an abort that times out, and the
    standalone openers. A menu left open makes the next Finder AppleScript call wait 20 s (device run, 2026-11-18).
    The original error is kept; a cleanup failure is added to it."""
    ALPHA = FOLDER + '/alpha.txt'

    def choose(self, desktop):
        return drive(desktop, 'choose', 'Copy Path', '--target', self.ALPHA, *GROUP)

    def assert_closed(self, desktop, code, err, exit_code, original):
        self.assertEqual(code, exit_code, err)
        self.assertEqual(desktop.pressed, [])
        self.assertEqual(len(desktop.clicks), 1)
        self.assertTrue(desktop.menu is None, 'the menu this right-click opened was left open: ' + err)
        self.assertEqual(desktop.cancelled, [FINDER])
        self.assertIn(original, err)
        self.assertEqual(desktop.timeouts, [])

    def test_an_ax_error_while_waiting_for_the_menu_closes_it(self):
        desktop = FakeDesktop()
        desktop.menu_at_errors = 1
        code, _, err = self.choose(desktop)
        self.assert_closed(desktop, code, err, 70, 'AXError -25204')

    def test_a_session_that_cannot_start_closes_the_menu(self):
        desktop = FakeDesktop()
        desktop.session_fails = True
        code, _, err = self.choose(desktop)
        self.assert_closed(desktop, code, err, 70, "owner pid")

    def test_an_abort_that_times_out_still_closes_the_menu_and_keeps_the_refusal(self):
        desktop = FakeDesktop()
        desktop.fixed_menu = fixture('menu-file-sibling-option.jsonl')  # refused: Compress “%41.txt”
        desktop.abort_hangs = True
        code, _, err = self.choose(desktop)
        self.assert_closed(desktop, code, err, 65, 'Compress “%41.txt”')
        self.assertIn('did not answer in 30 s', err)

    def test_the_standalone_openers_close_their_menu_when_they_fail(self):
        for argv in (('open-menu', 'alpha.txt'), ('open-menu', '--background'), ('open-menu', 'alpha.txt', '--option')):
            with self.subTest(argv=argv):
                desktop = FakeDesktop()
                desktop.menu_at_errors = 1
                code, out, err = drive(desktop, *argv)
                self.assert_closed(desktop, code, err, 70, 'AXError -25204')
                self.assertNotIn('menu-point', out)

    def test_a_cleanup_that_fails_is_reported_beside_the_original_error(self):
        desktop = FakeDesktop()
        desktop.menu_at_errors = 1
        desktop.cancel_works = desktop.esc_works = False
        code, _, err = self.choose(desktop)
        self.assertEqual(code, 70, err)
        self.assertIn('AXError -25204', err)
        self.assertIn('could not be closed', err)
        self.assertIn('close it by hand', err)


class ModifiersAreReleased(unittest.TestCase):
    """Fix r5 item 1 (device run, 2026-11-18): after calibration's `open-menu --option` the HID system state kept the
    Option flag (CGEventSourceFlagsState 0x20080000), so every later PLAIN right-click showed `Delete Direct (skip
    confirmation)` and a plain Delete Direct would have skipped its confirmation. Every path that posts Option must
    release it (modifiers.sh release) on success, on every failure, on Ctrl-C and on SIGTERM."""
    ALPHA = FOLDER + '/alpha.txt'

    def assert_released(self, desktop):
        self.assertEqual(desktop.hid_flags & FakeDesktop.OPTION, 0,
                         f'Option left set in the HID state: flags 0x{desktop.hid_flags:x}')

    def test_open_menu_with_option_releases_it_so_the_next_plain_menu_is_plain(self):
        desktop = FakeDesktop()
        code, out, err = drive(desktop, 'open-menu', 'alpha.txt', '--option')
        self.assertEqual(code, 0, err)
        point = re.search(r'menu-point (\d+,\d+)', out).group(1)
        self.assertIn('Delete Direct (skip confirmation)', drive(desktop, 'menu', point)[1])
        self.assert_released(desktop)
        self.assertEqual(drive(desktop, 'close-menu', point)[0], 0)
        code, out, err = drive(desktop, 'open-menu', 'beta.txt')
        self.assertEqual(code, 0, err)
        point = re.search(r'menu-point (\d+,\d+)', out).group(1)
        listing = drive(desktop, 'menu', point)[1]
        self.assertIn('|Delete Direct|', listing)
        self.assertNotIn('skip confirmation', listing, 'a plain right-click after the Option one showed the skip title')

    def test_choose_with_option_and_the_background_opener_release_it(self):
        for argv in (('choose', 'Delete Direct (skip confirmation)', '--option', '--target', self.ALPHA, *GROUP),
                     ('open-menu', '--background', '--option')):
            with self.subTest(argv=argv[:2]):
                desktop = FakeDesktop()
                code, _, err = drive(desktop, *argv)
                self.assertEqual(code, 0, err)
                self.assert_released(desktop)
                self.assertEqual(desktop.releases, [['option']])

    def test_a_plain_click_presses_and_releases_nothing(self):
        desktop = FakeDesktop()
        code, _, err = drive(desktop, 'choose', 'Copy Path', '--target', self.ALPHA, *GROUP)
        self.assertEqual(code, 0, err)
        self.assertEqual(desktop.releases, [])

    def test_a_failure_in_the_middle_of_the_option_flow_still_releases_it(self):
        def failing_click(desktop):
            desktop.click_code = 1

        def no_menu(desktop):
            desktop.menu_delay = 10 ** 6

        def menu_of_another_row(desktop):
            desktop.fixed_menu = fixture('menu-file-sibling-option.jsonl')

        for name, setup, exit_code in (('rightclick.sh fails after posting', failing_click, 70),
                                       ('no menu appears', no_menu, 65),
                                       ('the guard refuses the menu', menu_of_another_row, 65)):
            for argv in (('choose', 'Delete Direct (skip confirmation)', '--option', '--target', self.ALPHA, *GROUP),
                         ('open-menu', 'alpha.txt', '--option')):
                if argv[0] == 'open-menu' and setup is menu_of_another_row:
                    continue
                with self.subTest(failure=name, command=argv[0]):
                    desktop = FakeDesktop()
                    setup(desktop)
                    code, _, err = drive(desktop, *argv)
                    self.assertEqual(code, exit_code, err)
                    self.assertEqual(desktop.pressed, [])
                    self.assert_released(desktop)

    def test_ctrl_c_during_the_option_click_releases_it_and_closes_the_menu(self):
        def interrupt(desktop):
            raise KeyboardInterrupt
        desktop = FakeDesktop()
        desktop.during_click = interrupt
        try:
            code, _, err = drive(desktop, 'choose', 'Delete Direct (skip confirmation)', '--option', '--target',
                                 self.ALPHA, *GROUP)
        except KeyboardInterrupt:
            code, err = 'KeyboardInterrupt escaped ui.sh', ''
        self.assertEqual(code, 130, err)
        self.assert_released(desktop)
        self.assertIsNone(desktop.menu, 'the menu the interrupted click opened was left open')
        self.assertEqual(desktop.pressed, [])

    def test_sigterm_during_the_option_click_releases_it_and_closes_the_menu(self):
        seen = []

        def terminate(desktop):
            handler = signal.getsignal(signal.SIGTERM)
            seen.append(handler)
            if callable(handler):  # deliver the signal the way Python does: the handler runs in the main thread
                handler(signal.SIGTERM, None)
        desktop = FakeDesktop()
        desktop.during_click = terminate
        code, _, err = drive(desktop, 'open-menu', 'alpha.txt', '--option')
        self.assertTrue(callable(seen[0]), f'SIGTERM would end ui.sh with no release (handler {seen[0]!r})')
        self.assertEqual(code, 143, err)
        self.assert_released(desktop)
        self.assertIsNone(desktop.menu, 'the menu the terminated click opened was left open')
        self.assertIsNot(signal.getsignal(signal.SIGTERM), seen[0], 'main did not restore the previous handler')

    def test_a_release_that_does_not_clear_it_is_reported(self):
        desktop = FakeDesktop()
        desktop.release_works = False
        code, _, err = drive(desktop, 'open-menu', 'alpha.txt', '--option')
        self.assertEqual(code, 70, err)
        self.assertIn('could not release option', err)
        self.assertIn('press and release that key', err)
        self.assertIsNone(desktop.menu, 'the menu was left open')

    def test_a_release_failure_after_a_failed_click_reports_both(self):
        desktop = FakeDesktop()
        desktop.release_works = False
        desktop.click_code = 1
        code, _, err = drive(desktop, 'open-menu', 'alpha.txt', '--option')
        self.assertEqual(code, 70, err)
        self.assertIn('rightclick.sh failed', err)
        self.assertIn('could not release option', err)

    def test_rightclick_sh_releases_option_itself_in_a_finally_and_on_signals(self):
        source = (HERE / 'rightclick.sh').read_text(encoding='utf-8')
        script = source.split("<<'JXA'", 1)[1]
        self.assertRegex(script, r'finally\s*\{\s*if \(flags\) release\(\);\s*\}',
                         'the Option flag is not released in a finally')
        release = script[script.index('function release()'):script.index('function run(')]
        self.assertIn('CGEventSetType(changed, 12)', release)  # flagsChanged
        # fix r6 (confirm r5 gpt F1): never all-zero flags, which cleared a key someone else held; test_raw_clicks
        # runs the script itself
        self.assertNotIn('CGEventSetFlags(changed, 0)', release)
        self.assertIn('CGEventSetFlags(changed, keep)', release)
        self.assertRegex(release, r'\[58, 61\]')  # both Option keys up
        for name in ('INT', 'TERM', 'HUP'):
            self.assertRegex(source, r"trap '\"\$here/modifiers.sh\" release option[^']*' " + name + r'\n')


class AStuckModifierIsRefused(unittest.TestCase):
    """Fix r5 item 2: an acting command reads the HID modifier state (modifiers.sh state, nothing posted) and refuses
    (65) when Shift, Control, Option or Command is held that it did not press: it selects, clicks and presses nothing.
    The device run of 2026-11-18 had Option stuck, which turns Delete Direct into its skip-confirmation form."""
    ALPHA = FOLDER + '/alpha.txt'
    MASKS = (('Option', 0x80000), ('Shift', 0x20000), ('Control', 0x40000), ('Command', 0x100000))

    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='rclick-run-')
        self.addCleanup(temp.cleanup)
        self.run_dir = Path(temp.name)
        (self.run_dir / 'rclick.pid').write_text('28075\n')

    def dirty(self, mask):
        desktop = FakeDesktop()
        desktop.hid_flags |= mask
        return desktop

    def assert_refused(self, desktop, code, err, name):
        self.assertEqual(code, 65, err)
        self.assertIn(f'{name} held down', err)
        self.assertEqual((desktop.clicks, desktop.pressed, desktop.acted), ([], [], []))
        self.assertFalse([call for call in desktop.calls if 'select chosen' in ' '.join(call)], 'it selected')

    def test_choose_refuses_and_selects_clicks_and_presses_nothing(self):
        for name, mask in self.MASKS:
            for title in ('Delete Direct', 'Copy Path'):
                with self.subTest(modifier=name, title=title):
                    desktop = self.dirty(mask)
                    code, _, err = drive(desktop, 'choose', title, '--target', self.ALPHA, *GROUP)
                    self.assert_refused(desktop, code, err, name)

    def test_the_openers_refuse_and_click_nothing(self):
        for argv in (('open-menu', 'alpha.txt'), ('open-menu', '--background')):
            with self.subTest(argv=argv):
                desktop = self.dirty(0x80000)
                code, out, err = drive(desktop, *argv)
                self.assert_refused(desktop, code, err, 'Option')
                self.assertNotIn('menu-point', out)

    def test_press_button_and_grant_refuse_and_press_nothing(self):
        for argv in (('press-button', '28075', 'Cancel', '--window-text', 'Permanently delete'),
                     ('grant', '28075', '/tmp/run/fixtures/rclick-cal')):
            with self.subTest(command=argv[0]):
                desktop = self.dirty(0x80000)
                desktop.windows = fixture('panel-grant-listview-assumed.jsonl') if argv[0] == 'grant' else desktop.windows
                with mock.patch.dict(os.environ, RUN_DIR=str(self.run_dir)):
                    code, _, err = drive(desktop, *argv)
                self.assert_refused(desktop, code, err, 'Option')

    def test_the_non_modifier_bit_the_device_showed_is_not_a_held_key(self):
        desktop = FakeDesktop()
        self.assertEqual(desktop.hid_flags, 0x20000000)
        code, _, err = drive(desktop, 'choose', 'Copy Path', '--target', self.ALPHA, *GROUP)
        self.assertEqual(code, 0, err)

    def test_a_modifier_state_that_cannot_be_read_acts_on_nothing(self):
        desktop = FakeDesktop()
        desktop.modifiers = lambda argv: desktop.completed(argv, 'garbage\n')
        code, _, err = drive(desktop, 'choose', 'Copy Path', '--target', self.ALPHA, *GROUP)
        self.assertEqual(code, 70, err)
        self.assertIn('modifier state is unknown', err)
        self.assertEqual((desktop.clicks, desktop.pressed), ([], []))

    def test_a_modifier_stuck_between_the_selection_and_the_click_is_refused_before_the_click(self):
        def stick(desktop, n):
            desktop.hid_flags |= 0x80000
        desktop = FakeDesktop()
        desktop.before_dump = stick
        code, _, err = drive(desktop, 'choose', 'Delete Direct', '--target', self.ALPHA, *GROUP)
        self.assertEqual(code, 65, err)
        self.assertIn('Option held down', err)
        self.assertEqual((desktop.clicks, desktop.pressed), ([], []))


class CommandLine(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='rclick-ui-')
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        self.bin, self.home, self.log = base / 'bin', base / 'home', base / 'calls.log'
        self.bin.mkdir()
        self.home.mkdir()
        for tool in ('osascript', 'xcrun', 'pgrep', 'swiftc', 'open'):
            (self.bin / tool).write_text(TRAP)
            (self.bin / tool).chmod(0o755)

    def run_script(self, script, *args):
        env = dict(os.environ, PATH=f'{self.bin}:/usr/bin:/bin', HOME=str(self.home), TRAP_LOG=str(self.log))
        return subprocess.run([str(HERE / script), *args], capture_output=True, text=True, env=env, timeout=60)

    def assert_no_desktop_call(self):
        self.assertFalse(self.log.exists(), self.log.read_text() if self.log.exists() else '')

    def test_help_lists_every_command_and_the_exit_codes(self):
        result = self.run_script('ui.sh', '--help')
        self.assertEqual(result.returncode, 0, result.stderr)
        for word in ('rows', 'select PATH', 'open-menu NAME', 'menu X,Y', 'close-menu X,Y', 'choose TITLE', 'dialog PID',
                     'press-button PID', 'grant PID FOLDER', '64 usage', '65 refused', '70 environment'):
            self.assertIn(word, result.stdout)
        self.assert_no_desktop_call()

    def test_help_after_a_command_prints_the_usage_once_and_exits_zero(self):
        for script, args in (('calibrate.sh', ('--help',)), ('ui.sh', ('choose', '--help')),
                             ('ui.sh', ('close-menu', '-h'))):
            with self.subTest(script=script, args=args):
                result = self.run_script(script, *args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(result.stdout.startswith('usage: ui.sh COMMAND'), result.stdout[:80])
                self.assertEqual(result.stdout.count('usage:'), 1, result.stdout)
                self.assertIn('calibrate RUN_DIR', result.stdout)
        self.assert_no_desktop_call()

    def test_usage_errors_exit_64_without_touching_the_desktop(self):
        for args in ((), ('bogus',), ('select', 'relative.txt'), ('choose', 'Copy Path'),
                     ('grant', 'Finder', '/tmp/x'), ('menu', 'x'), ('close-menu',), ('guard', '620,225', '/tmp/a'),
                     ('choose', 'Copy Path', '--target', '/tmp/a', '--group', 'Copy Path')):
            with self.subTest(args=args):
                result = self.run_script('ui.sh', *args)
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertIn('usage error', result.stderr)
        self.assert_no_desktop_call()

    def test_acting_without_the_rclick_gui_lock_exits_70_and_acts_on_nothing(self):
        for args in (('select', '/tmp/a.txt'), ('open-menu', 'alpha.txt'),
                     ('choose', 'Copy Path', '--target', '/tmp/a', '--group', 'Copy Path', '--group', 'New File'),
                     ('press-button', '42', 'OK'),
                     ('grant', '42', '/tmp/x'), ('close-menu', '1,2'), ('open-menu', '--background')):
            with self.subTest(args=args):
                result = self.run_script('ui.sh', *args)
                self.assertEqual(result.returncode, 70, result.stderr)
                self.assertIn('GUI lock', result.stderr)
        run = Path(self.temp.name) / 'run'
        result = self.run_script('calibrate.sh', str(run), '--group', 'Copy Path', '--group', 'New File',
                                 '--background-group', 'Terminal', '--background-group', 'New File')
        self.assertEqual(result.returncode, 70, result.stderr)
        self.assertFalse(run.exists())
        self.assert_no_desktop_call()

    def test_calibration_dry_run_prints_every_step_and_creates_nothing(self):
        run = Path(self.temp.name) / 'run'
        result = self.run_script('calibrate.sh', str(run), '--dry-run')
        self.assertEqual(result.returncode, 0, result.stderr)
        for step in ('row-order', 'select-readback', 'context-menu', 'menu-read', 'choose-multi', 'choose', 'dialog-read',
                     'press-button', 'panel-grant-row', 'panel-grant-current', 'option-menu', 'background-menu',
                     'background-choose', 'close-menu', 'modifiers-start', 'modifiers-after-option', 'modifiers-end'):
            self.assertIn(f'step {step}:', result.stdout)
        self.assertIn('21 steps', result.stdout.splitlines()[0])
        self.assertEqual(result.stdout.count('\n  step '), 21)
        self.assertIn("NOT covered: RClick's own sandboxed folder panel", result.stdout)
        self.assertFalse(run.exists())
        self.assertEqual(self.run_script('calibrate.sh', 'relative-run', '--dry-run').returncode, 64)
        self.assert_no_desktop_call()


class WhitespaceIsIdentity(unittest.TestCase):
    """`alpha.txt` and `alpha.txt ` are distinct files; neither the row check nor the press may take one for the other
    (audit r1 F1). Driven through finderdrive.main with the process boundary replaced."""
    ALPHA, SPACED = FOLDER + '/alpha.txt', FOLDER + '/alpha.txt '

    def spaced_window(self, url_only=False):
        """The recorded window with alpha.txt's AXURL (and, unless url_only, its shown name) ending in a space."""
        window = fixture('finder-window-calibration.jsonl').replace('/alpha.txt"', '/alpha.txt "')
        return window if url_only else window.replace('"value":"alpha.txt"', '"value":"alpha.txt "')

    def test_choose_with_the_spaced_target_on_the_unspaced_row_presses_nothing(self):
        desktop = FakeDesktop()
        code, _, err = drive(desktop, 'choose', 'Delete Direct', '--target', self.SPACED, *GROUP)
        self.assertEqual(code, 65, err)
        self.assertEqual((desktop.clicks, desktop.pressed), ([], []))

    def test_choose_with_n_targets_compares_each_path_exactly(self):
        desktop = FakeDesktop()
        code, _, err = drive(desktop, 'choose', 'Delete Direct', '--target', self.SPACED,
                             '--target', FOLDER + '/beta.txt', *GROUP)
        self.assertEqual(code, 65, err)
        self.assertEqual((desktop.clicks, desktop.pressed), ([], []))

    def test_a_row_showing_the_name_but_holding_the_spaced_path_is_refused(self):
        desktop = FakeDesktop(window=self.spaced_window(url_only=True))
        code, _, err = drive(desktop, 'choose', 'Copy Path', '--target', self.ALPHA, *GROUP)
        self.assertEqual(code, 65, err)
        self.assertEqual(desktop.clicks, [])
        self.assertIn("'" + self.SPACED + "'", err)

    def test_a_spaced_name_round_trips_and_is_pressed(self):
        desktop = FakeDesktop(window=self.spaced_window())
        code, out, err = drive(desktop, 'choose', 'Copy Path', '--target', self.SPACED, *GROUP)
        self.assertEqual(code, 0, err)
        self.assertIn("'" + self.SPACED + "'", out)
        self.assertEqual(len(desktop.pressed), 1)

    def test_a_selected_path_with_a_line_break_is_refused(self):
        desktop = FakeDesktop()
        desktop.selection_reply = [FOLDER + '/alpha\n.txt']
        code, _, err = drive(desktop, 'choose', 'Copy Path', '--target', self.ALPHA, *GROUP)
        self.assertEqual(code, 65, err)
        self.assertEqual((desktop.clicks, desktop.pressed), ([], []))


class AxprobeCache(unittest.TestCase):
    """axprobe runs with the host terminal's Accessibility trust, so its cached executable must be one only this user
    could have written: a 0700 directory under ~/Library/Caches, lstat-checked before every reuse (audit r1 M1/M6)."""

    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='rclick-axcache-')
        self.addCleanup(temp.cleanup)
        self.home, self.tmpdir = Path(temp.name) / 'home', Path(temp.name) / 'tmp'
        self.home.mkdir()
        self.tmpdir.mkdir()
        self.compiles = []
        for patch in (mock.patch.dict(os.environ, HOME=str(self.home), TMPDIR=str(self.tmpdir)),
                      mock.patch.object(finderdrive, 'run', self.fake_run)):
            patch.start()
            self.addCleanup(patch.stop)

    def fake_run(self, argv, timeout=20):
        argv = [str(a) for a in argv]
        out = Path(argv[argv.index('-o') + 1])
        out.write_text('#!/bin/sh\n')
        self.compiles.append(argv)
        return subprocess.CompletedProcess(argv, 0, '', '')

    def test_compiles_once_into_a_private_cache_under_library_caches(self):
        binary = finderdrive.probe_binary()
        cache = self.home / 'Library' / 'Caches' / 'rclick-axprobe'
        self.assertTrue(binary.is_relative_to(cache), binary)
        self.assertEqual(cache.stat().st_mode & 0o777, 0o700)
        self.assertEqual(binary.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(finderdrive.probe_binary(), binary)
        self.assertEqual(len(self.compiles), 1)
        self.assertEqual(list(self.tmpdir.iterdir()), [])  # $TMPDIR is never used

    def test_a_planted_symlink_to_an_admissible_file_is_refused(self):
        # The link's target passes every other check (same user, regular, 0700), so only lstat refuses it
        # (audit r2 gpt M3: a link to root-owned /bin/sh was refused by the owner check even through os.stat).
        binary = finderdrive.probe_binary()
        admissible = self.home / 'admissible'
        admissible.write_text('#!/bin/sh\n')
        admissible.chmod(0o700)
        binary.unlink()
        binary.symlink_to(admissible)
        with self.assertRaisesRegex(finderdrive.ui.Environment, 'axprobe cache'):
            finderdrive.probe_binary()

    def test_a_binary_owned_by_another_user_is_refused(self):
        binary = finderdrive.probe_binary()
        real_lstat = os.lstat

        def foreign(path, *args, **kwargs):
            info = real_lstat(path, *args, **kwargs)
            if Path(path) != binary:
                return info
            fields = list(info)
            fields[stat.ST_UID] = os.getuid() + 1
            return os.stat_result(fields)

        with mock.patch.object(finderdrive.os, 'lstat', foreign), \
                self.assertRaisesRegex(finderdrive.ui.Environment, 'axprobe cache'):
            finderdrive.probe_binary()

    def test_a_cache_others_can_write_is_refused(self):
        binary = finderdrive.probe_binary()
        for target, mode in ((binary, 0o775), (binary.parent, 0o777), (binary.parent.parent, 0o757)):
            with self.subTest(target=target.name, mode=oct(mode)):
                target.chmod(mode)
                with self.assertRaisesRegex(finderdrive.ui.Environment, 'axprobe cache'):
                    finderdrive.probe_binary()
                target.chmod(0o700)

    def test_a_symlinked_cache_directory_is_refused(self):
        caches = self.home / 'Library' / 'Caches'
        caches.mkdir(parents=True)
        elsewhere = self.home / 'elsewhere'
        elsewhere.mkdir(mode=0o700)
        (caches / 'rclick-axprobe').symlink_to(elsewhere)
        with self.assertRaisesRegex(finderdrive.ui.Environment, 'axprobe cache'):
            finderdrive.probe_binary()

    def test_an_ancestor_link_or_writable_ancestor_is_refused_before_anything_is_written(self):
        # audit r2 gpt M1: ~/Library/Caches linked elsewhere was followed by mkdir(parents=True). Every ancestor the
        # cache relies on (home, ~/Library, ~/Library/Caches) is lstat-checked; nothing is compiled or created.
        for ancestor in ('Library', 'Library/Caches'):
            with self.subTest(link=ancestor):
                self.reset_home()
                elsewhere = self.home.parent / 'elsewhere'
                elsewhere.mkdir(mode=0o700)
                link = self.home / ancestor
                link.parent.mkdir(parents=True, exist_ok=True)
                link.symlink_to(elsewhere)
                with self.assertRaisesRegex(finderdrive.ui.Environment, 'axprobe cache'):
                    finderdrive.probe_binary()
                self.assertEqual((self.compiles, list(elsewhere.iterdir())), ([], []))
        for ancestor, mode in (('', 0o770), ('Library', 0o702), ('Library/Caches', 0o720)):
            with self.subTest(writable=ancestor or 'home', mode=oct(mode)):
                self.reset_home()
                (self.home / 'Library' / 'Caches').mkdir(parents=True, mode=0o700)
                (self.home / ancestor).chmod(mode)
                with self.assertRaisesRegex(finderdrive.ui.Environment, 'axprobe cache'):
                    finderdrive.probe_binary()
                self.assertEqual((self.compiles, list((self.home / 'Library' / 'Caches').iterdir())), ([], []))

    def reset_home(self):
        for path in sorted(self.home.parent.rglob('*'), reverse=True):
            if path != self.tmpdir:
                if path.is_dir() and not path.is_symlink():
                    path.chmod(0o700)
                    path.rmdir()
                else:
                    path.unlink()
        self.home.mkdir(mode=0o700)
        self.compiles.clear()


@unittest.skipUnless(Path('/usr/bin/xcrun').exists(), 'needs the Xcode toolchain (the Mac gate lane has it)')
class AxprobeNeedsTheLock(unittest.TestCase):
    """axprobe's acting commands check the GUI lock themselves (the driver's strict check), so calling the compiled
    helper directly cannot bypass it; the refusal comes before any AX call (audit r1 F4). Compiles the real axprobe
    into a temporary HOME; no AX action is reached."""

    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='rclick-axlock-')
        cls.home = Path(cls.temp.name)
        with mock.patch.dict(os.environ, HOME=str(cls.home)):
            cls.binary = finderdrive.probe_binary()

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def axprobe(self, *args, **env):
        environment = dict(os.environ, HOME=str(self.home), **env)
        for key in LOCK_ENV:
            environment.pop(key, None)
        environment.update(env)
        return subprocess.run([str(self.binary), *args], capture_output=True, text=True, env=environment, timeout=60)

    def acting_calls(self):
        return (('act', str(os.getpid()), '0', 'select', 'AXRow', 'alpha.txt'),
                ('menu-session', '-10000', '-10000', '3', str(os.getpid())), ('menu-cancel', '-10000', '-10000', str(os.getpid())))

    def test_acting_without_the_lock_is_refused_before_any_ax_call(self):
        for args in self.acting_calls():
            with self.subTest(command=args[0]):
                result = self.axprobe(*args)
                self.assertEqual(result.returncode, 70, result.stderr)
                self.assertIn('GUI lock', result.stderr)

    def test_another_projects_lock_is_refused(self):
        lock = self.home / '.cache' / 'desktop-gui.lock'
        lock.mkdir(parents=True)
        self.addCleanup(lambda: (lock / 'owner').unlink() or lock.rmdir())
        (lock / 'owner').write_text(HELD.split('\n', 1)[1].replace('  ', '').replace('project=rclick', 'project=picsee'))
        for args in self.acting_calls():
            with self.subTest(command=args[0]):
                result = self.axprobe(*args, **LOCK_ENV)
                self.assertEqual(result.returncode, 70, result.stderr)
                self.assertIn("project 'picsee'", result.stderr)


class PressOnlyInAllowedProcesses(unittest.TestCase):
    """`press-button` acts only in an allowed process (finderui.allowed_process); the RClick pid comes from
    $RUN_DIR/rclick.pid (audit r1 opus M3)."""

    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='rclick-run-')
        self.addCleanup(temp.cleanup)
        self.run_dir = Path(temp.name)
        (self.run_dir / 'rclick.pid').write_text('28075\n')

    def press(self, pid):
        desktop = FakeDesktop(fixture('menu-file-alpha.jsonl'), [])
        with mock.patch.dict(os.environ, RUN_DIR=str(self.run_dir)):
            code, out, err = drive(desktop, 'press-button', str(pid), 'Cancel', '--window-text', 'Permanently delete')
        return code, err, desktop

    def test_the_rclick_pid_of_this_run_is_pressed(self):
        code, err, desktop = self.press(28075)
        self.assertEqual(code, 0, err)
        self.assertEqual(desktop.acted, [['28075', '0.3', 'press', 'AXButton', 'Cancel']])

    def test_a_privacy_prompt_or_another_app_is_never_pressed(self):
        for pid in (92997, 3610, 562, 60606):
            with self.subTest(pid=pid):
                code, err, desktop = self.press(pid)
                self.assertEqual(code, 65, err)
                self.assertEqual(desktop.acted, [])
                self.assertNotIn(['dump'], [call[1:2] for call in desktop.calls if Path(call[0]).name == 'axprobe'])


class AllowListResolvesTheExecutable(unittest.TestCase):
    """finderdrive.allowed_process on REAL processes (no desktop: `osascript -e 'delay 5'` and /bin/sleep): the
    calibration's own osascript, spawned by its absolute path or by a PATH lookup, is allowed; a process whose argv[0]
    claims to be Finder is not (device run, 2026-11-18: `pid N is osascript` refused the calibration's alert)."""

    def spawn(self, argv, executable=None):
        process = subprocess.Popen(argv, executable=executable, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(process.wait)
        self.addCleanup(process.kill)
        return process.pid

    def test_the_calibrations_osascript_is_allowed_however_it_was_spawned(self):
        for argv in (['osascript', '-e', 'delay 5'], ['/usr/bin/osascript', '-e', 'delay 5']):
            with self.subTest(argv=argv[0]):
                pid = self.spawn(argv)
                self.assertEqual(finderdrive.allowed_process(pid, extra_pids={pid}), 'calibration osascript')

    def test_a_process_claiming_finders_path_in_argv0_is_refused(self):
        pid = self.spawn(['/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder', '5'], executable='/bin/sleep')
        with self.assertRaisesRegex(finderui.Refused, '/bin/sleep'):
            finderdrive.allowed_process(pid)

    def test_a_pid_that_is_not_running_is_refused(self):
        process = subprocess.Popen(['/usr/bin/true'])
        process.wait()
        with self.assertRaisesRegex(finderui.Refused, 'not running'):
            finderdrive.allowed_process(process.pid)


class GrantByFullPath(unittest.TestCase):
    """`grant` through finderdrive.main: the full path is established before anything is selected, and the selection
    is read again before the button is pressed (audit r1 F3). The panel structure is ASSUMED (fixtures/README.md)."""

    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='rclick-run-')
        self.addCleanup(temp.cleanup)
        self.run_dir = Path(temp.name)
        (self.run_dir / 'rclick.pid').write_text('28075\n')
        self.panel = fixture('panel-grant-listview-assumed.jsonl')

    def with_selected(self, *paths):
        lines = []
        for line in self.panel.splitlines():
            node = json.loads(line)
            if node['role'] == 'AXRow':
                node['selected'] = node['path'] in [list(p) for p in paths]
            lines.append(json.dumps(node, ensure_ascii=False))
        return '\n'.join(lines) + '\n'

    def grant(self, desktop, pid, folder):
        desktop.windows = self.panel
        with mock.patch.dict(os.environ, RUN_DIR=str(self.run_dir)):
            return drive(desktop, 'grant', str(pid), folder)

    def test_the_target_row_is_selected_read_back_and_granted(self):
        desktop = FakeDesktop('', [])
        desktop.after_act = [self.with_selected((0, 0, 1, 0, 0)), '']
        code, out, err = self.grant(desktop, 28075, '/tmp/run/fixtures/rclick-cal')
        self.assertEqual(code, 0, err)
        self.assertEqual([call[2] for call in desktop.acted], ['select', 'press'])
        self.assertIn('granted: /tmp/run/fixtures/rclick-cal (row mode; verified', out)

    def test_an_equal_basename_elsewhere_selects_and_presses_nothing(self):
        desktop = FakeDesktop('', [])
        code, _, err = self.grant(desktop, 28075, '/tmp/other/fixtures/rclick-cal')
        self.assertEqual(code, 65, err)
        self.assertEqual(desktop.acted, [])

    def test_another_row_selected_after_the_select_is_not_pressed(self):
        desktop = FakeDesktop('', [])
        desktop.after_act = [self.with_selected((0, 0, 1, 0, 2))]
        code, _, err = self.grant(desktop, 28075, '/tmp/run/fixtures/rclick-cal')
        self.assertEqual(code, 65, err)
        self.assertEqual([call[2] for call in desktop.acted], ['select'])

    def test_a_panel_in_a_process_that_is_not_allowed_is_not_touched(self):
        desktop = FakeDesktop('', [])
        code, _, err = self.grant(desktop, 92997, '/tmp/run/fixtures/rclick-cal')
        self.assertEqual(code, 65, err)
        self.assertEqual(desktop.acted, [])


class GrantOnTheColumnBrowser(unittest.TestCase):
    """`grant` through finderdrive.main on the REAL panel shape (fix r3 item 3; device run, 2026-11-18): a column
    browser of AXGroup entries, where the old code refused "rows expose no AXURL" and would have selected an AXRow.
    What the panel shows after the AX select is constructed (test_finderui.opened) and UNVERIFIED on a device."""
    FOLDER = '/Users/tester/work/runs/run-1/phase2/fixtures/calibration-x1y2z3'

    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='rclick-run-')
        self.addCleanup(temp.cleanup)
        self.run_dir = Path(temp.name)
        (self.run_dir / 'rclick.pid').write_text('28075\n')
        self.panel = fixture('panel-browser-row.jsonl')

    def opened(self, folder, names):
        import test_finderui
        nodes = test_finderui.opened(finderui.parse_dump(self.panel), folder, names)
        return ''.join(json.dumps(dict(n, path=list(n['path'])), ensure_ascii=False) + '\n' for n in nodes)

    def grant(self, desktop, folder):
        desktop.windows = self.panel
        with mock.patch.dict(os.environ, RUN_DIR=str(self.run_dir)):
            return drive(desktop, 'grant', '28075', folder, '--button', 'Choose')

    def test_the_shown_folder_is_granted_without_selecting(self):
        desktop = FakeDesktop('', [])
        desktop.after_act = ['']  # the press closes the panel
        code, out, err = self.grant(desktop, self.FOLDER)
        self.assertEqual(code, 0, err)
        self.assertEqual([call[2:4] for call in desktop.acted], [['press', 'AXButton']])
        self.assertIn('current mode', out)

    def test_an_entry_is_selected_as_its_group_and_pressed_once_the_browser_opened_it(self):
        target = self.FOLDER + '/folder a'
        desktop = FakeDesktop('', [])
        desktop.after_act = [self.opened(target, ['inner.txt']), '']
        code, out, err = self.grant(desktop, target)
        self.assertEqual(code, 0, err)
        self.assertEqual([call[1:] for call in desktop.acted],
                         [['0.0.2.0.0.6.0.4', 'select', 'AXGroup', 'folder a'], ['0.0.11', 'press', 'AXButton', 'Choose']])
        self.assertIn('row mode', out)

    def test_a_select_that_opens_nothing_presses_nothing(self):
        target = self.FOLDER + '/folder a'
        for after in (None, self.opened(target, [])):
            desktop = FakeDesktop('', [])
            desktop.after_act = [after or self.panel]
            with self.subTest(empty=after is not None):
                code, _, err = self.grant(desktop, target)
                self.assertEqual(code, 65, err)
                self.assertEqual([call[2] for call in desktop.acted], ['select'])

    def test_an_equal_basename_elsewhere_selects_and_presses_nothing(self):
        desktop = FakeDesktop('', [])
        code, _, err = self.grant(desktop, '/Users/tester/other/calibration-x1y2z3/folder a')
        self.assertEqual(code, 65, err)
        self.assertEqual(desktop.acted, [])


class Source(unittest.TestCase):
    def test_no_personal_path_in_the_skill(self):
        marker = '/' + 'Users' + '/'  # split so this file does not match itself
        # the one home allowed: dumps are sanitised to /Users/tester (fixtures/README.md); testerX is not it
        placeholder = re.compile(re.escape(marker + 'tester') + r'(?![\w.-])')
        home = str(Path.home())
        for path in SKILL.rglob('*'):
            if path.is_file() and '__pycache__' not in path.parts:
                text = placeholder.sub('', path.read_text(encoding='utf-8', errors='replace'))
                with self.subTest(path=path.relative_to(SKILL)):
                    self.assertNotIn(marker, text)
                    if len(home) > 1:
                        self.assertNotIn(home, text)

    def test_axprobe_cancels_a_menu_only_after_checking_its_owner(self):
        # audit r3 gpt F2 / opus M1: the session's abort and no-decision branches AXCancelled with no owner check. The
        # Swift is not run offline, so its one AXCancel must sit in cancelOwned, after the owner comparison, and every
        # caller must pass the owner the driver expects (the session's OWNER argument, or menu-cancel's PID).
        source = (HERE / 'axprobe.swift').read_text(encoding='utf-8')
        self.assertEqual(source.count('"AXCancel"'), 1)
        body = re.search(r'func cancelOwned\(_ menu: AXUIElement, by expected: pid_t\) -> String\? \{(.*?)\n\}', source,
                         re.S)
        self.assertIsNotNone(body, 'no cancelOwned(_:by:)')
        body = body.group(1)
        self.assertIn('"AXCancel"', body)
        self.assertLess(body.index('guard owner == expected'), body.index('"AXCancel"'))
        calls = re.findall(r'cancelOwned\(root, by: (\w+)\)', source)
        self.assertEqual(len(calls), source.count('cancelOwned(') - 1, 'a cancelOwned call this test does not read')
        self.assertEqual(set(calls), {'expected'})
        for command, argument in (('menu-session', 5), ('menu-cancel', 4)):
            branch = source.split(f'case "{command}":', 1)[1].split('\ncase ', 1)[0]
            self.assertIn(f'let expected = pid_t(number({argument}))', branch)

    @unittest.skipUnless(Path('/usr/bin/xcrun').exists(), 'needs the Xcode toolchain (the Mac gate lane has it)')
    def test_axprobe_type_checks(self):
        # axprobe.swift is compiled as main.swift with the generated driver.swift (finderdrive.probe_binary).
        with tempfile.TemporaryDirectory(prefix='rclick-axcheck-') as build:
            (Path(build) / 'main.swift').write_bytes((HERE / 'axprobe.swift').read_bytes())
            (Path(build) / 'driver.swift').write_text('let driverScript = "finderdrive.py"\n')
            result = subprocess.run(['/usr/bin/xcrun', 'swiftc', '-typecheck', str(Path(build) / 'main.swift'),
                                     str(Path(build) / 'driver.swift')], capture_output=True, text=True, timeout=300)
        self.assertEqual(result.returncode, 0, result.stderr)


class RecipesMatchTheDriver(unittest.TestCase):
    """The recipes a tester follows use `choose` the way it works since fix round 3 (audit r3 opus F1): `choose` opens
    its own menu, so a recipe never runs it while a menu it opened with `open-menu` is still open (its first
    AppleScript call to Finder would time out, exit 70); a menu is dismissed with `ui.sh close-menu X,Y`, never a bare
    Esc; and a `(skip confirmation)` title is chosen with `--option`. Read per step: a numbered item, a bullet, a
    table row or a heading starts a new one."""
    DOCS = ('features/*.md', 'SKILL.md', 'references/device-runbook.md')
    STEP = re.compile(r'^(?:\d+\.|-|#+|\|) ', re.M)
    COMMAND = re.compile(r'(?P<open>(?<!no `)open-menu\b)|(?P<close>close-menu\b)|(?P<choose>ui\.sh choose\b|`choose\b)')

    def steps(self):
        for pattern in self.DOCS:
            for path in sorted(SKILL.glob(pattern)):
                text = path.read_text(encoding='utf-8')
                starts = [m.start() for m in self.STEP.finditer(text)] + [len(text)]
                for start, end in zip([0] + starts, starts):
                    yield path.relative_to(SKILL), text[start:end]

    def test_no_recipe_runs_choose_with_a_menu_it_left_open(self):
        for name, step in self.steps():
            menu_open = False
            for match in self.COMMAND.finditer(step):
                if match.group('open'):
                    menu_open = True
                elif match.group('close'):
                    menu_open = False
                elif menu_open:
                    self.fail(f'{name}: `choose` after `open-menu` with no `close-menu` between: {step.strip()[:300]}')

    def test_a_menu_is_dismissed_with_close_menu_not_a_bare_esc(self):
        for path in sorted(SKILL.glob('features/*.md')):
            for line in path.read_text(encoding='utf-8').splitlines():
                with self.subTest(path=path.name, line=line):
                    self.assertIsNone(re.search(r'\bEsc\b(?! to Finder)', line))

    def test_the_act_05_sequence_runs_on_the_fake_desktop(self):
        # read with open-menu --option + menu, close-menu, then choose --option (alpha.txt stands in for delete-2.txt)
        desktop = FakeDesktop()
        code, out, err = drive(desktop, 'open-menu', 'alpha.txt', '--option')
        self.assertEqual(code, 0, err)
        point = out.split('menu-point ')[1].strip()
        code, out, err = drive(desktop, 'menu', point)
        self.assertEqual(code, 0, err)
        self.assertIn('Delete Direct (skip confirmation)', out)
        self.assertEqual(drive(desktop, 'close-menu', point)[0], 0)
        code, out, err = drive(desktop, 'choose', 'Delete Direct (skip confirmation)', '--option', '--target',
                               FOLDER + '/alpha.txt', *GROUP)
        self.assertEqual(code, 0, err)
        self.assertIn('GUARD PASS', out)
        self.assertEqual([request['title'] for request in desktop.pressed], ['Delete Direct (skip confirmation)'])
        self.assertEqual(desktop.timeouts, [])

    def test_a_skip_confirmation_title_is_chosen_with_option(self):
        found = 0
        for name, step in self.steps():
            for match in re.finditer(r'`[^`]*\bchoose "[^"]*\(skip confirmation\)"[^`]*`', step):  # the command's code span
                found += 1
                self.assertIn(' --option', match.group(0), f'{name}: {match.group(0)}')
        self.assertGreater(found, 0, 'ACT-05 names the skip-confirmation title it chooses')


class CloseMenuAndBackground(unittest.TestCase):
    """`ui.sh close-menu X,Y` closes Finder's menu through AX (AXCancel), with Esc to Finder only while AX still
    shows that Finder menu (fix r3 item 5: the old frontmost check through System Events did not see Finder with a
    menu open, so it sent nothing and left the menu open). `choose --background` reads the front folder through AX
    before the click (fix r3 item 1)."""
    BACKGROUND = ('--group', 'Copy Path', '--group', 'Copy File Name', '--group', 'Delete Direct', '--group',
                  'Terminal', '--group', 'New File')

    def opened(self, **state):
        desktop = FakeDesktop()
        for key, value in state.items():
            setattr(desktop, key, value)
        code, out, err = drive(desktop, 'open-menu', 'alpha.txt')
        self.assertEqual(code, 0, err)
        self.assertIsNotNone(desktop.menu)
        self.assertEqual(desktop.timeouts, [])
        return desktop, out.split('menu-point ')[1].strip()

    def test_close_menu_cancels_the_finder_menu_through_ax_and_sends_no_key(self):
        desktop, point = self.opened()
        code, out, err = drive(desktop, 'close-menu', point)
        self.assertEqual(code, 0, err)
        self.assertIsNone(desktop.menu)
        self.assertEqual(desktop.keys, [])
        self.assertIn('AXCancel', out)

    def test_close_menu_falls_back_to_esc_while_ax_shows_the_menu(self):
        desktop, point = self.opened(cancel_works=False)
        code, out, err = drive(desktop, 'close-menu', point)
        self.assertEqual(code, 0, err)
        self.assertIsNone(desktop.menu)
        self.assertEqual(len(desktop.keys), 1)
        self.assertIn('Esc to Finder', out)

    def test_close_menu_reports_a_menu_it_cannot_close(self):
        desktop, point = self.opened(cancel_works=False, esc_works=False)
        code, _, err = drive(desktop, 'close-menu', point)
        self.assertEqual(code, 70, err)
        self.assertIn('close it by hand', err)

    def test_close_menu_with_no_menu_sends_nothing(self):
        desktop = FakeDesktop()
        code, out, err = drive(desktop, 'close-menu', '660,237')
        self.assertEqual(code, 0, err)
        self.assertEqual(desktop.keys, [])
        self.assertIn('nothing sent', out)

    def test_close_menu_never_touches_another_process_menu(self):
        desktop, point = self.opened(menu_pid=999)
        code, _, err = drive(desktop, 'close-menu', point)
        self.assertEqual(code, 65, err)
        self.assertIsNotNone(desktop.menu)
        self.assertEqual(desktop.keys, [])

    def test_open_menu_background_right_clicks_below_the_rows(self):
        desktop = FakeDesktop()
        code, out, err = drive(desktop, 'open-menu', '--background')
        self.assertEqual(code, 0, err)
        self.assertEqual(len(desktop.clicks), 1)
        x, y, _ = desktop.clicks[0]
        self.assertGreater(y, 485)  # below the lowest row (465 + 20)
        self.assertGreater(x, 243)  # right of the sidebar
        self.assertIn('menu-point ', out)

    def test_open_menu_background_with_a_selection_left_clicks_nothing(self):
        desktop = FakeDesktop(selection=[FOLDER + '/alpha.txt'])
        desktop.deselect_works = False
        code, _, err = drive(desktop, 'open-menu', '--background')
        self.assertEqual(code, 65, err)
        self.assertEqual(desktop.clicks, [])

    def test_choose_background_presses_the_submenu_item_with_no_applescript_while_the_menu_is_open(self):
        desktop = FakeDesktop(selection=[FOLDER + '/alpha.txt'])
        code, out, err = drive(desktop, 'choose', 'New File', '--sub', 'TXT', *self.BACKGROUND, '--background', FOLDER)
        self.assertEqual(code, 0, err)
        self.assertEqual(desktop.timeouts, [])
        self.assertEqual(desktop.pressed[0]['press'], [31, 0, 0])
        self.assertIn('background menu of ' + FOLDER, out)

    def test_choose_background_of_another_folder_clicks_nothing(self):
        desktop = FakeDesktop()
        code, _, err = drive(desktop, 'choose', 'New File', '--sub', 'TXT', *self.BACKGROUND, '--background', '/tmp/x')
        self.assertEqual(code, 65, err)
        self.assertEqual(desktop.clicks, [])

    def test_choose_background_of_an_empty_folder_is_refused_not_guessed(self):
        window = '\n'.join(line for line in fixture('finder-window-calibration.jsonl').splitlines()
                           if not json.loads(line)['path'][:5] == [0, 0, 2, 0, 0]
                           or len(json.loads(line)['path']) < 6) + '\n'
        desktop = FakeDesktop(window=window)
        code, _, err = drive(desktop, 'choose', 'New File', '--sub', 'TXT', *self.BACKGROUND, '--background', FOLDER)
        self.assertEqual(code, 65, err)
        self.assertEqual(desktop.clicks, [])
        self.assertIn('no rows', err)

    def test_open_menu_needs_a_name_or_background_not_both(self):
        for argv in (['open-menu'], ['open-menu', 'alpha.txt', '--background']):
            with self.subTest(argv=argv), self.assertRaises(finderui.Usage):
                finderui.parse_args(argv)


if __name__ == '__main__':
    unittest.main()
