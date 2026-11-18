#!/usr/bin/env python3
"""Side effects of the Finder UI driver (ui.sh, calibrate.sh): run axprobe, AppleScript, the synthetic right-click
and Esc. Every decision (which row, which item, guard, panel plan, verdicts) is made by finderui.py from dumps.

Never changes a system or privacy setting, never runs pluginkit, never quits a process it did not start, never
types through the keyboard layer (Esc is a key code, not text). Acting commands refuse unless the shared GUI lock
is held by an rclick run (gui-lock.sh).
"""
import hashlib
import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import finderui as ui  # noqa: E402

ACTING = ('select', 'open-menu', 'guard', 'choose', 'press-button', 'grant', 'calibrate')
SELECT_SCRIPT = '''on run argv
  set chosen to {}
  repeat with p in argv
    set end of chosen to ((POSIX file (p as text)) as alias)
  end repeat
  tell application "Finder" to select chosen
end run'''
SELECTION_SCRIPT = '''tell application "Finder" to set chosen to selection as alias list
set out to ""
repeat with a in chosen
  set out to out & POSIX path of a & linefeed
end repeat
return out'''
FRONT_SCRIPT = 'tell application "Finder" to return POSIX path of (target of front Finder window as alias)'


def run(argv, timeout=20):
    try:
        return subprocess.run([str(a) for a in argv], capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError as error:
        raise ui.Environment(f'{argv[0]} not found') from error
    except subprocess.TimeoutExpired as error:
        raise ui.Environment(f'{Path(str(argv[0])).name} timed out after {timeout} s') from error


def probe_binary():
    """axprobe compiled once per source hash into $TMPDIR (never into the repo)."""
    source = HERE / 'axprobe.swift'
    digest = hashlib.sha256(source.read_bytes()).hexdigest()[:16]
    binary = Path(os.environ.get('TMPDIR') or '/tmp') / f'rclick-axprobe-{digest}' / 'axprobe'
    if binary.is_file():
        return binary
    binary.parent.mkdir(parents=True, exist_ok=True)
    partial = binary.with_name(f'axprobe.{os.getpid()}')
    result = run(['xcrun', 'swiftc', '-O', '-o', partial, source], timeout=300)
    if result.returncode != 0:
        raise ui.Environment('cannot compile axprobe.swift: ' + (result.stderr.strip().splitlines() or ['?'])[-1])
    partial.replace(binary)
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
    frontmost, so it never lands in another app (the terminal running the tester, an RClick dialog)."""
    run(['osascript', '-e', ESCAPE_SCRIPT], timeout=10)


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
        front = osascript(FRONT_SCRIPT).strip() if background else None
        return items, ui.check_guard(targets, selection(), items, background=background, front=front)
    except ui.Refused:
        escape()
        raise


def print_menu(items, also=()):
    for item in items:
        x, y = item.point or ('?', '?')
        print(f'{item.index}|{item.title}|{str(item.enabled).lower()}|{x},{y}|{len(item.sub)}')
    print('compress: ' + (' / '.join(ui.compress_titles(items)) or '(none)'))
    group = ui.rclick_group(items, also)
    print('rclick-group: ' + (', '.join(item.title for item in group) or '(none)'))
    for item in group:
        if item.sub:
            print(f'  {item.title}: ' + ', '.join(name for name, _ in item.sub))


def press_button(pid, title, window_text=None):
    path = ui.find_button(app_nodes(pid), title, window_text)
    probe('act', pid, dotted(path), 'press', 'AXButton', title)


def grant(pid, folder, button='Grant Access'):
    plan = ui.panel_plan(app_nodes(pid, 20), folder, button)
    if plan.row_path is not None:
        probe('act', pid, dotted(plan.row_path), 'select', 'AXRow', ui.basename(folder))
        time.sleep(0.4)
        again = ui.panel_plan(app_nodes(pid, 20), folder, button)
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
    if args.command == 'calibrate':
        import calibration
        return calibration.calibrate(Path(args.run_dir), args.dry_run)
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
    elif args.command == 'open-menu':
        row, point = open_menu(args.name, args.option)
        print(f'row: {row.index} {row.name} {row.point[0]},{row.point[1]}')
        print(f'menu-point {point[0]},{point[1]}')
    elif args.command == 'menu':
        print_menu(read_menu(args.point), args.also)
    elif args.command == 'guard':
        _, reason = guard(args.point, args.targets, args.background)
        print('GUARD PASS — ' + reason)
    elif args.command == 'choose':
        items, reason = guard(args.point, args.target, args.background)
        try:
            item, sub = ui.find_group_item(items, args.title, args.sub, args.also)
        except ui.Refused:
            escape()
            raise
        print('GUARD PASS — ' + reason)
        probe('menu-press', args.point[0], args.point[1], dotted(sub or item.path), item.title,
              *([args.sub] if sub else []))
        print('chose: ' + item.title + (f' → {args.sub}' if sub else ''))
    elif args.command == 'dialog':
        print(ui.format_dialogs(ui.dialog_windows(app_nodes(args.pid))))
    elif args.command == 'press-button':
        press_button(args.pid, args.title, args.window_text)
        print(f'pressed: {args.title}')
    elif args.command == 'grant':
        plan = grant(args.pid, args.folder, args.button)
        print(f'granted: {ui.clean_path(args.folder)} ({plan.mode} mode{"; " + plan.note if plan.note else ""})')
    return ui.OK


def main(argv):
    if argv[:1] in (['-h'], ['--help'], ['help']):
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
