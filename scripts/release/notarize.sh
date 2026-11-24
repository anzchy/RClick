#!/usr/bin/env bash
# Submit one artifact; credentials are used only in notarytool's authentication argv.
# Python captures and redacts service diagnostics before they reach the Actions log.
set +x
set -euo pipefail
umask 077

python3 -I - "$@" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys

names = ('APPLE_ID', 'APPLE_APP_SPECIFIC_PASSWORD', 'APPLE_TEAM_ID')
# Children receive no credential environment, including stapler in the calling step.
credentials = {name: os.environ.pop(name, '') for name in names}


def report(message, *, error=False):
    redactions = {form for value in credentials.values() if value
                  for form in (value, json.dumps(value)[1:-1])}
    for value in sorted(redactions, key=len, reverse=True):
        message = message.replace(value, '[REDACTED]')
    print(message, file=sys.stderr if error else sys.stdout)


def run(arguments):
    return subprocess.run(['xcrun', 'notarytool', *arguments, *authentication],
                          text=True, capture_output=True, check=False)


if len(sys.argv) != 2 or not Path(sys.argv[1]).is_file():
    report('usage: notarize.sh <file to notarize>', error=True)
    sys.exit(2)
missing = [name for name, value in credentials.items() if not value]
if missing:
    report('Missing notarization environment: ' + ', '.join(missing), error=True)
    sys.exit(2)

authentication = ['--apple-id', credentials['APPLE_ID'],
                  '--password', credentials['APPLE_APP_SPECIFIC_PASSWORD'],
                  '--team-id', credentials['APPLE_TEAM_ID']]
try:
    result = run(['submit', sys.argv[1], '--wait', '--timeout', '1h', '--output-format', 'json'])
    try:
        submission = json.loads(result.stdout)
        if not isinstance(submission, dict):
            raise ValueError('expected a JSON object')
    except ValueError:
        report('Notarization failed: invalid JSON response', error=True)
        report(result.stdout + result.stderr, error=True)
        sys.exit(1)

    status = submission.get('status', 'unknown')
    submission_id = submission.get('id', '')
    report(f'notarytool submission {submission_id}: {status}')
    if result.returncode != 0 or status != 'Accepted':
        report(f'Notarization failed (exit {result.returncode})', error=True)
        report(result.stdout + result.stderr, error=True)
        if isinstance(submission_id, str) and submission_id and not submission_id.startswith('-'):
            log = run(['log', submission_id])
            report(log.stdout + log.stderr, error=True)
            if log.returncode:
                report(f'notarytool log failed (exit {log.returncode})', error=True)
        sys.exit(1)
except OSError as error:
    report(f'Cannot run notarytool: {error}', error=True)
    sys.exit(1)
PY
