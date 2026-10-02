#!/usr/bin/env bash
#
# rotation kernel — Claude Code `Stop` hook handler.
#
# Wired in by the plugin's hooks/hooks.json (`Stop`). Claude Code invokes
# this script when an agent turn ends, in the session's working directory;
# lib.sh resolves the project root from it. Two jobs:
#
#   1. every turn end runs the project's after-write hook
#      (ROTATION_AFTER_WRITE_CMD), so whatever the project derives from
#      the state (a dashboard) is refreshed;
#   2. while an intent is pending — trigger.sh wrote .claude/autorun-intent
#      (rotation_id, single line) and appended the rotations.jsonl row for
#      the same rid — the INV-1..5 gate (check.sh) runs at every turn end:
#      green consumes the intent, red keeps it so the next turn end retries
#      once the agent has fixed the failed invariant (saved the handoff,
#      committed the tree) without re-running trigger.sh.
#
# The intent is the only sentinel, consumed exactly once on the green path.
#
# Why we call check.sh WITHOUT the rid: trigger.sh has already appended
# rotation_id to rotations.jsonl by the time this hook fires. If we
# passed the rid, INV-5 (rotation_id-uniqueness-in-jsonl) would always
# FAIL → the intent would never be consumed. INV-5's true call-site is
# the self-test (which simulates duplicate rids explicitly); the
# stop-hook path must omit the rid → INV-5 SKIPs. See README
# §"INV-1..5 spec" for full rationale.
#
# Always exits 0: a hook failure must never break the user's turn.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
# every turn end refreshes whatever the project derives from the state (dashboard)
autorun_after_write

# No intent ⇒ this is just a normal turn-end. Nothing to do.
if [ ! -f "$INTENT_FILE" ]; then
  exit 0
fi

rid=$(head -1 "$INTENT_FILE" 2>/dev/null | tr -d '[:space:]')
if [ -z "$rid" ]; then
  echo "stop_hook: $INTENT_FILE is empty, ignoring" >&2
  exit 0
fi

# Run the INV-1..5 pre-act gate. Pass NO rid — see header comment for
# why (INV-5 would otherwise always FAIL since trigger.sh already
# appended the rid to jsonl before this hook ran).
if "$SCRIPT_DIR/check.sh" >&2; then
  rm -f "$INTENT_FILE"
  echo "stop_hook: rotation $rid green · INV-1..5 pass · intent consumed" >&2
else
  # Red: leave intent in place so the agent can retry next turn-end
  # after fixing the failed INV (typically: re-save handoff, commit
  # working tree).
  echo "stop_hook: rotation $rid blocked by INV check · intent kept" >&2
fi

exit 0
