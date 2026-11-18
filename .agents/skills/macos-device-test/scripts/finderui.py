"""Pure logic of the Finder UI driver: no subprocess, no AX, no clock.

The AX side (axprobe.swift, driven by finderdrive.py) prints one JSON object per accessibility element:
    {"path": [i, j, ...], "role": "AXRow", "subrole": "", "title": "", "value": "alpha.txt" | null,
     "desc": "", "enabled": true | null, "selected": false | null, "frame": [x, y, w, h] | null}
`path` is the child-index path from the dump root (a window index first for app dumps, [] for the menu root of a
menu dump). Everything here decides from such dumps, so the unit tests replay recorded or reconstructed dumps
(fixtures/) and never touch the desktop.
"""
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


def rclick_group(items, also=()):
    """RClick's section: Finder lists extension items after its own `Quick Actions` item with no separator between
    extensions (i22-device-20261116e). The group starts after the last `Quick Actions` (or at the first known
    RClick title when there is none) and ends at the first title that is not an RClick title or repeats one, so
    another extension's `New File` or `Copy Path` right after it is not taken for RClick's."""
    known = set(RCLICK_TITLES) | {nfc(title) for title in also}
    quick = [i for i, item in enumerate(items) if item.title == 'Quick Actions']
    if quick:
        start = quick[-1] + 1
    else:
        start = next((i for i, item in enumerate(items) if base_title(item.title) in known), len(items))
    group, seen = [], set()
    for item in items[start:]:
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
    path = nfc(path.strip())
    return path.rstrip('/') or '/' if path else ''


def parse_selection(text):
    """POSIX paths read back from Finder's selection, one per line (folders end with '/', which is dropped)."""
    return [clean_path(line) for line in text.splitlines() if line.strip()]


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
