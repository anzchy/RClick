import os, sys
if os.environ.get("RCLICK_FIXTURE_WARMUP") == "1":
    sys.exit(0)
import os, signal, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
open(sys.argv[1] + '.tmp', 'w').write('{} {}'.format(os.getpid(), os.getppid()))
os.replace(sys.argv[1] + '.tmp', sys.argv[1])
time.sleep(60)
