#!/usr/bin/env bash
#
# rotation kernel — onboard_check.sh (the eight onboarding steps) and doctor.sh's plan.* rows.
#
# A throwaway project wired by init.sh, with a vision, a plan, a handoff, a stamp and a rules table that
# pass every step. Then each step is broken on its own and must FAIL that step (and only make the run
# FAIL); restoring the file must pass again. The plan is a made-up project's (a kettle controller), not
# any adopter's.
#
# exit: 0 every case passed · 1 otherwise

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KBIN="$ROOT/bin"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/     | /'; }
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$3] got [$2]"; fi; }
expect_has() { if printf '%s\n' "$2" | grep -qE -- "$3"; then ok "$1"; else bad "$1 (wanted /$3/)" "$2"; fi; }

TMP=$(cd "$TMP" && pwd -P)
P="$TMP/kettle"
mkdir -p "$P/.dev/stamps"
gk() { git -C "$P" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
gk init -q -b develop
printf '.claude/\n.dev/\n' > "$P/.gitignore"; echo k > "$P/k.txt"; gk add -A; gk commit -q -m "feat: first"
(cd "$P" && CLAUDE_PLUGIN_ROOT="$ROOT" bash "$KBIN/init.sh" >/dev/null 2>&1)
C="$P/.claude"
printf 'export ROTATION_STAMP_DIR="$PROJECT_DIR/.dev/stamps"\n' > "$C/rotation/project.sh"
printf '#name\tpaths\tartifact\tstamp\tminutes\tmode\tsync_paths\tneeds\tshow\tregress\nsweep\tsrc/**\t-\tsweep\t1\tsync\t-\t-\tpass\tpass:down\nbench\tsrc/**\t-\tbench\t1\tsync\t-\t-\tmedian\t-\n' > "$C/rotation/close_rules.tsv"
echo '{"headSha":"x"}' > "$P/.dev/stamps/sweep-latest.json"

cat > "$C/vision.md" <<'MD'
# kettle — direction

## Positioning
A firmware controller for one kettle model that holds a set temperature within one degree.

## Non-goals
No app, no cloud, no second model before v1.
MD
cat > "$C/plan-state.md" <<'MD'
# kettle plan — L1 to L4

## L1 roadmap
v1 holds temperature; v2 adds schedules.

## L2 version scope
v1.0: heating loop, boil-dry cutoff, button UI. Out: schedules.

## L3a hot queue

| lane | id | status | summary | source | registered | acceptance | blocked_by | done |
|---|---|---|---|---|---|---|---|---|
| control | CT-pid | active | PID loop on the heater | plan "heating loop" | r1 | `make test-pid` exits 0 | — | — |
| control | CT-dry | queued | boil-dry cutoff | plan "boil-dry cutoff" | r1 | dry-run rig trips in under 2 s | CT-pid | — |
| ui | UI-btn | queued | button debounce \| long press | plan "button UI" | r1 | `make test-ui` exits 0 | — | — |

## L3b cold queue
- the cheaper thermistor, once the PID loop holds

## L4 trigger predicates
- CT-dry moves to L3a when CT-pid is done
- v1.0 is cut when every L2 item is done and the rig log shows no overshoot above one degree

## Lanes

### Lane control
Work line: heater and safety. Independence: touches firmware/control only. Verification: the bench rig. Merge: tags merged by ui at batch start.

### Lane ui
Work line: buttons and display. Independence: firmware/ui only. Verification: the simulator host. Merge: tags merged into develop by the control lane.
MD
cat > "$C/handoff.md" <<'MD'
# handoff

## rotate-trigger

axis: A
closed: abc123 CT-pid; abc124 tests; abc125 rig
gate: 10/0/0
MD
for f in vision.md plan-state.md handoff.md rotation/rotation.conf rotation/close_rules.tsv; do cp "$C/$f" "$TMP/good.$(basename "$f")"; done
restore() { for f in vision.md plan-state.md handoff.md rotation/rotation.conf rotation/close_rules.tsv; do cp "$TMP/good.$(basename "$f")" "$C/$f"; done; }
run() { (cd "$P" && bash .claude/rotation/onboard_check.sh "$@" 2>&1); }
level() { printf '%s\n' "$1" | sed -nE "s/^(PASS|WARN|FAIL) step\.$2 .*/\1/p"; }
edit() { python3 - "$C/$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p, encoding="utf-8").read()
assert old in s, old
open(p, "w", encoding="utf-8").write(s.replace(old, new))
PY
}

# ── the whole fixture passes ────────────────────────────────────────────
out=$(run); rc=$?
expect_eq "good fixture: exit 0, ONBOARD PASS" "$rc:$(printf '%s\n' "$out" | tail -1)" "0:ONBOARD PASS"
expect_eq "good fixture: steps 1-8 in order, all PASS" "$(printf '%s\n' "$out" | sed -nE 's/^(PASS|WARN|FAIL) step\.([0-9]) .*/\2\1/p' | tr '\n' ' ')" \
  "1PASS 2PASS 3PASS 4PASS 5PASS 6PASS 7PASS 8PASS "
expect_has "step 3 counts the rows (an escaped pipe stays inside its cell)" "$(level "$out" 3) $out" 'PASS step\.3 queue: .*: 3 rows'
out=$(run --bogus); rc=$?
expect_eq "unknown option: usage (exit 2)" "$rc" 2

# one step broken at a time: that step FAILs and the run FAILs
case_fail() { # <name> <step>
  local out rc
  out=$(run); rc=$?
  expect_eq "$1: step.$2 FAIL, ONBOARD FAIL, exit 1" "$(level "$out" "$2"):$(printf '%s\n' "$out" | tail -1):$rc" "FAIL:ONBOARD FAIL:1"
  restore
}

# ① vision
edit vision.md '## Non-goals' '## Later'; case_fail "vision without non-goals" 1
rm "$C/vision.md"; case_fail "no vision file" 1
printf 'ROTATION_VISION_FILE=docs/direction.md\n' >> "$C/rotation/rotation.conf"; case_fail "ROTATION_VISION_FILE pointing at a missing file" 1
mkdir -p "$P/docs"; cp "$TMP/good.vision.md" "$P/docs/direction.md"; printf 'ROTATION_VISION_FILE=docs/direction.md\n' >> "$C/rotation/rotation.conf"
expect_eq "ROTATION_VISION_FILE relative to the root: step.1 PASS" "$(level "$(run)" 1)" PASS; restore
# ② roadmap
edit plan-state.md '## L2 version scope' '## Notes'; case_fail "plan without L2" 2
rm "$C/plan-state.md"; case_fail "no plan file" 2
# ③ queue table
edit plan-state.md '| control | CT-pid |' '| control | pid |'; case_fail "queue id without a prefix" 3
edit plan-state.md '| CT-dry | queued |' '| CT-dry | someday |'; case_fail "queue state not in the list" 3
edit plan-state.md '| r1 | `make test-ui` exits 0 |' '| r1 | — |'; case_fail "queue row with an empty acceptance" 3
edit plan-state.md '| lane | id | status |' '| track | id | status |'; case_fail "queue header not recognised" 3
edit plan-state.md '| control | CT-dry | queued | boil-dry cutoff |' '| control | CT-dry | queued |'; case_fail "queue row with eight cells" 3
python3 - "$C/plan-state.md" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
s = s.replace("| lane | id | status | summary | source | registered | acceptance | blocked_by | done |",
              "| 通道 | id | 状态 | 一句话 | 出处 | 登记 | 验收 | blocked_by | done |")
s = s.replace("| active |", "| 在做 |").replace("| queued |", "| 排队 |")
open(p, "w", encoding="utf-8").write(s)
PY
expect_eq "queue with the Chinese header and states: step.3 PASS" "$(level "$(run)" 3)" PASS
printf 'ROTATION_QUEUE_STATES=open,closed\n' >> "$C/rotation/rotation.conf"
expect_eq "ROTATION_QUEUE_STATES narrows the states: 在做 now FAILs" "$(level "$(run)" 3)" FAIL
restore
printf 'ROTATION_QUEUE_HEADER=track|key|state|what|from|reg|check|after|commit\n' >> "$C/rotation/rotation.conf"
edit plan-state.md '| lane | id | status | summary | source | registered | acceptance | blocked_by | done |' '| track | key | state | what | from | reg | check | after | commit |'
expect_eq "ROTATION_QUEUE_HEADER names the project's own columns: step.3 PASS" "$(level "$(run)" 3)" PASS
restore
# ④ L3a / L3b
edit plan-state.md '## L3b cold queue' '## Ideas'; case_fail "plan without L3b" 4
# ⑤ L4
edit plan-state.md '- CT-dry moves to L3a when CT-pid is done' '- CT-dry moves to L3a when CT-pid is 80% done'; case_fail "L4 with a percentage threshold" 5
edit plan-state.md '## L4 trigger predicates' '## History (see L4 in the wiki)'; case_fail "L4 only mentioned in passing in a heading" 5
# ⑥ stamps
printf 'tests\tsrc/**\t-\ttests\t1\tsync\t-\t-\t-\t-\n' >> "$C/rotation/close_rules.tsv"; case_fail "rules row with a stamp not in ROTATION_STAMPS" 6
printf 'ROTATION_STAMPS=\n' >> "$C/rotation/rotation.conf"; case_fail "ROTATION_STAMPS empty" 6
rm "$P/.dev/stamps/sweep-latest.json"; out=$(run); rc=$?
expect_eq "no stamp yet: step.6 WARN, the run still passes" "$(level "$out" 6):$rc" "WARN:0"
echo '{"headSha":"x"}' > "$P/.dev/stamps/sweep-latest.json"
# ⑦ handoff
edit handoff.md 'gate: 10/0/0' 'gates ran'; case_fail "trigger section without gate:" 7
edit handoff.md '## rotate-trigger' '## next'; case_fail "handoff without the trigger section" 7
edit handoff.md '## rotate-trigger' '## rotate 触发'; printf 'ROTATION_TRIGGER_SECTION=rotate 触发\n' >> "$C/rotation/rotation.conf"
expect_eq "ROTATION_TRIGGER_SECTION names the heading: step.7 PASS" "$(level "$(run)" 7)" PASS
restore
# ⑧ lanes
(cd "$P" && CLAUDE_PLUGIN_ROOT="$ROOT" bash "$KBIN/init.sh" --lane ui >/dev/null 2>&1)
out=$(run)
expect_has "a lane wired and described: step.8 PASS naming it" "$out" '^PASS step\.8 lanes: .* describes ui '
edit plan-state.md 'Merge: tags merged into develop by the control lane.' 'Nothing else.'; case_fail "lane section without its merge protocol" 8
edit plan-state.md '### Lane ui' '### Lane screens'; case_fail "lane without a section" 8
printf 'ROTATION_LANE_NAME=control\n' >> "$C/rotation/rotation.conf"
expect_eq "the named first lane is described too: step.8 PASS" "$(level "$(run)" 8)" PASS
edit plan-state.md '### Lane control' '### Lane heater'; printf 'ROTATION_LANE_NAME=control\n' >> "$C/rotation/rotation.conf"; case_fail "the named first lane without a section" 8
printf 'ROTATION_LANES_DOC=docs/lanes.md\n' >> "$C/rotation/rotation.conf"; case_fail "ROTATION_LANES_DOC pointing at a missing file" 8
out=$(run --lane ui); rc=$?
expect_eq "--lane ui: the lane's handoff is empty, step.7 FAIL" "$(level "$out" 7):$rc" "FAIL:1"
cp "$TMP/good.handoff.md" "$C/rotation-lanes/ui/handoff.md"
printf 'export ROTATION_STAMP_DIR="$PROJECT_DIR/.dev/stamps"\n' > "$C/rotation-lanes/ui/project.sh"
out=$(run --lane ui); rc=$?
expect_eq "--lane ui with its handoff written: ONBOARD PASS" "$rc:$(printf '%s\n' "$out" | tail -1)" "0:ONBOARD PASS"
out=$(run --lane nosuch); rc=$?
expect_eq "--lane of a lane that does not exist: exit 1" "$rc" 1

# ── doctor.sh plan.* ────────────────────────────────────────────────────
doc() { (cd "$P" && bash .claude/rotation/doctor.sh 2>&1); }
plan_rows() { printf '%s\n' "$1" | grep -E '^(PASS|WARN|FAIL) plan\.' | awk '{print $1 ":" $2}' | tr '\n' ' '; }
out=$(doc)
expect_eq "doctor: plan.queue, plan.l4, plan.handoff PASS on the good fixture" "$(plan_rows "$out")" "PASS:plan.queue PASS:plan.l4 PASS:plan.handoff "
expect_has "doctor: the plan rows come just before the verdict line" "$(printf '%s\n' "$out" | tail -2 | head -1)" '^PASS plan\.handoff '
edit plan-state.md '| r1 | `make test-ui` exits 0 |' '| r1 | — |'
out=$(doc)
expect_eq "doctor: a broken queue table is FAIL plan.queue" "$(plan_rows "$out")" "FAIL:plan.queue PASS:plan.l4 PASS:plan.handoff "
expect_eq "doctor: the FAIL counts in the verdict line" "$(printf '%s\n' "$out" | tail -1)" "DOCTOR FAIL n=$(printf '%s\n' "$out" | grep -c '^FAIL ')"
expect_eq "doctor: doctor.result names plan.queue among the failed" \
  "$(tail -1 "$C/rotation-state/events.jsonl" | python3 -c 'import json,sys; print("plan.queue" in json.loads(sys.stdin.read())["doctor"]["failed"])')" True
restore
rm "$C/plan-state.md" "$C/handoff.md"
out=$(doc)
expect_eq "doctor: no plan file and no handoff yet (a project wired before onboarding): WARN, not FAIL" "$(plan_rows "$out")" "WARN:plan.queue WARN:plan.l4 WARN:plan.handoff "
restore

echo "onboard_self_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
