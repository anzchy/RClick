"""The raw click scripts (rightclick.sh, click.sh) and modifiers.sh, run as they are: the real zsh entry point and
the real JXA it hands to osascript. Only osascript is fake: a node script on PATH that executes that JXA with a
CoreGraphics stand-in whose HID and combined-session modifier states live in a JSON file (FAKE_HID_STATE), so
nothing is posted on this Mac. The model follows the device run of 2026-11-18: a mouse event posted at the HID tap
with the Option flag leaves Option set in the HID state (0x20080000); a flagsChanged event sets the HID state to its
flags; a key-up alone changes nothing. Fix r6 (confirm r5: gpt F1/F2, opus M1/M2): the earlier tests replaced
rightclick.sh with a fake and never ran it."""
import json
import os
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent

SHIFT, CONTROL, OPTION, COMMAND = 0x20000, 0x40000, 0x80000, 0x100000
DEVICE_BIT = 0x20000000  # set beside Option on the device run; not a key
CAPS_LOCK = 0x10000
MOUSE = {5: 'moved', 3: 'right-down', 4: 'right-up', 1: 'left-down', 2: 'left-up'}

FAKE_OSASCRIPT = r"""#!/usr/bin/env node
// Fake osascript: runs the JXA from stdin against a CoreGraphics stand-in. State: $FAKE_HID_STATE (JSON).
const fs = require('fs'); const vm = require('vm');
const file = process.env.FAKE_HID_STATE;
const load = () => JSON.parse(fs.readFileSync(file, 'utf8'));
const save = (s) => fs.writeFileSync(file, JSON.stringify(s));
const args = process.argv.slice(2);
if (args[0] !== '-l' || args[1] !== 'JavaScript' || args[2] !== '-') {
  process.stderr.write('fake osascript: expected -l JavaScript -\n'); process.exit(64);
}
const argv = args.slice(3);
const source = fs.readFileSync(0, 'utf8');
function sleep(seconds) {
  if (load().real_sleep) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, seconds * 1000);
}
function post(tap, e) {
  const s = load();
  s.events.push({tap: tap, type: e.type, flags: e.flags, code: e.code, down: e.down});
  if (tap === 0 && e.type === 12) { if (!s.stuck) s.hid = e.flags || 0; }       // flagsChanged: the new flags
  else if (tap === 0 && [1, 2, 3, 4, 5].includes(e.type) && e.flags !== undefined) s.hid = (s.hid | e.flags) >>> 0;
  const n = s.events.length;
  if (s.or_after && s.or_after[n] !== undefined) s.hid = (s.hid | s.or_after[n]) >>> 0;  // a key the owner pressed
  save(s);
  if (s.kill_after === n) process.kill(process.pid, s.kill_signal);
}
const cg = {
  CGEventCreateMouseEvent: (src, type, point, button) => ({type: type, point: point}),
  CGEventCreateKeyboardEvent: (src, code, down) => ({type: down ? 10 : 11, code: code, down: down}),
  CGEventCreate: (src) => ({type: 0}),
  CGEventSetType: (e, type) => { e.type = type; },
  CGEventSetFlags: (e, flags) => { e.flags = Number(flags) >>> 0; },
  CGEventPost: (tap, e) => post(tap, e),
  CGEventSourceFlagsState: (which) => {
    const s = load();
    if (s.unreadable) throw new Error('CGEventSourceFlagsState unavailable');
    if (which === 1) return s.hid;
    if (which === 0) return s.session;
    throw new Error('fake: unexpected event source state ' + which);
  },
  NSThread: {sleepForTimeInterval: sleep},
};
const $ = new Proxy(cg, {get: (t, name) => {
  if (!(name in t)) throw new Error('fake osascript: $.' + String(name) + ' is not modelled');
  return t[name];
}});
const context = vm.createContext({ObjC: {import: () => {}}, $: $, Number: Number, Error: Error});
try {
  vm.runInContext(source, context);
  const result = context.run(argv);
  if (result !== undefined) process.stdout.write(String(result) + '\n');
} catch (error) {
  process.stderr.write('execution error: Error: ' + error.message + ' (-2700)\n'); process.exit(1);
}
"""


TOOLS = None  # the directory holding the fake osascript, written once: macOS scans every new executable on its
# first run (about 3 s), so one per test would make this file slow.


def setUpModule():
    global TOOLS
    missing = [tool for tool in ('node', 'zsh') if not shutil.which(tool)]
    if missing:
        raise AssertionError(f'{", ".join(missing)} not found: the raw-script tests need them (node runs the JXA)')
    TOOLS = tempfile.TemporaryDirectory(prefix='rclick-raw-tools-')
    tool = Path(TOOLS.name) / 'osascript'
    tool.write_text(FAKE_OSASCRIPT, encoding='utf-8')
    tool.chmod(0o755)


def tearDownModule():
    TOOLS.cleanup()


class Desk:
    """One fake desktop: the fake osascript first on PATH and its own JSON state file."""

    def __init__(self, test, hid=DEVICE_BIT, session=0, **extra):
        temp = tempfile.TemporaryDirectory(prefix='rclick-raw-')
        test.addCleanup(temp.cleanup)
        self.file = Path(temp.name) / 'state.json'
        self.entry = hid
        self.write(dict(hid=hid, session=session, events=[], **extra))
        self.env = dict(os.environ, PATH=f'{TOOLS.name}{os.pathsep}{os.environ.get("PATH", "")}',
                        FAKE_HID_STATE=str(self.file))

    def write(self, state):
        self.file.write_text(json.dumps(state), encoding='utf-8')

    def state(self):
        return json.loads(self.file.read_text(encoding='utf-8'))

    def run(self, script, *argv, timeout=30):
        result = subprocess.run([str(HERE / script), *argv], capture_output=True, text=True, env=self.env,
                                timeout=timeout)
        return result.returncode, result.stdout, result.stderr

    def start(self, script, *argv):
        return subprocess.Popen([str(HERE / script), *argv], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, env=self.env)

    def option_events(self):
        return [e for e in self.state()['events'] if e['type'] in MOUSE and (e.get('flags') or 0) & OPTION]


class Checks(unittest.TestCase):
    def assert_untouched(self, desk, code, err, expected_code=65):
        self.assertEqual(code, expected_code, err)
        state = desk.state()
        self.assertEqual(state['events'], [], 'an event was posted although the state was dirty')
        self.assertEqual(state['hid'], desk.entry, f'the held modifier was changed: 0x{state["hid"]:x}')

    def assert_restored(self, desk, why=''):
        hid = desk.state()['hid']
        self.assertEqual(hid, desk.entry, f'HID state 0x{hid:x} is not the entry state 0x{desk.entry:x} {why}')


CLICKS = (('rightclick.sh', '100', '200', 'option'), ('rightclick.sh', '100', '200'), ('click.sh', '100', '200'))
HELD = (('Shift', SHIFT), ('Control', CONTROL), ('Option', OPTION), ('Command', COMMAND),
        ('Option', DEVICE_BIT | OPTION))  # the last: Option repeated, the state the device's option click left


class RawClicksRefuseAHeldModifier(Checks):
    """F1: with a modifier already held (the owner's, or one left set) the raw scripts post nothing (65) and leave it
    as it was. 46e9c2e posted the click, then cleared every flag (all-zero flagsChanged) or left a leaked Option."""

    def test_every_modifier_held_at_entry_is_refused_and_left_as_it_was(self):
        for argv in CLICKS:
            for name, flags in HELD:
                with self.subTest(script=' '.join(argv), held=f'{name} 0x{flags:x}'):
                    desk = Desk(self, hid=flags)
                    code, out, err = desk.run(*argv)
                    self.assert_untouched(desk, code, err)
                    self.assertIn(f'{name} held down', err)
                    self.assertNotIn('clicked', out)

    def test_an_unreadable_state_posts_nothing(self):
        for argv in CLICKS:
            with self.subTest(script=' '.join(argv)):
                desk = Desk(self, unreadable=True)
                code, _, err = desk.run(*argv)
                self.assert_untouched(desk, code, err, 70)
                self.assertIn('modifier state is unknown', err)

    def test_a_clean_option_click_presses_option_and_restores_the_entry_state(self):
        for entry in (DEVICE_BIT, 0, DEVICE_BIT | CAPS_LOCK):
            with self.subTest(entry=f'0x{entry:x}'):
                desk = Desk(self, hid=entry)
                code, out, err = desk.run('rightclick.sh', '100', '200', 'option')
                self.assertEqual(code, 0, err)
                self.assertEqual([MOUSE[e['type']] for e in desk.option_events()], ['moved', 'right-down', 'right-up'])
                self.assert_restored(desk, '(the release cleared bits it did not set)')
                self.assertIn('released', out)
                changed = [e for e in desk.state()['events'] if e['type'] == 12]
                self.assertTrue(changed, 'no flagsChanged event released Option')
                self.assertTrue(all(e['flags'] == entry for e in changed),
                                f'flagsChanged flags {[hex(e["flags"]) for e in changed]} are not the entry state')

    def test_a_key_the_owner_presses_during_the_hold_is_not_released(self):
        desk = Desk(self, or_after={'3': SHIFT})  # Shift goes down right after the right-up, while Option is held
        code, _, err = desk.run('rightclick.sh', '100', '200', 'option')
        self.assertEqual(code, 0, err)
        self.assertEqual(desk.state()['hid'], DEVICE_BIT | SHIFT, 'the release cleared the owner\'s Shift')

    def test_a_clean_plain_click_posts_no_modifier_and_changes_nothing(self):
        for argv, types in ((CLICKS[1], ['moved', 'right-down', 'right-up']),
                            (CLICKS[2], ['moved', 'left-down', 'left-up'])):
            with self.subTest(script=' '.join(argv)):
                desk = Desk(self)
                code, _, err = desk.run(*argv)
                self.assertEqual(code, 0, err)
                events = desk.state()['events']
                self.assertEqual([MOUSE.get(e['type']) for e in events], types)
                self.assertEqual(desk.option_events(), [])
                self.assert_restored(desk)


# The events of a clean `rightclick.sh X Y option` in order: 1 mouse-moved with Option, 2 right-down, 3 right-up
# (the click; then the 1 s hold), 4 and 5 the Option key-ups and 6 the flagsChanged of the JXA `finally`.
KILL_POINTS = ((1, 'after the first Option event'), (2, 'before the click completes (right-down only)'),
               (3, 'after the click, during the hold'), (4, 'inside the JXA release, after one key-up'))


class RawOptionClickCleansUpWhenItsChildDies(Checks):
    """F2: a SIGTERM or SIGKILL of the osascript child skips its JXA `finally`; on 46e9c2e nothing else released the
    Option it had posted (HID state 0x20080000 after exit 143/137). The surviving shell must release it (only it),
    keep the child's status and read the state back."""

    def test_a_terminated_or_killed_child_leaves_the_entry_state_and_its_status(self):
        for sig in (signal.SIGTERM, signal.SIGKILL):
            for after, where in KILL_POINTS:
                with self.subTest(signal=sig.name, point=where):
                    desk = Desk(self, kill_after=after, kill_signal=sig.name)
                    code, out, err = desk.run('rightclick.sh', '100', '200', 'option')
                    self.assertEqual(code, 128 + sig, f'not the child\'s status: {err}')
                    self.assert_restored(desk, f'(child {sig.name} {where})')
                    self.assertNotIn('released', out, 'a failed click reported as done')
                    self.assertIn('Option released', err)

    def test_a_release_that_does_not_clear_option_is_reported_never_as_released(self):
        for kill in (None, 'SIGTERM'):
            with self.subTest(child=kill or 'exits 0'):
                extra = dict(kill_after=3, kill_signal=kill) if kill else {}
                desk = Desk(self, stuck=True, **extra)
                code, out, err = desk.run('rightclick.sh', '100', '200', 'option')
                self.assertEqual(code, 143 if kill else 70, err)
                self.assertNotIn('released', out)
                self.assertIn('Option could not be released', err)
                self.assertNotIn('Option released', err)


class RawOptionClickCleansUpOnItsOwnSignals(Checks):
    """F2: the shell itself interrupted (INT, TERM, HUP) during the hold: it stops its child, releases the Option the
    child posted, and exits 130/143/129. On 46e9c2e zsh ran the trap only after osascript had finished."""

    def test_int_term_and_hup_during_the_hold(self):
        for sig, code in ((signal.SIGINT, 130), (signal.SIGTERM, 143), (signal.SIGHUP, 129)):
            with self.subTest(signal=sig.name):
                desk = Desk(self, real_sleep=True)
                process = desk.start('rightclick.sh', '100', '200', 'option')
                deadline = time.monotonic() + 10
                while len(desk.state()['events']) < 3:  # the click is done; the child holds Option for 1 s
                    self.assertLess(time.monotonic(), deadline, 'the click never happened')
                    time.sleep(0.01)
                started = time.monotonic()
                process.send_signal(sig)
                out, err = process.communicate(timeout=10)
                self.assertEqual(process.returncode, code, err)
                self.assertLess(time.monotonic() - started, 0.9, 'the shell waited for the hold to end')
                self.assert_restored(desk, f'(shell {sig.name})')
                events = len(desk.state()['events'])
                time.sleep(1.3)
                self.assertEqual(len(desk.state()['events']), events, 'the child lived on and posted after the exit')


if __name__ == '__main__':
    unittest.main()
