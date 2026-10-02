#!/usr/bin/env bash
#
# rotation kernel — carry a stamp forward to HEAD without re-running it.
#
# The close planner (close_plan.sh) decides a check is carried when nothing
# on its trigger paths changed between the commit its stamp measured and
# HEAD: the reading is unchanged by construction, so re-running would only
# re-measure the same thing. Carrying is not the same as being current —
# the stamp keeps its headSha (what was measured) and gains `carriedTo`
# (what it is held valid for) plus the reason, so a reader can always tell
# a measured sha from an inferred one. TRIG-6 and the dashboard accept
# `carriedTo == HEAD` as fresh; a dirty or red stamp is never carried, and
# neither is one without a `verdict` (the planner would not have decided
# so, and this script refuses too).
#
# usage: carry_stamp.sh <x> <head-sha> <reason>
#   x        the stamp's basename: $ROTATION_STAMP_DIR/<x>-latest.json
#   reason   the planner's wording
#
# Writes carriedTo / carriedReason / carriedAt into the stamp, appends one
# row to the stamp history (same tool, `carried: true`, the original ranAt)
# and records a stamp.carried event. Idempotent for the same head.
#
# exit: 0 carried (or already carried to this head) · 1 refused · 2 usage

set -u
[ "$#" -eq 3 ] || { echo "usage: carry_stamp.sh <x> <head-sha> <reason>" >&2; exit 2; }
X=$1; HEAD_SHA=$2; REASON=$3
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
DEV="${HARDEV_STAMP_DIR:-${ROTATION_STAMP_DIR:-}}"
[ -n "$DEV" ] || { echo "carry_stamp: ROTATION_STAMP_DIR unset" >&2; exit 2; }
HISTORY="${ROTATION_STAMP_HISTORY:-$DEV/stamps.jsonl}"
STAMP="$DEV/$X-latest.json"
[ -f "$STAMP" ] || { echo "carry_stamp: no stamp at $STAMP" >&2; exit 1; }

state=$(python3 - "$STAMP" "$HEAD_SHA" "$REASON" <<'PY'
import datetime, json, sys
path, head, reason = sys.argv[1:4]
doc = json.load(open(path))
sha = doc.get("headSha") or ""
verdict = doc.get("verdict") or ""
if not sha or sha.endswith("-dirty"):
    print("refuse: stamp names no clean commit"); raise SystemExit
if not verdict:
    print("refuse: stamp has no verdict"); raise SystemExit
if verdict != "ok":
    print(f"refuse: stamp verdict is {verdict}"); raise SystemExit
if sha.startswith(head) or head.startswith(sha):
    print("same: stamp already measured this head"); raise SystemExit
ct = doc.get("carriedTo") or ""
if ct and (ct.startswith(head) or head.startswith(ct)):
    print("already: carried to this head"); raise SystemExit
doc["carriedTo"] = head
doc["carriedReason"] = reason
doc["carriedAt"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(path, "w") as f:
    json.dump(doc, f, ensure_ascii=False, indent=2)
    f.write("\n")
print("carried")
PY
)
case "$state" in
  carried) ;;
  same:*|already:*) echo "carry_stamp: $X $state"; exit 0 ;;
  *) echo "carry_stamp: $X $state" >&2; exit 1 ;;
esac

REL="${STAMP#"$PROJECT_DIR"/}"
python3 - "$STAMP" "$REL" "$X" <<'PY' >> "$HISTORY"
import json, sys
doc = json.load(open(sys.argv[1]))
doc.setdefault("tool", sys.argv[3])
doc["file"] = sys.argv[2]
doc["carried"] = True
print(json.dumps(doc, ensure_ascii=False, separators=(",", ":")))
PY
echo "carry_stamp: $X headSha=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["headSha"][:9])' "$STAMP") carriedTo=${HEAD_SHA:0:9} ($REASON)"
autorun_record_event stamp.carried "stamp=raw:$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps({"tool": d.get("tool") or sys.argv[3], "file": sys.argv[2], "headSha": d.get("headSha"), "carriedTo": d.get("carriedTo"), "reason": d.get("carriedReason")}))' "$STAMP" "$REL" "$X")"
