#!/usr/bin/env python3
import ctypes
import re
import sys
from device import run_dir, checked, HERE

try:
    if len(sys.argv) not in (3, 4):
        raise RuntimeError('usage: shot.sh RUN_DIR NAME [x,y,w,h]')
    run = run_dir(sys.argv[1])
    name = sys.argv[2]
    if not re.fullmatch(r'[A-Za-z0-9_-]+', name):
        raise RuntimeError('screenshot name must be a simple artifact label')
    region = []
    if len(sys.argv) == 4:
        if not re.fullmatch(r'\d+,\d+,\d+,\d+', sys.argv[3]):
            raise RuntimeError('region must be x,y,w,h in points')
        region = ['-R' + sys.argv[3]]
    # Preflight does not request or change permission; no black/empty image is saved.
    cg = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
    cg.CGPreflightScreenCaptureAccess.restype = ctypes.c_bool
    if not cg.CGPreflightScreenCaptureAccess():
        raise RuntimeError('Screen Recording permission missing for the terminal/host running this command')
    folder = run / 'shots'
    folder.mkdir(exist_ok=True)
    out = folder / (name + '.png')
    temporary = folder / (name + '.capture.png')
    if out.exists() or temporary.exists():
        raise RuntimeError('artifact already exists; choose a new name')
    try:
        checked(['/usr/sbin/screencapture', '-x', '-m', *region, temporary])
        if not temporary.exists() or temporary.stat().st_size < 100:
            raise RuntimeError('Screen Recording capture failed: empty image')
        checked(['/usr/bin/osascript', '-l', 'JavaScript', HERE / 'check-image.js', temporary])
        temporary.rename(out)
    finally:
        if temporary.exists():
            temporary.unlink()  # Only this invocation's failed capture, never prior evidence.
    print(f'PASS screenshot file={out}')
except Exception as e:
    sys.exit('FAIL screenshot — ' + str(e))
