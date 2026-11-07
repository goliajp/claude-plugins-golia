#!/usr/bin/env bash
#
# rotation kernel — every lane of the project on one page. Read-only.
#
# usage: lanes.sh [--json]
#
# One line per lane — the first lane (named by ROTATION_LANE_NAME in its conf, else `main`), then each
# .claude/rotation-lanes/<lane>/ — each read in that lane's own environment:
#   <name> branch=<ROTATION_BASE_BRANCH or -> rid=<the round in progress: intent, last row, rotation.current>
#   head=<the lane's head: its branch for a lane, HEAD for the first lane> last=<kind>@<at of the last event>
#   executors=<n>[:<name>(<id>),…] (rotation executors with an agent.start and no agent.end) manager=<yes|no>
#   (manager.active present)
# then one line for the open windows (window.sh; read from every lane's events log):
#   windows: none open · or · windows: <name>(host=<h> until=<ISO> overdue=yes|no), …
# and one for the path claims in force (claim.sh; one file for every lane):
#   claims: <n> · or · claims: <n> (<lane>:<n>, …)
# --json: the same as a JSON array of objects {lane, value, branch, rid, head, lastEvent: {kind, at},
# executors: [{name, id}], managerActive}; `value` is the ROTATION_LANE the lane's shims export ("" for the
# first lane). Unknown fields are null. The windows and claims are not in it (`window.sh status --json`, `claim.sh
# list --json` list them).
#
# exit: 0 · 2 usage

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "${1:-}" = --one ]; then
  # internal: one lane's row as one JSON line, in that lane's environment (ROTATION_LANE set by the caller)
  . "$SCRIPT_DIR/lib.sh"
  export ROTATION_REPO="$PROJECT_DIR"
  export ROTATION_EVENTS_LOG="$EVENTS_LOG"
  export ROTATION_ROTATIONS_LOG="$ROTATIONS_LOG"
  export ROTATION_MANAGER_ACTIVE="$MANAGER_ACTIVE_FILE"
  export ROTATION_AGENT_ORIGIN_PATTERN="$AGENT_ORIGIN_PATTERN"
  scene=$(python3 "$SCRIPT_DIR/recover_lib.py" recover --json --no-probe 2>/dev/null)
  last=$(tail -1 "$EVENTS_LOG" 2>/dev/null)
  manager=false
  [ -f "$MANAGER_ACTIVE_FILE" ] && manager=true
  python3 - "$2" "$ROTATION_LANE" "${ROTATION_BASE_BRANCH:-}" "$(autorun_current_rotation_id)" "$(autorun_git_head)" "$last" "$scene" "$manager" <<'PY'
import json, sys
name, value, branch, rid, head, last, scene, manager = sys.argv[1:9]
try:
    ev = json.loads(last) if last else None
except json.JSONDecodeError:
    ev = None
try:
    executors = [{"name": a.get("name"), "id": a.get("id")} for a in (json.loads(scene).get("executors") or [])]
except json.JSONDecodeError:
    executors = None
print(json.dumps({"lane": name, "value": value, "branch": branch or None, "rid": rid or None,
                  "head": None if head == "unknown" else head,
                  "lastEvent": {"kind": ev.get("kind"), "at": ev.get("at")} if isinstance(ev, dict) else None,
                  "executors": executors, "managerActive": manager == "true"}, ensure_ascii=False))
PY
  exit 0
fi

JSON=0
case "$#:${1:-}" in
  0:) ;;
  1:--json) JSON=1 ;;
  *) echo "usage: lanes.sh [--json]" >&2; exit 2 ;;
esac
. "$SCRIPT_DIR/lib.sh"
. "$SCRIPT_DIR/lane_lib.sh"

rows=""
while IFS='|' read -r -u 3 val name; do
  row=$(env -u ROTATION_STATE_DIR -u ROTATION_CONF -u ROTATION_PROJECT_SH -u ROTATION_EVENTS_LOG -u ROTATION_ROTATIONS_LOG \
    -u HARDEV_EVENTS_LOG -u HARDEV_ROTATIONS_LOG -u ROTATION_MANAGER_ACTIVE -u ROTATION_REPO \
    ROTATION_LANE="$val" ROTATION_PROJECT_DIR="$PROJECT_DIR" bash "$SCRIPT_DIR/lanes.sh" --one "$name" </dev/null)
  rows="$rows$row
"
done 3< <(autorun_lanes)

printf '%s' "$rows" | python3 -c '
import json, sys
rows = [json.loads(l) for l in sys.stdin if l.strip()]
if sys.argv[1] == "1":
    print(json.dumps(rows, ensure_ascii=False, indent=1))
    raise SystemExit
for r in rows:
    ev = r["lastEvent"]
    ex = r["executors"]
    exs = "?" if ex is None else str(len(ex)) + (":" + ",".join("%s(%s)" % (a["name"], a["id"] or "no-id") for a in ex) if ex else "")
    print("%-12s branch=%s rid=%s head=%s last=%s executors=%s manager=%s" % (
        r["lane"], r["branch"] or "-", r["rid"] or "-", r["head"] or "-",
        "%s@%s" % (ev["kind"], ev["at"]) if ev else "-", exs, "yes" if r["managerActive"] else "no"))
' "$JSON"
[ "$JSON" -eq 1 ] && exit 0
wins=$(ROTATION_REPO="$PROJECT_DIR" ROTATION_EVENTS_LOG="$EVENTS_LOG" ROTATION_ROTATIONS_LOG="$ROTATIONS_LOG" \
  ROTATION_WINDOW_LOGS="$(autorun_window_logs)" python3 "$SCRIPT_DIR/recover_lib.py" windows --json)
printf '%s' "$wins" | python3 -c '
import json, sys
rows = json.loads(sys.stdin.read() or "[]")
print("windows: " + (", ".join("%s(host=%s until=%s overdue=%s)" % (w["name"], w["host"] or "-", w["untilAt"] or "-", "yes" if w["overdue"] else "no") for w in rows) or "none open"))
'
bash "$SCRIPT_DIR/claim.sh" list --json | python3 -c '
import collections, json, sys
rows = json.loads(sys.stdin.read() or "[]")
by = collections.Counter(r["lane"] for r in rows)
print("claims: %d" % len(rows) + (" (" + ", ".join("%s:%d" % kv for kv in sorted(by.items())) + ")" if rows else ""))
'
