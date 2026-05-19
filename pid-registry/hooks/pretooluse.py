#!/usr/bin/env python3
"""pid-registry PreToolUse hook.

Detects backgrounded Bash invocations (`run_in_background: true`) and injects a
systemMessage reminding Claude to consult the pid-registry skill — so a `.pid`
handle is recorded for later lookup / safe kill.

Trigger is intentionally narrow: only fires when `run_in_background` is truthy.
Foreground bash, shell-`&` backgrounding, `nohup`, `disown` etc. are intentionally
NOT detected at v0.1 — they're rare in Claude Code sessions and the narrow trigger
keeps false positives near zero.

Errors are swallowed silently (exit 0, empty stdout) so the hook never breaks
Claude's flow.
"""
import sys
import json
import os
from datetime import datetime

# Optional debug log — set PID_REGISTRY_HOOK_LOG=/tmp/foo.log to capture every
# invocation (matched and not). Off by default; no perf cost beyond an env lookup.
_LOG = os.environ.get('PID_REGISTRY_HOOK_LOG')


def _log(msg: str) -> None:
    if not _LOG:
        return
    try:
        with open(_LOG, 'a') as f:
            f.write(f'{datetime.now().isoformat()} {msg}\n')
    except Exception:
        pass


REMINDER = (
    "This Bash call is run_in_background:true — it will outlast this turn. "
    "Consult the pid-registry skill BEFORE running: pick a semantic process "
    "name, then after launching, record a .pid handle at "
    "<project>/.claude/pid-registry/<name>.pid with pid / command / cwd / port "
    "/ verify_before_kill / kill fields. That handle is what lets you (or a "
    "future session) find and safely kill it later."
)


def main() -> None:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        _log('invoked: malformed stdin')
        sys.exit(0)

    tool = payload.get('tool_name')
    if tool != 'Bash':
        _log(f'invoked: non-Bash tool={tool}')
        sys.exit(0)

    tool_input = payload.get('tool_input', {}) or {}
    bg = tool_input.get('run_in_background')
    if not bg:
        cmd = tool_input.get('command', '')
        _log(f'invoked: no-match (bg={bg!r}) cmd={cmd[:80]!r}')
        sys.exit(0)

    cmd = tool_input.get('command', '')
    _log(f'invoked: MATCH cmd={cmd[:120]!r}')
    sys.stdout.write(json.dumps({"systemMessage": REMINDER}))
    sys.exit(0)


if __name__ == '__main__':
    main()
