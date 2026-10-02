#!/usr/bin/env bash
#
# rotation kernel — plan a rotation's close: which checks run, which carry.
#
# A close used to run every mechanical check every time, whatever the
# rotation had changed. This reads the project's rules table and decides
# per check: diff from that check's own stamp sha to HEAD hits its trigger
# paths → run; otherwise the stamp is carried forward (its sha is still
# the last commit that could have moved the reading). The outcome is a
# verdict — <rid>.verdict.md for people, <rid>.verdict.json for the
# dashboard and the close scripts — with four sections: what changed,
# the decision per check, the results (filled later by
# close_verdict_fill.sh), and the release form the two mode columns give.
#
# Usage:
#   close_plan.sh [<prev-sha> [<head-sha>]] [--rid <rid>] [--explain] [--force]
#
#   no shas    the open rotation: last rotations.jsonl row's prevHead..HEAD
#              (after the close trigger has written the next row at HEAD,
#              the row before it)
#   --rid      the verdict's id; default: the row whose prevHead opened the
#              range, i.e. the id the rotation ran under and its events carry
#   --explain  print every trigger path each check hit
#   --force    re-plan over an existing verdict for the same range
#
# Everything project-specific (rules table, stamp dir, verdict dir) comes
# from rotation.conf / project.sh's ROTATION_* values; the kernel knows no
# project names. An empty rules table is a configuration error (exit 2).
#
# exit: 0 planned (or verdict already present) · 2 cannot plan

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

out=$(python3 "$SCRIPT_DIR/close_lib.py" plan "$@")
rc=$?
printf '%s\n' "$out"
[ "$rc" -eq 0 ] || exit "$rc"

# the plan is an event: what the close decided, under the rotation it closes
case "$out" in
  "verdict exists:"*) exit 0 ;;
esac
summary=$(printf '%s\n' "$out" | python3 -c '
import json, re, sys
lines = sys.stdin.read().split("\n")
plan = next((l for l in lines if l.startswith("plan: ")), "")
rel = next((l for l in lines if l.startswith("release: ")), "")
gate = next((l for l in lines if l.startswith("gate: ")), "")
path = next((l for l in lines if l.startswith("verdict: ")), "")[len("verdict: "):]
m = re.search(r"run=\[(.*?)\] carry=\[(.*?)\]", plan)
f = re.match(r"release: (\S+)", rel)
rid = re.search(r"/([^/]+)\.verdict\.md$", path)
print(json.dumps({"rid": rid.group(1) if rid else None, "verdict": path, "form": f.group(1) if f else None,
                  "run": m.group(1).split() if m else [], "carry": m.group(2).split() if m else [],
                  "gate": gate[len("gate: "):] or None, "rules": sys.argv[1], "rulesSha256": sys.argv[2]}))' \
  "$ROTATION_CLOSE_RULES" "$(shasum -a 256 "$ROTATION_CLOSE_RULES" | awk '{print $1}')")
autorun_record_event close.plan "plan=raw:$summary"
exit 0
