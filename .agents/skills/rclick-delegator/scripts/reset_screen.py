"""Classify one Codex screen and wait for reset evidence with an injectable clock."""

import json
import os
import re
import subprocess
import sys
import time


def footer(screen, proved=False):
    seen = started = proved
    clean = metadata = permissions_ok = False
    ctx = fence = ""
    # Slash commands are single /words; cwd metadata must be an unspaced home path
    # or a multi-component absolute path, never arbitrary slash-prefixed prose.
    def is_cwd(line):
        return bool(re.fullmatch(r"(?:~/\S+|/(?:[^/\s]+/)+[^/\s]*)", line))

    title = r">_ OpenAI Codex \(v[0-9][^)]*\)"
    # Codex 0.167 adds "← for agents · " before the shortcuts hint and may append "⚠ N warnings · f2 to view"
    # after a run of spaces; a hint line is any mix of these known parts (#34).
    hint_part = r"(?:← for agents · )?\? for (?:shortcuts|help|commands)|⚠ [0-9]+ warnings? · f2 to view"
    def is_hint(line):
        return bool(line) and all(re.fullmatch(hint_part, part) for part in re.split(r"\s{2,}", line))

    # Codex 0.167 prints "permissions: <mode>" under the cwd in the header.
    def is_permissions(line):
        return bool(re.fullmatch(r"permissions: [\w -]+", line))

    lines = screen.splitlines(keepends=True)
    last_title = None
    unfenced = set()
    for index, raw in enumerate(lines):
        line = raw.strip()
        if line.startswith(("```", "~~~")):
            mark = line[:3]
            fence = "" if fence == mark else fence or mark
        elif not fence:
            unfenced.add(index)
            if re.fullmatch(title, line):
                last_title = index
    fence = ""
    title_proof = False
    if last_title is not None:
        prefix = [line.strip() for line in lines[:last_title] if line.strip()]
        body = [line.strip() for line in lines[last_title + 1:] if line.strip()]
        # A fresh header after scrollback includes cwd metadata. Without it, an old
        # reply ending in an exact title would erase transcript evidence (#434).
        title_proof = (not prefix or
                       (len(prefix) == 1 and is_cwd(prefix[0])) or
                       bool(body and is_cwd(body[0])))
    # A short read can omit the title/cwd while retaining the full 17-row welcome
    # logo. Recognize its saved top/bottom signatures and contiguous braille rows,
    # never arbitrary decoration. A later title vetoes it. An earlier title must have
    # clean header metadata before a reset boundary or its own complete older logo;
    # otherwise dirty content between that title and this logo still vetoes it.
    logos = []
    for index in sorted(unfenced):
        block = [line.strip() for line in lines[index:index + 17]]
        if (len(block) == 17 and block[0] == "⣀⣤⣤⣤⣀⣀" and
                block[-1] == "⠈⠙⠛⠿⠿⠿⠿⠛⠉" and
                all(index + row in unfenced and re.fullmatch(r"[\s\u2800-\u28ff]+", line)
                    for row, line in enumerate(block))):
            logos.append(index)
    logo_proof = False
    for index in reversed(logos):
        separated = False
        if last_title is not None:
            if last_title > index:
                continue
            header = [(row, lines[row].strip()) for row in range(last_title + 1, index) if lines[row].strip()]
            clean_header = bool(header and is_cwd(header[0][1]))
            if clean_header:
                header = header[1:]
                if header and is_permissions(header[0][1]):
                    header = header[1:]
            if header:
                row, content = header[0]
                separated = clean_header and (row in logos or
                             bool(re.fullmatch(r"(?:(?:>|❯|›) )?/new", content)) or
                             content.startswith("Where should the new conversation run"))
                if not separated:
                    continue
        logo_proof = separated or not title_proof
        if logo_proof:
            lines = lines[index:]
            seen = started = clean = True
        break
    if not logo_proof and last_title is not None:
        lines = lines[last_title:]
    placeholder = False
    footer_hints = {"? for shortcuts", "? for help", "? for commands"}
    welcome = footer_hints | {"Tip: Use /help to see available commands."}
    for raw in lines:
        line = raw.strip()
        match = re.fullmatch(r"Context [0-9]+% used", line) or re.fullmatch(
            r"(?:GPT-|gpt-)\S+\s+[\w-]+\s+·\s+Context [0-9]+% used(?:\s+·.*)?", line)
        # A later footer replaces the result; otherwise only hints and blanks may
        # follow it. Revoke before processing dirty content, including fences/box art.
        if ctx and line and not is_hint(line) and not match:
            ctx = ""
            clean = False
            seen = proved
        if line.startswith(("```", "~~~")):
            mark = line[:3]
            fence = "" if fence == mark else fence or mark
            clean = metadata = False
            seen = proved
            continue
        if fence:
            continue
        if re.fullmatch(title, line):
            ctx = ""
            seen = started = clean = proved or title_proof
            metadata = True
            continue
        if line.startswith("Where should the new conversation run"):
            ctx = ""
            started = clean = metadata = False
            continue
        if re.fullmatch(r"(?:(?:>|❯|›) )?/new", line) or re.match(r"Starting MCP servers(?:\s|$)", line):
            ctx = ""
            started = proved
            clean = metadata = False
            continue
        if match:
            # Always replace ctx: a dirty transcript before the bottom-most footer
            # revokes the header even when an earlier clean footer was visible.
            ctx = re.search(r"Context [0-9]+% used", line).group() if started and (proved or (clean and (not logo_proof or placeholder))) else ""
            metadata = False
            continue
        if not line:
            continue
        # The worktree line immediately under the saved title is header metadata.
        if metadata and is_cwd(line):
            metadata = False
            permissions_ok = True
            continue
        metadata = False
        if permissions_ok and is_permissions(line):
            permissions_ok = False
            continue
        permissions_ok = False
        # One input placeholder; only blanks and known footer hints may follow it.
        # Tips, logo-like output, and duplicate placeholders remain transcript evidence.
        if line == "› Ask Codex to do anything" and not placeholder:
            placeholder = True
            continue
        if placeholder and not is_hint(line):
            clean = False
            seen = proved
            continue
        if line in welcome or is_hint(line) or all(c.isspace() or "\u2500" <= c <= "\u259f" or "\u2800" <= c <= "\u28ff" for c in line):
            continue
        clean = False
        seen = proved
    return bool(seen or ctx), ctx


def pane_session(payload):
    """Only the documented pane identity field is session evidence."""
    try:
        value = json.loads(payload)["result"]["pane"]["agent_session"]["value"]
        return value if isinstance(value, str) and value.strip() else ""
    except (ValueError, KeyError, TypeError):
        return ""


def wait_for_context(read, session, old_session, seconds, interval,
                     sleep=time.sleep, monotonic=time.monotonic):
    deadline = monotonic() + seconds
    boundary_seen = False
    while True:
        current = session()
        seen, context = footer(read(), bool(old_session and current and current != old_session))
        boundary_seen |= seen
        if context:
            return "context", context
        now = monotonic()
        if now >= deadline:
            return ("no-context" if boundary_seen else "no-boundary"), ""
        sleep(min(interval, deadline - now))


def outcome(name, old, seconds, kind, context):
    if kind == "no-boundary":
        return 1, f"FAIL reset {name}: no new-session boundary seen within {seconds}s; check the pane\n"
    if kind == "no-context":
        return 1, f"FAIL reset {name}: no context line after {seconds}s\n"
    if context != "Context 0% used":
        return 1, f"FAIL reset {name}: {context} after /new\n"
    return 0, f"reset {name} old_session={old} {context} (verify the session id changes after the next turn)\n"


def main(args):
    if args[0] == "session":
        print(pane_session(sys.stdin.read()))
        return 0
    name, pane, old_session, old, seconds, interval = args
    herdr = os.environ.get("RCLICK_HERDR") or "herdr"

    def get(*command):
        result = subprocess.run([herdr, "pane", *command], capture_output=True, text=True)
        return result.stdout + result.stderr

    kind, context = wait_for_context(
        lambda: get("read", pane, "--source", "recent-unwrapped", "--lines", "2000"),
        lambda: pane_session(get("get", pane)), old_session, float(seconds), float(interval))
    code, message = outcome(name, old, seconds, kind, context)
    print(message, end="")
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
