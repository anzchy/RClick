#!/usr/bin/env python3
import json, os, sys
if os.environ.get("RCLICK_FIXTURE_WARMUP") == "1": sys.exit(0)
from pathlib import Path
with open(os.environ['CALLS'], 'a') as f: f.write(json.dumps(['listener', *sys.argv[1:]]) + '\n')
if sys.argv[1] == 'start' and os.environ.get('CREATE_EVENT') == '1':
    event = sys.argv[sys.argv.index('--event')+1]
    (Path.home() / '.rclick-roster/herdr/delegator/listeners' / event).mkdir(parents=True)
print(os.environ.get('LISTENER_RESULT', 'started') + ' event=test')
sys.exit(int(os.environ.get('LISTENER_EXIT', '0')))
