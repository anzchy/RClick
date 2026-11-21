"""Pay fresh-export Gatekeeper costs before any subprocess test budget starts."""
import os
from pathlib import Path
import subprocess
import sys

SCRIPTS = Path(__file__).resolve().parent


def fixture_paths():
    # Include PATH aliases as well as targets, and interpreted listener fixtures.
    return sorted(p for p in (SCRIPTS / "fixtures").rglob("*")
                  if p.is_file() and (os.access(p, os.X_OK) or
                                     p.name.startswith("listener-") and p.suffix == ".py"))


def warm_up():
    env = {**os.environ, "RCLICK_FIXTURE_WARMUP": "1"}
    for path in fixture_paths():
        command = [str(path)] if os.access(path, os.X_OK) else [sys.executable, str(path)]
        subprocess.run(command, env=env, check=True, capture_output=True)
    for name in ("reset.sh", "poll-idle.sh", "poll-handoff.sh", "poll-report.py"):
        path = SCRIPTS / name
        # The Python entry point has a Mac-only shebang; timed callers use their interpreter too.
        command = [sys.executable, str(path)] if path.suffix == ".py" else [str(path)]
        subprocess.run([*command, "--help"], check=True, capture_output=True)
