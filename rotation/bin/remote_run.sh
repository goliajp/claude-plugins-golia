#!/usr/bin/env bash
#
# rotation kernel — run one job on a runner over a held ssh and record its
# remote.start with the pid it runs under there, so the job can later be
# ended by that pid and nothing else (remote_kill.py builds the command;
# recover.sh prints it, the trigger's reaper runs it).
#
# The runner's login shell first prints `ROTATION_REMOTE_PID=<pid> <start>`
# and then runs <command>. <pid> is that shell, the process sshd started for
# this connection: it runs <command> as its children or becomes it when the
# shell execs the last command, so everything the job starts is under <pid>.
# <start> is the shell's `ps -o lstart`, kept so a pid the runner later hands
# to another process is never taken for this job. A wrapper such as
# `bench-lock heavy <cmd>` sits in that tree and runs <cmd> as its own child,
# holding the lock fd there; ending the job means ending the tree, not one
# pid. A process that leaves the tree by itself (reparented after its parent
# died, or a new session) is not covered and stays the job's own to reap.
#
# remote.start is appended when that line arrives, with the fields given plus
# remote.host=<host>, remote.pid, remote.pidStart and remote.launcher (this
# script's pid: it holds the ssh, so once it is gone the job has no local end
# and recover.sh marks it `orphan?`). Every other line passes through as it
# comes. The project supplies host and command (its adapter commands call
# this through the .claude/rotation/remote_run.sh shim).
#
# usage: remote_run.sh <host> <command> <remote.start field>...
#   <command>  what `ssh <host> <command>` would run
#   fields     as event.sh takes them: remote.kind= remote.log= [remote.sha= remote.marker=]
#
# exit: ssh's exit code (255 = the link died; the job may still be running) ·
#       2 usage · 65 ssh exited 0 but no pid line came back (nothing recorded)

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[ "$#" -ge 3 ] || { echo "usage: remote_run.sh <host> <command> <remote.start field>..." >&2; exit 2; }
HOST=$1
CMD=$2
shift 2
case "$HOST" in ''|*[!A-Za-z0-9._@-]*) echo "remote_run: '$HOST' is not a plain host name" >&2; exit 2 ;; esac
for f in "$@"; do
  case "$f" in remote.host=*|remote.pid=*|remote.pidStart=*|remote.launcher=*)
    echo "remote_run: $f is set by remote_run.sh, not by the caller" >&2; exit 2 ;;
  esac
done

# sh, bash and zsh all split the unquoted command substitution, and "$*" joins it back with single spaces
PRELUDE='set -- $(ps -o lstart= -p $$); echo "ROTATION_REMOTE_PID=$$ $*"'
LAUNCHER=$$
SEEN=$(mktemp)
trap 'rm -f "$SEEN"' EXIT

ssh "$HOST" "$PRELUDE; $CMD" | {
  while IFS= read -r line; do
    case "$line" in
      ROTATION_REMOTE_PID=*)
        rec=${line#ROTATION_REMOTE_PID=}
        pid=${rec%% *}
        start=${rec#* }
        case "$pid" in
          ''|*[!0-9]*) echo "remote_run: unreadable pid line from $HOST: $line" >&2 ;;
          *)
            "$SCRIPT_DIR/event.sh" remote.start "$@" "remote.host=$HOST" "remote.pid=int:$pid" \
              "remote.pidStart=$start" "remote.launcher=int:$LAUNCHER" >/dev/null && echo "$pid" > "$SEEN" ;;
        esac
        break ;;
    esac
    printf '%s\n' "$line"
  done
  cat
}
rc=${PIPESTATUS[0]}
if [ "$rc" -eq 0 ] && [ ! -s "$SEEN" ]; then
  echo "remote_run: $HOST ran the job but no pid line was recorded; remote.start is missing" >&2
  exit 65
fi
exit "$rc"
