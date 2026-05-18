#!/usr/bin/env python3
"""Port-registry PreToolUse hook.

Watches Bash commands; if the command looks like it starts a local server that
binds a TCP port, injects a systemMessage reminding Claude to consult the
port-registry skill before running.

Wide pattern matching is intentional — a false positive costs ~70 tokens of
reminder; a false negative is the original pain point (Metro silently binding
8081 and clashing). Errors are swallowed silently (exit 0, empty stdout) so
the hook never breaks Claude's flow.
"""
import sys
import json
import re
import os
from datetime import datetime

# Optional debug log — set PORT_REGISTRY_HOOK_LOG=/tmp/foo.log to capture
# every invocation. Off by default; no perf cost beyond an env lookup.
_LOG = os.environ.get('PORT_REGISTRY_HOOK_LOG')


def _log(msg: str) -> None:
    if not _LOG:
        return
    try:
        with open(_LOG, 'a') as f:
            f.write(f'{datetime.now().isoformat()} {msg}\n')
    except Exception:
        pass

SERVER_PATTERNS = [
    # Node ecosystem: bun/npm/yarn/pnpm/deno run dev|start|ios|android|serve|preview|...
    r'\b(bun|npm|yarn|pnpm|deno)\s+(run\s+)?(dev|start|ios|android|web|serve|server|preview|watch)\b',
    # Direct dev-server CLIs
    r'\bmetro\b',
    r'\bvite\b(?!\s+build)',
    r'\bnext\s+(dev|start)\b',
    r'\bwebpack-dev-server\b',
    r'\bnodemon\b',
    # Python web frameworks
    r'\buvicorn\b',
    r'\bgunicorn\b',
    r'\bfastapi\s+dev\b',
    r'\bflask\s+run\b',
    r'\bdjango.*runserver\b',
    r'python\s+\S*manage\.py\s+runserver',
    r'python\s+-m\s+http\.server',
    # Ruby
    r'\brails\s+(server|s)\b',
    # Go
    r'\bgo\s+run\b.*\.go',
    # Rust
    r'\bcargo\s+(run|watch)\b',
    # Misc dev servers
    r'\bcaddy\s+(run|start)\b',
    r'\blivereload\b',
    r'\bhttp-server\b',
    r'\bhttpserver\b',
    r'\bbrowser-sync\b',
    r'\bserve\s+(-p|--port|\.)',
]

_COMPILED = [re.compile(p, re.IGNORECASE) for p in SERVER_PATTERNS]


def looks_like_server_start(cmd: str) -> bool:
    return any(p.search(cmd) for p in _COMPILED)


REMINDER = (
    "This command likely starts a local service that binds a TCP port. "
    "Consult the port-registry skill BEFORE running: look up the registered "
    "port for this project (or allocate one), verify it's free with lsof, "
    "and pass it via PORT env or --port flag. If startup fails with "
    "EADDRINUSE, follow the conflict-resolution flow."
)


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        _log('invoked: malformed stdin')
        sys.exit(0)

    tool = payload.get('tool_name')
    if tool != 'Bash':
        _log(f'invoked: non-Bash tool={tool}')
        sys.exit(0)

    cmd = payload.get('tool_input', {}).get('command', '')
    if not cmd:
        _log('invoked: empty Bash command')
        sys.exit(0)

    if not looks_like_server_start(cmd):
        _log(f'invoked: no-match cmd={cmd[:120]!r}')
        sys.exit(0)

    _log(f'invoked: MATCH cmd={cmd[:120]!r}')
    sys.stdout.write(json.dumps({"systemMessage": REMINDER}))
    sys.exit(0)


if __name__ == '__main__':
    main()
