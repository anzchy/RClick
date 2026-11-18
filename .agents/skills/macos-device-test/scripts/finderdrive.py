#!/usr/bin/env python3
"""Side effects of the Finder UI driver (ui.sh, calibrate.sh): run axprobe, AppleScript, the synthetic right-click
and Esc. Every decision (which row, which item, guard, panel plan, verdicts) is made by finderui.py from dumps.

Never changes a system or privacy setting, never runs pluginkit, never quits a process it did not start, never
types through the keyboard layer (Esc is a key code, not text). Acting commands refuse unless the shared GUI lock
is held by an rclick run (gui-lock.sh).
"""
import hashlib
import json
import os
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import finderui as ui  # noqa: E402

ACTING = ('select', 'open-menu', 'close-menu', 'guard', 'choose', 'press-button', 'grant', 'calibrate', 'lock-check')
SELECT_SCRIPT = '''on run argv
  set chosen to {}
  repeat with p in argv
    set end of chosen to ((POSIX file (p as text)) as alias)
  end repeat
  tell application "Finder" to select chosen
end run'''
SELECTION_SCRIPT = '''tell application "Finder" to set chosen to selection as alias list
set out to ((count of chosen) as text) & linefeed
repeat with a in chosen
  set out to out & POSIX path of a & linefeed
end repeat
return out'''
FRONT_SCRIPT = 'tell application "Finder" to return POSIX path of (target of front Finder window as alias)'


def run(argv, timeout=20):
    """Run to completion; stdout is decoded as UTF-8 WITHOUT newline translation (a `\\r` in a name stays)."""
    try:
        result = subprocess.run([str(a) for a in argv], capture_output=True, timeout=timeout)
        return subprocess.CompletedProcess(result.args, result.returncode, result.stdout.decode('utf-8'),
                                           result.stderr.decode('utf-8', 'replace'))
    except UnicodeDecodeError as error:
        raise ui.Environment(f'{Path(str(argv[0])).name} printed bytes that are not UTF-8') from error
    except FileNotFoundError as error:
        raise ui.Environment(f'{argv[0]} not found') from error
    except subprocess.TimeoutExpired as error:
        raise ui.Environment(f'{Path(str(argv[0])).name} timed out after {timeout} s') from error


def spawn(argv):
    """A long-lived process with pipes (axprobe menu-session). With `run`, the only process boundary of the driver."""
    try:
        return subprocess.Popen([str(a) for a in argv], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE)
    except FileNotFoundError as error:
        raise ui.Environment(f'{argv[0]} not found') from error


def private_dir(path):
    """`path` created 0700 when missing; refused unless it is a real directory (not a symlink) owned by this user that
    no one else can write."""
    try:
        os.mkdir(path, 0o700)
    except FileExistsError:
        pass
    info = os.lstat(path)
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() \
            or info.st_mode & 0o077:
        raise ui.Environment(f'axprobe cache {path} is not a private directory of this user (a symlink, another '
                             'owner, or group/other permissions): remove it by hand and rerun')
    return path


def probe_binary():
    """axprobe compiled once per source hash into ~/Library/Caches/rclick-axprobe/<hash>/ (never into the repo, never
    into a shared temporary directory). It runs with the host terminal's Accessibility trust, so before every reuse
    the directories and the executable must be this user's and writable by no one else; a build is compiled to a
    temporary name in the private directory and renamed into place."""
    source = (HERE / 'axprobe.swift').read_bytes()
    # axprobe's acting commands run THIS driver's lock check (`finderdrive.py lock-check`); its path is compiled in as
    # UTF-8 bytes (no string escaping), so the cache key covers it too.
    driver = ('let driverScript = String(decoding: [UInt8]([' + ', '.join(str(b) for b in str(HERE / 'finderdrive.py')
              .encode('utf-8')) + ']), as: UTF8.self)\n').encode('utf-8')
    digest = hashlib.sha256(source + b'\0' + driver).hexdigest()[:16]
    caches = Path.home() / 'Library' / 'Caches'
    caches.mkdir(parents=True, exist_ok=True)  # exists on every Mac; the tests use a temporary HOME
    folder = private_dir(private_dir(caches / 'rclick-axprobe') / digest)
    binary = folder / 'axprobe'
    try:
        info = os.lstat(binary)
    except FileNotFoundError:
        info = None
    if info is not None:
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
            raise ui.Environment(f'axprobe cache {binary} is not a regular file of this user writable only by it: '
                                 'remove it by hand and rerun')
        return binary
    build = Path(tempfile.mkdtemp(prefix='build.', dir=folder))
    try:
        (build / 'main.swift').write_bytes(source)
        (build / 'driver.swift').write_bytes(driver)
        partial = build / 'axprobe'
        result = run(['xcrun', 'swiftc', '-O', '-o', partial, build / 'main.swift', build / 'driver.swift'], timeout=300)
        if result.returncode != 0:
            raise ui.Environment('cannot compile axprobe.swift: ' + (result.stderr.strip().splitlines() or ['?'])[-1])
        os.chmod(partial, 0o700)
        os.rename(partial, binary)
    finally:
        for leftover in sorted(build.iterdir(), reverse=True):
            leftover.unlink()
        build.rmdir()
    return binary


def probe(*args, timeout=20):
    result = run([probe_binary(), *args], timeout=timeout)
    message = result.stderr.strip()
    if result.returncode == 65:
        raise ui.Refused(message)
    if result.returncode != 0:
        raise ui.Environment(message or f'axprobe exited {result.returncode}')
    return result.stdout


def osascript(script, *args, timeout=20):
    result = run(['osascript', '-e', script, *args], timeout=timeout)
    if result.returncode != 0:
        raise ui.Environment('AppleScript failed: ' + result.stderr.strip())
    return result.stdout


def require_lock():
    """The GUI lock must be held by THIS run's acquisition (finderui.check_lock)."""
    status = run([HERE / 'gui-lock.sh', 'status'], timeout=10)
    ui.check_lock(status.stdout, os.environ.get('RCLICK_GUI_LOCK_BATCH', ''),
                  os.environ.get('RCLICK_GUI_LOCK_ACQUISITION_ID', ''))


def require_trust():
    result = run([probe_binary(), 'trusted'], timeout=10)
    if result.returncode != 0:
        raise ui.Environment('Accessibility is not granted to the host terminal; the owner grants it in System Settings '
                             '→ Privacy & Security → Accessibility (no restart needed). Never change it from a run.')


def finder_pid():
    result = run(['pgrep', '-x', 'Finder'], timeout=10)
    pids = result.stdout.split()
    if result.returncode not in (0, 1) or len(pids) != 1:
        raise ui.Environment(f'expected one Finder process, found {len(pids)}')
    return int(pids[0])


def finder_dump():
    """Raw JSON lines of the front Finder window (window 0)."""
    return probe('dump', finder_pid(), '0', '14')


def finder_nodes():
    return ui.parse_dump(finder_dump())


def app_dump(pid, depth=12):
    return probe('dump', pid, 'all', depth)


def app_nodes(pid, depth=12):
    return ui.parse_dump(app_dump(pid, depth))


def alive(pid):
    state = run(['ps', '-o', 'stat=', '-p', pid], timeout=5).stdout.strip()
    return bool(state) and not state.startswith('Z')


def dotted(path):
    return '.'.join(str(step) for step in path)


ESCAPE_SCRIPT = '''tell application "System Events"
  if name of first process whose frontmost is true is "Finder" then
    key code 53
    return "escaped"
  end if
end tell
return "skipped: Finder is not frontmost"'''


def escape():
    """Esc (key code 53, not text: no input method involved) to close Finder's open menu, sent ONLY when Finder is
    frontmost, so it never lands in another app (the terminal running the tester, an RClick dialog). Returns
    osascript's answer (`escaped`, or `skipped: …`)."""
    return run(['osascript', '-e', ESCAPE_SCRIPT], timeout=10).stdout.strip()


def close_menu():
    """`ui.sh close-menu`: escape(), refused (65) when Finder was not frontmost and nothing was sent."""
    answer = escape()
    if answer != 'escaped':
        raise ui.Refused(f'Finder is not frontmost: no key sent ({answer or "no answer"})')
    return answer


def activate_finder():
    osascript('tell application "Finder" to activate')
    time.sleep(0.4)


def selection():
    return ui.parse_selection(osascript(SELECTION_SCRIPT))


def select(paths):
    osascript(SELECT_SCRIPT, *paths)
    time.sleep(0.3)
    got = selection()
    wanted = sorted(ui.clean_path(p) for p in paths)
    if sorted(got) != wanted:
        raise ui.Refused(f'Finder selection read back as {got}, not {wanted}')
    return got


def read_menu(point):
    return ui.menu_items(ui.parse_dump(probe('menu-at', point[0], point[1], '3')))


def menu_point(click):
    for point in ui.probe_points(click):
        try:
            if read_menu(point):
                return point
        except ui.Refused:
            continue
    raise ui.Refused(f'no menu opened at {click[0]},{click[1]} (probed {ui.probe_points(click)})')


DESELECT_SCRIPT = 'tell application "Finder" to set selection to {}'


def open_background_menu(option=False):
    """Deselect everything, read the selection back (it must be empty), then right-click the empty part of the front
    window's file list (finderui.background_point). Returns (point clicked, menu point)."""
    escape()
    activate_finder()
    osascript(DESELECT_SCRIPT)
    time.sleep(0.3)
    left = selection()
    if left:
        raise ui.Refused(f'Finder still has {left} selected after deselecting: no background menu opened')
    point = ui.background_point(finder_nodes())
    click = run([HERE / 'rightclick.sh', *map(str, point), *(['option'] if option else [])], timeout=10)
    if click.returncode != 0:
        raise ui.Environment('rightclick.sh failed: ' + click.stderr.strip())
    time.sleep(1.0)
    return point, menu_point(point)


def open_menu(name, option=False):
    """Fresh AX rows → the one row named `name` → AXSelected → right-click at its AX centre. Never reuses
    coordinates: a list that shifted after a delete (i13-device-20261117c) is re-read every time."""
    escape()
    activate_finder()
    row = ui.find_row(ui.list_rows(finder_nodes()), name)
    probe('act', finder_pid(), dotted(row.path), 'select', 'AXRow', name)
    time.sleep(0.3)
    again = ui.find_row(ui.list_rows(finder_nodes()), name)
    if again.point != row.point:
        raise ui.Refused(f'row {name!r} moved from {row.point} to {again.point} while selecting; retry')
    click = run([HERE / 'rightclick.sh', *map(str, row.point), *(['option'] if option else [])], timeout=10)
    if click.returncode != 0:
        raise ui.Environment('rightclick.sh failed: ' + click.stderr.strip())
    time.sleep(1.0)
    return row, menu_point(row.point)


def guard(point, targets, background=None):
    try:
        items = read_menu(point)
        front = ui.one_line(osascript(FRONT_SCRIPT)) if background else None
        return items, ui.check_guard(targets, selection(), items, background=background, front=front)
    except ui.Refused:
        escape()
        raise


class MenuSession:
    """`axprobe menu-session X Y`: one axprobe process finds the menu under the point, prints its owner pid and its
    dump, and waits for one decision. The press it is then told to make is checked by that same process against the
    menu it holds (owner pid, every top-level title) right before AXPress, so a menu closed or replaced after the
    guard is refused (65), never pressed."""

    def __init__(self, point):
        self.process = spawn([probe_binary(), 'menu-session', point[0], point[1], '3'])
        lines = []
        while True:
            line = self.process.stdout.readline()
            if not line:
                _, err = self.finish(None)
                raise (ui.Refused if self.process.returncode == 65 else ui.Environment)(
                    err or f'axprobe menu-session ended before its dump (exit {self.process.returncode})')
            text = line.decode('utf-8')
            try:
                if text.strip() and json.loads(text) == {'end': True}:
                    break
            except json.JSONDecodeError as error:
                self.process.kill()
                raise ui.Environment(f'axprobe menu-session printed a line that is not JSON: {error}') from error
            lines.append(text)
        header = json.loads(lines.pop(0)) if lines else {}
        if not isinstance(header.get('session'), dict) or not isinstance(header['session'].get('pid'), int):
            self.finish({'abort': True})
            raise ui.Environment('axprobe menu-session printed no owner pid')
        self.pid = header['session']['pid']
        self.nodes = ui.parse_dump(''.join(lines))

    def finish(self, request):
        data = (json.dumps(request) + '\n').encode('utf-8') if request is not None else None
        try:
            out, err = self.process.communicate(input=data, timeout=30)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
            raise ui.Environment('axprobe menu-session did not answer in 30 s: nothing pressed')
        return out.decode('utf-8', 'replace'), err.decode('utf-8', 'replace').strip()

    def abort(self):
        self.finish({'abort': True})

    def press(self, item, sub_path, sub_title):
        request = {'press': list(sub_path or item.path), 'title': item.title, 'sub': sub_title if sub_path else None,
                   'titles': [node.get('title') or '' for node in sorted(self.nodes, key=lambda n: n['path'])
                              if len(node['path']) == 1],
                   'pid': self.pid}
        _, err = self.finish(request)
        if self.process.returncode == 65:
            raise ui.Refused(err or 'the menu changed since it was verified: nothing pressed')
        if self.process.returncode != 0:
            raise ui.Environment(err or f'axprobe menu-session exited {self.process.returncode}')


def choose(point, title, group, sub=None, targets=(), background=None):
    """The guard and the press at ONE boundary: the menu session's dump must belong to Finder, pass the guard
    against a selection read now (inside the session), and hold `title` in RClick's group; the same axprobe
    process then re-checks the held menu and presses. Any refusal aborts the session, closes the menu, presses
    nothing. Returns (guard reason, item)."""
    session = MenuSession(point)
    try:
        owner = finder_pid()
        if session.pid != owner:
            raise ui.Refused(f'the menu at {point[0]},{point[1]} belongs to pid {session.pid}, not Finder ({owner})')
        items = ui.menu_items(session.nodes)
        front = ui.one_line(osascript(FRONT_SCRIPT)) if background else None
        reason = ui.check_guard(targets, selection(), items, background=background, front=front)
        item, sub_path = ui.find_group_item(items, title, sub, group)
    except (ui.Refused, ui.Environment):
        session.abort()
        escape()
        raise
    try:
        session.press(item, sub_path, sub)
    except ui.Refused:
        escape()
        raise
    return reason, item


def print_menu(items, also=(), expected=()):
    for item in items:
        x, y = item.point or ('?', '?')
        print(f'{item.index}|{item.title}|{str(item.enabled).lower()}|{x},{y}|{len(item.sub)}')
    print('compress: ' + (' / '.join(ui.compress_titles(items)) or '(none)'))
    group = ui.rclick_group(items, also)
    print('rclick-group (heuristic, never used to choose): ' + (', '.join(item.title for item in group) or '(none)'))
    if expected:
        group = ui.rclick_group(items, expected=expected)
        print(f'rclick-group (expected): found once at items {group[0].index}..{group[-1].index}')
    for item in group:
        if item.sub:
            print(f'  {item.title}: ' + ', '.join(name for name, _ in item.sub))


def allowed_process(pid, extra_pids=()):
    """finderui.allowed_process on the live process table; the RClick pid is this run's $RUN_DIR/rclick.pid."""
    table = ui.parse_process_table(run(['ps', '-p', pid, '-o', 'pid=,comm='], timeout=5).stdout)
    rclick_pid = None
    if os.environ.get('RUN_DIR'):
        try:
            rclick_pid = int((Path(os.environ['RUN_DIR']) / 'rclick.pid').read_text().strip())
        except (OSError, ValueError):
            rclick_pid = None
    return ui.allowed_process(pid, table, rclick_pid, extra_pids)


def press_button(pid, title, window_text=None, extra_pids=()):
    allowed_process(pid, extra_pids)
    path = ui.find_button(app_nodes(pid), title, window_text)
    probe('act', pid, dotted(path), 'press', 'AXButton', title)


def grant(pid, folder, button='Grant Access', extra_pids=()):
    """finderui.panel_plan from full paths, select the target row (row mode), re-read the panel and require
    finderui.panel_ready (the target the only selected row; none in current mode), press, wait for it to close."""
    allowed_process(pid, extra_pids)
    plan = ui.panel_plan(app_nodes(pid, 20), folder, button)
    if plan.mode == 'row':
        probe('act', pid, dotted(plan.row_path), 'select', 'AXRow', ui.basename(folder))
        time.sleep(0.4)
    again = ui.panel_ready(app_nodes(pid, 20), folder, button)
    if (again.mode, again.row_path, again.button_path) != (plan.mode, plan.row_path, plan.button_path):
        raise ui.Refused('the panel changed after selecting the row; nothing pressed')
    probe('act', pid, dotted(plan.button_path), 'press', 'AXButton', button)
    for _ in range(20):
        time.sleep(0.25)
        try:
            nodes = app_nodes(pid, 6)
        except ui.Environment:
            if alive(pid):
                raise
            return plan  # the process that showed the panel has ended (a calibration osascript)
        if not any(title == button for w in ui.dialog_windows(nodes) for title, _ in w.buttons):
            return plan
    raise ui.Refused(f'the panel is still open after {button!r} (button disabled, or not a folder?)')


def command(args):
    if args.command in ACTING and not (args.command == 'calibrate' and args.dry_run):
        require_lock()
    if args.command == 'lock-check':
        return ui.OK  # require_lock above passed
    if args.command == 'calibrate':
        import calibration
        return calibration.calibrate(Path(args.run_dir), args.dry_run, args.group, args.background_group)
    require_trust()
    if args.command == 'rows':
        nodes = finder_nodes()
        print('window: ' + next((n.get('title') or '' for n in nodes if n['path'] == (0,)), ''))
        for row in ui.list_rows(nodes):
            print(f'{row.index}\t{row.name}\t{row.point[0]}\t{row.point[1]}\t{"visible" if row.visible else "hidden"}')
    elif args.command == 'select':
        for path in select(args.paths):
            print(path)
    elif args.command == 'selection':
        for path in selection():
            print(path)
    elif args.command == 'open-menu' and args.background:
        clicked, point = open_background_menu(args.option)
        print(f'background: {clicked[0]},{clicked[1]}')
        print(f'menu-point {point[0]},{point[1]}')
    elif args.command == 'open-menu':
        row, point = open_menu(args.name, args.option)
        print(f'row: {row.index} {row.name} {row.point[0]},{row.point[1]}')
        print(f'menu-point {point[0]},{point[1]}')
    elif args.command == 'close-menu':
        print(close_menu())
    elif args.command == 'menu':
        print_menu(read_menu(args.point), args.also, args.group)
    elif args.command == 'guard':
        _, reason = guard(args.point, args.targets, args.background)
        print('GUARD PASS — ' + reason)
    elif args.command == 'choose':
        reason, item = choose(args.point, args.title, args.group, args.sub, args.target, args.background)
        print('GUARD PASS — ' + reason)
        print('chose: ' + item.title + (f' → {args.sub}' if args.sub else ''))
    elif args.command == 'dialog':
        print(ui.format_dialogs(ui.dialog_windows(app_nodes(args.pid))))
    elif args.command == 'press-button':
        press_button(args.pid, args.title, args.window_text)
        print(f'pressed: {args.title}')
    elif args.command == 'grant':
        plan = grant(args.pid, args.folder, args.button)
        print(f'granted: {ui.clean_path(args.folder)} ({plan.mode} mode; {plan.note})')
    return ui.OK


def main(argv):
    if argv[:1] == ['help'] or any(arg in ('-h', '--help') for arg in argv):
        print(ui.USAGE_TEXT)
        return ui.OK
    try:
        return command(ui.parse_args(argv))
    except ui.Usage as error:
        print(f'usage error: {error} (ui.sh --help lists the commands)', file=sys.stderr)
        return ui.USAGE
    except ui.Refused as error:
        print(f'REFUSED: {error}', file=sys.stderr)
        return ui.REFUSED
    except (ui.Environment, OSError, RuntimeError) as error:
        print(f'ENVIRONMENT: {error}', file=sys.stderr)
        return ui.ENVIRONMENT


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
