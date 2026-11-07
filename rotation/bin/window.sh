#!/usr/bin/env bash
#
# rotation kernel — a window on a host, as events: the span in which one job owns a machine (a bench on
# the benchmark host, say) and every other lane keeps its heavy work off it. The window is what the
# events say, nothing else: no free-text line to read, no end marker to remember.
#
# usage: window.sh open   <name> --until <ISO8601 | +seconds | epoch> [--host H] [--reason TEXT]
#        window.sh extend <name> --until <ISO8601 | +seconds | epoch> [--host H] [--reason TEXT]
#        window.sh close  <name> [--reason TEXT]
#        window.sh status [<name>] [--json]
#
#   open    records window.open {name, host, until (epoch), untilAt (ISO), reason}; when a window of that name
#           is already open it records window.extend instead (the same fields), and says so
#   extend  records window.extend: a new end (and host / reason when given) for an open window
#   close   records window.close
#   status  reads every lane's events log (a lane waits on a window another lane opened) and prints
#           `OPEN name=… host=… until=<ISO> overdue=yes|no` for the window, or `CLOSED name=…`; without a name,
#           one OPEN line per open window, or `CLOSED` when none is. --json: the same as JSON (one object for a
#           name, a list of the open windows without one)
#
# A lane that has to wait for a window records `event.sh executor.waiting waiting.window=<name>`: the watchdog
# then neither wakes it nor takes its silent workers for dead while the window is open, and wakes it after the
# close. A window whose end passed --wake seconds ago with no extend or close is the watchdog's WINDOW-OVERDUE,
# reported in the lane that opened it.
#
# exit: 0 recorded, or (status) a window is open · 1 (status) closed, (extend / close) no such window is open ·
#       2 usage

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

usage() {
  echo "usage: window.sh open|extend <name> --until <ISO8601|+seconds|epoch> [--host H] [--reason TEXT] · close <name> [--reason TEXT] · status [<name>] [--json]" >&2
  exit 2
}
[ "$#" -ge 1 ] || usage
VERB=$1
shift
case "$VERB" in open|extend|close|status) ;; *) usage ;; esac
NAME=""; HOST=""; UNTIL=""; REASON=""; JSON=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --host|--until|--reason)
      [ "$#" -ge 2 ] || usage
      case "$1" in --host) HOST=$2 ;; --until) UNTIL=$2 ;; --reason) REASON=$2 ;; esac
      shift 2 ;;
    --json) JSON=1; shift ;;
    -*) usage ;;
    *) [ -z "$NAME" ] || usage; NAME=$1; shift ;;
  esac
done
case "$NAME" in *[!A-Za-z0-9._-]*) echo "window.sh: a name is [A-Za-z0-9._-]+, got '$NAME'" >&2; exit 2 ;; esac
[ -n "$NAME" ] || [ "$VERB" = status ] || usage
[ "$JSON" -eq 0 ] || [ "$VERB" = status ] || usage
case "$VERB" in
  open|extend) [ -n "$UNTIL" ] || { echo "window.sh: $VERB needs --until" >&2; exit 2; } ;;
  *) [ -z "$UNTIL" ] && [ -z "$HOST" ] || usage ;;
esac
[ "$VERB" != status ] || [ -z "$REASON" ] || usage

export ROTATION_REPO="${ROTATION_REPO:-$PROJECT_DIR}"
export ROTATION_EVENTS_LOG="$EVENTS_LOG"
export ROTATION_ROTATIONS_LOG="$ROTATIONS_LOG"
export ROTATION_WINDOW_LOGS="$(autorun_window_logs)"
windows() { python3 "$SCRIPT_DIR/recover_lib.py" windows "$@"; }

if [ "$VERB" = status ]; then
  if [ "$JSON" -eq 1 ]; then windows ${NAME:+"$NAME"} --json; else windows ${NAME:+"$NAME"}; fi
  exit $?
fi

windows "$NAME" >/dev/null
is_open=$?
[ "$is_open" -le 1 ] || exit 2
KIND="window.$VERB"
case "$VERB" in
  open)
    if [ "$is_open" -eq 0 ]; then
      echo "window.sh: $NAME is already open; recording window.extend"
      KIND=window.extend
    fi ;;
  extend|close)
    [ "$is_open" -eq 0 ] || { echo "window.sh: no open window $NAME" >&2; exit 1; } ;;
esac

fields=("window.name=$NAME")
if [ -n "$UNTIL" ]; then
  until=$(python3 - "$UNTIL" <<'PY'
import datetime, sys, time
v = sys.argv[1].strip()
if v.startswith('+') and v[1:].isdigit():
    t = int(time.time()) + int(v[1:])
elif v.isdigit():
    t = int(v)
else:
    try:
        d = datetime.datetime.fromisoformat(v.replace('Z', '+00:00'))
    except ValueError:
        raise SystemExit(1)
    if d.tzinfo is None:
        d = d.astimezone()
    t = int(d.timestamp())
print(t, datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))
PY
) || { echo "window.sh: --until '$UNTIL' is not an ISO 8601 time, +seconds or an epoch" >&2; exit 2; }
  fields+=("window.until=int:${until%% *}" "window.untilAt=${until#* }")
fi
[ -z "$HOST" ] || fields+=("window.host=$HOST")
[ -z "$REASON" ] || fields+=("window.reason=$REASON")
"$SCRIPT_DIR/event.sh" "$KIND" "${fields[@]}"
