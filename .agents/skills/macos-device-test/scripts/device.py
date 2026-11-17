#!/usr/bin/env python3
"""RClick device-run orchestration: build, launch, doctor, pause/resume, cleanup.

Adapted from picsee's scripts/device/device.py. Evidence stays outside the checkout, under
~/.rclick-roster/device/<run-id>/. Every process action is tied to the PID, executable path and birth
time this run recorded; nothing is ever found or signalled by name.
"""
import argparse
import ctypes
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
ROOT = Path(os.environ.get('RCLICK_DEVICE_ROOT') or HERE.parents[3]).resolve()  # .agents/skills/<skill>/scripts
APP_NAME = 'RClick'
APP_ID = 'cn.anzchy.RClick'
EXT_NAME = 'FinderSyncExt'
EXT_ID = 'cn.anzchy.RClick.FinderSyncExt'
LOG_SUBSYSTEM = APP_ID
# The public log line applicationDidFinishLaunching writes (RClick/RClickApp.swift).
LAUNCH_LOG = 'launch decision:'
REQUIRED_XCODE_MAJOR = 26
BIRTH_FORMAT = '%a %b %d %H:%M:%S %Y'


def command(argv, timeout=30):
    return subprocess.run([str(a) for a in argv], text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=timeout, env={**os.environ, 'LC_ALL': 'C'})


def checked(argv, timeout=30, strip=True):
    r = command(argv, timeout)
    if r.returncode:
        raise RuntimeError(r.stderr.strip() or r.stdout.strip() or str(argv))
    return r.stdout.strip() if strip else r.stdout


def executable(pid):
    lib = ctypes.CDLL('/usr/lib/libproc.dylib')
    buf = ctypes.create_string_buffer(4096)
    if lib.proc_pidpath(int(pid), buf, len(buf)) <= 0:
        return None
    return Path(os.fsdecode(buf.value)).resolve()


def process_snapshot(pid):
    before = executable(pid)
    if before is None:
        return None
    try:
        birth = checked(['/bin/ps', '-o', 'lstart=', '-p', str(pid)])
    except RuntimeError:
        if executable(pid) is None:
            return None  # The process exited between path and birth reads.
        raise
    datetime.datetime.strptime(birth, BIRTH_FORMAT)
    after = executable(pid)
    if after is None:
        return None
    if after != before:
        raise RuntimeError('process identity changed while reading birth time')
    return dict(pid=pid, executable=str(before), birth=birth)


def inside(exe, app):
    return exe is not None and Path(exe).is_relative_to(app / 'Contents')


def pids_named(name):
    """Exact-name process query that fails closed. Used to *detect* instances, never to signal them."""
    try:
        r = command(['/usr/bin/pgrep', '-x', name])
    except (OSError, subprocess.TimeoutExpired) as error:
        raise RuntimeError('pgrep process query failed: ' + str(error)) from error
    if r.returncode == 1 and not r.stdout.strip() and not r.stderr.strip():
        return []
    if r.returncode != 0:
        raise RuntimeError(f'pgrep process query failed (exit {r.returncode}): '
                           + (r.stderr.strip() or r.stdout.strip() or 'inconsistent result'))
    if r.stderr.strip():
        raise RuntimeError('pgrep process query emitted a diagnostic: ' + r.stderr.strip())
    parts = r.stdout.split()
    if not parts or any(not re.fullmatch(r'[0-9]+', part) for part in parts):
        raise RuntimeError('pgrep returned malformed or empty PID list')
    pids = [int(part) for part in parts]
    if any(pid <= 1 for pid in pids) or len(set(pids)) != len(pids):
        raise RuntimeError('pgrep returned malformed or duplicate PID list')
    return pids


def running():
    return pids_named(APP_NAME)


def recorded_identity(run):
    if (run / 'retired').exists():
        raise RuntimeError('process identity record is retired')
    try:
        pid = int((run / 'rclick.pid').read_text().strip())
        app = Path((run / 'bundle.path').read_text().strip()).resolve()
        record = json.loads((run / 'process.json').read_text())
        if (pid <= 1 or type(record['pid']) is not int or record['pid'] != pid
                or not record['birth'] or not isinstance(record['birth'], str)
                or not Path(record['executable']).is_absolute()):
            raise ValueError('ambiguous PID, executable or birth')
        datetime.datetime.strptime(record['birth'], BIRTH_FORMAT)
        if not inside(Path(record['executable']).resolve(), app):
            raise ValueError('executable outside recorded bundle')
    except Exception as e:
        raise RuntimeError('invalid process identity record: ' + str(e)) from e
    return pid, app, record


def identity(run):
    pid, app, record = recorded_identity(run)
    if process_snapshot(pid) != record:
        raise RuntimeError('process identity differs from recorded birth, PID or executable')
    return pid, app


def atomic_text(path, text):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, prefix='.' + path.name, delete=False) as output:
            temporary = Path(output.name)
            output.write(text)
        os.replace(temporary, path)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def save(run, name, data):
    atomic_text(run / name, json.dumps(data, indent=2) + '\n')


def machine():
    # Only non-sensitive model/display facts; no serial number or user information.
    scale = checked(['/usr/bin/osascript', '-l', 'JavaScript', '-e',
                     "ObjC.import('AppKit'); Number($.NSScreen.mainScreen.backingScaleFactor)"])
    return dict(model=checked(['/usr/sbin/sysctl', '-n', 'hw.model']),
                chip=checked(['/usr/sbin/sysctl', '-n', 'machdep.cpu.brand_string']),
                memory=checked(['/usr/sbin/sysctl', '-n', 'hw.memsize']),
                macOS=checked(['/usr/bin/sw_vers', '-productVersion']), scale=float(scale))


# Build inputs: everything that goes into RClick.app or its extension.
INPUT_ROOTS = ('RClick', 'FinderSyncExt', 'Shared', 'RClick.xcodeproj')


def is_input(relative):
    path = Path(relative)
    return (bool(path.parts) and path.parts[0] in INPUT_ROOTS
            and not any(part in ('.build', '.git', '__pycache__', 'DerivedData', 'xcuserdata') for part in path.parts)
            and path.name != '.DS_Store')


def input_inventory(root=ROOT):
    paths = []
    for name in INPUT_ROOTS:
        p = root / name
        if p.is_file() or p.is_symlink():
            paths.append(p)
        elif p.is_dir():
            paths.extend(p.rglob('*'))
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in paths if p.is_file() and is_input(p.relative_to(root))}


def assert_clean_inputs(root=ROOT):
    inventory = input_inventory(root)
    tracked = set(checked(['git', '-C', root, 'ls-files', '-z']).split('\0'))
    tracked = {name for name in tracked if name and is_input(name)}
    if set(inventory) != tracked:
        raise RuntimeError('untracked or missing build inputs: ' + ', '.join(sorted(set(inventory) ^ tracked)))
    if command(['git', '-C', root, 'diff', '--quiet', 'HEAD', '--', *sorted(tracked)]).returncode:
        raise RuntimeError('modified build inputs; commit before building')
    return inventory


def run_dir(value):
    run = Path(value).expanduser().resolve()
    if run == ROOT or run.is_relative_to(ROOT):
        raise RuntimeError('run evidence must be outside the worktree')
    run.mkdir(parents=True, exist_ok=True)
    return run


def signing_settings(value):
    """RCLICK_DEVICE_SIGNING: `team:<TEAMID>` (Apple Development, automatic) or `adhoc` (Sign to Run Locally).

    The project's DEVELOPMENT_TEAM (GRT84NAK4T) belongs to the fork owner. A device build must say
    which signing it uses; the choice is recorded in build.json and the validation record.
    """
    if not value:
        raise RuntimeError('set RCLICK_DEVICE_SIGNING=team:<TEAMID> or adhoc (see the runbook §4)')
    if value == 'adhoc':
        return ['CODE_SIGN_IDENTITY=-', 'CODE_SIGN_STYLE=Manual', 'DEVELOPMENT_TEAM=', 'PROVISIONING_PROFILE_SPECIFIER=']
    match = re.fullmatch(r'team:([A-Z0-9]{10})', value)
    if not match:
        raise RuntimeError('RCLICK_DEVICE_SIGNING must be team:<10-character team ID> or adhoc')
    return ['DEVELOPMENT_TEAM=' + match.group(1), 'CODE_SIGN_STYLE=Automatic', '-allowProvisioningUpdates']


def xcode_version():
    version = checked(['/usr/bin/xcodebuild', '-version'])
    match = re.match(r'Xcode (\d+)', version)
    if not match or int(match.group(1)) < REQUIRED_XCODE_MAJOR:
        raise RuntimeError(f'requires Xcode {REQUIRED_XCODE_MAJOR}+; xcode-select points at: {version!r}')
    return version


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def build(run):
    if running():
        raise RuntimeError('another RClick is running; ask its owner to quit it (never quit it for them)')
    signing = os.environ.get('RCLICK_DEVICE_SIGNING', '')
    extra = signing_settings(signing)
    inputs = assert_clean_inputs(ROOT)
    version = xcode_version()
    sha = checked(['git', '-C', ROOT, 'rev-parse', '--short=8', 'HEAD'])
    full = checked(['git', '-C', ROOT, 'rev-parse', 'HEAD'])
    dd = ROOT / '.build' / ('device-' + run.name)
    argv = ['/usr/bin/xcodebuild', 'build', '-project', 'RClick.xcodeproj', '-scheme', 'RClick',
            '-configuration', 'Debug', '-destination', 'platform=macOS', '-derivedDataPath', str(dd), *extra]
    with (run / 'build.log').open('w') as output:
        r = subprocess.run(argv, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT)
    if r.returncode:
        raise RuntimeError(f'build failed; see {run / "build.log"}')
    if inputs != assert_clean_inputs(ROOT) or full != checked(['git', '-C', ROOT, 'rev-parse', 'HEAD']):
        raise RuntimeError('build inputs or commit changed during build; refusing proof image')
    app = dd / 'Build/Products/Debug/RClick.app'
    ext = app / 'Contents/PlugIns/FinderSyncExt.appex'
    if not ext.is_dir():
        raise RuntimeError('built app has no embedded FinderSyncExt.appex')
    (run / 'bundle.path').write_text(str(app) + '\n')
    save(run, 'build.json', dict(
        sha=sha, fullSHA=full, configuration='Debug', xcode=version, signing=signing, machine=machine(),
        inputs=inputs,
        executables={'app': sha256(app / 'Contents/MacOS/RClick'),
                     'extension': sha256(ext / 'Contents/MacOS/FinderSyncExt')}))
    print(f'PASS build bundle={app} git={sha} signing={signing}')


def logs(run, pid):
    start = (run / 'start.txt').read_text().strip()
    r = command(['/usr/bin/log', 'show', '--start', start, '--style', 'compact', '--info',
                 '--predicate', f'subsystem == "{LOG_SUBSYSTEM}" AND processID == {pid}'])
    if r.returncode:
        raise RuntimeError(r.stderr.strip())
    (run / 'app.log').write_text(r.stdout)
    return r.stdout


PLUGINKIT_LINE = re.compile(r'^\s*([+\-!=?]*)\s*(\S+)\(([^)]*)\)\s*$')


def parse_pluginkit(output):
    """Parse `pluginkit -m -v` registration output into [{flags, id, version, path}].

    Lines look like `+    cn.anzchy.RClick.FinderSyncExt(2.3.4)\t<uuid>\t<date>\t/path/FinderSyncExt.appex`.
    Flags: `+` enabled by the user, `-` disabled, `=` superseded, `!` debug, empty = undecided.
    """
    entries = []
    for line in output.splitlines():
        if not line.strip():
            continue
        fields = line.split('\t')
        head = PLUGINKIT_LINE.match(fields[0])
        if not head:
            raise RuntimeError('unrecognised pluginkit line: ' + line.strip())
        path = next((f.strip() for f in fields[1:] if f.strip().startswith('/')), None)
        entries.append(dict(flags=head.group(1), id=head.group(2), version=head.group(3), path=path))
    return entries


def extension_entries():
    # Read-only. Never `pluginkit -e use|ignore` or `-a/-r` from a script: that changes system state.
    r = command(['/usr/bin/pluginkit', '-m', '-v', '-p', 'com.apple.FinderSync'])
    if r.returncode not in (0, 1):
        raise RuntimeError('pluginkit query failed: ' + (r.stderr.strip() or str(r.returncode)))
    # Include dormant upstream and other RClick identities, not just the fork ID.
    return [entry for entry in parse_pluginkit(r.stdout) if 'rclick' in entry['id'].lower()]


def accessibility_trusted():
    out = checked(['/usr/bin/osascript', '-l', 'JavaScript', '-e',
                   "ObjC.import('ApplicationServices'); $.AXIsProcessTrusted() ? 'yes' : 'no'"])
    return out == 'yes'


def launch(run):
    if (run / 'process.json').exists() or (run / 'retired').exists():
        raise RuntimeError('run already has an ownership record; use a new run directory')
    before = set(running())
    if before:
        # SingleInstanceGuard makes the *older* copy of the same version quit itself, so launching now would
        # effectively terminate the user's RClick. Refuse instead.
        raise RuntimeError('another RClick is running; ask its owner to quit it (launching would make it quit)')
    app = Path((run / 'bundle.path').read_text().strip()).resolve()
    argv = ['/usr/bin/open', '-n', '-W', str(app)]
    # Optional per-run UI language for the *app* (Settings window). The Finder menu is rendered by the
    # extension inside Finder and follows the system language; this flag does not reach it.
    if (run / 'app-lang.txt').exists():
        lang = (run / 'app-lang.txt').read_text().strip()
        if not re.fullmatch(r'[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*', lang):
            raise RuntimeError('app-lang.txt is not a language tag')
        argv += ['--args', '-AppleLanguages', f'({lang})']
    launch_time = time.time()
    (run / 'start.txt').write_text(datetime.datetime.fromtimestamp(launch_time).strftime('%Y-%m-%d %H:%M:%S'))
    opener = subprocess.Popen(argv, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              env={**os.environ, 'LC_ALL': 'C'})
    deadline = time.monotonic() + 30
    missing = 'process'
    while time.monotonic() < deadline:
        if opener.poll() is not None:
            _, diagnostic = opener.communicate()
            raise RuntimeError('LaunchServices app exited before readiness'
                               + (': ' + diagnostic.strip() if diagnostic.strip() else ''))
        candidates = [p for p in running() if p not in before and executable(p) == app / 'Contents/MacOS/RClick']
        if len(candidates) > 1:
            raise RuntimeError('more than one new matching RClick process; no PID recorded')
        if not candidates and (run / 'process.json').exists():
            raise RuntimeError('launched process exited after identity was recorded')
        if candidates:
            pid = candidates[0]
            if not (run / 'process.json').exists():
                record = process_snapshot(pid)
                if record is None:
                    raise RuntimeError('launched process disappeared before birth identity was recorded')
                birth = datetime.datetime.strptime(record['birth'], BIRTH_FORMAT).timestamp()
                if (record['pid'] != pid or not inside(Path(record['executable']), app)
                        or birth < int(launch_time)):
                    raise RuntimeError('new process identity or birth differs from this launch')
                (run / 'rclick.pid').write_text(str(pid) + '\n')
                save(run, 'process.json', record)
            elif pid != json.loads((run / 'process.json').read_text())['pid']:
                raise RuntimeError('launched process identity changed')
            identity(run)
            if LAUNCH_LOG in logs(run, pid):
                save(run, 'ready.json', dict(pid=pid, extensions=extension_entries()))
                print(f'PASS ready pid={pid} (run doctor next; the extension is checked there)')
                return
            missing = f'public "{LAUNCH_LOG}" log line from this PID'
        time.sleep(0.5)
    raise RuntimeError('ready timeout after 30 s: missing ' + missing)


def adopt(run, source):
    """Record the RClick that the extension's offline hint relaunched from this run's bundle.

    The hint click starts the host app through LaunchServices, so launch.sh never saw that PID. The source run
    must already be retired (its own process cleaned up); the new run directory takes over the same bundle.
    """
    source = run_dir(source)
    if not (source / 'retired').exists():
        raise RuntimeError('source run is not retired; run cleanup.sh on it before the hint relaunch')
    if (run / 'process.json').exists() or (run / 'retired').exists():
        raise RuntimeError('run already has an ownership record; use a new run directory')
    app = Path((source / 'bundle.path').read_text().strip()).resolve()
    retired_at = (source / 'retired').stat().st_mtime
    candidates = [p for p in running() if executable(p) == app / 'Contents/MacOS/RClick']
    others = [p for p in running() if p not in candidates]
    if others:
        raise RuntimeError('another RClick is running from a different bundle; stop and ask the user')
    if len(candidates) != 1:
        raise RuntimeError(f'expected exactly one RClick from this run\'s bundle, found {len(candidates)}')
    record = process_snapshot(candidates[0])
    if record is None:
        raise RuntimeError('relaunched process disappeared before birth identity was recorded')
    if datetime.datetime.strptime(record['birth'], BIRTH_FORMAT).timestamp() < int(retired_at):
        raise RuntimeError('process predates the source run\'s cleanup; it is not the hint relaunch')
    for name in ('bundle.path', 'build.json'):
        (run / name).write_text((source / name).read_text())
    (run / 'start.txt').write_text(datetime.datetime.fromtimestamp(retired_at).strftime('%Y-%m-%d %H:%M:%S'))
    (run / 'rclick.pid').write_text(f'{record["pid"]}\n')
    save(run, 'process.json', record)
    (run / 'adopted-from.txt').write_text(str(source) + '\n')
    print(f'PASS adopt pid={record["pid"]} from={source.name}')


def sandbox_enabled(output):
    try:
        raw = output.encode() if isinstance(output, str) else output
        return plistlib.loads(raw).get('com.apple.security.app-sandbox') is True
    except Exception:
        return False


CHECKS = ('bundle-hash', 'bundle-id', 'signature-valid', 'sandbox', 'process-bundle', 'fresh-sources',
          'single-instance', 'launch-log', 'extension-registered', 'extension-enabled', 'extension-process',
          'accessibility', 'machine')


def collect(run, expected):
    data = dict(expectedSHA=expected, errors={})

    def observe(names, action, default=None):
        try:
            return action()
        except Exception as e:
            for name in names:
                data['errors'][name] = str(e)
            return default

    app = observe(('bundle-hash', 'bundle-id', 'signature-valid', 'sandbox', 'fresh-sources',
                   'extension-registered', 'extension-process'),
                  lambda: Path((run / 'bundle.path').read_text().strip()).resolve())
    recorded = observe(('bundle-hash', 'machine', 'fresh-sources'),
                       lambda: json.loads((run / 'build.json').read_text()), {})
    data['recordedSHA'] = recorded.get('sha')
    data['hashesMatch'] = observe(('bundle-hash',), lambda: recorded['executables'] == {
        'app': sha256(app / 'Contents/MacOS/RClick'),
        'extension': sha256(app / 'Contents/PlugIns/FinderSyncExt.appex/Contents/MacOS/FinderSyncExt')}, False)
    info = observe(('bundle-id',), lambda: plistlib.loads((app / 'Contents/Info.plist').read_bytes()), {})
    ext_info = observe(('bundle-id',), lambda: plistlib.loads(
        (app / 'Contents/PlugIns/FinderSyncExt.appex/Contents/Info.plist').read_bytes()), {})
    data.update(bundleID=info.get('CFBundleIdentifier'), extBundleID=ext_info.get('CFBundleIdentifier'))

    def signature():
        checked(['/usr/bin/codesign', '--verify', '--deep', '--strict', app])
        return True
    data['signatureValid'] = observe(('signature-valid',), signature, False)
    data['sandbox'] = observe(('sandbox',), lambda: sandbox_enabled(checked(
        ['/usr/bin/codesign', '-d', '--entitlements', ':-', app])) and sandbox_enabled(checked(
        ['/usr/bin/codesign', '-d', '--entitlements', ':-', app / 'Contents/PlugIns/FinderSyncExt.appex'])), False)
    owned = observe(('process-bundle', 'single-instance', 'launch-log'), lambda: identity(run))
    data['processMatches'] = owned is not None and owned[1] == app
    data['alone'] = observe(('single-instance',), lambda: owned is not None and running() == [owned[0]], False)
    data['log'] = observe(('launch-log',), lambda: logs(run, owned[0]), '') if owned else ''
    entries = observe(('extension-registered', 'extension-enabled'), extension_entries, [])
    data['extensions'] = entries
    data['extProcesses'] = observe(('extension-process',), lambda: [
        str(executable(p)) for p in pids_named(EXT_NAME)], [])
    data['appPath'] = str(app) if app else None
    data['accessibility'] = observe(('accessibility',), accessibility_trusted, False)
    data['machine'] = observe(('machine',), machine)
    data['machineMatches'] = data['machine'] is not None and data['machine'] == recorded.get('machine')

    def fresh():
        current = assert_clean_inputs(ROOT)
        return current == recorded['inputs']
    data['fresh'] = observe(('fresh-sources',), fresh, False)
    if owned:
        observe(('process-bundle', 'single-instance', 'launch-log'), lambda: identity(run))
    save(run, 'doctor-input.json', data)
    return data


def verdicts(data):
    app = Path(data['appPath']) if data.get('appPath') else None
    ours = [e for e in data.get('extensions', []) if e.get('id') == EXT_ID and app and e.get('path') and Path(e['path']).is_relative_to(app)]
    foreign = [e for e in data.get('extensions', []) if e not in ours]
    ext_procs = data.get('extProcesses', [])
    checks = [
        ('bundle-hash', data.get('hashesMatch') is True and bool(data.get('expectedSHA'))
         and data.get('recordedSHA') == data.get('expectedSHA'),
         'app/extension executables or build SHA differ from build.json'),
        ('bundle-id', data.get('bundleID') == APP_ID and data.get('extBundleID') == EXT_ID, 'wrong bundle identifier'),
        ('signature-valid', data.get('signatureValid') is True, 'codesign verification failed'),
        ('sandbox', data.get('sandbox') is True, 'App Sandbox entitlement missing on app or extension'),
        ('process-bundle', data.get('processMatches') is True, 'PID executable differs from recorded bundle'),
        ('fresh-sources', data.get('fresh') is True, 'build input modified, missing or untracked since build'),
        ('single-instance', data.get('alone') is True, 'recorded PID is not the only RClick instance'),
        ('launch-log', LAUNCH_LOG in data.get('log', ''), f'public "{LAUNCH_LOG}" log line missing for this PID'),
        ('extension-registered', len(ours) == 1 and not foreign,
         f'expected exactly one {EXT_ID} registration, inside this run\'s bundle; found '
         + (', '.join(str(e.get('id')) + ' at ' + str(e.get('path')) for e in data.get('extensions', [])) or 'none')),
        ('extension-enabled', len(ours) == 1 and '+' in ours[0].get('flags', ''),
         'extension not enabled; the user enables it in System Settings (never pluginkit -e from a run)'),
        ('extension-process', len(ext_procs) == 1 and app is not None and Path(ext_procs[0]).is_relative_to(app),
         f'expected one {EXT_NAME} process from this bundle; found ' + (', '.join(ext_procs) or 'none')),
        ('accessibility', data.get('accessibility') is True,
         'this terminal/host lacks Accessibility; the owner grants it, the run never changes privacy settings'),
        ('machine', data.get('machineMatches') is True, 'machine/display differs from build record'),
    ]
    checks = [(name, ok and name not in data.get('errors', {}), why) for name, ok, why in checks]
    lines = [('PASS ' + name if ok
              else 'FAIL ' + name + ' — ' + ' '.join(str(data.get('errors', {}).get(name, why)).split()))
             for name, ok, why in checks]
    return lines, all(ok for _, ok, _ in checks)


def doctor(run, expected=None, fixture=None):
    try:
        data = json.loads(Path(fixture).read_text()) if fixture else collect(
            run, expected or checked(['git', '-C', ROOT, 'rev-parse', '--short=8', 'HEAD']))
        lines, passed = verdicts(data)
    except Exception as e:
        data = dict(errors={name: str(e) for name in CHECKS})
        lines, passed = verdicts(data)
    output = '\n'.join(lines) + '\n'
    print(output, end='', flush=True)
    if run:
        report = run / 'doctor.txt'
        try:
            atomic_text(report, output)
        except Exception as e:
            print(f'FAIL report-write — {" ".join(str(e).split())}; existing doctor.txt is STALE/UNUSABLE')
            return 1
    return 0 if passed else 1


def signal_owned(run, sig, label):
    """SIGSTOP/SIGCONT to this run's own RClick, used to simulate a hung host for the 3 s ack alert."""
    pid, app, record = recorded_identity(run)
    if process_snapshot(pid) != record:
        raise RuntimeError('process identity differs from recorded birth, PID or executable; refusing signal')
    os.kill(pid, sig)
    stamp = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    with (run / 'signals.log').open('a') as out:
        out.write(f'{stamp} {label} pid={pid}\n')
    print(f'PASS {label} pid={pid}')


def pause(run):
    signal_owned(run, signal.SIGSTOP, 'pause')


def resume(run):
    signal_owned(run, signal.SIGCONT, 'resume')


def cleanup(run):
    try:
        pid, app, record = recorded_identity(run)
        current = process_snapshot(pid)
        if current is None:
            print(f'PASS cleanup pid={pid} already exited; evidence retained at {run}')
            return
        if current != record:
            raise RuntimeError('process identity differs from recorded birth, PID or executable')
        if process_snapshot(pid) != record:
            raise RuntimeError('process identity changed; refusing signal')
        os.kill(pid, signal.SIGCONT)  # A paused process cannot handle SIGTERM.
        os.kill(pid, signal.SIGTERM)
        for _ in range(50):
            if process_snapshot(pid) != record:
                print(f'PASS cleanup terminated pid={pid}; evidence retained at {run}')
                return
            time.sleep(0.1)
        raise RuntimeError(f'PID {pid} did not exit after SIGTERM; no escalation sent')
    finally:
        atomic_text(run / 'retired', 'Cleanup attempted; ownership record is permanently retired.\n')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['build', 'launch', 'adopt', 'doctor', 'pause', 'resume', 'cleanup'])
    parser.add_argument('run', nargs='?')
    parser.add_argument('--expected-sha')
    parser.add_argument('--fixture', help='offline doctor input only; never device proof')
    parser.add_argument('--from', dest='source', help='adopt: the retired run whose bundle was relaunched')
    args = parser.parse_args()
    try:
        if args.action == 'doctor':
            run = None if args.fixture else run_dir(args.run)
            return doctor(run, args.expected_sha, args.fixture)
        if args.action == 'adopt':
            if not args.source:
                raise RuntimeError('usage: adopt.sh NEW_RUN_DIR --from RETIRED_RUN_DIR')
            adopt(run_dir(args.run), args.source)
            return 0
        globals()[args.action](run_dir(args.run))
        return 0
    except Exception as e:
        print(f'FAIL {args.action} — {e}')
        return 1


if __name__ == '__main__':
    sys.exit(main())
