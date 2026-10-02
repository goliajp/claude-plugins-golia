#!/usr/bin/env bash
#
# rotation kernel — record a rotation.
#
# Usage:
#   trigger.sh              # default: manual
#   trigger.sh manual       # operator-initiated; needs an interactive terminal
#   trigger.sh self         # agent-self-initiated, gated by trig_gate.sh
#
# Effect:
#   1. `self` runs trig_gate.sh (TRIG-1..7); a FAIL blocks the trigger.
#   2. Reaps every stray child shell of this session (kill_stray_shells.sh).
#   3. Generates a unique rotation_id, writes it to .claude/autorun-intent.
#   4. Appends a schema-stable JSON line to rotations.jsonl, carrying the
#      effective rotation.conf values and the file's sha256; archives the
#      handoff the next session starts from under the new id.
#
# `manual` is the operator's override and only the operator has a
# terminal: without one on stdin it refuses (exit 3), so a model's shell
# cannot take this path.
#
# exit: 0 triggered · 1 blocked by the gate or the reaper · 2 usage /
#       configuration · 3 manual without a terminal

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

TRIGGER="${1:-manual}"
case "$TRIGGER" in
  self|manual|hook|daemon) ;;
  *)
    echo "trigger.sh: unknown trigger source '$TRIGGER'" >&2
    echo "  expected: self | manual | hook | daemon" >&2
    exit 2
    ;;
esac

# .claude/ must exist (handoff lives there too); fail loud if not.
if [ ! -d "$CLAUDE_DIR" ]; then
  echo "trigger.sh: $CLAUDE_DIR not found — is this a project with a .claude directory?" >&2
  exit 2
fi
if [ -n "$ROTATION_CONF_ERROR" ]; then
  echo "trigger.sh: $ROTATION_CONF_ERROR" >&2
  exit 2
fi

if [ "$TRIGGER" = "manual" ] && [ ! -t 0 ]; then
  echo "trigger.sh: manual needs an interactive terminal on stdin (the operator's override is not a path for a model's shell)" >&2
  exit 3
fi

# TRIG-1..7 pre-gate. Only self-triggered rotations are gated — manual is
# the operator's override path. See README → "TRIG-1..7 spec".
if [ "$TRIGGER" = "self" ]; then
  gate_out=$("$SCRIPT_DIR/trig_gate.sh" 2>&1)
  gate_rc=$?
  printf '%s\n' "$gate_out"
  gate_failed=$(printf '%s\n' "$gate_out" | grep -oE '^TRIG-[0-9]+ FAIL' | cut -d' ' -f1 | paste -sd, - )
  # gates in observe mode that would have failed: recorded, not enforced
  gate_observed=$(printf '%s\n' "$gate_out" | grep -oE '^TRIG-[0-9]+ OBSERVE' | cut -d' ' -f1 | paste -sd, - )
  autorun_record_event trigger.result \
    "trig=raw:$(python3 -c 'import json,sys; print(json.dumps({"result": sys.argv[1], "failed": [x for x in sys.argv[2].split(",") if x], "observed": [x for x in sys.argv[3].split(",") if x], "conf": json.loads(sys.argv[4])}))' \
      "$([ "$gate_rc" -eq 0 ] && echo PASS || echo FAIL)" "$gate_failed" "$gate_observed" "$(autorun_conf_json)")"
  if [ "$gate_rc" -ne 0 ]; then
    echo "trigger.sh: self trigger BLOCKED by TRIG gate (see lines above)" >&2
    echo "  · ship more first, or wait wall time, or fix the handoff's trigger section." >&2
    echo "  · operator override (terminal only): $SCRIPT_DIR/trigger.sh manual" >&2
    exit 1
  fi
fi

# HARD invariant (2026-08-02): a rotation may not close while ANY child
# process this round started survives — every watcher/poller/sleeper the
# round registered (event.sh process.start) is reaped mechanically here,
# not by agent discipline. Runs on every accepted trigger (self AND
# manual). rotation-276 incident: a watcher polling a pattern that never
# appears ran 6h into the next rotation because the ps-based audit
# truncated its command line; the reaper reads the registrations instead.
ROTATION_STATE_DIR="$STATE_DIR" ROTATION_EVENTS_LOG="$EVENTS_LOG" ROTATION_REAP_ROTATION_ID="$(autorun_current_rotation_id)" \
  "$SCRIPT_DIR/kill_stray_shells.sh" || {
  echo "trigger.sh: kill_stray_shells.sh FAILED — rotation close aborted" >&2
  exit 1
}

rotation_id=$(autorun_new_id)

# 0. the session that ends here, under the id it ran as, before the new id is written
autorun_record_event rotation.end "trigger=$TRIGGER" "next=$rotation_id"

# 1. intent file (read by the Stop hook; also a discoverable trace).
printf '%s\n' "$rotation_id" > "$INTENT_FILE"

# 2. JSON log line, and the handoff the new session starts from, kept under its id.
autorun_record_rotation "$rotation_id" "$TRIGGER"
if [ -f "$HANDOFF_FILE" ]; then
  mkdir -p "$HANDOFF_HISTORY"
  cp "$HANDOFF_FILE" "$HANDOFF_HISTORY/$rotation_id.md"
fi
autorun_after_write

# 3. Operator instructions. Compact, machine-greppable header line first.
project=$(autorun_project_name)
head=$(autorun_git_head)
echo "rotation $rotation_id triggered ($TRIGGER) · $project @ $head · kernel $ROTATION_KERNEL_VERSION conf ${ROTATION_CONF_SHA256:0:12}"
echo
echo "  intent: $INTENT_FILE"
echo "  log:    $ROTATIONS_LOG"
echo
echo "the new session inherits state from $HANDOFF_FILE (archived as $HANDOFF_HISTORY/$rotation_id.md)."
