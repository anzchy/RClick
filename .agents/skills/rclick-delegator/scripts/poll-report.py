#!/opt/homebrew/bin/python3
"""Observe a task-specific report and agent status without reading pane scrollback."""

import json
import os
import subprocess
import sys
import time
from pathlib import Path


GET_FAILURE_LIMIT = 5


class AgentLookupError(RuntimeError):
    """A failed get may recover on the next polling tick."""


def agent_info(agent, terminal):
    try:
        result = subprocess.run(
            [os.environ.get("RCLICK_HERDR") or "herdr", "agent", "get", agent], capture_output=True, text=True, timeout=20,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise AgentLookupError("herdr agent get failed: " + str(error)) from error
    if result.returncode:
        raise AgentLookupError("herdr agent get failed: " + (result.stderr.strip() or str(result.returncode)))
    payload = json.loads(result.stdout)
    envelope = payload.get("result") if isinstance(payload, dict) else None
    if not isinstance(envelope, dict) or envelope.get("type") != "agent_info":
        raise ValueError("herdr agent get returned an invalid agent_info envelope")
    record = envelope.get("agent")
    if not isinstance(record, dict):
        raise ValueError("herdr agent get returned a missing agent identity")
    if not terminal or record.get("terminal_id") != terminal:
        raise ValueError(f"terminal mismatch for {agent}: expected {terminal}, got {record.get('terminal_id')}")
    status = record.get("agent_status")
    if status not in ("working", "idle", "done", "blocked"):
        raise ValueError("unexpected agent_status: " + str(status))
    return record


def _status(agent, terminal):
    return agent_info(agent, terminal)["agent_status"]


def _fresh_report(report, created_at, marker):
    return report_evidence(report, created_at, marker) == "ready"


def report_evidence(report, created_at, marker):
    """Require one exact `Report-Task: <task ID>` line in a fresh report."""
    try:
        report = Path(report)
        if not report.is_file():
            return "missing"
        if report.stat().st_mtime < created_at:
            return "stale"
        identities = [line for line in report.read_text(errors="replace").splitlines()
                      if line.startswith("Report-Task:")]
        return "ready" if identities == ["Report-Task: " + marker] else "stale"
    except FileNotFoundError:
        return "missing"


def watch(pane, report, created_at, marker, interval, max_minutes, idle_grace_seconds,
          get_status=None, sleep=time.sleep, monotonic=time.monotonic, agent_terminal=None):
    if get_status is None:
        get_status = lambda pane: _status(pane, agent_terminal)
    report = Path(report)
    started = monotonic()
    idle_since = None
    failures = 0
    while True:
        now = monotonic()
        try:
            status = get_status(pane)
        except AgentLookupError as error:
            failures += 1
            idle_since = None
            if failures >= GET_FAILURE_LIMIT:
                raise AgentLookupError(f"{GET_FAILURE_LIMIT} consecutive lookup failures: {error}") from error
            if now - started >= max_minutes * 60:
                return "timeout"
            sleep(min(interval, max_minutes * 60 - (now - started)))
            continue
        failures = 0
        if status == "blocked":
            return "blocked"
        if status in ("idle", "done"):
            if _fresh_report(report, created_at, marker):
                return "done"
            if idle_since is None:
                idle_since = now
            if now - idle_since >= idle_grace_seconds:
                return "missing-handoff"
        else:
            idle_since = None
        if now - started >= max_minutes * 60:
            return "timeout"
        sleep(min(interval, max_minutes * 60 - (now - started)))


if __name__ == "__main__":
    if sys.argv[1:] == ["--help"]:
        print("Usage: poll-report.py agent report config marker seconds minutes grace pane terminal")
        sys.exit(0)
    if sys.argv[1] == "--get-failure-limit":
        print(GET_FAILURE_LIMIT)
        sys.exit(0)
    if sys.argv[1] == "--agent-info":
        try:
            print(json.dumps(agent_info(*sys.argv[2:]), separators=(",", ":")))
        except AgentLookupError as error:
            print(str(error), file=sys.stderr)
            sys.exit(75)
        sys.exit(0)
    agent, path, config_path, marker, seconds, minutes, grace, pane, terminal = sys.argv[1:]
    created = json.loads(Path(config_path).read_text())["created_at"]
    outcome = watch(pane, path, float(created), marker, float(seconds), float(minutes), float(grace),
                    agent_terminal=terminal)
    print(agent + " " + outcome, flush=True)
