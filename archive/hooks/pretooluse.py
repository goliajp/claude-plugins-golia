#!/usr/bin/env python3
"""archive PreToolUse hook — steer bare file moves inside the pandanas archive
to the five write entry points.

The archive at /volume1/PandanasShared keeps append-only ledgers (PLACED,
RENAME-LOG, SUPERSEDE-LOG, DELETION-LOG, EXCLUSION-LIST) that are the only
instrument able to answer "what did we lose". A bare `mv` / `rm` / `cp` /
`rmdir` inside it desynchronises those ledgers from the disk silently — the
command succeeds, and the damage shows up only when someone later asks a
question the ledgers can no longer answer.

Two triggers:

  1. A mutating shell command whose target looks like the archive
     (/volume1/PandanasShared, ~/nas/pandanas, or a bare top-level entity dir
     reached after cd'ing there). Steers to relocate/supersede/remove/unpack.

  2. Deleting a registered source (stsync, PandaSSD, the rescue mirror).
     That is allowed only once srccover.py reports zero unplaced for it.

Soft inject only (systemMessage, exit 0) — never blocks. A false positive costs
~60 tokens; a false negative costs a ledger that no longer matches reality.
Errors are swallowed so the hook can never wedge the flow.
"""
import sys
import json
import re
import os
from datetime import datetime

_LOG = os.environ.get('ARCHIVE_HOOK_LOG')


def _log(msg: str) -> None:
    if not _LOG:
        return
    try:
        with open(_LOG, 'a') as f:
            f.write(f'{datetime.now().isoformat()} {msg}\n')
    except Exception:
        pass


# Where the archive lives, however it is reached.
_ARCHIVE_PATH = re.compile(
    r'(/volume1/PandanasShared|~/nas/pandanas|/Users/[^/\s]+/nas/pandanas)')

# A command that changes the filesystem. `cp` counts: a copy into the archive
# creates a file with no PLACED row, which reads as an orphan forever after.
_MUTATING = re.compile(
    r'(?:^|[;&|]\s*|\s)(mv|rm|cp|rsync|rmdir|install|ln|truncate|chmod|chown)\s',
    re.IGNORECASE)

# The sanctioned entry points. If one of these is in the command, the write is
# already going through the ledgers — say nothing.
_BLESSED = re.compile(
    r'\.staging/(relocate|supersede|remove|unpack|unpackx|annul|repoint|'
    r'plclean|exclzip|srcledger|srccover|fixcount|catcount|prosecount|roster|'
    r'mdsync|check)\.py')

# Deleting a registered source.
_SOURCE_DELETE = re.compile(
    r'(?:^|[;&|]\s*|\s)rm\s+[^|;&]*\b(stsync|PandaSSD|golianas-rescue-\d{4}-\d{2}-\d{2})\b')

ARCHIVE_MSG = (
    "This writes into the pandanas archive without going through its ledgers. "
    "The archive answers 'what did we lose' only while PLACED/RENAME-LOG/"
    "SUPERSEDE-LOG/DELETION-LOG match the disk, and a bare mv/rm/cp breaks that "
    "silently. Use the entry point instead: `.staging/relocate.py` (move or "
    "rename), `.staging/supersede.py` (demote an older version), "
    "`.staging/remove.py` (delete — it re-measures the survivor at deletion "
    "time), `.staging/unpack.py` / `unpackx.py` (open an archive), "
    "`.staging/annul.py` (retract a demotion). Load the `archive-ingest` skill; "
    "the protocol is INGEST.md in the archive root."
)

SOURCE_MSG = (
    "This deletes a registered source. A source may only be deleted once "
    "`python3 .staging/srccover.py <id>` reports **0 unplaced** for it, "
    "`check.py` passes, and the archive-side copies were re-measured at "
    "deletion time — not read off an earlier report. Check first, then set the "
    "source's state to `retired` in SOURCES.tsv. Load the `archive-ingest` skill."
)


def touches_archive(cmd: str) -> bool:
    if _BLESSED.search(cmd):
        return False
    if not _MUTATING.search(cmd):
        return False
    return bool(_ARCHIVE_PATH.search(cmd))


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

    if _SOURCE_DELETE.search(cmd) and not _BLESSED.search(cmd):
        _log(f'invoked: MATCH source-delete cmd={cmd[:120]!r}')
        sys.stdout.write(json.dumps({"systemMessage": SOURCE_MSG}))
        sys.exit(0)

    if touches_archive(cmd):
        _log(f'invoked: MATCH archive-write cmd={cmd[:120]!r}')
        sys.stdout.write(json.dumps({"systemMessage": ARCHIVE_MSG}))
        sys.exit(0)

    _log(f'invoked: no-match cmd={cmd[:120]!r}')
    sys.exit(0)


if __name__ == '__main__':
    main()
