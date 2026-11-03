#!/usr/bin/env bash
#
# rotation kernel — close a lane's round and hand its result to the lane that merges it. Run by the lane's
# executor in the lane's worktree, through the lane's shim (`bash .claude/rotation-lanes/<lane>/lane_close.sh`),
# after the close checks and the handoff are done — in place of `trigger.sh self`:
#
#   1. git merge <ROTATION_MERGE_FROM>   (default develop; message `merge: <base> into <branch>`) — the round
#                                         closes on top of what the merging lane has, so the tag merges back cleanly
#   2. ROTATION_LANE_CLOSE_HOOK          (optional, project.sh or rotation.conf; run with sh -c in the worktree)
#                                         what the project regenerates after that merge
#   3. trigger.sh self                   the lane's trigger gate; blocked = nothing below happens
#   4. git tag lane/<lane>/<rid> HEAD    <rid> is the round that closed (the id its events carry)
#   5. the inbox row                     at ROTATION_INBOX_INSERT_LINE (default 65) of ROTATION_INBOX_FILE (default
#                                         .claude/autorun-inbox.md):
#                                         | <date> | lane/<lane>/<rid> ready · <N> commit · gate <N>/<F>/<S> | <handoff> |
#                                         N = commitsInSession of the row the trigger wrote; the gate triple = the
#                                         round's last gate.end; `?` where unknown
#   6. event lane.ready                  tag=<tag> ready={rid, head, commits, gate: {pass, fail, skip} | null,
#                                         mergedFrom, inboxLine, handoff}
#
# A merge conflict leaves the merge in progress for the executor to resolve (or `git merge --abort`) and
# prints the conflicted files. Run it again once resolved: the merge is then already done.
#
# usage: lane_close.sh
# exit: 0 tagged and announced · 1 a step failed (not a lane worktree on its branch, the tag exists, the hook,
#       the trigger gate) · 2 usage · 3 merge conflict

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ "$#" -eq 0 ] || { echo "usage: lane_close.sh" >&2; exit 2; }
. "$SCRIPT_DIR/lib.sh"
. "$SCRIPT_DIR/lane_lib.sh"
[ -n "$ROTATION_LANE" ] || { echo "lane_close: run it through a lane's shim (.claude/rotation-lanes/<lane>/lane_close.sh)" >&2; exit 2; }
g() { git -C "$PROJECT_DIR" "$@"; }

branch=$(g rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ -n "${ROTATION_BASE_BRANCH:-}" ] && [ "$branch" != "$ROTATION_BASE_BRANCH" ]; then
  echo "lane_close: $PROJECT_DIR is on '$branch', the lane's branch is $ROTATION_BASE_BRANCH (run it in the lane's worktree)" >&2
  exit 1
fi
rid=$(autorun_current_rotation_id)
[ -n "$rid" ] || { echo "lane_close: no round in progress for lane $ROTATION_LANE" >&2; exit 1; }
tag="lane/$ROTATION_LANE/$rid"
if g rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
  echo "lane_close: tag $tag exists already — this round was closed" >&2
  exit 1
fi
base="${ROTATION_MERGE_FROM:-develop}"

echo "lane_close: 1 merge $base into $branch"
if ! g merge --no-edit -m "merge: $base into $branch" "$base"; then
  conflicts=$(g diff --name-only --diff-filter=U)
  if [ -n "$conflicts" ]; then
    echo "lane_close: merge conflict — resolve and commit (or git merge --abort), then run lane_close.sh again:"
    printf '%s\n' "$conflicts" | sed 's/^/  /'
    exit 3
  fi
  echo "lane_close: git merge $base failed" >&2
  exit 1
fi

if [ -n "${ROTATION_LANE_CLOSE_HOOK:-}" ]; then
  echo "lane_close: 2 hook: $ROTATION_LANE_CLOSE_HOOK"
  (cd "$PROJECT_DIR" && sh -c "$ROTATION_LANE_CLOSE_HOOK") || { echo "lane_close: the close hook failed (exit $?)" >&2; exit 1; }
else
  echo "lane_close: 2 hook: none (ROTATION_LANE_CLOSE_HOOK unset)"
fi

echo "lane_close: 3 trigger.sh self"
bash "$SCRIPT_DIR/trigger.sh" self
rc=$?
[ "$rc" -eq 0 ] || { echo "lane_close: trigger.sh self exit $rc — no tag, no inbox row" >&2; exit 1; }

head=$(g rev-parse --short HEAD)
g tag "$tag" HEAD || { echo "lane_close: git tag $tag failed" >&2; exit 1; }
echo "lane_close: 4 tag $tag → $head"

# the round's numbers: the row the trigger just wrote, the round's last gate.end
nums=$(python3 - "$ROTATIONS_LOG" "$EVENTS_LOG" "$rid" <<'PY'
import json, sys
rows, events, rid = sys.argv[1:4]
def lines(path):
    try:
        with open(path) as f:
            for l in f:
                l = l.strip()
                if l:
                    try:
                        yield json.loads(l)
                    except json.JSONDecodeError:
                        pass
    except FileNotFoundError:
        return
commits = None
for r in lines(rows):
    commits = r.get("commitsInSession")
gate = None
for e in lines(events):
    if e.get("kind") == "gate.end" and e.get("rotationId") == rid and isinstance(e.get("gate"), dict):
        gate = {k: e["gate"].get(k) for k in ("pass", "fail", "skip")}
print(json.dumps({"commits": commits, "gate": gate}))
PY
)
row=$(python3 - "$nums" "$tag" "${HANDOFF_FILE#"$PROJECT_DIR"/}" <<'PY'
import datetime, json, sys
n, tag, handoff = json.loads(sys.argv[1]), sys.argv[2], sys.argv[3]
q = lambda v: "?" if v is None else str(v)
g = n["gate"] or {}
print(f"| {datetime.date.today().isoformat()} | {tag} ready · {q(n['commits'])} commit · gate {q(g.get('pass'))}/{q(g.get('fail'))}/{q(g.get('skip'))} | {handoff} |")
PY
)
at=$(autorun_inbox_insert "$row") || { echo "lane_close: writing $INBOX_FILE failed" >&2; exit 1; }
echo "lane_close: 5 inbox $INBOX_FILE:$at $row"

ready=$(python3 -c '
import json, sys
n = json.loads(sys.argv[1])
print(json.dumps({"rid": sys.argv[2], "head": sys.argv[3], "commits": n["commits"], "gate": n["gate"],
                  "mergedFrom": sys.argv[4], "inboxLine": int(sys.argv[5]), "handoff": sys.argv[6]}, ensure_ascii=False))' \
  "$nums" "$rid" "$head" "$base" "$at" "${HANDOFF_FILE#"$PROJECT_DIR"/}")
autorun_record_event lane.ready "tag=$tag" "ready=raw:$ready"
echo "lane_close: 6 event lane.ready → $EVENTS_LOG"
echo "LANE READY $tag head=$head"
