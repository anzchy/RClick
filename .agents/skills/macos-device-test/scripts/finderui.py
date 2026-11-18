"""Pure logic of the Finder UI driver: no subprocess, no AX, no clock.

The AX side (axprobe.swift, driven by finderdrive.py) prints one JSON object per accessibility element:
    {"path": [i, j, ...], "role": "AXRow", "subrole": "", "title": "", "value": "alpha.txt" | null,
     "desc": "", "enabled": true | null, "selected": false | null, "frame": [x, y, w, h] | null}
`path` is the child-index path from the dump root (a window index first for app dumps, [] for the menu root of a
menu dump). Everything here decides from such dumps, so the unit tests replay recorded or reconstructed dumps
(fixtures/) and never touch the desktop.
"""
import json
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
