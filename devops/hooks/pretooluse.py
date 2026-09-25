#!/usr/bin/env python3
"""devops PreToolUse hook — steer hand-crafted infra mutations to the safe verb.

Watches Bash commands. Two things trigger a steering systemMessage:

  1. A hand-crafted API mutation against the devops control plane —
     curl/http/xh/wget with a mutating method (DELETE/PUT/POST/PATCH) hitting
     devops.golia.jp/api/... . That bypasses the CLI primitive and, with it,
     the red-line confirm/diff/audit. The message points back to
     `devops <verb>` and the capability manifest.

  2. `devops caddy deploy ... --force` — a real CLI verb, but a red line: it
     overwrites the entire live Caddyfile. The message reminds to review drift
     first.

Soft inject only (systemMessage, exit 0) — same contract as port-registry's
hook. Never blocks; a false positive costs ~60 tokens, a false negative is a
skipped red line. Errors are swallowed (exit 0, empty stdout) so the hook can
never wedge Claude's flow.
"""
import sys
import json
import re
import os
from datetime import datetime

_LOG = os.environ.get('DEVOPS_HOOK_LOG')


def _log(msg: str) -> None:
    if not _LOG:
        return
    try:
        with open(_LOG, 'a') as f:
            f.write(f'{datetime.now().isoformat()} {msg}\n')
    except Exception:
        pass


# A raw HTTP client…
_HTTP_CLIENT = r'\b(curl|http|xh|wget|https)\b'
# …with a mutating method…
_MUTATING_METHOD = r'(-X\s*|--request\s*|-m\s*)?(DELETE|PUT|POST|PATCH)\b'
# …aimed at the devops API.
_DEVOPS_API = r'devops\.golia\.jp/api/'

_FORCE_DEPLOY = re.compile(r'\bdevops\s+caddy\s+deploy\b.*--force', re.IGNORECASE)


def hand_crafted_mutation(cmd: str) -> bool:
    """curl/http/xh/wget + a mutating method + the devops API host, in any order."""
    if not re.search(_HTTP_CLIENT, cmd, re.IGNORECASE):
        return False
    if not re.search(_DEVOPS_API, cmd, re.IGNORECASE):
        return False
    # A plain GET to the API is fine (reads are safe). Flag only when a
    # mutating method is explicit, OR a body is being sent (-d/--data/--json)
    # which implies a write.
    if re.search(_MUTATING_METHOD, cmd):
        return True
    if re.search(r'(-d\b|--data\b|--data-raw\b|--json\b|-F\b)', cmd):
        return True
    return False


MUTATION_MSG = (
    "This looks like a hand-crafted mutation against the devops API "
    "(devops.golia.jp/api/...). Do NOT change infra this way — the raw call "
    "skips the red-line confirm/diff/audit that the CLI primitive enforces. "
    "Use the blessed verb instead: `devops dns add|rm`, `devops caddy add|rm|set-block`, "
    "`devops deploy`, `devops secrets`, etc. Find the exact one with "
    "`curl -s https://devops.golia.jp/api/meta/capabilities | jq`. "
    "Load the `devops` skill for the red lines."
)

FORCE_DEPLOY_MSG = (
    "`caddy deploy --force` regenerates the ENTIRE live Caddyfile from the "
    "store and overwrites it — any live-only site disappears. This is a red "
    "line: run `devops caddy drift <device>` and review the diff FIRST. To "
    "remove one site use `devops caddy rm`; to change one site's block use "
    "`devops caddy set-block` — both print the change and confirm before "
    "forcing. Load the `devops` skill."
)


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        _log('invoked: malformed stdin')
        sys.exit(0)

    if payload.get('tool_name') != 'Bash':
        sys.exit(0)

    cmd = payload.get('tool_input', {}).get('command', '')
    if not cmd:
        sys.exit(0)

    if _FORCE_DEPLOY.search(cmd):
        _log(f'invoked: MATCH force-deploy cmd={cmd[:120]!r}')
        sys.stdout.write(json.dumps({"systemMessage": FORCE_DEPLOY_MSG}))
        sys.exit(0)

    if hand_crafted_mutation(cmd):
        _log(f'invoked: MATCH mutation cmd={cmd[:120]!r}')
        sys.stdout.write(json.dumps({"systemMessage": MUTATION_MSG}))
        sys.exit(0)

    _log(f'invoked: no-match cmd={cmd[:120]!r}')
    sys.exit(0)


if __name__ == '__main__':
    main()
