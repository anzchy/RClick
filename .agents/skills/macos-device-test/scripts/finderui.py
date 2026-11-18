"""Pure logic of the Finder UI driver: no subprocess, no AX, no clock.

The AX side (axprobe.swift, driven by finderdrive.py) prints one JSON object per accessibility element:
    {"path": [i, j, ...], "role": "AXRow", "subrole": "", "title": "", "value": "alpha.txt" | null,
     "desc": "", "enabled": true | null, "selected": false | null, "frame": [x, y, w, h] | null,
     "url": "/full/path" | null}   (url: the element's AXURL, when it has one)
`path` is the child-index path from the dump root (a window index first for app dumps, [] for the menu root of a
menu dump). Everything here decides from such dumps, so the unit tests replay recorded or reconstructed dumps
(fixtures/) and never touch the desktop.
"""
import argparse
import json
import re
import unicodedata

OK, USAGE, REFUSED, ENVIRONMENT = 0, 64, 65, 70


class Refused(Exception):
    """The target is ambiguous, missing or does not match: act on nothing (exit 65)."""


class Usage(Exception):
    """Bad arguments (exit 64)."""


class Environment(Exception):
    """A missing grant, tool or process (exit 70)."""


LIST_CONTAINERS = ('AXOutline', 'AXTable', 'AXList', 'AXBrowser')
NAME_ROLES = ('AXTextField', 'AXStaticText')


def nfc(text):
    return unicodedata.normalize('NFC', text or '')


def parse_dump(text):
    """One element per non-empty line; a malformed line fails closed (a half-read dump must not drive a click)."""
    nodes = []
    for number, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        try:
            node = json.loads(line)
        except json.JSONDecodeError as error:
            raise Environment(f'AX dump line {number} is not JSON: {error}') from error
        if not isinstance(node, dict) or not isinstance(node.get('path'), list) or not node.get('role'):
            raise Environment(f'AX dump line {number} lacks path or role')
        node['path'] = tuple(node['path'])
        nodes.append(node)
    return nodes


def label(node):
    """The text an element shows: its title, else a string value, else its description."""
    value = node.get('value')
    for text in (node.get('title'), value if isinstance(value, str) else None, node.get('desc')):
        if text:
            return text
    return ''


def ancestors(node, by_path):
    path = node['path']
    for cut in range(len(path) - 1, -1, -1):
        parent = by_path.get(path[:cut])
        if parent is not None:
            yield parent


def descendants(node, nodes):
    path = node['path']
    return [other for other in nodes if len(other['path']) > len(path) and other['path'][:len(path)] == path]


def in_sidebar(node, by_path):
    """True when the nearest list container above the element is a sidebar (Finder's and the open panel's)."""
    for parent in ancestors(node, by_path):
        if parent['role'] in LIST_CONTAINERS:
            return nfc(parent.get('desc')).lower() == 'sidebar' or parent.get('subrole') == 'AXSidebar'
    return False


def centre(frame):
    x, y, w, h = frame
    return round(x + w / 2), round(y + h / 2)


class Row:
    def __init__(self, index, name, path, frame, point, visible):
        self.index, self.name, self.path, self.frame, self.point, self.visible = index, name, path, frame, point, visible

    def __repr__(self):
        return f'Row({self.index}, {self.name!r}, point={self.point}, visible={self.visible})'


def list_rows(nodes):
    """File-list rows of a Finder window (or an open panel) in DISPLAY order: sorted by their on-screen y, then x.

    The AX child order and AppleScript's `items` order are not the display order (i5-device-20261117c); only the
    frames are. A row's name is its first name-bearing text (the Name column); its click point is the centre of
    that text, so a right-click lands on the name, not on a blank column. A row outside its scroll area is listed
    with visible=False and is never a click target.
    """
    by_path = {node['path']: node for node in nodes}
    found = []
    for node in nodes:
        if node['role'] != 'AXRow' or not node.get('frame') or in_sidebar(node, by_path):
            continue
        texts = [d for d in descendants(node, nodes) if d['role'] in NAME_ROLES and label(d)]
        if not texts:
            continue
        texts.sort(key=lambda d: d['path'])
        name_node = texts[0]
        frame = name_node.get('frame') or node['frame']
        point = centre(frame)
        area = next((p for p in ancestors(node, by_path) if p['role'] == 'AXScrollArea' and p.get('frame')), None)
        visible = area is None or contains(area['frame'], point)
        found.append((node['frame'][1], node['frame'][0], nfc(label(name_node)), node['path'], node['frame'], point,
                      visible))
    found.sort(key=lambda item: (item[0], item[1]))
    return [Row(i, name, path, frame, point, visible)
            for i, (_, _, name, path, frame, point, visible) in enumerate(found, 1)]


def contains(frame, point):
    x, y, w, h = frame
    return x <= point[0] <= x + w and y <= point[1] <= y + h


def find_row(rows, name):
    """The one visible row whose name is exactly `name` (NFC-normalised, case and spaces significant), else Refused."""
    wanted = nfc(name)
    matches = [row for row in rows if row.name == wanted]
    if not matches:
        raise Refused(f'no row named {name!r} in the front Finder window (list view?); rows: '
                      + ', '.join(repr(row.name) for row in rows[:12]))
    if len(matches) > 1:
        raise Refused(f'{len(matches)} rows named {name!r} (display rows '
                      + ', '.join(str(row.index) for row in matches) + '); collapse folders or rename the fixture')
    row = matches[0]
    if not row.visible:
        raise Refused(f'row {name!r} is not visible in its scroll area; scroll it into view or enlarge the window')
    return row


# English titles the extension can put at the top level of its section (FinderSyncExt.swift, RCAction.all,
# the default Open With app). `%@ (skip confirmation)` is matched by its base title. Open With apps and common
# folders the user added have their own names: pass them with --also.
RCLICK_TITLES = (
    'Copy Path', 'Copy File Name', 'Delete Direct', 'Hide', 'Unhide', 'AirDrop', 'Terminal',
    'Actions', 'Open With', 'New File', 'Common Dirs',
    'RClick is not running', 'Restart RClick to restore the menu', 'RClick (loading...)',
)
SKIP_SUFFIX = ' (skip confirmation)'
COMPRESS_ONE = re.compile(r'Compress “(.+)”')
COMPRESS_MANY = re.compile(r'Compress (\d+) Items')


class MenuItem:
    def __init__(self, index, title, enabled, point, path, sub):
        self.index, self.title, self.enabled, self.point, self.path, self.sub = index, title, enabled, point, path, sub

    def __repr__(self):
        return f'MenuItem({self.index}, {self.title!r}, enabled={self.enabled}, point={self.point})'


def menu_items(nodes):
    """Top-level items of a menu dump (paths relative to the menu: [i] item, [i, 0] its submenu, [i, 0, j] a
    submenu item), in AX order, which for menus is the on-screen order (alternates share a position)."""
    items = []
    for node in nodes:
        path = node['path']
        if len(path) != 1 or node['role'] != 'AXMenuItem':
            continue
        sub = [(nfc(label(child)), child['path']) for child in nodes
               if len(child['path']) == 3 and child['path'][0] == path[0] and child['role'] == 'AXMenuItem']
        point = centre(node['frame']) if node.get('frame') else None
        items.append(MenuItem(path[0], nfc(node.get('title')), node.get('enabled') is not False, point, path, sub))
    return items


def compress_titles(items):
    """Distinct titles of Finder's own Compress item (`Compress “name”`, `Compress N Items`)."""
    titles = {item.title for item in items if COMPRESS_ONE.fullmatch(item.title) or COMPRESS_MANY.fullmatch(item.title)}
    return sorted(titles)


def base_title(title):
    return title[:-len(SKIP_SUFFIX)] if title.endswith(SKIP_SUFFIX) else title


def extension_area(items):
    """Items after the LAST `Quick Actions` (Finder lists extension items there, no separator between extensions,
    i22-device-20261116e), or the whole menu when there is none."""
    quick = [i for i, item in enumerate(items) if item.title == 'Quick Actions']
    return items[quick[-1] + 1:] if quick else items


def rclick_group(items, also=(), expected=None):
    """RClick's section. With `expected` (RClick's configured top-level titles in order, `--group`): positive
    evidence, the ONE run of exactly those titles in the extension area (a skip-confirmation title matches its base
    title); none or two such runs are Refused. Without it, a heuristic for reading only (`ui.sh menu`): known RClick
    titles from the start of the extension area up to the first unknown or repeated title; it cannot tell RClick's
    items from another extension's same-titled ones and is never used to choose."""
    area = extension_area(items)
    if expected is not None:
        want = [nfc(title) for title in expected]
        runs = [area[i:i + len(want)] for i in range(len(area) - len(want) + 1)
                if [base_title(item.title) for item in area[i:i + len(want)]] == want]
        if not runs:
            raise Refused(f"RClick's group {want} not found after Quick Actions: another configuration, the "
                          'extension not loaded, or a localized menu')
        if len(runs) > 1:
            raise Refused(f"{len(runs)} runs of RClick's group {want} in the menu: ambiguous, nothing chosen")
        return runs[0]
    known = set(RCLICK_TITLES) | {nfc(title) for title in also}
    start = 0 if len(area) < len(items) else next(
        (i for i, item in enumerate(area) if base_title(item.title) in known), len(area))
    group, seen = [], set()
    for item in area[start:]:
        if not item.title:
            if group:
                break
            continue
        title = base_title(item.title)
        if title not in known or title in seen:
            break
        seen.add(title)
        group.append(item)
    return group


def clean_path(path):
    """A POSIX path for EXACT comparison: whitespace and every other character are significant; only one trailing
    `/` of a folder is dropped. A path holding a line break is Refused: it cannot be read back exactly through
    AppleScript's line-based output. Unicode decision: both sides are compared in NFC. APFS and HFS+ look names up
    normalization-insensitively, so one folder cannot hold two names that differ only in normalization: NFC
    equality still names exactly one file, while case stays significant (a case-only mismatch is refused)."""
    if '\n' in path or '\r' in path:
        raise Refused(f'{path!r} contains a line break: it cannot be read back exactly; rename it')
    path = nfc(path)
    return path[:-1] if len(path) > 1 and path.endswith('/') else path


def one_line(text):
    """osascript's single-line answer without its line terminator (exactly one `\\n`; nothing else is stripped)."""
    if not text.endswith('\n') or '\n' in text[:-1]:
        raise Refused(f'expected one line from AppleScript, got {text!r}')
    return text[:-1]


def parse_selection(text):
    """Finder's selection as finderdrive's SELECTION_SCRIPT prints it through osascript: a count line, one POSIX path
    per line (a folder ends with `/`, dropped), then osascript's own terminator. Only those line terminators are
    removed. A count that does not match the lines means a path holds a line break: Refused, never guessed."""
    lines = text.split('\n')
    if len(lines) < 3 or lines[-2:] != ['', ''] or not lines[0].isdecimal():
        raise Environment(f'selection read-back is not `count, paths, terminator`: {text[:80]!r}')
    paths = lines[1:-2]
    if len(paths) != int(lines[0]):
        raise Refused(f'Finder reports {lines[0]} selected items but {len(paths)} lines: a selected path contains '
                      'a line break and cannot be read back exactly')
    return [clean_path(path) for path in paths]


def basename(path):
    return clean_path(path).rsplit('/', 1)[-1]


def check_guard(targets, selection, items, background=None, front=None):
    """The pre-action guard. Before any RClick item is chosen, the open menu must be the menu of the intended
    target: Finder's own `Compress “<name>”` (`Compress N Items`) title names it, and Finder's selection read back
    through AppleScript is exactly the target set. For a window-background menu: nothing selected, no Compress
    item, and the front Finder window shows `background`. Returns what matched; raises Refused otherwise (the
    caller closes the menu and acts on nothing)."""
    selected = sorted(clean_path(path) for path in selection)
    titles = compress_titles(items)
    if background is not None:
        if selected:
            raise Refused(f'background menu expected, but the Finder selection is {selected}')
        if titles:
            raise Refused(f'background menu expected, but the menu has {titles[0]!r} (an item menu)')
        if clean_path(front or '') != clean_path(background):
            raise Refused(f'the front Finder window shows {front!r}, not {background!r}')
        return f'background menu of {clean_path(background)}'
    wanted = sorted(clean_path(path) for path in targets)
    if not wanted:
        raise Refused('no target given')
    if selected != wanted:
        raise Refused(f'Finder selection {selected} is not the target {wanted}')
    expected = f'Compress “{basename(wanted[0])}”' if len(wanted) == 1 else f'Compress {len(wanted)} Items'
    if not titles:
        raise Refused(f'no Finder Compress item in the menu (expected {expected!r}; a background or sidebar menu, '
                      'or a system language other than English)')
    if titles != [expected]:
        raise Refused(f'menu shows {" / ".join(titles)}, expected {expected!r}: the menu belongs to another item')
    return f'{expected} and selection {wanted}'


def find_group_item(items, title, sub=None, group=()):
    """The enabled item titled exactly `title` inside RClick's group, identified by the expected titles `group`
    (positive evidence, see rclick_group), and its submenu item `sub`; else Refused. Returns (item, submenu item path
    or None)."""
    if not group:
        raise Usage("choosing needs RClick's expected group (--group TITLE, repeated in menu order)")
    group = rclick_group(items, expected=group)
    matches = [item for item in group if item.title == nfc(title)]
    if not matches:
        raise Refused(f"{title!r} is not in RClick's group ({', '.join(item.title for item in group)})")
    item = matches[0]
    if not item.enabled:
        raise Refused(f'{title!r} is disabled in the menu')
    if sub is None:
        return item, None
    paths = [path for name, path in item.sub if name == nfc(sub)]
    if len(paths) != 1:
        raise Refused(f'no submenu item {sub!r} under {title!r} (has: {", ".join(name for name, _ in item.sub)})'
                      if not paths else f'{len(paths)} submenu items {sub!r} under {title!r}')
    return item, paths[0]


class Window:
    def __init__(self, index, title, kind, texts, buttons):
        self.index, self.title, self.kind, self.texts, self.buttons = index, title, kind, texts, buttons


def dialog_windows(nodes):
    """Every window of an app dump with its static texts and its buttons ((title, path)), in AX order. An NSAlert
    is a window of the process that raised it: the RClick app for Delete Direct and the folder panel,
    FinderSyncExt for "RClick is not running" / "RClick did not respond"."""
    windows = []
    for node in nodes:
        if len(node['path']) != 1 or node['role'] != 'AXWindow':
            continue
        inside = descendants(node, nodes)
        texts = [nfc(label(d)) for d in inside if d['role'] == 'AXStaticText' and label(d)]
        buttons = [(nfc(label(d)), d['path']) for d in inside if d['role'] == 'AXButton' and label(d)]
        kind = node.get('subrole') or node.get('desc') or ''
        windows.append(Window(node['path'][0], nfc(node.get('title')), kind, texts, buttons))
    return windows


def format_dialogs(windows):
    lines = []
    for window in windows:
        lines.append(f'window {window.index} title={window.title!r} kind={window.kind}')
        lines += [f'  text: {text}' for text in window.texts]
        lines += [f'  button: {title}' for title, _ in window.buttons]
    return '\n'.join(lines)


def find_button(nodes, title, window_text=None):
    """Path of the one button titled exactly `title`, in the one window that has it (and whose texts contain
    `window_text`, when given). Ambiguity is refused, never resolved by order."""
    wanted = nfc(title)
    candidates = []
    for window in dialog_windows(nodes):
        if window_text is not None and not any(nfc(window_text) in text for text in window.texts):
            continue
        paths = [path for name, path in window.buttons if name == wanted]
        if len(paths) > 1:
            raise Refused(f'window {window.index} has {len(paths)} buttons titled {title!r}')
        if paths:
            candidates.append(paths[0])
    if not candidates:
        where = f' (among windows with text {window_text!r})' if window_text is not None else ''
        raise Refused(f'no window has a button titled {title!r}{where}')
    if len(candidates) > 1:
        raise Refused(f'{len(candidates)} windows have a button titled {title!r}; pass --window-text')
    return candidates[0]


class PanelPlan:
    def __init__(self, mode, window, row_path, button_path, location, note):
        self.mode, self.window, self.row_path, self.button_path = mode, window, row_path, button_path
        self.location, self.note = location, note


def element_url(node, nodes):
    """The AXURL path (axprobe `url`) of a row: the row's own, else its first descendant's."""
    if node.get('url'):
        return node['url']
    return next((d['url'] for d in sorted(descendants(node, nodes), key=lambda d: d['path']) if d.get('url')), None)


def panel_plan(nodes, folder, button='Grant Access'):
    """How to grant `folder` in an open folder panel (NSOpenPanel) without typing (panel-choose.sh failed under a
    pinyin IME, i22-device-20261116e), from FULL paths only.

    The panel's location is established from the AXURL of its file-list rows (never the sidebar): the folder of the
    first row in display order, which every other row must lie under; a location pop-up, when present, must name
    that folder. No row URL: Refused (the location cannot be proven). mode 'row': a row's full path is `folder`:
    select it, then press. mode 'current': `folder` is the location itself and no row is selected (the panel would
    return a selected row, not the folder it shows): press. Anything else is Refused."""
    if not folder.startswith('/'):
        raise Usage(f'folder must be an absolute path: {folder!r}')
    target = clean_path(folder)
    windows = [w for w in dialog_windows(nodes) if any(title == nfc(button) for title, _ in w.buttons)]
    if len(windows) != 1:
        raise Refused(f'{len(windows)} windows have a button titled {button!r}; expected one open panel')
    window = windows[0]
    button_path = next(path for title, path in window.buttons if title == nfc(button))
    inside = [n for n in nodes if n['path'][:1] == (window.index,)]
    by_path = {n['path']: n for n in inside}
    rows = list_rows(inside)
    urls = [element_url(by_path[row.path], inside) for row in rows]
    if not rows or None in urls:
        raise Refused("cannot establish the panel's full location: its file-list rows expose no AXURL (grant by "
                      'hand and record it under Script problems)')
    urls = [clean_path(url) for url in urls]
    location = urls[0].rsplit('/', 1)[0] or '/'
    if any(not url.startswith(location.rstrip('/') + '/') for url in urls):
        raise Refused(f'the panel lists rows outside {location!r}; collapse expanded folders')
    shown = sorted({nfc(n['value']) for n in inside if n['role'] == 'AXPopUpButton' and isinstance(n.get('value'), str)
                    and n['value']})
    if shown and basename(location) not in shown:
        raise Refused(f'the location pop-up shows {shown[0]!r} but the rows are in {location!r}')
    selected = [row for row in rows if by_path[row.path].get('selected') is True]
    matches = [row for row, url in zip(rows, urls) if url == target]
    if len(matches) > 1:
        raise Refused(f'{len(matches)} rows have the path {target!r}')
    if matches:
        if not matches[0].visible:
            raise Refused(f'row {matches[0].name!r} is not visible in the panel')
        return PanelPlan('row', window.index, matches[0].path, button_path, location,
                         'verified: full path from AXURL, the only selected row')
    if target == location:
        if selected:
            raise Refused(f'row {selected[0].name!r} is selected: the panel would return it, not {target!r}')
        return PanelPlan('current', window.index, None, button_path, location,
                         'verified: full location from AXURL, no row selected')
    raise Refused(f'panel shows {basename(location)!r} ({location!r}): no row is {target!r} and it is not the shown '
                  'folder')


def panel_ready(nodes, folder, button='Grant Access'):
    """The plan again, right before the button is pressed: in row mode the target row must now be the ONE selected
    row, in current mode no row may be selected. Refused otherwise (nothing pressed)."""
    plan = panel_plan(nodes, folder, button)
    if plan.mode == 'row':
        inside = [n for n in nodes if n['path'][:1] == (plan.window,)]
        by_path = {n['path']: n for n in inside}
        selected = [row.path for row in list_rows(inside) if by_path[row.path].get('selected') is True]
        if selected != [plan.row_path]:
            raise Refused(f'{len(selected)} rows selected, expected only {folder!r}: nothing pressed')
    return plan


def parse_process_table(text):
    """{pid: executable path} from `ps -o pid=,comm=` lines (macOS prints the full executable path as comm)."""
    table = {}
    for line in text.split('\n'):
        pid, _, executable = line.strip().partition(' ')
        if pid.isdecimal() and executable.strip():
            table[int(pid)] = executable.strip()
    return table


FINDER_EXECUTABLE = '/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder'
RCLICK_EXECUTABLE = '/RClick.app/Contents/MacOS/RClick'
EXTENSION_EXECUTABLE = '/RClick.app/Contents/PlugIns/FinderSyncExt.appex/Contents/MacOS/FinderSyncExt'


def allowed_process(pid, table, rclick_pid=None, extra_pids=()):
    """The process `press-button`/`grant` may press in, by its executable: Finder, an RClick build's FinderSyncExt,
    the RClick process of this run (`rclick_pid`, from $RUN_DIR/rclick.pid, and an RClick executable), or an
    osascript the calibration started (`extra_pids`). Anything else, above all a system or privacy prompt (TCC,
    UserNotificationCenter, System Settings, the open-panel service), is Refused."""
    executable = table.get(pid)
    if executable is None:
        raise Refused(f'pid {pid} is not running')
    if executable == FINDER_EXECUTABLE:
        return 'Finder'
    if executable.endswith(EXTENSION_EXECUTABLE):
        return 'FinderSyncExt'
    if rclick_pid is not None and pid == rclick_pid and executable.endswith(RCLICK_EXECUTABLE):
        return 'RClick'
    if pid in extra_pids and executable == '/usr/bin/osascript':
        return 'calibration osascript'
    raise Refused(f'pid {pid} is {executable}: press-button and grant act only in RClick ($RUN_DIR/rclick.pid), '
                  "RClick's FinderSyncExt, Finder or the calibration's own osascript, never in a system prompt")


USAGE_TEXT = """usage: ui.sh COMMAND ...   (exit 0 ok, 64 usage, 65 refused: target missing/ambiguous/mismatched, 70 environment)
  rows                                   rows of the front Finder window in display order: index, name, centre x y
  select PATH...                         select these items through AppleScript, read the selection back, compare
  selection                              print Finder's selection (POSIX paths, read back through AppleScript)
  open-menu NAME [--option]              AXSelected on the one row named NAME, right-click its AX centre; prints
                                         `menu-point X,Y` (pass it to menu/guard/choose)
  menu X,Y [--also TITLE]... [--group TITLE]...
                                         list the open menu (element at position): Compress title, RClick group
                                         (heuristic; with --group: where the expected group is, or refused)
  guard X,Y (TARGET... | --background DIR)
                                         refuse (close the menu, exit 65) unless the menu and the selection are the target's
  choose X,Y TITLE [--sub ITEM] --group TITLE... (--target PATH... | --background DIR)
                                         guard, then AXPress TITLE (and ITEM in its submenu) inside RClick's group,
                                         the one run of exactly the --group titles (RClick's configured items in order)
  dialog PID                             texts and buttons of every window of PID (alerts, confirmations, panels)
  press-button PID TITLE [--window-text TEXT]
                                         AXPress the one button titled TITLE (in the window containing TEXT)
  grant PID FOLDER [--button TITLE]      in PID's open folder panel select FOLDER's row (or the shown folder) and
                                         press TITLE (default `Grant Access`); no typing, any input source
  lock-check                             exit 0 only if the GUI lock is this run's (axprobe runs it before acting)
  calibrate RUN_DIR --group TITLE... [--dry-run]
                                         the calibration run (calibrate.sh)"""


class ArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise Usage(message)


def point_arg(text):
    match = re.fullmatch(r'(-?\d+),(-?\d+)', text)
    if not match:
        raise argparse.ArgumentTypeError(f'expected X,Y in whole screen points, got {text!r}')
    return int(match.group(1)), int(match.group(2))


def absolute(text):
    if not text.startswith('/'):
        raise argparse.ArgumentTypeError(f'expected an absolute path, got {text!r}')
    return text


def pid_arg(text):
    if not text.isdigit() or int(text) <= 0:
        raise argparse.ArgumentTypeError(f'expected a numeric PID, got {text!r}')
    return int(text)


def parse_args(argv):
    """Parse a ui.sh command line; every error is Usage (exit 64), before any AX or AppleScript call."""
    parser = ArgumentParser(prog='ui.sh', usage=USAGE_TEXT, add_help=False)
    commands = parser.add_subparsers(dest='command', parser_class=ArgumentParser)
    commands.add_parser('rows')
    commands.add_parser('select').add_argument('paths', nargs='+', type=absolute)
    commands.add_parser('selection')
    command = commands.add_parser('open-menu')
    command.add_argument('name')
    command.add_argument('--option', action='store_true')
    command = commands.add_parser('menu')
    command.add_argument('point', type=point_arg)
    command.add_argument('--also', action='append', default=[])
    command.add_argument('--group', action='append', default=[])
    command = commands.add_parser('guard')
    command.add_argument('point', type=point_arg)
    command.add_argument('targets', nargs='*', type=absolute)
    command.add_argument('--background', type=absolute)
    command = commands.add_parser('choose')
    command.add_argument('point', type=point_arg)
    command.add_argument('title')
    command.add_argument('--sub')
    command.add_argument('--group', action='append', default=[])
    command.add_argument('--target', action='append', default=[], type=absolute)
    command.add_argument('--background', type=absolute)
    commands.add_parser('dialog').add_argument('pid', type=pid_arg)
    command = commands.add_parser('press-button')
    command.add_argument('pid', type=pid_arg)
    command.add_argument('title')
    command.add_argument('--window-text')
    command = commands.add_parser('grant')
    command.add_argument('pid', type=pid_arg)
    command.add_argument('folder', type=absolute)
    command.add_argument('--button', default='Grant Access')
    commands.add_parser('lock-check')
    command = commands.add_parser('calibrate')
    command.add_argument('run_dir', type=absolute)
    command.add_argument('--dry-run', action='store_true')
    command.add_argument('--group', action='append', default=[])
    args = parser.parse_args(argv)
    if args.command is None:
        raise Usage('a command is required')
    if args.command == 'guard' and bool(args.targets) == bool(args.background):
        raise Usage('guard needs TARGET paths or --background DIR, not both')
    if args.command == 'choose' and bool(args.target) == bool(args.background):
        raise Usage('choose needs --target PATH (repeatable) or --background DIR, not both')
    if args.command == 'calibrate' and not args.dry_run and not args.group:
        raise Usage("calibrate needs --group TITLE (repeated): RClick's configured top-level items of a file menu")
    if args.command == 'choose' and not args.group:
        raise Usage("choose needs --group TITLE (repeated): RClick's configured top-level items in menu order")
    return args


def probe_points(point):
    """Where to look for the menu a right-click at `point` opened: lower right first, then the flipped corners."""
    x, y = point
    return [(x + 40, y + 12), (x + 40, y - 12), (x - 40, y + 12), (x - 40, y - 12)]


LOCK_FIELDS = ('project', 'session', 'batch', 'start', 'pid', 'expected_minutes', 'purpose', 'acquisition_id')
UUID4 = re.compile(r'[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}')


def check_lock(status_text, batch, acquisition_id):
    """Raise Environment unless `gui-lock.sh status` shows ONE complete owner record (`HELD:` then exactly the eight
    indented key=value fields of gui-lock.sh, each once) with project=rclick, this run's batch and this run's
    acquisition id (the caller exports both from `gui-lock.sh acquire`). The record's pid is the acquire process,
    which has exited by design, so it is checked for form only. A lock that is not this acquisition is never removed:
    report it."""
    if not batch or not acquisition_id:
        raise Environment('the GUI lock is not bound to this run: export RCLICK_GUI_LOCK_BATCH=<run-id> and '
                          'RCLICK_GUI_LOCK_ACQUISITION_ID=<uuid> as printed by `gui-lock.sh acquire`')
    lines = status_text.split('\n')
    if lines[-1] == '':
        lines.pop()
    if not lines or lines[0] != 'HELD:':
        raise Environment('the shared GUI lock is not held (gui-lock.sh status: '
                          f'{lines[0] if lines else "no output"!r}): gui-lock.sh acquire <run-id> first')
    values = {}
    for line in lines[1:]:
        key, equals, value = line[2:].partition('=')
        if not line.startswith('  ') or not equals or key not in LOCK_FIELDS or key in values or not value:
            raise Environment(f'the GUI lock owner record is malformed or incomplete at {line!r}; report it, '
                              'never remove a lock')
        values[key] = value
    if set(values) != set(LOCK_FIELDS):
        raise Environment('the GUI lock owner record lacks ' + ', '.join(sorted(set(LOCK_FIELDS) - set(values))))
    if values['project'] != 'rclick':
        raise Environment(f'the GUI lock is held by project {values["project"]!r}, not rclick')
    if not values['pid'].isdecimal() or not UUID4.fullmatch(values['acquisition_id']):
        raise Environment('the GUI lock owner record has a malformed pid or acquisition_id')
    if values['batch'] != batch:
        raise Environment(f'the GUI lock is held by rclick run {values["batch"]!r}, not this run {batch!r}')
    if values['acquisition_id'] != acquisition_id:
        raise Environment('the GUI lock is held under another acquisition of this run id (a stale lock?): '
                          'report it, never remove it')


# Calibration steps in run order, each with the ui.sh command a failure tells the tester to distrust.
CALIBRATION_STEPS = (
    ('gui-lock', 'every ui.sh command'),
    ('axprobe', 'every ui.sh command'),
    ('accessibility', 'every ui.sh command'),
    ('row-order', 'ui.sh rows'),
    ('select-readback', 'ui.sh select'),
    ('context-menu', 'ui.sh open-menu'),
    ('menu-read', 'ui.sh menu'),
    ('rclick-group', "ui.sh menu (RClick's group)"),
    ('guard', 'ui.sh guard'),
    ('choose', 'ui.sh choose'),
    ('dialog-read', 'ui.sh dialog'),
    ('press-button', 'ui.sh press-button'),
    ('panel-grant-row', 'ui.sh grant (row mode)'),
    ('panel-grant-current', 'ui.sh grant (current-folder mode)'),
)
ENVIRONMENT_STEPS = ('gui-lock', 'axprobe', 'accessibility')


def calibration_report(results):
    """One `PASS|FAIL|SKIP <step> — <detail>` line per calibration step, in order, then the summary line.
    A step with no result is a FAIL (`not run`). Exit 0 when every step passed, 70 when an environment step
    failed (nothing else can be trusted), 65 otherwise; SKIP is not a pass."""
    by_step = {step: (status, detail) for step, status, detail in results}
    lines, distrust, environment = [], [], []
    for step, command in CALIBRATION_STEPS:
        status, detail = by_step.get(step, ('FAIL', 'not run (the calibration stopped before this step)'))
        lines.append(f'{status} {step} — {detail}')
        if status != 'PASS':
            if command not in distrust:
                distrust.append(command)
            if step in ENVIRONMENT_STEPS and status == 'FAIL':
                environment.append(step)
    if environment:
        lines.append(f'CALIBRATION FAIL — environment ({", ".join(environment)}): fix it and rerun; '
                     'distrust: every ui.sh command')
        return lines, ENVIRONMENT
    if distrust:
        lines.append(f'CALIBRATION FAIL — distrust: {", ".join(distrust)}')
        return lines, REFUSED
    lines.append(f'CALIBRATION PASS ({len(CALIBRATION_STEPS)} steps)')
    return lines, OK
