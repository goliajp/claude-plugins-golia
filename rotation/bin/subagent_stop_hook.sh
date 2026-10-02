#!/usr/bin/env bash
# SubagentStop hook. Claude Code runs it in the session that spawned the
# subagent, with the agent's id on stdin. When that id is one the session
# registered through agent_log.sh, the end is put on record mechanically,
# so neither the executor nor the manager has to notice it:
#   the executor (role rotation)   agent.stop  — the round's executor finished a reply
#                                                (its final report, or an answer to a SendMessage)
#   any other registered agent     agent.end   — a worker the executor was waiting for is done; the
#                                                watchdog's WAKE reads it (recorded once: a later
#                                                agent_log.sh end for the same agent is the usual second row)
# An id the events do not know is somebody else's agent: nothing is written.
# Always exits 0: a hook failure must never break the session.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
[ -f "$EVENTS_LOG" ] || exit 0
input=$(cat)
pairs=$(python3 - "$EVENTS_LOG" "$input" <<'PY'
import json, sys
hook = json.loads(sys.argv[2] or "{}")
agent_id = hook.get("agent_id") or ""
if not agent_id:
    raise SystemExit
# the latest agent.start carrying this id, and whether an agent.end of the same name followed it
start, ended = None, False
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            continue
        a = e.get("agent") or {}
        if e.get("kind") == "agent.start" and a.get("id") == agent_id:
            start, ended = a, False
        elif e.get("kind") == "agent.end" and start and a.get("name") == start.get("name"):
            ended = True
if start is None:
    raise SystemExit
doc = {"name": start.get("name"), "role": start.get("role"), "model": start.get("model"), "id": agent_id}
if start.get("role") == "rotation":
    kind = "agent.stop"
elif not ended:
    kind, doc["status"] = "agent.end", "ok"
else:
    raise SystemExit
print(kind)
print("agent=raw:" + json.dumps(doc, ensure_ascii=False))
print("hook=raw:" + json.dumps({"event": "SubagentStop", "agentType": hook.get("agent_type"),
                                 "transcript": hook.get("agent_transcript_path")}, ensure_ascii=False))
PY
) || exit 0
[ -n "$pairs" ] || exit 0
kind=$(printf '%s\n' "$pairs" | sed -n 1p)
autorun_record_event "$kind" "$(printf '%s\n' "$pairs" | sed -n 2p)" "$(printf '%s\n' "$pairs" | sed -n 3p)"
exit 0
