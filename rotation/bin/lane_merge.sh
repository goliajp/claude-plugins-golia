#!/usr/bin/env bash
#
# rotation kernel — merge a lane's closed round (the tag lane_close.sh made) into the lane that merges it, or
# hand it back. Run by that lane's executor in its own tree (for the first lane: the main tree, through
# .claude/rotation/lane_merge.sh); the events go to that lane's log.
#
#   lane_merge.sh <tag>
#     event lane.merge.start   tag=<tag> merge={branch, baseHead, tagHead}
#     git merge --no-ff -m "merge: <tag> into <branch>" <tag>
#     event lane.merge.end     tag=<tag> merge={status: ok|conflict|fail, commit (the merge commit, null unless ok),
#                              branch, baseHead}
#     A conflict leaves the merge in progress (resolve and commit, or git merge --abort) and prints the files.
#
#   lane_merge.sh --returned <tag> <reason> [<revert commit>]
#     event lane.returned      tag=<tag> returned={reason, revert (null when not given)}
#     the inbox row at ROTATION_INBOX_INSERT_LINE (default 65) of ROTATION_INBOX_FILE (default .claude/autorun-inbox.md):
#                              | <date> | <tag> returned · <reason>[ · revert <sha>] | .claude/rotation-lanes/<lane>/handoff.md |
#
# lane.ready (lane_close.sh), lane.merge.start / lane.merge.end and lane.returned share `tag`: one chain per tag.
#
# usage: lane_merge.sh <tag> | lane_merge.sh --returned <tag> <reason> [<revert commit>]
# exit: 0 · 1 no such tag / revert commit, or the merge failed · 2 usage · 3 merge conflict

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
usage() { echo "usage: lane_merge.sh <tag> | lane_merge.sh --returned <tag> <reason> [<revert commit>]" >&2; exit 2; }
MODE=merge
case "${1:-}" in
  --returned) [ "$#" -eq 3 ] || [ "$#" -eq 4 ] || usage; MODE=returned; TAG=$2; REASON=$3; REVERT="${4:-}" ;;
  ''|-*) usage ;;
  *) [ "$#" -eq 1 ] || usage; TAG=$1 ;;
esac
case "$TAG" in lane/*/*) ;; *) echo "lane_merge: a lane tag looks like lane/<lane>/<rid>, got '$TAG'" >&2; exit 2 ;; esac
TAG_LANE=$(printf '%s' "$TAG" | cut -d/ -f2)
case "$TAG_LANE" in ''|*[!a-z0-9-]*) echo "lane_merge: a lane tag looks like lane/<lane>/<rid>, got '$TAG'" >&2; exit 2 ;; esac
. "$SCRIPT_DIR/lib.sh"
. "$SCRIPT_DIR/lane_lib.sh"
g() { git -C "$PROJECT_DIR" "$@"; }
js() { python3 -c 'import json,sys; it=iter(sys.argv[1:]); print(json.dumps({k: (None if v == "" else v) for k, v in zip(it, it)}, ensure_ascii=False))' "$@"; }

tag_head=$(g rev-parse --verify --quiet --short "refs/tags/$TAG^{commit}") || { echo "lane_merge: no tag $TAG" >&2; exit 1; }

if [ "$MODE" = returned ]; then
  if [ -n "$REVERT" ]; then
    REVERT=$(g rev-parse --verify --quiet --short "$REVERT^{commit}") || { echo "lane_merge: no commit $4" >&2; exit 1; }
  fi
  autorun_record_event lane.returned "tag=$TAG" "returned=raw:$(js reason "$REASON" revert "$REVERT")"
  row="| $(date +%F) | $TAG returned · $REASON${REVERT:+ · revert $REVERT} | .claude/rotation-lanes/$TAG_LANE/handoff.md |"
  at=$(autorun_inbox_insert "$row") || { echo "lane_merge: writing $INBOX_FILE failed" >&2; exit 1; }
  echo "lane_merge: event lane.returned → $EVENTS_LOG"
  echo "lane_merge: inbox $INBOX_FILE:$at $row"
  echo "LANE RETURNED $TAG"
  exit 0
fi

branch=$(g rev-parse --abbrev-ref HEAD 2>/dev/null)
base_head=$(g rev-parse --short HEAD)
autorun_record_event lane.merge.start "tag=$TAG" "merge=raw:$(js branch "$branch" baseHead "$base_head" tagHead "$tag_head")"
if g merge --no-ff -m "merge: $TAG into $branch" "$TAG"; then
  commit=$(g rev-parse --short HEAD)
  autorun_record_event lane.merge.end "tag=$TAG" "merge=raw:$(js status ok commit "$commit" branch "$branch" baseHead "$base_head")"
  echo "LANE MERGED $TAG commit=$commit"
  exit 0
fi
conflicts=$(g diff --name-only --diff-filter=U)
if [ -n "$conflicts" ]; then
  autorun_record_event lane.merge.end "tag=$TAG" "merge=raw:$(js status conflict commit "" branch "$branch" baseHead "$base_head")"
  echo "lane_merge: merge conflict — resolve and commit (or git merge --abort):"
  printf '%s\n' "$conflicts" | sed 's/^/  /'
  exit 3
fi
autorun_record_event lane.merge.end "tag=$TAG" "merge=raw:$(js status fail commit "" branch "$branch" baseHead "$base_head")"
echo "lane_merge: git merge $TAG failed" >&2
exit 1
