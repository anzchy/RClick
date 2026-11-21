import os, signal, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
open(sys.argv[1] + '.tmp', 'w').write('{} {}'.format(os.getpid(), os.getppid()))
os.replace(sys.argv[1] + '.tmp', sys.argv[1])
time.sleep(60)
