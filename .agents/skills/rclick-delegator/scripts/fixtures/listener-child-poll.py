import os, sys
if os.environ.get("RCLICK_FIXTURE_WARMUP") == "1":
    sys.exit(0)
import subprocess, sys
child = subprocess.Popen([sys.executable, '-c', 'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)'])
open(sys.argv[1], 'w').write(str(child.pid))
print('gpt-imple-3 idle 12:00:00', flush=True)
