#!/usr/bin/env bash
#
# rotation kernel — make a worktree of the project usable as a lane's
# working tree.
#
# A lane's executor works in its own git worktree of the project, on the
# lane's branch. The project keeps everything the protocol needs under
# `.claude/` (and, often, a development directory such as `.dev/`), and
# those directories are not in git, so a fresh worktree has none of them.
# This script gives the worktree a real `.claude/` directory whose entries
# are symbolic links to the main tree's, except for what must be the
# worktree's own:
#   .claude/worktrees/     the lane's own (its workers' worktrees land here, not among the main lane's)
#   .claude/handoff.md     → the lane's handoff (.claude/rotation-lanes/<lane>/handoff.md), so the
#                          executor reads "the handoff" at the usual path and gets the lane's
#   .claude/autorun-intent never linked: the main lane's intent stays the main lane's
# and links the directories named in the lane's rotation.conf
# ROTATION_LANE_SHARED_DIRS (space-separated top-level names, e.g. `.dev`)
# or given with --share. Shims called through these links resolve the
# project root to the worktree (a shim's root is where it lives, through
# the link's logical path), so the lane's events, commit counts and HEAD are
# the worktree's, while conf, state and rules are the shared files.
#
# Idempotent: existing entries are left alone; a `.claude` that is itself a
# symbolic link is refused (the worktrees directory must be the lane's own).
#
# usage: lane_enter.sh <lane> [--share <dir>]...     (run inside the worktree)
# exit: 0 · 1 not a worktree of a project with that lane · 2 usage

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ "$#" -ge 1 ] || { echo "usage: lane_enter.sh <lane> [--share <dir>]..." >&2; exit 2; }
LANE=$1
shift
case "$LANE" in ''|*[!a-z0-9-]*) echo "lane_enter: lane must match [a-z0-9-]+, got '$LANE'" >&2; exit 2 ;; esac
SHARE=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --share) [ "$#" -ge 2 ] || { echo "lane_enter: --share needs a directory name" >&2; exit 2; }; SHARE+=("$2"); shift 2 ;;
    *) echo "usage: lane_enter.sh <lane> [--share <dir>]..." >&2; exit 2 ;;
  esac
done

WT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "lane_enter: not inside a git work tree" >&2; exit 1; }
COMMON=$(cd "$WT" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || { echo "lane_enter: no git common dir" >&2; exit 1; }
MAIN=$(cd "$(dirname "$COMMON")" && pwd)
if [ "$MAIN" = "$WT" ]; then
  echo "lane_enter: $WT is the main tree, not a worktree — a lane's executor never works on the main tree" >&2
  exit 1
fi
LANE_DIR="$MAIN/.claude/rotation-lanes/$LANE"
[ -d "$LANE_DIR" ] || { echo "lane_enter: no lane '$LANE' at $LANE_DIR (init.sh --lane $LANE in the main tree first)" >&2; exit 1; }

if [ -L "$WT/.claude" ]; then
  echo "lane_enter: $WT/.claude is a symbolic link; it must be a directory of its own (rm it and rerun)" >&2
  exit 1
fi
mkdir -p "$WT/.claude/worktrees"
linked=0
for entry in "$MAIN"/.claude/* "$MAIN"/.claude/.[!.]*; do
  [ -e "$entry" ] || continue
  name=$(basename "$entry")
  case "$name" in worktrees|handoff.md|autorun-intent) continue ;; esac
  if [ ! -e "$WT/.claude/$name" ] && [ ! -L "$WT/.claude/$name" ]; then
    ln -s "$entry" "$WT/.claude/$name"
    linked=$((linked + 1))
  fi
done
if [ ! -e "$WT/.claude/handoff.md" ] && [ ! -L "$WT/.claude/handoff.md" ]; then
  [ -e "$LANE_DIR/handoff.md" ] || : > "$LANE_DIR/handoff.md"
  ln -s "$LANE_DIR/handoff.md" "$WT/.claude/handoff.md"
  linked=$((linked + 1))
fi

# the shared top-level directories: the lane's conf, then --share
conf_dirs=""
if [ -f "$LANE_DIR/rotation.conf" ]; then
  conf_dirs=$(sed -n 's/^[[:space:]]*ROTATION_LANE_SHARED_DIRS[[:space:]]*=[[:space:]]*//p' "$LANE_DIR/rotation.conf" | tail -1)
fi
for d in $conf_dirs ${SHARE[@]+"${SHARE[@]}"}; do
  case "$d" in ''|/*|*/*|.|..|.git|.claude) echo "lane_enter: shared dir must be a top-level name, got '$d'" >&2; exit 2 ;; esac
  [ -d "$MAIN/$d" ] || { echo "lane_enter: $MAIN/$d does not exist" >&2; exit 1; }
  if [ ! -e "$WT/$d" ] && [ ! -L "$WT/$d" ]; then
    ln -s "$MAIN/$d" "$WT/$d"
    linked=$((linked + 1))
  fi
done

echo "lane_enter: lane $LANE · worktree $WT · main $MAIN · $linked link(s) made"
echo "lane_enter: shims: $WT/.claude/rotation-lanes/$LANE/<script> (project root resolves to this worktree)"
exit 0
