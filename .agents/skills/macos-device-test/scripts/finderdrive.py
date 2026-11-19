#!/usr/bin/env python3
"""Side effects of the Finder UI driver (ui.sh, calibrate.sh): run axprobe, AppleScript, the synthetic right-click
and Esc. Every decision (which row, which item, guard, panel plan, verdicts) is made by finderui.py from dumps.

Never changes a system or privacy setting, never runs pluginkit, never quits a process it did not start, never
types through the keyboard layer (Esc is a key code, not text). Acting commands refuse unless the shared GUI lock
is held by an rclick run (gui-lock.sh).
"""
import contextlib
import ctypes
import hashlib
import json
import os
import signal
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import finderui as ui  # noqa: E402

CLICKING = ('choose', 'open-menu')  # refused up front on a stuck modifier (require_clean_input)
ACTING = ('select', 'open-menu', 'close-menu', 'choose', 'press-button', 'grant', 'calibrate', 'lock-check')
SELECT_SCRIPT = '''on run argv
  set chosen to {}
  repeat with p in argv
    set end of chosen to ((POSIX file (p as text)) as alias)
  end repeat
  tell application "Finder" to select chosen
end run'''
# Finder answers NO AppleScript while its context menu is open (every call waits for the 20 s timeout: device run,
# 2026-11-18); System Events still answers. So every Finder script below runs before a menu is opened, never while
# one is: the menu is checked and pressed through AX (axprobe), and closed through AX (close_menu).
SELECTION_SCRIPT = '''tell application "Finder" to set chosen to selection as alias list
set out to ((count of chosen) as text) & linefeed
repeat with a in chosen
  set out to out & POSIX path of a & linefeed
end repeat
return out'''


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


def checked_dir(path, others_mask, create=True):
    """`path` (created 0700 when missing and `create`) refused unless lstat shows a real directory (not a symlink)
    owned by this user with none of the `others_mask` permission bits. Nothing below a refused directory is read."""
    if create:
        try:
            os.mkdir(path, 0o700)
        except FileExistsError:
            pass
    try:
        info = os.lstat(path)
    except FileNotFoundError as error:
        raise ui.Environment(f'axprobe cache ancestor {path} does not exist') from error
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() \
            or info.st_mode & others_mask:
        raise ui.Environment(f'axprobe cache path {path} is not a directory of this user that only it can '
                             f'{"use" if others_mask == 0o077 else "write"} (a symlink, another owner, or '
                             'group/other permissions): fix or remove it by hand and rerun')
    return path


def private_dir(path):
    """`path` created 0700 when missing; refused unless it is a real directory (not a symlink) owned by this user that
    no one else can read, write or enter."""
    return checked_dir(path, 0o077)


def cache_root():
    """~/Library/Caches, reached one lstat-checked level at a time from the home directory: each of home, Library and
    Caches must be a real directory (no symlink is followed) owned by this user that group and other cannot write.
    Library and Caches are created 0700 when missing (only in a fresh temporary HOME; every Mac has them)."""
    home = checked_dir(Path.home(), 0o022, create=False)
    return checked_dir(checked_dir(home / 'Library', 0o022) / 'Caches', 0o022)


def probe_binary():
    """axprobe compiled once per source hash into ~/Library/Caches/rclick-axprobe/<hash>/ (never into the repo, never
    into a shared temporary directory). It runs with the host terminal's Accessibility trust, so before every reuse
    every path from the home directory down (cache_root, then the two private directories, then the executable) is
    lstat-checked: no symlink, this user's, writable by no one else. A build is compiled to a temporary name in the
    private directory and renamed into place."""
    source = (HERE / 'axprobe.swift').read_bytes()
    # axprobe's acting commands run THIS driver's lock check (`finderdrive.py lock-check`); its path is compiled in as
    # UTF-8 bytes (no string escaping), so the cache key covers it too.
    driver = ('let driverScript = String(decoding: [UInt8]([' + ', '.join(str(b) for b in str(HERE / 'finderdrive.py')
              .encode('utf-8')) + ']), as: UTF8.self)\n').encode('utf-8')
    digest = hashlib.sha256(source + b'\0' + driver).hexdigest()[:16]
    folder = private_dir(private_dir(cache_root() / 'rclick-axprobe') / digest)
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


FOCUS_SCRIPT = 'tell application "System Events" to set frontmost of process "Finder" to true'
FINDER_ESCAPE_SCRIPT = 'tell application "System Events" to tell process "Finder" to key code 53'
POLL = 0.25
MENU_WAIT = 4.0  # seconds a fresh context menu may take to appear (the first, cold menu of a run is the slowest)


def focus_finder():
    """Bring Finder to the front through System Events (not Finder's own `activate`: no Finder AppleScript)."""
    osascript(FOCUS_SCRIPT, timeout=10)
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


def menu_open(point):
    """True when AX shows a menu under `point` (read only: no key, no AppleScript)."""
    try:
        return bool(read_menu(point))
    except ui.Refused:
        return False


def wait_menu(click, seconds=MENU_WAIT):
    """The point where the menu a right-click at `click` opened can be read, polled through AX for up to `seconds`
    (one fixed wait missed the first, cold menu of the device run of 2026-11-18). Refused with axprobe's last
    answer (`found AXTextField`: the click point still shows the row, no menu) when none appears."""
    last = 'nothing probed'
    for _ in range(round(seconds / POLL) + 1):
        time.sleep(POLL)
        for point in ui.probe_points(click):
            try:
                if read_menu(point):
                    return point
                last = f'empty menu at {point[0]},{point[1]}'
            except ui.Refused as error:
                last = str(error)
    raise ui.Refused(f'no menu opened at {click[0]},{click[1]} within {seconds:g} s (probed '
                     f'{ui.probe_points(click)}; last: {last})')


def wait_closed(point, seconds=1.0):
    for _ in range(round(seconds / POLL) + 1):
        if not menu_open(point):
            return True
        time.sleep(POLL)
    return not menu_open(point)


def close_menu(point):
    """`ui.sh close-menu X,Y`: close Finder's menu at `point`. No menu there: nothing is sent. A menu of another
    process: Refused, nothing sent. Else AXCancel through axprobe (no key event); if AX still shows the menu, Esc
    (key code 53) to Finder through System Events, sent ONLY while AX shows that open Finder menu, which takes the
    key (so it never lands in another app such as the terminal). Environment when the menu is still open."""
    if not menu_open(point):
        return f'no menu open at {point[0]},{point[1]}: nothing sent'
    how = []
    try:
        probe('menu-cancel', point[0], point[1], finder_pid())
        how.append('AXCancel')
    except ui.Environment as error:
        how.append(f'AXCancel failed ({error})')
    if wait_closed(point):
        return f'closed ({", ".join(how)})'
    osascript(FINDER_ESCAPE_SCRIPT, timeout=10)
    how.append('Esc to Finder')
    if wait_closed(point):
        return f'closed ({", ".join(how)})'
    raise ui.Environment(f'a Finder menu is still open at {point[0]},{point[1]} after {", ".join(how)}: close it by '
                         'hand (Finder answers no AppleScript until it is closed)')


class Opened:
    """What one right-click of this process may have opened: the click point, the menu point once found, the axprobe
    session once it holds the menu, and whether that menu is another process's (never ours to close)."""

    def __init__(self, click):
        self.click, self.point, self.session, self.foreign = click, None, None, False

    def release(self):
        """After a failure: end the session (abandon another process's menu; abort Finder's, which axprobe cancels only
        when Finder owns it), then close_menu at the menu point, or at every probe point of the click when the menu
        was never found. Never raises; returns what could not be done."""
        problems = []
        session, self.session = self.session, None
        if session is not None and not session.done:
            try:
                session.abandon() if self.foreign else session.abort()
            except (ui.Refused, ui.Environment, OSError) as error:
                problems.append(f'the menu session could not be ended ({error})')
        if self.foreign:
            return problems
        for point in [self.point] if self.point else ui.probe_points(self.click):
            try:
                if not close_menu(point).startswith('no menu open'):
                    break
            except ui.Refused as error:
                problems.append(f'the menu at {point[0]},{point[1]} was left open ({error})')
            except (ui.Environment, OSError) as error:
                problems.append(str(error))
        return problems


@contextlib.contextmanager
def menu_boundary(click):
    """From a right-click at `click` onward: any exception closes what that click opened (Opened.release) before it
    propagates, with a cleanup failure added to the original error (whose type, so its exit code, is kept). The
    right-click itself runs inside: a click that failed half-way may still have opened a menu."""
    opened = Opened(click)
    try:
        yield opened
    except BaseException as error:
        problems = opened.release()
        if problems and isinstance(error, Exception):
            error.args = (f'{error}; and the menu could not be closed: {"; ".join(problems)}',)
        raise


MODIFIERS = HERE / 'modifiers.sh'


def modifier_state():
    """(flags, held names) of the HID | combined session state through `modifiers.sh state` (a read: no event)."""
    result = run([MODIFIERS, 'state'], timeout=10)
    if result.returncode != 0:
        raise ui.Environment('modifiers.sh state failed: ' + (result.stderr.strip() or f'exit {result.returncode}'))
    return ui.held_modifiers(result.stdout)


def require_clean_input(doing):
    """Fail closed (Refused, 65) when the HID or the combined session state holds Shift, Control, Option or Command:
    at every check this process holds none of its own (pressing releases them before it returns), so a held one is
    stuck or someone else's, and it would change what the click or press does. A read only: nothing is posted."""
    flags, held = modifier_state()
    if held:
        raise ui.dirty_input(flags, held, doing)


def release_modifiers(names):
    """Release the modifiers this process pressed (`modifiers.sh release`: key-ups, then a flagsChanged event with no
    flags) and read the state back: Environment when one of them still shows as held."""
    result = run([MODIFIERS, 'release', *names], timeout=10)
    flags, held = modifier_state()
    still = [name for name in held if name.lower() in names]
    if result.returncode != 0 or still:
        raise ui.Environment(f'could not release {", ".join(names)} (modifiers.sh release: '
                             f'{result.stderr.strip() or f"exit {result.returncode}"}; flags now 0x{flags:x}): press '
                             'and release that key on the keyboard before anything else is clicked (every acting '
                             'ui.sh command refuses until `modifiers.sh state` shows no modifier)')


@contextlib.contextmanager
def pressing(names):
    """Modifiers posted inside the block are released on EVERY exit: success, an exception, Ctrl-C (KeyboardInterrupt)
    or SIGTERM (main turns it into Terminated). A release failure after another error is added to that error (whose
    type, so its exit code, is kept); after success it is raised."""
    if not names:
        yield
        return
    try:
        yield
    except BaseException as error:
        try:
            release_modifiers(names)
        except (ui.Environment, OSError) as problem:
            if isinstance(error, Exception):
                error.args = (f'{error}; and {problem}',)
        raise
    release_modifiers(names)


def right_click(point, option=False):
    """rightclick.sh at `point`; with `option` the Option flag it posts is released here as well (pressing), whatever
    happens to rightclick.sh (a failure, a timeout, a signal that kills it before its own release)."""
    require_clean_input('nothing clicked')
    with pressing(['option'] if option else []):
        click = run([HERE / 'rightclick.sh', *map(str, point), *(['option'] if option else [])], timeout=10)
        if click.returncode != 0:
            raise ui.Environment('rightclick.sh failed: ' + click.stderr.strip())


DESELECT_SCRIPT = 'tell application "Finder" to set selection to {}'


def deselect_all():
    """Deselect everything through AppleScript (no menu is open yet) and read the empty selection back."""
    osascript(DESELECT_SCRIPT)
    time.sleep(0.3)
    left = selection()
    if left:
        raise ui.Refused(f'Finder still has {left} selected after deselecting: no background menu opened')


def open_background_menu(option=False):
    """Deselect everything, read the selection back (it must be empty), then right-click the empty part of the front
    window's file list (finderui.background_point). Returns (point clicked, menu point)."""
    focus_finder()
    deselect_all()
    point = ui.background_point(finder_nodes())
    with menu_boundary(point) as opened:
        right_click(point, option)
        opened.point = wait_menu(point)
    return point, opened.point


def open_menu(name, option=False):
    """Fresh AX rows → the one row named `name` → AXSelected → right-click at its AX centre. Never reuses
    coordinates: a list that shifted after a delete (i13-device-20261117c) is re-read every time."""
    focus_finder()
    row = ui.find_row(ui.list_rows(finder_nodes()), name)
    probe('act', finder_pid(), dotted(row.path), 'select', 'AXRow', name)
    time.sleep(0.3)
    again = ui.find_row(ui.list_rows(finder_nodes()), name)
    if again.point != row.point:
        raise ui.Refused(f'row {name!r} moved from {row.point} to {again.point} while selecting; retry')
    with menu_boundary(row.point) as opened:
        right_click(row.point, option)
        opened.point = wait_menu(row.point)
    return row, opened.point


class MenuSession:
    """`axprobe menu-session X Y DEPTH OWNER`: one axprobe process finds the menu under the point, prints its owner pid
    and its dump, and waits for one decision. The press it is then told to make is checked by that same process
    against the menu it holds (owner pid, every top-level title) right before AXPress, so a menu closed or replaced
    after the guard is refused (65), never pressed. `abort` cancels the held menu (AXCancel) only when OWNER (Finder)
    owns it; `abandon` ends the session touching nothing (a menu of another process is never ours to close)."""

    def __init__(self, point, owner):
        self.process = spawn([probe_binary(), 'menu-session', point[0], point[1], '3', owner])
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
            self.finish({'abort': True})  # axprobe cancels it only if Finder owns it
            raise ui.Environment('axprobe menu-session printed no owner pid')
        self.pid = header['session']['pid']
        self.done = False
        self.nodes = ui.parse_dump(''.join(lines))

    def finish(self, request):
        self.done = True
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

    def abandon(self):
        self.finish({'abandon': True})

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


def prepare_targets(targets):
    """Select the targets through AppleScript and read the selection back (no menu is open yet), then verify through
    AX (finderui.target_row) twice: the click point must not move in between. Returns (row to click, selected)."""
    focus_finder()
    select(targets)
    row, selected = ui.target_row(finder_nodes(), targets)
    again, _ = ui.target_row(finder_nodes(), targets)
    if (again.point, again.url) != (row.point, row.url):
        raise ui.Refused(f'row {row.name!r} moved from {row.point} to {again.point} before the click; retry')
    return row.point, selected


def prepare_background(folder):
    """Deselect all (AppleScript, read back), then from AX: the front folder must be `folder` (finderui.front_folder)
    and the click point is the empty list below the rows. Returns (point to click, front folder)."""
    focus_finder()
    deselect_all()
    nodes = finder_nodes()
    front = ui.front_folder(nodes)
    if ui.clean_path(front) != ui.clean_path(folder):
        raise ui.Refused(f'the front Finder window lists {front!r}, not {ui.clean_path(folder)!r}: nothing clicked')
    return ui.background_point(nodes), front


def still_bound(click, targets, background):
    """finderui.bound_menu on the front Finder window read through AX while the menu is open (Finder answers no
    AppleScript then). If that read cannot be made, or disagrees: Refused, nothing pressed."""
    try:
        nodes = finder_nodes()
    except ui.Environment as error:
        raise ui.Refused(f'cannot read the front Finder window through AX with the menu open ({error}): the menu '
                         'cannot be tied to the targets, nothing pressed') from error
    try:
        return ui.bound_menu(nodes, click, targets, background)
    except ui.Refused as error:
        raise ui.Refused(f'read again with the menu open: {error}; the menu may act on other items than were '
                         'verified before the click, nothing pressed') from error


def choose(title, group, sub=None, targets=(), background=None, option=False):
    """`ui.sh choose`, ONE process from selection to press, with no Finder AppleScript once the menu can be open:
    select and verify (prepare_targets / prepare_background), right-click, wait for the menu, then inside one axprobe
    menu session: Finder owns the menu, finderui.check_guard against the evidence read before the click, the item in
    RClick's group, then the front window read AGAIN through AX with the menu open must still hold exactly the
    verified targets (still_bound: the title alone proves only a basename or a count); the same axprobe process
    re-checks the held menu and presses. From the right-click on, any
    refusal or failure (an AX or transport error, a session that cannot start or end) presses nothing and closes the
    menu (menu_boundary: AXCancel, Esc fallback); another process's menu is left open. Returns (guard reason, item)."""
    if background:
        point, front = prepare_background(background)
        selected = []
    else:
        point, selected = prepare_targets(targets)
        front = None
    with menu_boundary(point) as opened:
        right_click(point, option)
        opened.point = menu_point = wait_menu(point)
        owner = finder_pid()
        opened.session = session = MenuSession(menu_point, owner)
        if session.pid != owner:  # not Finder's menu: never ours to cancel, so it is left exactly as it is
            opened.foreign = True
            raise ui.Refused(f'the menu at {menu_point[0]},{menu_point[1]} belongs to pid {session.pid}, not Finder '
                             f'({owner}): nothing pressed, that menu left open')
        items = ui.menu_items(session.nodes)
        reason = ui.check_guard(targets, selected, items, background=background, front=front)
        item, sub_path = ui.find_group_item(items, title, sub, group)
        bound = still_bound(point, targets, background)
        session.press(item, sub_path, sub)
    return f'{reason}; {bound}', item


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


def executable_of(pid):
    """The executable the kernel ran for `pid` (proc_pidpath), or None when no such process. Not `ps -o comm=`, which
    prints the process's own argv[0] (`osascript` for a PATH lookup, or any path it chose)."""
    buffer = ctypes.create_string_buffer(4096)
    try:
        length = ctypes.CDLL('/usr/lib/libproc.dylib').proc_pidpath(int(pid), buffer, ctypes.sizeof(buffer))
    except OSError as error:
        raise ui.Environment(f'cannot load libproc to resolve pid {pid}: {error}') from error
    return os.fsdecode(buffer.value) if length > 0 else None


def allowed_process(pid, extra_pids=()):
    """finderui.allowed_process on pid's resolved executable; the RClick pid is this run's $RUN_DIR/rclick.pid."""
    executable = executable_of(pid)
    table = {pid: executable} if executable else {}
    rclick_pid = None
    if os.environ.get('RUN_DIR'):
        try:
            rclick_pid = int((Path(os.environ['RUN_DIR']) / 'rclick.pid').read_text().strip())
        except (OSError, ValueError):
            rclick_pid = None
    return ui.allowed_process(pid, table, rclick_pid, extra_pids)


def press_button(pid, title, window_text=None, extra_pids=()):
    require_clean_input('nothing pressed')
    allowed_process(pid, extra_pids)
    path = ui.find_button(app_nodes(pid), title, window_text)
    probe('act', pid, dotted(path), 'press', 'AXButton', title)


def grant(pid, folder, button='Grant Access', extra_pids=()):
    """finderui.panel_plan from full paths, select the target (row mode: an AXRow in list view, the entry's AXGroup
    in column view), re-read the panel and require finderui.panel_ready (list view: the target the only selected
    row; column view: the browser now shows the target; current mode: unchanged), press, wait for it to close."""
    require_clean_input('nothing selected or pressed')
    allowed_process(pid, extra_pids)
    plan = ui.panel_plan(app_nodes(pid, 20), folder, button)
    if plan.mode == 'row':
        probe('act', pid, dotted(plan.row_path), 'select', plan.row_role, ui.basename(folder))
        time.sleep(0.4)
    ui.panel_ready(app_nodes(pid, 20), folder, button, plan)
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
    # A stuck modifier refuses choose and open-menu before anything is selected; right_click checks again before the
    # click, and press_button and grant check inside (calibration calls them directly).
    if args.command in CLICKING:
        require_clean_input('nothing selected, clicked or pressed')
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
        print(close_menu(args.point))
    elif args.command == 'menu':
        print_menu(read_menu(args.point), args.also, args.group)
    elif args.command == 'choose':
        reason, item = choose(args.title, args.group, args.sub, args.target, args.background, args.option)
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


class Terminated(BaseException):
    """SIGTERM, raised in the main thread so every `finally` (pressing: modifier release; menu_boundary: menu close;
    the calibration teardown) runs before the process ends, as it does for Ctrl-C."""


def terminated(signum, frame):
    raise Terminated(f'signal {signum}')


def main(argv):
    if argv[:1] == ['help'] or any(arg in ('-h', '--help') for arg in argv):
        print(ui.USAGE_TEXT)
        return ui.OK
    previous = signal.signal(signal.SIGTERM, terminated)
    try:
        return dispatch(argv)
    finally:
        signal.signal(signal.SIGTERM, previous)


def dispatch(argv):
    try:
        return command(ui.parse_args(argv))
    except KeyboardInterrupt:
        print('INTERRUPTED: Ctrl-C (pressed modifiers released, an open menu closed)', file=sys.stderr)
        return 130
    except Terminated:
        print('INTERRUPTED: SIGTERM (pressed modifiers released, an open menu closed)', file=sys.stderr)
        return 143
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
