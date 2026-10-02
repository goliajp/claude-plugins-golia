#!/bin/bash
# kill_stray_shells.sh — rotation-close hard invariant (set by the operator,
# 2026-08-02): when a rotation ends, every child process the round
# started must be dead. No watcher, poller, sleeper, or remote-wait shell
# may survive into the next rotation.
#
# Mechanism: the round registers the shells it starts —
#   event.sh process.start process.pid=int:$$ process.what=<label>
# at the top of a background command ($$ there is the Bash-tool shell, the
# direct child of the Claude Code process), and process.end for one that
# finished on its own. The reaper reads this round's registrations from the
# events log and ends every registered pid still alive, with its subtree.
# Nothing else is touched: a shell nobody registered is not the reaper's to
# end. The earlier reaper walked the whole Claude Code process tree and ended
# every Bash-tool shell under it; in manager mode the manager, the executor,
# its workers and any harness agent share that one process, and on 2026-10-02
# the walk took down the manager's watchdog (exit 144), another agent's
# pre-flight chain and three workers' remote links.
#
# Guards: a registered pid is ended only when it is alive and a descendant of
# the Claude Code process this script runs under — a pid another process took
# after the shell exited is reported STALE and left alone — and the chain this
# script runs under is never a victim.
#
# Manager mode (manager.active in the state directory): the process is shared,
# so the project's remote reap command (ROTATION_REAP_REMOTE_CMD, a pattern
# kill on the runner) is skipped — workers' remote jobs match the same
# patterns. Registered pids are still reaped; they are this round's own.
# Session mode runs the remote reap best-effort.
#
# Inputs (set by trigger.sh): ROTATION_STATE_DIR, ROTATION_EVENTS_LOG (default
# <state>/events.jsonl; HARDEV_EVENTS_LOG wins), ROTATION_REAP_ROTATION_ID
# (the round whose registrations count; empty = every registration in the log).
#
# Exit 0 + "CLEAN" when no registered process is alive; exit 0 + KILL lines
# and a REAPED count otherwise; STALE lines for registrations that no longer
# name a process of this session. Exit 1 only when no claude ancestor is
# found (not run from within a session — refuse rather than guess).

set -u

state_dir="${ROTATION_STATE_DIR:-$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)/.claude/rotation-state}"
events="${HARDEV_EVENTS_LOG:-${ROTATION_EVENTS_LOG:-$state_dir/events.jsonl}}"
rid="${ROTATION_REAP_ROTATION_ID:-}"
manager=0
[ -e "$state_dir/manager.active" ] && manager=1

me=$$
ancestors=" $me "
claude_pid=""
p=$me
while [ -n "$p" ] && [ "$p" != "0" ] && [ "$p" != "1" ]; do
  cmd=$(ps -p "$p" -o comm= 2>/dev/null)
  case "$cmd" in
    *claude*) claude_pid=$p; break ;;
  esac
  p=$(ps -p "$p" -o ppid= 2>/dev/null | tr -d ' ')
  ancestors="$ancestors$p "
done

if [ -z "$claude_pid" ]; then
  echo "NO_CLAUDE_ANCESTOR — not inside a Claude Code session, refusing"
  exit 1
fi

# this round's registrations: process.start pids without a process.end, as `<pid><TAB><what>`
registered=$(python3 - "$events" "$rid" <<'PY'
import json, os, sys
path, rid = sys.argv[1], sys.argv[2]
if not os.path.isfile(path):
    sys.exit(0)
live = {}
for line in open(path, encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    try:
        e = json.loads(line)
    except ValueError:
        continue
    if rid and e.get("rotationId") != rid:
        continue
    proc = e.get("process") if isinstance(e.get("process"), dict) else {}
    pid = proc.get("pid")
    if not isinstance(pid, int) or isinstance(pid, bool):
        continue
    if e.get("kind") == "process.start":
        live[pid] = proc.get("what") or ""
    elif e.get("kind") == "process.end":
        live.pop(pid, None)
for pid, what in live.items():
    print("%d\t%s" % (pid, what))
PY
)

descendants() {
  local pid=$1 c
  for c in $(pgrep -P "$pid" 2>/dev/null); do
    echo "$c"
    descendants "$c"
  done
}

under_session() {
  local p=$1
  while [ -n "$p" ] && [ "$p" != "0" ] && [ "$p" != "1" ]; do
    [ "$p" = "$claude_pid" ] && return 0
    p=$(ps -p "$p" -o ppid= 2>/dev/null | tr -d ' ')
  done
  return 1
}

killed=0
while IFS=$'\t' read -r pid what; do
  [ -n "$pid" ] || continue
  case "$ancestors" in *" $pid "*) continue ;; esac
  kill -0 "$pid" 2>/dev/null || continue
  if ! under_session "$pid"; then
    echo "STALE $pid: registered as '$what' but not under claude pid $claude_pid, left alone"
    continue
  fi
  for victim in $pid $(descendants "$pid"); do
    case "$ancestors" in *" $victim "*) continue ;; esac
    line=$(ps -p "$victim" -ww -o command= 2>/dev/null | cut -c1-140)
    [ -z "$line" ] && continue
    echo "KILL $victim: $line"
    kill "$victim" 2>/dev/null
    killed=$((killed + 1))
  done
done <<EOF
$registered
EOF

if [ "$manager" -eq 1 ]; then
  echo "SKIP remote reap: manager mode ($state_dir/manager.active): the Claude process is shared, only registered pids were reaped"
elif [ -n "${ROTATION_REAP_REMOTE_CMD:-}" ]; then
  # project-side best-effort reap (the adapter's ROTATION_REAP_REMOTE_CMD; never blocks)
  sh -c "$ROTATION_REAP_REMOTE_CMD" >/dev/null 2>&1 || true
fi

if [ "$killed" -eq 0 ]; then
  echo "CLEAN: no registered process of this round alive under claude pid $claude_pid"
else
  echo "REAPED $killed registered process(es) under claude pid $claude_pid"
fi
exit 0
