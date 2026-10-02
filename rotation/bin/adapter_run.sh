#!/usr/bin/env bash
#
# rotation kernel — run one of the project's adapter commands and hold it
# to its contract.
#
# The kernel does not know how a gate, a pre-flight, a close segment or a
# bench is run. project.sh registers one command for each
# (ROTATION_GATE_CMD, ROTATION_PREFLIGHT_CMD, ROTATION_CLOSE_SEGMENT_CMD,
# ROTATION_BENCH_CMD; the contract is the README adapter command contract), and this is
# the kernel's one call site. The arguments pass through unchanged, stdout
# is shown as it comes. A command that exits 0 has claimed success, and the
# claim must be on record: the terminal line its contract names must be in
# its output, and the events its contract names must have been appended to
# events.jsonl while it ran. A claim without the record exits 64 — the hole
# the close planner would otherwise find later as "no gate.end", found now.
# Any non-zero exit is the command's own and passes through untouched (a
# gate with F>0, a dead ssh, a usage error): only success is checked.
#
# usage: adapter_run.sh gate|preflight|close-segment|bench [args...]
#   gate           <sha> ...              line `N pass / F fail / S skip`; events remote.start gate.end remote.end
#   preflight      [-q] ...               line `PREFLIGHT PASS` (`PREFLIGHT FAIL: …` exits 1); event preflight.end
#   close-segment  <head> <segment> ...   events remote.start remote.end
#   bench          <sha> [segments] ...   events remote.start remote.end
#
# exit: the command's exit code · 2 usage, command not registered or not a file · 64 exit 0 without the record

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

[ "$#" -ge 1 ] || { echo "usage: adapter_run.sh gate|preflight|close-segment|bench [args...]" >&2; exit 2; }
WHAT=$1
shift
case "$WHAT" in
  gate)          VAR=ROTATION_GATE_CMD;          LINE='[0-9]+ pass / [0-9]+ fail / [0-9]+ skip'; KINDS="remote.start gate.end remote.end" ;;
  preflight)     VAR=ROTATION_PREFLIGHT_CMD;     LINE='^PREFLIGHT PASS';                        KINDS="preflight.end" ;;
  close-segment) VAR=ROTATION_CLOSE_SEGMENT_CMD; LINE='';                                       KINDS="remote.start remote.end" ;;
  bench)         VAR=ROTATION_BENCH_CMD;         LINE='';                                       KINDS="remote.start remote.end" ;;
  *) echo "adapter_run: unknown command '$WHAT' (gate | preflight | close-segment | bench)" >&2; exit 2 ;;
esac
eval "CMD=\${$VAR:-}"
if [ -z "$CMD" ]; then
  echo "adapter_run: $VAR is not registered in project.sh" >&2
  exit 2
fi
if [ ! -f "$CMD" ]; then
  echo "adapter_run: $VAR=$CMD is not a file" >&2
  exit 2
fi

before=0
[ -f "$EVENTS_LOG" ] && before=$(wc -l < "$EVENTS_LOG" | tr -d ' ')
OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT
bash "$CMD" "$@" | tee "$OUT"
rc=${PIPESTATUS[0]}
[ "$rc" -eq 0 ] || exit "$rc"

missing=()
if [ -n "$LINE" ] && ! grep -qE -- "$LINE" "$OUT"; then
  missing+=("line /$LINE/")
fi
for kind in $KINDS; do
  if ! [ -f "$EVENTS_LOG" ] || ! tail -n +"$(( before + 1 ))" "$EVENTS_LOG" | grep -qF "\"kind\":\"$kind\""; then
    missing+=("event $kind")
  fi
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "adapter_run: $WHAT ($VAR) exited 0 without its record: ${missing[*]} — the kernel cannot credit this run" >&2
  exit 64
fi
exit 0
