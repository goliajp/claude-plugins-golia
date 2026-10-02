#!/usr/bin/env bash
#
# Watch a running rotation from outside the model: check every --interval
# seconds, and on the first hit print one line and exit. The exit is the
# notification (the manager session starts this with run_in_background).
# It changes nothing: no file, no process, no event.
#
# usage: watchdog.sh [--interval 60] [--stale 1800] [--wake 300] [--dirty 600] [--once]
#
#   WAKE           (exit 10)  what the last executor.waiting waits for has happened (its remote
#                             marker is in the log, or every listed worker has an agent.end),
#                             the executor has recorded nothing since, and --wake seconds passed
#   STALE          (exit 11)  no sign of life for --stale seconds: the latest of the last event, the
#                             main tree's HEAD commit and the newest commit in any worktree (and
#                             never earlier than this watchdog's start)
#   QUOTA          (exit 12)  the last quota.hit's reset time has passed and neither an executor event nor a
#                             manager.resume followed it (the manager's own segments and other manager.*
#                             events do not count, for WAKE either)
#   DIRTY          (exit 13)  the main tree has an uncommitted file written --dirty seconds or more
#                             after the executor's last event, and still there --dirty seconds later
#   FOREIGN-COMMIT (exit 14)  the manager marker is present, the base branch's HEAD moved past the
#                             round's prevHead, and no rotation executor is registered as running —
#                             or the HEAD commit is later than the last executor event and that
#                             executor is not running. Someone other than the executor committed
#                             to the main tree (the manager session, in the 2026-10-01 incident).
#   MULTI-EXECUTOR (exit 15)  more than one rotation executor of this round is registered as running; the
#                             protocol runs one at a time, the stale one has to be ended (checked first)
#
#   --once  one pass, no start floor: prints the hit, or `OK …` and exits 0
#
# exit: 10–15 as above · 0 only with --once · 1 the check itself failed · 2 usage

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

INTERVAL=60; STALE=1800; WAKE=300; DIRTY=600; ONCE=0
usage() { echo "usage: watchdog.sh [--interval 60] [--stale 1800] [--wake 300] [--dirty 600] [--once]" >&2; exit 2; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --interval|--stale|--wake|--dirty)
      [ "$#" -ge 2 ] || usage
      case "$2" in ''|*[!0-9]*) usage ;; esac
      case "$1" in
        --interval) INTERVAL=$2 ;;
        --stale) STALE=$2 ;;
        --wake) WAKE=$2 ;;
        --dirty) DIRTY=$2 ;;
      esac
      shift 2 ;;
    --once) ONCE=1; shift ;;
    *) usage ;;
  esac
done

export ROTATION_REPO="${ROTATION_REPO:-$PROJECT_DIR}"
export ROTATION_EVENTS_LOG="$EVENTS_LOG"
export ROTATION_ROTATIONS_LOG="$ROTATIONS_LOG"
export ROTATION_MANAGER_ACTIVE="${ROTATION_MANAGER_ACTIVE:-$MANAGER_ACTIVE_FILE}"
export ROTATION_AGENT_ORIGIN_PATTERN="$AGENT_ORIGIN_PATTERN"
FLOOR=$(date +%s)
[ "$ONCE" -eq 1 ] && FLOOR=0

while :; do
  line=$(python3 "$SCRIPT_DIR/recover_lib.py" watch --stale "$STALE" --wake "$WAKE" --dirty "$DIRTY" --floor "$FLOOR")
  rc=$?
  if [ "$rc" -ne 0 ] || [ "$ONCE" -eq 1 ]; then
    printf '%s\n' "$line"
    exit "$rc"
  fi
  sleep "$INTERVAL"
done
