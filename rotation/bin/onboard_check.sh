#!/usr/bin/env bash
#
# rotation kernel — is this project's plan in the shape the protocol needs?
# The checks behind the `/rotation:init` onboarding, one per step, in order:
#
#   step.1  vision          ROTATION_VISION_FILE (default .claude/vision.md) has a positioning section
#                           (定位 / Positioning) and a non-goals section (非目标 / Non-goals)
#   step.2  roadmap         ROTATION_PLAN_FILE (default .claude/plan-state.md) has an L1 roadmap heading and an
#                           L2 version scope heading
#   step.3  queue table     the plan has the queue table: header ROTATION_QUEUE_HEADER (default
#                           `通道|id|状态|一句话|出处|登记|验收|blocked_by|done`, or the English
#                           `lane|id|status|summary|source|registered|acceptance|blocked_by|done`), every row nine
#                           cells, the id `<prefix>-<name>`, the state one of ROTATION_QUEUE_STATES (default
#                           在做,排队,已完成,等决定,撤回 and active,queued,done,decision,withdrawn), acceptance not empty
#   step.4  L3a / L3b       the plan has a hot queue heading (L3a) and a cold queue heading (L3b)
#   step.5  L4              the plan has an L4 trigger predicate section, not empty, with no `<digits>%` in it
#   step.6  stamps          ROTATION_STAMPS not empty; every stamp of the close rules table is in it (or is the
#                           axis stamp); a missing <name>-latest.json is a WARN (none exist before the first round)
#   step.7  handoff         the handoff has the trigger section (ROTATION_TRIGGER_SECTION) with axis: closed: gate:
#   step.8  lanes           when lanes exist (or --lane): ROTATION_LANES_DOC (default: the plan file) has a section per
#                           lane — headed by its name — naming its work line, independence, verification machine and
#                           merge protocol; the first lane only when ROTATION_LANE_NAME names it
#
# Read-only: nothing is written, no event is recorded.
#
# usage: onboard_check.sh [--lane <name>]
#   --lane <name>  check as that lane (its conf, handoff and stamps); step.8 is then required
#   --doctor       (doctor.sh's call) only the plan.queue / plan.l4 / plan.handoff rows: steps 3, 5 and 7, where a
#                  missing plan file or handoff is a WARN
#
# Output: `PASS|WARN|FAIL step.<n> <detail>` per step; last line `ONBOARD PASS` or `ONBOARD FAIL`.
# exit: 0 every step passed (WARN allowed) · 1 a step failed · 2 usage

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
usage() { echo "usage: onboard_check.sh [--lane <name>]" >&2; exit 2; }
MODE=onboard
LANE_ARG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --lane) [ "$#" -ge 2 ] || usage; LANE_ARG=$2; shift 2 ;;
    --doctor) MODE=doctor; shift ;;
    *) usage ;;
  esac
done
if [ -n "$LANE_ARG" ]; then
  case "$LANE_ARG" in *[!a-z0-9-]*) echo "onboard_check: lane must match [a-z0-9-]+, got '$LANE_ARG'" >&2; exit 2 ;; esac
  export ROTATION_LANE="$LANE_ARG"
fi
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
if [ -n "$LANE_ARG" ] && [ ! -d "$PROJECT_ROTATION_DIR" ]; then
  echo "onboard_check: no lane '$LANE_ARG' at $PROJECT_ROTATION_DIR (init.sh --lane $LANE_ARG first)" >&2
  exit 1
fi

lanes=""
for d in "$CLAUDE_DIR"/rotation-lanes/*/; do
  [ -d "$d" ] || continue
  n=$(basename "$d")
  case "$n" in *[!a-z0-9-]*) continue ;; esac
  lanes="$lanes $n"
done
# the first lane joins the description only when the project named it (ROTATION_LANE_NAME of its own conf)
if [ -n "$lanes" ]; then
  first=$(sed -n 's/^[[:space:]]*ROTATION_LANE_NAME[[:space:]]*=[[:space:]]*//p' "$CLAUDE_DIR/rotation/rotation.conf" 2>/dev/null | tail -1 | tr -d '[:space:]')
  [ -z "$first" ] || lanes="$first$lanes"
fi

export PROJECT_DIR
export ONBOARD_PLAN_FILE="${ROTATION_PLAN_FILE:-$CLAUDE_DIR/plan-state.md}"
export ONBOARD_VISION_FILE="${ROTATION_VISION_FILE:-$CLAUDE_DIR/vision.md}"
export ONBOARD_LANES_DOC="${ROTATION_LANES_DOC:-$ONBOARD_PLAN_FILE}"
export ONBOARD_HANDOFF_FILE="$HANDOFF_FILE"
export ONBOARD_TRIGGER_SECTION_RE="$TRIGGER_SECTION_RE"
ONBOARD_TRIGGER_SECTION_TEXT="$(autorun_handoff_trigger_section)"
export ONBOARD_TRIGGER_SECTION_TEXT
export ONBOARD_LANES="$lanes"
export ROTATION_STAMP_DIR="${ROTATION_STAMP_DIR:-}"

if [ "$MODE" = doctor ]; then
  exec python3 "$SCRIPT_DIR/onboard_lib.py" doctor
fi
python3 "$SCRIPT_DIR/onboard_lib.py" onboard ${LANE_ARG:+--lane-required}
rc=$?
case "$rc" in
  0) echo "ONBOARD PASS" ;;
  1) echo "ONBOARD FAIL" ;;
  *) exit "$rc" ;;
esac
exit "$rc"
