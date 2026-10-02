#!/bin/bash
# kill_stray_shells.sh — rotation-close hard invariant (set by the operator,
# 2026-08-02): when a rotation ends, EVERY child process this
# Claude Code session spawned must be dead. No watcher, poller,
# sleeper, or remote-wait shell may survive into the next rotation.
#
# Mechanism: walk up from $$ to the owning `claude` process, then
# enumerate its descendants. A Bash-tool shell is identified by the
# `shell-snapshots` marker in its command line (every Bash tool
# invocation wraps as `/bin/zsh -c source .../shell-snapshots/...`);
# such a shell and its whole subtree are victims — EXCEPT the chain
# this very script is running under, and EXCEPT a shell whose subtree
# runs a watchdog.sh: the manager starts it through the same Bash
# tool, so it carries the marker, and it is the one process meant to
# live across a rotation close (2026-10-02: the reaper took it down,
# exit 144, and the manager lost its wake-up; again when a kernel
# installed under another directory name matched only its own path).
# The kernel keeps no registry of spawned pids — catching the
# unregistered is the point of walking the tree — so the exception is
# by command line, any path ending in `/watchdog.sh`. Non-shell children of
# claude (MCP servers, IDE helpers) are never touched.
#
# Exit 0 + "CLEAN" when nothing stray; exit 0 + KILL lines after
# reaping, KEEP lines for the watchdog shells left alone. Exit 1 only
# when no claude ancestor is found (not run from within a session —
# refuse rather than guess).
#
# Also best-effort runs the project's remote reap command
# (ROTATION_REAP_REMOTE_CMD) — runner-side processes outlive dev-side
# shells when an ssh link drops.

set -u

# In manager mode every agent (the manager, the executor, its workers, harness
# agents) runs its shells under one shared Claude process, so reaping by that
# process tree kills shells this round does not own: the manager's watchdog,
# other agents' background jobs and their ssh links to the runner. Skip the
# reap (local and remote) while manager.active exists; stray shells there are
# collected by PID by whoever started them.
state_dir="${ROTATION_STATE_DIR:-$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)/.claude/rotation-state}"
if [ -e "$state_dir/manager.active" ]; then
  echo "SKIP: manager mode ($state_dir/manager.active): the Claude process is shared, nothing reaped"
  exit 0
fi

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

descendants() {
  local pid=$1 c
  for c in $(pgrep -P "$pid" 2>/dev/null); do
    echo "$c"
    descendants "$c"
  done
}

killed=0
# a watchdog, as it appears on a command line: `bash <some dir>/watchdog.sh`. Matched by file
# name, not by this kernel's directory: the manager's watchdog may run from another install
# of the kernel (a shim directory, an older copy) under the same session process
watchdog_mark="/watchdog.sh"
# Bash-tool shells are DIRECT children of claude carrying the
# shell-snapshots marker; kill each such subtree except our own and
# except the one(s) running the watchdog.
for shell in $(pgrep -P "$claude_pid" 2>/dev/null); do
  case "$ancestors" in *" $shell "*) continue ;; esac
  cmdline=$(ps -p "$shell" -ww -o command= 2>/dev/null)
  case "$cmdline" in
    *shell-snapshots*) ;;
    *) continue ;;
  esac
  subtree="$shell $(descendants "$shell")"
  keep=0
  for p in $subtree; do
    case "$(ps -p "$p" -ww -o command= 2>/dev/null)" in *"$watchdog_mark"*) keep=1; break ;; esac
  done
  if [ "$keep" -eq 1 ]; then
    echo "KEEP $shell: runs a watchdog.sh"
    continue
  fi
  for victim in $subtree; do
    case "$ancestors" in *" $victim "*) continue ;; esac
    line=$(ps -p "$victim" -ww -o command= 2>/dev/null | cut -c1-140)
    [ -z "$line" ] && continue
    echo "KILL $victim: $line"
    kill "$victim" 2>/dev/null
    killed=$((killed + 1))
  done
done

# project-side best-effort reap (the adapter's ROTATION_REAP_REMOTE_CMD; never blocks)
if [ -n "${ROTATION_REAP_REMOTE_CMD:-}" ]; then
  sh -c "$ROTATION_REAP_REMOTE_CMD" >/dev/null 2>&1 || true
fi

if [ "$killed" -eq 0 ]; then
  echo "CLEAN: no stray shells under claude pid $claude_pid"
else
  echo "REAPED $killed stray process(es) under claude pid $claude_pid"
fi
exit 0
