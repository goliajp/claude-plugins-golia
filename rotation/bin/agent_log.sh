#!/usr/bin/env bash
#
# Record an agent's start or end in events.jsonl, so the dashboard can list
# what is running and what ran, and recover.sh can continue it by id. The
# caller (the session that launches the agent) runs this before and after
# the Agent call; nothing here depends on a hook.
#
# usage:
#   agent_log.sh start <name> <role> <model> [task] [report]
#   agent_log.sh end   <name> <role> <model> [task] [report]
#     role   : rotation | worker | reviewer | research (a read-only study agent, no commits)
#              | manager (a segment the manager session did itself)
#     end    : ROTATION_AGENT_STATUS=ok|fail|abandoned (default ok)
#   `start … rotation` also records a `rotation.start` event (mode=subagent,
#   rotationAgent=<name>, agent={name,id}): the round's active start. Both
#   events carry managerSession = CLAUDE_CODE_SESSION_ID of the caller (null
#   when unset): the executor can be continued by SendMessage only from that
#   session, so recover.sh offers RESUME only when the ids are equal.
#   written into the event when set (what a restarted session needs to
#   continue the agent or take over its work):
#     ROTATION_AGENT_ID        the id the Agent call returned (SendMessage target)
#                              REQUIRED for `start … rotation`: an executor registered
#                              without an id cannot be resumed after a restart, and a
#                              `RESUME name:<x>` line is a dead end in a new session
#     ROTATION_AGENT_WORKTREE  the worker's worktree path
#     ROTATION_AGENT_SCRATCH   its scratch directory on the runner
#     ROTATION_AGENT_GATE_LOG  the log of the gate it runs
#
# exit: 0 recorded · 2 usage (including a rotation start without ROTATION_AGENT_ID)

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

[ "$#" -ge 4 ] || { echo "usage: agent_log.sh start|end <name> <role> <model> [task] [report]" >&2; exit 2; }
PHASE=$1; NAME=$2; ROLE=$3; MODEL=$4; TASK="${5:-}"; REPORT="${6:-}"
case "$PHASE" in
  start|end) ;;
  *) echo "agent_log.sh: phase must be start or end, got '$PHASE'" >&2; exit 2 ;;
esac
case "$ROLE" in
  rotation|worker|reviewer|research|manager) ;;
  *) echo "agent_log.sh: role must be rotation | worker | reviewer | research | manager, got '$ROLE'" >&2; exit 2 ;;
esac
if [ "$ROLE" = rotation ] && [ "$PHASE" = start ] && [ -z "${ROTATION_AGENT_ID:-}" ]; then
  echo "agent_log.sh: a rotation executor must be registered with ROTATION_AGENT_ID=<the id the Agent call returned>" >&2
  exit 2
fi

# a rotation executor starting or ending moves the manager marker the
# resume hook reads: present while a round is being managed
if [ "$ROLE" = rotation ]; then
  if [ "$PHASE" = start ]; then
    mkdir -p "$(dirname "$MANAGER_ACTIVE_FILE")"
    printf 'rotation=%s executor=%s id=%s since=%s session=%s\n' "$(autorun_current_rotation_id 2>/dev/null || echo -)" "$NAME" "$ROTATION_AGENT_ID" "$(date -u +%FT%TZ)" "${CLAUDE_CODE_SESSION_ID:-null}" > "$MANAGER_ACTIVE_FILE"
  elif [ "${ROTATION_MANAGER_IDLE:-0}" = 1 ]; then
    rm -f "$MANAGER_ACTIVE_FILE"
  fi
fi

agent_json=$(python3 - "$PHASE" "$NAME" "$ROLE" "$MODEL" "$TASK" "$REPORT" "${ROTATION_AGENT_STATUS:-ok}" \
  "${ROTATION_AGENT_ID:-}" "${ROTATION_AGENT_WORKTREE:-}" "${ROTATION_AGENT_SCRATCH:-}" "${ROTATION_AGENT_GATE_LOG:-}" <<'PY'
import json, sys
phase, name, role, model, task, report, status = sys.argv[1:8]
doc = {"name": name, "role": role, "model": model, "task": task or None, "report": report or None}
for key, value in zip(("id", "worktree", "scratch", "gateLog"), sys.argv[8:12]):
    if value:
        doc[key] = value
if phase == "end":
    doc["status"] = status
print(json.dumps(doc, ensure_ascii=False))
PY
)
if [ "$ROLE" = rotation ] && [ "$PHASE" = start ]; then
  # the session registering the executor: the only one whose SendMessage reaches it (null when not in a session)
  session_json=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1] or None))' "${CLAUDE_CODE_SESSION_ID:-}")
  autorun_record_event "agent.$PHASE" "agent=raw:$agent_json" "managerSession=raw:$session_json"
  # a rotation executor starting is the round's active start: the wall the
  # active measure counts from (lib.sh autorun_round_measures) begins here,
  # not at the handover that opened the round
  autorun_record_event rotation.start "mode=subagent" "rotationAgent=$NAME" \
    "agent=raw:$(python3 -c 'import json,sys; print(json.dumps({"name": sys.argv[1], "id": sys.argv[2]}))' "$NAME" "$ROTATION_AGENT_ID")" \
    "managerSession=raw:$session_json"
else
  autorun_record_event "agent.$PHASE" "agent=raw:$agent_json"
fi
echo "agent_log: $PHASE $NAME ($ROLE, $MODEL) → $EVENTS_LOG"
