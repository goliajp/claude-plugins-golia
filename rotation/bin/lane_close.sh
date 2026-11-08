#!/usr/bin/env bash
#
# rotation kernel — close a lane's round and hand its result to the lane that merges it. Run by the lane's
# executor in the lane's worktree, through the lane's shim (`bash .claude/rotation-lanes/<lane>/lane_close.sh`),
# after the close checks and the handoff are done — in place of `trigger.sh self`:
#
#   0. trace check                       before anything is merged: every commit of <merge-base>..HEAD
#                                         (merge-base of <base> below and HEAD) is read with `git log --format=%B`;
#                                         a message line matching ROTATION_AGENT_ORIGIN_PATTERN (default
#                                         ^Agent-Origin:) or ROTATION_TRACE_PATTERN (rotation.conf, default
#                                         Co-Authored-By|Generated with|generated with|🤖|[Cc]laude) is refused,
#                                         listed as sha and line. The handoff (HANDOFF_FILE) must carry every title
#                                         of ROTATION_HANDOFF_SECTIONS (rotation.conf, `|`-separated, default empty =
#                                         not checked): a line `#`..`######` + space whose text contains the title,
#                                         or a line starting `**` + the title (literal text, not a regexp); the
#                                         missing ones are listed. Either finding = exit 1, nothing merged or tagged.
#                                         Then ROTATION_LANE_CLOSE_PRECHECK (rotation.conf, default empty = none):
#                                         run with sh -c in the worktree, ROTATION_MERGE_BASE (the merge-base sha) and
#                                         ROTATION_HEAD (HEAD's sha) in its environment; non-zero = exit 1, nothing
#                                         merged or tagged, its last 20 output lines printed
#   1. git merge <base>                  (--merge-from REF, else ROTATION_MERGE_FROM, else develop; message
#                                         `merge: <base> into <branch>`) — the round
#                                         closes on top of what the merging lane has, so the tag merges back cleanly
#   2. ROTATION_LANE_CLOSE_HOOK          (optional, project.sh or rotation.conf; run with sh -c in the worktree)
#                                         what the project regenerates after that merge
#   3. trigger.sh self                   the lane's trigger gate; blocked = nothing below happens
#   4. git tag lane/<lane>/<rid> HEAD    <rid> is the round that closed (the id its events carry); then every
#                                         path claim of this lane in force from round <rid> is dropped
#                                         (claim.sh drop --rid <rid>, reason lane-close)
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
# usage: lane_close.sh [--merge-from REF]
#   --merge-from REF   the commit to merge this once (a round-end sha of the merging lane, say); the key in
#                      rotation.conf stays the standing default and the conf file is not touched
# exit: 0 tagged and announced · 1 a step failed (not a lane worktree on its branch, the tag exists, a trace
#       in a commit message or a missing handoff section, the precheck, the hook, the trigger gate) · 2 usage · 3 merge conflict

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MERGE_FROM_ARG=""
if [ "${1:-}" = --merge-from ]; then
  [ -n "${2:-}" ] || { echo "usage: lane_close.sh [--merge-from REF]" >&2; exit 2; }
  MERGE_FROM_ARG=$2; shift 2
fi
[ "$#" -eq 0 ] || { echo "usage: lane_close.sh [--merge-from REF]" >&2; exit 2; }
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
base="${MERGE_FROM_ARG:-${ROTATION_MERGE_FROM:-develop}}"

mb=$(g merge-base "$base" HEAD) || { echo "lane_close: no merge base of $base and HEAD" >&2; exit 1; }
# word boundaries: "regenerated with the tool" is not a trace (devline-09 rewrote 7 commits over it, 2026-11-09)
trace="${ROTATION_TRACE_PATTERN:-Co-Authored-By|\\b[Gg]enerated with|🤖|\\b[Cc]laude\\b}"
echo "lane_close: 0 trace check ${mb:0:9}..HEAD, handoff sections"
found=0
for sha in $(g rev-list "$mb..HEAD"); do
  hits=$(g log -1 --format=%B "$sha" | grep -nE -e "$AGENT_ORIGIN_PATTERN" -e "$trace")
  [ -n "$hits" ] || continue
  found=1
  echo "lane_close: commit ${sha:0:9} carries a trace:"
  printf '%s\n' "$hits" | sed 's/^/  /'
done
missing=$(python3 - "$HANDOFF_FILE" "${ROTATION_HANDOFF_SECTIONS:-}" <<'PY'
import re, sys
path, spec = sys.argv[1], sys.argv[2]
titles = [t.strip() for t in spec.split('|') if t.strip()]
try:
    text = open(path, encoding='utf-8').read().splitlines()
except OSError:
    text = []
for t in titles:
    e = re.escape(t)
    if not any(re.match(r'#{1,6} .*' + e, l) or re.match(r'\*\*' + e, l) for l in text):
        print(t)
PY
)
if [ -n "$missing" ]; then
  found=1
  echo "lane_close: the handoff $HANDOFF_FILE lacks section(s):"
  printf '%s\n' "$missing" | sed 's/^/  /'
fi
[ "$found" -eq 0 ] || { echo "lane_close: trace check failed — nothing merged, no tag" >&2; exit 1; }
if [ -n "${ROTATION_LANE_CLOSE_PRECHECK:-}" ]; then
  echo "lane_close: 0 precheck: $ROTATION_LANE_CLOSE_PRECHECK"
  pout=$(cd "$PROJECT_DIR" && ROTATION_MERGE_BASE="$mb" ROTATION_HEAD="$(g rev-parse HEAD)" sh -c "$ROTATION_LANE_CLOSE_PRECHECK" 2>&1)
  prc=$?
  if [ "$prc" -ne 0 ]; then
    echo "lane_close: the precheck failed (exit $prc) — nothing merged, no tag; its last 20 lines:"
    printf '%s\n' "$pout" | tail -20 | sed 's/^/  /'
    exit 1
  fi
fi

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
# the round's path claims end with it
bash "$SCRIPT_DIR/claim.sh" drop --rid "$rid" --reason lane-close | sed 's/^/lane_close: 4 /'

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
