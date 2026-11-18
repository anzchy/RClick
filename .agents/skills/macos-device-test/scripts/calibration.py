"""The calibration run (calibrate.sh): proves every ui.sh helper on this Mac's macOS and Finder before a device run
relies on it. It works on a throwaway folder under $RUN_DIR/fixtures/, and on an alert and a folder panel raised by
osascript processes it starts itself (and only those may be terminated). The verdict lines come from
finderui.calibration_report; the raw AX dumps are saved under $RUN_DIR/calibration/ for the correction loop.

Side effects on the desktop, all under the GUI lock: opens and closes one Finder window on the fixture folder (list
view), selects in it, opens context menus there, chooses RClick's Copy Path once (the pasteboard is overwritten with a
fixture path), shows one alert and two folder panels from its own osascript processes.
"""
import subprocess
import time
from datetime import datetime
from pathlib import Path

import device
import finderdrive as drive
import finderui as ui

FILES = ('%41.txt', '%2541.txt', 'alpha.txt', 'beta.txt', '中文 名称.txt', 'folder a/inner.txt')
ALERT = 'RClick calibration alert'


def plan_lines(run_dir):
    lines = [f'calibration plan (dry run, nothing touched); fixture folder {run_dir}/fixtures/calibration-<time>/',
             '  files: ' + ', '.join(repr(name) for name in FILES)]
    lines += [f'  step {step}: proves {command}' for step, command in ui.CALIBRATION_STEPS]
    return lines


class Run:
    def __init__(self, run_dir):
        self.run = device.run_dir(str(run_dir))
        stamp = datetime.now().strftime('%Y%m%d-%H%M%S')
        self.folder = self.run / 'fixtures' / f'calibration-{stamp}'
        self.evidence = self.run / 'calibration'
        self.results = []
        self.started = []

    def record(self, step, status, detail):
        self.results.append((step, status, detail))
        print(f'{status} {step} — {detail}', flush=True)

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
            drive.escape()
            return None
        self.record(name, 'PASS', detail)
        return detail

    # environment ---------------------------------------------------------------------------------------------
    def environment(self):
        checks = (('gui-lock', drive.require_lock, 'held by an rclick run'),
                  ('axprobe', lambda: drive.probe_binary(), 'compiled into $TMPDIR'),
                  ('accessibility', drive.require_trust, 'host terminal is AX-trusted'))
        for name, check, detail in checks:
            try:
                check()
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
        for name in FILES:
            target = self.folder / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(name + '\n', encoding='utf-8')
        drive.run(['open', self.folder], timeout=10)
        for _ in range(20):
            time.sleep(0.25)
            try:
                if ui.clean_path(drive.osascript(drive.FRONT_SCRIPT).strip()) == str(self.folder):
                    break
            except ui.Environment:
                continue
        else:
            raise ui.Environment('the fixture window did not come to the front')
        drive.osascript('tell application "Finder" to set current view of front Finder window to list view')
        time.sleep(0.5)

    def remove_fixture(self):
        drive.escape()
        try:
            drive.osascript('on run argv\ntell application "Finder" to close (every Finder window whose target is '
                            '((POSIX file (item 1 of argv)) as alias))\nend run', str(self.folder))
        except ui.Environment:
            print('note: could not close the fixture Finder window; close it by hand')
        for name in FILES:
            (self.folder / name).unlink(missing_ok=True)
        for directory in (self.folder / 'folder a', self.folder):
            (directory / '.DS_Store').unlink(missing_ok=True)  # Finder writes it into the fixture folder
            try:
                directory.rmdir()
            except OSError:
                print(f'note: left {directory} (not empty: Finder may have written .DS_Store)')

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

    def context_menu(self):
        row, point = drive.open_menu('%2541.txt')
        self.point = point
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
        group = ui.rclick_group(self.items)
        if not group:
            raise ui.Refused("no RClick group after Quick Actions: extension not loaded (doctor extension-*)?")
        return ', '.join(item.title for item in group)

    def guard(self):
        reason = ui.check_guard([self.path('%2541.txt')], drive.selection(), self.items)
        try:
            ui.check_guard([self.path('%41.txt')], drive.selection(), self.items)
        except ui.Refused as refusal:
            refused = str(refusal)
        else:
            raise ui.Refused('the guard accepted the sibling %41.txt')
        drive.escape()
        return f'accepted {reason}; refused the sibling: {refused}'

    def choose(self):
        if 'Copy Path' not in [item.title for item in ui.rclick_group(self.items)]:
            raise ui.Refused("RClick's group has no Copy Path")
        _, point = drive.open_menu('alpha.txt')
        drive.choose(point, 'Copy Path', targets=[self.path('alpha.txt')])
        time.sleep(0.8)
        pasted = drive.run(['pbpaste'], timeout=5).stdout.strip()
        if pasted != self.path('alpha.txt'):
            raise ui.Refused(f'pasteboard holds {pasted!r} after Copy Path, not the fixture path')
        return 'Copy Path chose through the guard; pbpaste equals the fixture path (pasteboard overwritten)'

    def start(self, script, *args):
        process = subprocess.Popen(['osascript', '-e', script, *args], stdout=subprocess.PIPE,
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
        drive.press_button(self.alert.pid, 'OK', window_text=ALERT)
        out, _ = self.alert.communicate(timeout=10)
        if 'OK' not in out:
            raise ui.Refused(f'osascript returned {out.strip()!r}, not OK')
        return 'pressed OK by title; osascript returned ' + out.strip()

    def panel(self, target, mode):
        process = self.start('on run argv\nreturn POSIX path of (choose folder with prompt "RClick calibration panel" '
                             'default location ((POSIX file (item 1 of argv)) as alias))\nend run', str(self.folder))
        self.wait_window(process, 'Choose')
        self.save(f'panel-{mode}.jsonl', drive.app_dump(process.pid, 20))
        plan = drive.grant(process.pid, target, button='Choose')
        out, _ = process.communicate(timeout=10)
        chosen = ui.clean_path(out.strip())
        if plan.mode != mode or chosen != ui.clean_path(target):
            raise ui.Refused(f'{plan.mode} mode chose {chosen!r}; expected {mode} mode and {target!r}')
        return f'{mode} mode chose {chosen}' + (f' ({plan.note})' if plan.note else '')

    def stop_started(self):
        for process in self.started:
            if process.poll() is None:
                process.terminate()  # only an osascript this calibration started
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    print(f'note: calibration osascript {process.pid} did not exit')


def calibrate(run_dir, dry_run=False):
    if dry_run:
        print('\n'.join(plan_lines(run_dir)))
        return ui.OK
    run = Run(run_dir)
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
                run.step('guard', run.guard, needs=('menu-read',))
                run.step('choose', run.choose, needs=('rclick-group', 'guard'))
                run.step('dialog-read', run.dialog_read)
                run.step('press-button', run.press_button, needs=('dialog-read',))
                run.step('panel-grant-row', lambda: run.panel(run.path('folder a'), 'row'))
                run.step('panel-grant-current', lambda: run.panel(str(run.folder), 'current'))
        finally:
            run.stop_started()
            run.remove_fixture()
    lines, code = ui.calibration_report(run.results)
    print('---')
    print('\n'.join(lines))
    run.save('calibration.txt', '\n'.join(lines) + '\n')
    return code
