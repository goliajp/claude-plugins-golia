#!/usr/bin/env bash
#
# rotation kernel — fill section 3 of a close verdict with what the checks read.
#
# For every check the verdict names, reads its <x>-latest.json stamp and the
# stamp history, and writes into the verdict: whether it ran at HEAD, was
# carried to HEAD, or is still pending; the readings the rules table lists
# (`show`) with the delta against the last stamp of the same check that
# measured a different commit; and the regressions the table defines
# (`regress`): red stops the next rotation from closing, amber must be
# attributed. A stamp without a `verdict` key is red (an unknown reading is
# not a green one), and so is a range with substrate commits and no
# `gate.end` event. Re-runnable — each run replaces the section from the
# stamps as they are now.
#
# Usage:
#   close_verdict_fill.sh <rid>
#
# exit: 0 filled (regressions are reported, not an exit code) · 2 no verdict

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

export ROTATION_REPO="${ROTATION_REPO:-$PROJECT_DIR}"
export ROTATION_CLOSE_RULES="${ROTATION_CLOSE_RULES:?rotation.conf / project.sh must set ROTATION_CLOSE_RULES}"
export ROTATION_STAMP_DIR="${HARDEV_STAMP_DIR:-${ROTATION_STAMP_DIR:?project.sh must set ROTATION_STAMP_DIR}}"
export ROTATION_STAMP_HISTORY="${ROTATION_STAMP_HISTORY:-$ROTATION_STAMP_DIR/stamps.jsonl}"
export ROTATION_VERDICT_DIR="${ROTATION_VERDICT_DIR:?project.sh must set ROTATION_VERDICT_DIR}"
export ROTATION_ROTATIONS_LOG="$ROTATIONS_LOG"
export ROTATION_EVENTS_LOG="$EVENTS_LOG"

out=$(python3 "$SCRIPT_DIR/close_lib.py" fill "$@")
rc=$?
printf '%s\n' "$out"
[ "$rc" -eq 0 ] || exit "$rc"
red=$(printf '%s\n' "$out" | grep -c '^  RED ')
amber=$(printf '%s\n' "$out" | grep -c '^  amber ')
autorun_record_event close.result "result=raw:$(python3 -c 'import json,sys; print(json.dumps({"rid": sys.argv[1], "red": int(sys.argv[2]), "amber": int(sys.argv[3])}))' "${1:-}" "$red" "$amber")"
exit 0
