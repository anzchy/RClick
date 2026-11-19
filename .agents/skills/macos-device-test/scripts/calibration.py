"""The calibration run (calibrate.sh): proves every ui.sh helper on this Mac's macOS and Finder before a device run
relies on it. It works on a throwaway folder under $RUN_DIR/fixtures/, and on an alert and a folder panel raised by
osascript processes it starts itself (and only those may be terminated). The verdict lines come from
finderui.calibration_report; the raw AX dumps are saved under $RUN_DIR/calibration/ for the correction loop.

The menu steps run the real `ui.sh` command lines a device run uses (close-menu, choose for one and for several
targets, open-menu --option and --background, choose --background --sub), each a subprocess that checks the GUI lock
itself. No step calls Finder through AppleScript while a menu it opened may be open (Finder answers none then:
device run, 2026-11-18); a failed step closes its menus through `close-menu` (AXCancel, Esc fallback).

The HID modifier state (`modifiers.sh state`, a read) is checked three times: before anything (modifiers-start, an
environment step: a held Shift, Control, Option or Command stops the calibration), right after option-menu
(modifiers-after-option: the Option it posted was released) and last (modifiers-end). 21 steps in all.

Side effects on the desktop, all under the GUI lock: opens and closes one Finder window on the fixture folder (list
view), selects in it, opens context menus there (one with Option held, two on the window background), chooses
RClick's Copy Path twice (one and two targets; the pasteboard is overwritten with fixture paths) and New File → TXT once on the fixture's
background (a new file in the fixture, or RClick's folder panel, which is cancelled), shows one alert and two folder
panels from its own osascript processes.

NOT covered: RClick's own sandboxed folder panel as the grant target (the grant steps use an osascript panel).
PERM-01 on the device proves it.
"""
import re
import os
import stat
import subprocess
import tempfile
import time
from pathlib import Path

import device
import finderdrive as drive
import finderui as ui

FILES = ('%41.txt', '%2541.txt', 'alpha.txt', 'beta.txt', '中文 名称.txt', 'folder a/inner.txt')
ALERT = 'RClick calibration alert'


# The fixture window is addressed by the id Finder gave it, read in the same call as its folder: on the device run,
# 2026-11-18, `close (every Finder window whose target is <alias>)` matched nothing (-1708) and left it open.
FRONT_WINDOW_SCRIPT = ('tell application "Finder" to tell front Finder window to return (id as text) & linefeed & '
                       'POSIX path of (target as alias)')
LIST_VIEW_SCRIPT = ('on run argv\ntell application "Finder" to set current view of Finder window id '
                    '((item 1 of argv) as integer) to list view\nend run')
CLOSE_WINDOW_SCRIPT = ('on run argv\ntell application "Finder" to close Finder window id ((item 1 of argv) as integer)'
                       '\nend run')


def front_window(reply):
    """FRONT_WINDOW_SCRIPT's reply → (window id, folder path); a reply of another shape is refused."""
    lines = reply.rstrip('\n').split('\n')
    if len(lines) != 2 or not lines[0].isdigit():
        raise ui.Refused(f'unexpected front Finder window reply {reply!r}')
    return int(lines[0]), ui.clean_path(lines[1])


class Fixture:
    """The calibration's throwaway folder: allocated exclusively (mkdtemp, 0700) under $RUN_DIR/fixtures/, which
    must be a real directory of this user; files are created O_EXCL|O_NOFOLLOW (an existing name is Refused, never
    overwritten). remove() deletes only what this instance created or adopted (plus Finder's .DS_Store in its own
    folders) and returns a note for anything it had to leave."""

    def __init__(self, run):
        fixtures = Path(run) / 'fixtures'
        try:
            os.mkdir(fixtures, 0o700)
        except FileExistsError:
            pass
        info = os.lstat(fixtures)
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
            raise ui.Environment(f'{fixtures} is not a directory of this user (a symlink?): calibration refuses it')
        self.folder = Path(tempfile.mkdtemp(prefix='calibration-', dir=fixtures))
        self.created = [self.folder]

    def create(self, names):
        for name in names:
            target = self.folder / name
            if target.parent != self.folder and target.parent not in self.created:
                os.mkdir(target.parent, 0o700)
                self.created.append(target.parent)
            try:
                handle = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            except FileExistsError as error:
                raise ui.Refused(f'{target} already exists: the fixture is not this calibration\'s alone') from error
            with os.fdopen(handle, 'w', encoding='utf-8') as stream:
                stream.write(name + '\n')
            self.created.append(target)

    def adopt(self, path):
        """A regular file a calibration step made RClick create directly in the folder (New File): removed too."""
        path = Path(path)
        try:
            info = os.lstat(path)
        except FileNotFoundError as error:
            raise ui.Refused(f'{path} does not exist') from error
        if path.parent != self.folder or not stat.S_ISREG(info.st_mode) or path in self.created:
            raise ui.Refused(f'{path} is not a new regular file directly in {self.folder}')
        self.created.append(path)

    def remove(self):
        notes = []
        for path in reversed(self.created):
            try:
                if stat.S_ISDIR(os.lstat(path).st_mode):
                    store = path / '.DS_Store'  # Finder writes it into a folder it showed
                    if store.is_file() and not store.is_symlink():
                        store.unlink()
                    os.rmdir(path)
                else:
                    os.unlink(path)
            except FileNotFoundError:
                continue
            except OSError as error:
                notes.append(f'left {path}: {error.strerror} (not only this calibration\'s files)')
        return notes


def plan_lines(run_dir):
    lines = [f'calibration plan (dry run, nothing touched): {len(ui.CALIBRATION_STEPS)} steps; fixture folder '
             f'{run_dir}/fixtures/calibration-<random>/',
             '  files: ' + ', '.join(repr(name) for name in FILES)]
    lines += [f'  step {step}: proves {command}' for step, command in ui.CALIBRATION_STEPS]
    return lines + ['  ' + ui.NOT_COVERED]


def group_args(titles):
    return [arg for title in titles for arg in ('--group', title)]


def menu_point_of(out):
    match = re.search(r'^menu-point (\d+),(\d+)$', out, re.M)
    if not match:
        raise ui.Environment(f'ui.sh open-menu printed no menu-point: {out[:120]!r}')
    return f'{match.group(1)},{match.group(2)}'


class Run:
    def __init__(self, run_dir, group, background_group=()):
        self.group = group
        self.background_group = list(background_group)
        self.run = device.run_dir(str(run_dir))
        self.fixture = None
        self.folder = None
        self.window_id = None  # the fixture Finder window's id, read when it came to the front; teardown closes it
        self.point = None
        self.menu_points = []  # every menu point a step opened: closed after a failure and before teardown
        self.evidence = self.run / 'calibration'
        self.results = []
        self.started = []
        self.notes = []

    def record(self, step, status, detail):
        self.results.append((step, status, detail))
        print(f'{status} {step} — {detail}', flush=True)

    def note(self, text):
        self.notes.append(text)
        print('note: ' + text, flush=True)

    def attempt(self, what, action):
        """A dismiss or teardown call whose failure (osascript timed out or missing: finderui.Environment, or anything
        else) must not stop the rest of the teardown or the report: it becomes a note naming the error."""
        try:
            return action()
        except Exception as error:  # noqa: BLE001 — cleanup goes on; the error is kept in the note
            self.note(f'{what}: {error}'.replace('\n', ' '))
            return None

    def save(self, name, text):
        self.evidence.mkdir(parents=True, exist_ok=True)
        (self.evidence / name).write_text(text, encoding='utf-8')

    def path(self, name):
        return str(self.folder / name)

    def step(self, name, action, needs=()):
        failed = [n for n in needs if dict((s, st) for s, st, _ in self.results).get(n) != 'PASS']
        if failed:
            self.record(name, 'SKIP', f'needs {", ".join(failed)}')
            return None
        try:
            detail = action()
        except Exception as error:  # noqa: BLE001 — any helper failure is this step's FAIL, never a crash
            self.record(name, 'FAIL', str(error).replace('\n', ' '))
            self.close_menus(f'after {name} failed')
            return None
        self.record(name, 'PASS', detail)
        return detail

    # environment ---------------------------------------------------------------------------------------------
    def environment(self):
        checks = (('gui-lock', drive.require_lock, 'held by an rclick run'),
                  ('axprobe', lambda: drive.probe_binary(), 'compiled into its private cache'),
                  ('accessibility', drive.require_trust, 'host terminal is AX-trusted'),
                  ('modifiers-start', self.modifiers_start, None))
        for name, check, detail in checks:
            try:
                result = check()
                detail = detail or result
            except (ui.Environment, OSError) as error:
                self.record(name, 'FAIL', str(error))
                for step, _ in ui.CALIBRATION_STEPS:
                    if step not in {done for done, _, _ in self.results}:
                        self.record(step, 'SKIP', f'blocked by {name}')
                return False
            self.record(name, 'PASS', detail)
        return True

    # fixture -------------------------------------------------------------------------------------------------
    def make_fixture(self):
        self.fixture = Fixture(self.run)
        self.folder = self.fixture.folder
        self.fixture.create(FILES)
        drive.run(['open', self.folder], timeout=10)
        for _ in range(20):
            time.sleep(0.25)
            try:
                window_id, front = front_window(drive.osascript(FRONT_WINDOW_SCRIPT))
            except (ui.Environment, ui.Refused):
                continue
            if front == str(self.folder):
                self.window_id = window_id
                break
        else:
            raise ui.Environment('the fixture window did not come to the front')
        drive.osascript(LIST_VIEW_SCRIPT, str(self.window_id))
        time.sleep(0.5)

    def close_menus(self, when):
        """Close any menu still open at a point a step opened one (drive.close_menu: AX read, AXCancel, Esc only
        while AX shows that Finder menu); each failure is a note."""
        for point in dict.fromkeys(self.menu_points):
            self.attempt(f'could not close the menu at {point[0]},{point[1]} {when}', lambda: drive.close_menu(point))

    def remove_fixture(self):
        """Close open menus, close the fixture window, then remove this invocation's own files: the removal runs
        even when closing failed (each failure is a note)."""
        if self.fixture is None:
            return
        try:
            self.close_menus('before removing the fixture')
            if self.window_id is None:
                self.note('no fixture Finder window id was recorded: no window closed; close it by hand if one is open')
            else:
                self.attempt(f'could not close the fixture Finder window (id {self.window_id}); close it by hand',
                             lambda: drive.osascript(CLOSE_WINDOW_SCRIPT, str(self.window_id)))
        finally:
            for note in self.attempt(f'could not remove the fixture {self.folder}', self.fixture.remove) or []:
                self.note(note)

    def teardown(self):
        """Stop the calibration's own osascript processes, then remove the fixture; neither failure skips the other."""
        try:
            self.attempt('could not stop the calibration osascript', self.stop_started)
        finally:
            self.remove_fixture()

    # steps ---------------------------------------------------------------------------------------------------
    def row_order(self):
        raw = drive.finder_dump()
        self.save('finder-window.jsonl', raw)
        rows = ui.list_rows(ui.parse_dump(raw))
        top = sorted({name.split('/')[0] for name in FILES})
        for name in top:
            ui.find_row(rows, name)
        display = [row.name for row in rows]
        listed = drive.osascript('on run argv\ntell application "Finder" to return name of every item of folder '
                                 '((POSIX file (item 1 of argv)) as alias)\nend run', str(self.folder)).strip()
        return f'display order {display}; AppleScript order [{listed}]'

    def select_readback(self):
        return 'read back ' + str(drive.select([self.path('beta.txt')]))

    def opened(self, out):
        """The `menu-point X,Y` an `ui.sh open-menu` printed, remembered so a failure closes it."""
        point = menu_point_of(out)
        self.menu_points.append(tuple(int(n) for n in point.split(',')))
        return point

    def context_menu(self):
        row, point = drive.open_menu('%2541.txt')
        self.point = point
        self.menu_points.append(point)
        return f'row {row.index} at {row.point}, menu at {point}'

    def menu_read(self):
        nodes = drive.probe('menu-at', self.point[0], self.point[1], '3')
        self.save('menu.jsonl', nodes)
        self.items = ui.menu_items(ui.parse_dump(nodes))
        titles = ui.compress_titles(self.items)
        if titles != ['Compress “%2541.txt”']:
            raise ui.Refused(f'Compress title {titles}, expected Compress “%2541.txt”')
        return f'{len(self.items)} items, {titles[0]}'

    def rclick_group(self):
        group = ui.rclick_group(self.items, expected=self.group)
        return f'found once at items {group[0].index}..{group[-1].index}: ' + ', '.join(item.title for item in group)

    def ui(self, *args):
        """Run `ui.sh ARGS` (the command line a device run uses) and return the finished process."""
        return drive.run([drive.HERE / 'ui.sh', *map(str, args)], timeout=120)

    def cli(self, *args):
        """`ui.sh ARGS` that must succeed: its stdout; exit 65 is Refused, any other failure Environment."""
        result = self.ui(*args)
        if result.returncode == ui.REFUSED:
            raise ui.Refused(f'ui.sh {args[0]}: {result.stderr.strip()}')
        if result.returncode != ui.OK:
            raise ui.Environment(f'ui.sh {args[0]} exited {result.returncode}: {result.stderr.strip()}')
        return result.stdout

    def close_menu(self):
        """`ui.sh close-menu X,Y` on the context menu the context-menu step left open; AX must then show none."""
        self.cli('close-menu', '{},{}'.format(*self.point))
        if drive.menu_open(self.point):
            raise ui.Refused(f'a menu is still open at {self.point} after ui.sh close-menu')
        return 'ui.sh close-menu: the menu closed through AX; no menu left at the menu point'

    def pasted(self, wanted):
        time.sleep(0.8)
        pasted = drive.run(['pbpaste'], timeout=5).stdout
        if sorted(pasted.split('\n')) != sorted(wanted):
            raise ui.Refused(f'pasteboard holds {pasted!r} after Copy Path, not {wanted}')

    def choose(self):
        if 'Copy Path' not in self.group:
            raise ui.Refused("the --group has no Copy Path: calibration chooses Copy Path")
        out = self.cli('choose', 'Copy Path', *group_args(self.group), '--target', self.path('alpha.txt'))
        self.pasted([self.path('alpha.txt')])
        return 'ui.sh choose Copy Path: ' + ui.one_line(out.split('\n', 1)[0] + '\n') + '; pbpaste equals the path'

    def choose_multi(self):
        targets = [self.path('%41.txt'), self.path('%2541.txt')]
        out = self.cli('choose', 'Copy Path', *group_args(self.group), *[a for t in targets for a in ('--target', t)])
        if 'Compress 2 Items' not in out:
            raise ui.Refused(f'ui.sh choose did not verify `Compress 2 Items`: {out!r}')
        self.pasted(targets)
        return 'ui.sh choose with two targets: Compress 2 Items; pbpaste holds both paths, one per line'

    def modifiers_clean(self, when):
        """The HID modifier state read through `modifiers.sh state` (no event posted): Refused when Shift, Control,
        Option or Command is held (device run, 2026-11-18: Option stayed set after option-menu)."""
        flags, held = drive.modifier_state()
        if held:
            raise ui.dirty_input(flags, held, f'{when}; every later click or press refuses until it is released')
        return f'no Shift, Control, Option or Command held {when} (flags 0x{flags:x})'

    def modifiers_start(self):
        try:
            return self.modifiers_clean('before the calibration')
        except ui.Refused as error:
            raise ui.Environment(str(error)) from error

    def modifiers_after_option(self):
        return self.modifiers_clean('after the Option menu')

    def modifiers_end(self):
        return self.modifiers_clean('at the end of the calibration')

    def option_menu(self):
        wanted = 'Delete Direct' + ui.SKIP_SUFFIX
        if 'Delete Direct' not in self.group:
            raise ui.Refused('the --group has no Delete Direct: the Option step reads its skip-confirmation title')
        point = self.opened(self.cli('open-menu', '%2541.txt', '--option'))
        try:
            titles = ui.menu_listing_titles(self.cli('menu', point, *group_args(self.group)))
        finally:
            self.cli('close-menu', point)
        if wanted not in titles:
            raise ui.Refused(f'the Option menu has no {wanted!r} (Option not seen when the menu was built?)')
        return f'ui.sh open-menu --option: the menu shows {wanted!r}'

    def background_menu(self):
        if not self.background_group:
            raise ui.Refused('no --background-group: the background steps need RClick\'s background-menu items')
        point = self.opened(self.cli('open-menu', '--background'))
        try:
            self.cli('menu', point, *group_args(self.background_group))
        finally:
            self.cli('close-menu', point)
        return f'background menu at {point}; RClick\'s background group found; closed'

    def rclick_pid(self):
        try:
            return int((self.run / 'rclick.pid').read_text().strip())
        except (OSError, ValueError):
            return None

    def background_choose(self):
        if 'New File' not in self.background_group:
            raise ui.Refused('the --background-group has no New File: calibration chooses New File → TXT')
        before = set(os.listdir(self.folder))
        self.cli('choose', 'New File', '--sub', 'TXT', *group_args(self.background_group),
                 '--background', str(self.folder))
        pid = self.rclick_pid()
        for _ in range(16):
            time.sleep(0.25)
            new = sorted(set(os.listdir(self.folder)) - before)
            if len(new) > 1:
                raise ui.Refused(f'{len(new)} new entries in the fixture after New File → TXT: {new}')
            if new:
                self.fixture.adopt(self.folder / new[0])
                return f'ui.sh choose --background --sub: New File → TXT created {new[0]!r} in the fixture'
            if pid is not None and self.rclick_panel(pid):
                self.save('rclick-panel.jsonl', drive.app_dump(pid, 20))
                drive.press_button(pid, 'Cancel', window_text=None)
                return ('ui.sh choose --background --sub: New File → TXT reached RClick, which opened its folder '
                        'panel (sandboxed build; saved rclick-panel.jsonl); Cancel pressed, no file created')
        raise ui.Refused('New File → TXT was chosen but no file appeared in the fixture and RClick showed no panel')

    def rclick_panel(self, pid):
        try:
            nodes = drive.app_nodes(pid, 20)
        except (ui.Environment, ui.Refused):
            return False
        return any(title == 'Grant Access' for w in ui.dialog_windows(nodes) for title, _ in w.buttons)

    def start(self, script, *args):
        process = subprocess.Popen(['/usr/bin/osascript', '-e', script, *args], stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)
        self.started.append(process)
        return process

    def wait_window(self, process, button):
        for _ in range(40):
            time.sleep(0.25)
            try:
                if any(title == button for w in ui.dialog_windows(drive.app_nodes(process.pid, 20))
                       for title, _ in w.buttons):
                    return
            except (ui.Refused, ui.Environment):
                continue
        raise ui.Refused(f'no window with a {button!r} button appeared for the calibration process')

    def dialog_read(self):
        self.alert = self.start(f'display alert "{ALERT}" message "dialog reader check" buttons {{"Cancel", "OK"}} '
                                'giving up after 60')
        self.wait_window(self.alert, 'OK')
        raw = drive.app_dump(self.alert.pid)
        self.save('alert.jsonl', raw)
        nodes = ui.parse_dump(raw)
        texts = [text for w in ui.dialog_windows(nodes) for text in w.texts]
        if ALERT not in texts:
            raise ui.Refused(f'alert text not read; texts {texts}')
        return f'texts {texts}'

    def press_button(self):
        drive.press_button(self.alert.pid, 'OK', window_text=ALERT, extra_pids=self.own_pids())
        out, _ = self.alert.communicate(timeout=10)
        if 'OK' not in out:
            raise ui.Refused(f'osascript returned {out.strip()!r}, not OK')
        return 'pressed OK by title; osascript returned ' + out.strip()

    def panel(self, target, mode):
        process = self.start('on run argv\nreturn POSIX path of (choose folder with prompt "RClick calibration panel" '
                             'default location ((POSIX file (item 1 of argv)) as alias))\nend run', str(self.folder))
        self.wait_window(process, 'Choose')
        self.save(f'panel-{mode}.jsonl', drive.app_dump(process.pid, 20))
        plan = drive.grant(process.pid, target, button='Choose', extra_pids=self.own_pids())
        out, _ = process.communicate(timeout=10)
        chosen = ui.clean_path(ui.one_line(out))
        if plan.mode != mode or chosen != ui.clean_path(target):
            raise ui.Refused(f'{plan.mode} mode chose {chosen!r}; expected {mode} mode and {target!r}')
        return f'{mode} mode chose {chosen}' + (f' ({plan.note})' if plan.note else '')

    def own_pids(self):
        return {process.pid for process in self.started if process.poll() is None}

    def stop_started(self):
        for process in self.started:
            if process.poll() is None:
                process.terminate()  # only an osascript this calibration started
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    print(f'note: calibration osascript {process.pid} did not exit')


def calibrate(run_dir, dry_run=False, group=(), background_group=()):
    if dry_run:
        print('\n'.join(plan_lines(run_dir)))
        return ui.OK
    run = Run(run_dir, list(group), background_group)
    # press-button and grant (also inside the ui.sh subprocesses) read RClick's pid from $RUN_DIR/rclick.pid
    if Path(os.environ.setdefault('RUN_DIR', str(run.run))).resolve() != run.run:
        raise ui.Usage(f'RUN_DIR is {os.environ["RUN_DIR"]}, not the calibration run {run.run}')
    try:
        if run.environment():
            try:
                try:
                    run.make_fixture()
                except Exception as error:  # noqa: BLE001
                    run.record('row-order', 'FAIL', f'fixture window: {error}')
                else:
                    run.step('row-order', run.row_order)
                    run.step('select-readback', run.select_readback)
                    run.step('context-menu', run.context_menu)
                    run.step('menu-read', run.menu_read, needs=('context-menu',))
                    run.step('rclick-group', run.rclick_group, needs=('menu-read',))
                    run.step('close-menu', run.close_menu, needs=('context-menu',))
                    run.step('choose', run.choose, needs=('rclick-group',))
                    run.step('choose-multi', run.choose_multi, needs=('choose',))
                    run.step('option-menu', run.option_menu, needs=('rclick-group',))
                    run.step('modifiers-after-option', run.modifiers_after_option)  # also after a failed option-menu
                    run.step('background-menu', run.background_menu)
                    run.step('background-choose', run.background_choose, needs=('background-menu',))
                    run.step('dialog-read', run.dialog_read)
                    run.step('press-button', run.press_button, needs=('dialog-read',))
                    run.step('panel-grant-row', lambda: run.panel(run.path('folder a'), 'row'))
                    run.step('panel-grant-current', lambda: run.panel(str(run.folder), 'current'))
                    run.step('modifiers-end', run.modifiers_end)
            finally:
                run.teardown()
    finally:
        # printed on every path, also when something escaped the steps (it propagates after the report)
        lines, code = ui.calibration_report(run.results)
        report = '\n'.join(lines + ['note: ' + note for note in run.notes])
        print('---')
        print(report, flush=True)
        run.attempt('could not save calibration.txt', lambda: run.save('calibration.txt', report + '\n'))
    return code
