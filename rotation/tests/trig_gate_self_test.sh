#!/usr/bin/env bash
#
# rotation kernel — trig_gate.sh self-test.
#
# The TRIG gate had no test until 2026-09-07, which is part of why two
# of its inputs could rot unnoticed. Every branch that can block or
# release a rotation is exercised here against fixtures: a throwaway git
# repository (ROTATION_PROJECT_DIR), a rotation.conf written here
# (ROTATION_CONF), fake reading / freshness / sweep-line commands under
# $TMP/bin, and redirected logs — nothing depends on the project this
# kernel is installed in, its adapter, or its name.
#
# Cases:
#   1  happy path                       → exit 0, TRIG-1..7 PASS
#   2  too few commits                  → exit 1, TRIG-1 FAIL
#   3  too few commits + over wall cap   → exit 0, TRIG-1 WAIVED
#   4  wall under the floor              → exit 1, TRIG-2 FAIL
#   5  missing axis:                     → exit 1, TRIG-3 FAIL
#   6  closed: sha outside session range → exit 1, TRIG-3 FAIL
#   7  gate: triple with a nonzero fail  → exit 1, TRIG-3 FAIL
#   8  blacklist phrase                  → exit 1, TRIG-4 FAIL
#   9  8th consecutive same-axis, no review → exit 1, TRIG-5 FAIL
#  10  same, with axes-review:           → exit 0, TRIG-5 PASS
#  11  a stamp missing                    → exit 1, TRIG-6 FAIL
#  12  a stamp from an earlier session    → exit 1, TRIG-6 FAIL
#  13  a stamp written against a dirty tree → exit 1, TRIG-6 FAIL
#  14  a stamp whose verdict is fail      → exit 1, TRIG-6 FAIL
#  15  no sweep: line in the handoff       → exit 1, TRIG-7 FAIL
#  16  a hand-edited sweep counter         → exit 1, TRIG-7 FAIL
#  17  the pasted sweep line               → exit 0, TRIG-7 PASS
#  18  axis skew, review without the reading → exit 1, TRIG-5 FAIL
#  19  axis skew, axis reading months old    → exit 1, TRIG-5 FAIL
#  20  commits enough, one thing closed     → exit 1, TRIG-1 FAIL
#  21  reading against a stale comparator   → exit 1, TRIG-5 FAIL
#  22  reading with no comparator version   → exit 1, TRIG-5 FAIL
#  23  every commit carries Agent-Origin     → exit 1, TRIG-1 FAIL
#  24  an old stamp carried to HEAD by the close plan → exit 0, TRIG-6 PASS
#  25  carried to an earlier commit of the session   → exit 1, TRIG-6 FAIL
#  26  a red stamp carried                           → exit 1, TRIG-6 FAIL
#  27  ROTATION_STAMPS empty in the conf             → exit 1, TRIG-6 FAIL (not PASS on 0 stamps)
#  28  a stamp without a verdict key                 → exit 1, TRIG-6 FAIL (unknown is not green)
#  29  no sweep line command configured              → exit 1, TRIG-7 FAIL (not SKIP)
#  30  sweep stamp missing                           → exit 1, TRIG-7 FAIL (not SKIP)
#  31  a threshold in the environment is ignored     → exit 1, TRIG-1 FAIL at the conf's N
#  32  a threshold lowered in the conf takes effect  → exit 0, TRIG-1 PASS
#  33  no rotation.conf                              → exit 2
#  34  rotation.conf for another kernel major        → exit 2
#  35  the recorded row carries the effective conf   (thresholds / confSha256 / kernelVersion)
#  36  an axis outside ROTATION_AXES                 → exit 1, TRIG-3 FAIL
#  37  the English section heading is accepted       → exit 0, TRIG-3 PASS
#  38  trigger.sh manual without a terminal          → exit 3, nothing written
#  39  a --no-ff merge counts as one commit          → exit 1, TRIG-1 FAIL commits=1
#  40  TRIG2_MEASURE=active, rotation.start 50min ago   → TRIG-2 PASS on the active wall
#  41  active, rotation.start 10min ago                 → exit 1, TRIG-2 FAIL under the floor
#  42  active, no start event in the round              → exit 1, TRIG-2 FAIL (unknown is not a pass)
#  43  active, only agent.start role=rotation           → TRIG-2 PASS from that event
#  44  active, rotation.start past the cap              → exit 0, TRIG-1 WAIVED on the active wall
#  45  TRIG2_MEASURE set to something else              → exit 2
#  46  trigger measure ignores the events               → TRIG-2 PASS wall=120min as before
#  47  the row's activeWallSec from rotation.start, managerCommits skips executor-interval / Agent-Origin, merge is one
#  48  activeWallSec falls back to the first rotation agent.start
#  49  no start event: activeWallSec null, every first-parent commit is the manager's
#  50  TRIG-8 switch absent (off)                      → no TRIG-8 line at all (output unchanged)
#  51  TRIG-8 on, substrate changed, gate.end of this round → TRIG-8 PASS
#  52  TRIG-8 on, substrate changed, no gate.end          → exit 1, TRIG-8 FAIL
#  53  TRIG-8 on, range off every trigger path            → TRIG-8 PASS without a gate
#  54  TRIG-8 switch with an unknown value                → exit 2
#  55  TRIG-8 on without a rules table                    → exit 1, TRIG-8 FAIL
#  56  TRIG1A_MODE=observe, commits under N, 3 closed    → exit 0, TRIG-1 OBSERVE (recorded, not enforced)
#  57  the same under enforce (default)                   → exit 1, TRIG-1 FAIL
#  58  observe, commits under N, one thing closed         → exit 1, TRIG-1 FAIL (TRIG-1b still enforces)
#  59  TRIG2_MODE=observe, wall under the floor           → exit 0, TRIG-2 OBSERVE; enforce → exit 1
#  60  TRIG2_MODE=observe, active wall unknown            → exit 0, TRIG-2 OBSERVE
#  61  a mode with an unknown value                       → exit 2
#  62  ROTATION_TRIGGER_SECTION=handover                  → `## handover` read, `## rotate-trigger` not
#  63  a conf alternation reads both headings            → TRIG-3 PASS on `## handover` under `handover|rotate-trigger`
#  64  blacklist: kernel list alone is 7 patterns; the project's additions are counted and a kernel phrase still hits
#  65  stats --effect --json: throughput from the closing row's activeWallSec; null when the row predates it
#  66  stats --effect --json: regressions = verdict red + sweep passes lost; null without a verdict
#  67  stats --effect --json: gap = trigger → first rotation.start; null without one
#  68  stats --effect --json: restarts = executor registrations − 1, resumes beside it; null without an executor
#  69  stats --effect (table): the round's line, and the null note
#  70  stats --suggest under the bootstrap count            → how many more rounds
#  71  stats --suggest with enough rows                     → p10/p50/p90, N = ⌊p50 × 0.8⌋, cap = active p90 (or how many more)
#  72  TRIG-9 switch absent (off)                       → no TRIG-9 line, exit 0 (a red verdict changes nothing)
#  73  TRIG-9 on, no verdict for the round              → exit 1, TRIG-9 FAIL (not SKIP)
#  74  TRIG-9 on, verdict planned but never filled      → exit 1, TRIG-9 FAIL
#  75  TRIG-9 on, filled verdict with red              → exit 1, TRIG-9 FAIL naming each red line
#  76  TRIG-9 on, filled verdict with red=0            → TRIG-9 PASS, exit 0
#  77  TRIG-9 switch with an unknown value              → exit 2
#
# Exit: 0 if all cases behave as expected; 1 otherwise.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$(cd "$SCRIPT_DIR/../bin" && pwd)"
GATE="$BIN/trig_gate.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

# ── the throwaway repository: 30 commits on `develop` ───────────────────
REPO="$TMP/repo"
mkdir -p "$REPO/.claude" "$TMP/bin" "$TMP/stamps" "$TMP/state"
g() { git -C "$REPO" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
g init -q -b develop
for i in $(seq 1 30); do
  echo "$i" > "$REPO/f$i.txt"; g add "f$i.txt"; g commit -q -m "feat: change $i"
done
PROJECT=$(basename "$REPO")

# A sha that really is in the fixture's recent history, and one that is not.
REAL_SHA="$(g rev-parse --short HEAD)"
REAL_SHA2="$(g rev-parse --short HEAD~1)"
REAL_SHA3="$(g rev-parse --short HEAD~2)"
OLD_SHA="$(g rev-list HEAD | tail -1 | cut -c1-9)"

# ── the conf, and the fake project commands ─────────────────────────────
mk_conf() {  # mk_conf <file> [extra lines...]
  local f=$1; shift
  {
    echo "ROTATION_CONF_KERNEL=1"
    echo "ROTATION_TRIG1_MIN_COMMITS=12"
    echo "ROTATION_TRIG1_MIN_CLOSED=3"
    echo "ROTATION_TRIG2_MIN_WALL_SEC=1800"
    echo "ROTATION_TRIG2_MAX_WALL_SEC=18000"
    echo "ROTATION_TRIG5_SAME_AXIS_MAX=8"
    echo "ROTATION_TRIG5_BENCH_MAX_AGE_DAYS=14"
    echo "ROTATION_AXES=A,B,C,D,E"
    echo "ROTATION_STAMPS=sweep determinism gmalloc file-size"
    echo "ROTATION_AXIS_STAMP=bench"
    echo "ROTATION_SWEEP_STAMP=sweep"
    printf '%s\n' "$@"
  } > "$f"
}
mk_conf "$TMP/rotation.conf"

cat > "$TMP/bin/sweep_line.sh" <<'EOF'
#!/bin/sh
# stands in for the project's sweep line: renders the stamp's counters; exit 2 when there is no stamp
f="${ROTATION_SWEEP_JSON:-${HARDEV_SWEEP_JSON:-}}"
[ -f "$f" ] || exit 2
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("sweep: head=%s pass=%s passTotal=%s bug=%s harnessError=%s conservation=n/a" % (d["headSha"], d["pass"], d["passTotal"], d["bug"], d["harnessError"]))' "$f"
EOF
cat > "$TMP/bin/axis_line.sh" <<'EOF'
#!/bin/sh
# stands in for the project's axis reading line
f="${ROTATION_AXIS_JSON:-${HARDEV_BENCH_JSON:-}}"
[ -f "$f" ] || exit 2
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("reading: head=%s median=%s cells=%s ran=%s comparator=%s" % (d["headSha"], d["median"], d["cells"], d["benchRanAt"], d.get("comparatorStamped")))' "$f"
EOF
cat > "$TMP/bin/fresh.sh" <<'EOF'
#!/bin/sh
# stands in for the comparator freshness check: the stamp's comparator version against a pinned upstream
f="${ROTATION_AXIS_JSON:-${HARDEV_BENCH_JSON:-}}"
up="${FIXTURE_UPSTREAM:-1.4.2}"
st=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("comparatorStamped") or "")' "$f")
if [ -z "$st" ]; then echo "fresh: status=unknown stamped=none upstream=$up"; exit 2; fi
if [ "$st" != "$up" ]; then echo "fresh: status=stale stamped=$st upstream=$up"; exit 1; fi
echo "fresh: status=current stamped=$st"
EOF
chmod +x "$TMP"/bin/*.sh

# Write a rotations.jsonl of self rows sitting `age` seconds back and
# `n` commits behind HEAD. Any further arguments are the axis values,
# one row each, oldest first — the LAST one is the most recent rotation,
# which is the row lib.sh reads for wall time and commit count. With no
# axis arguments a single axis-less row is written (the pre-2026-09-07
# schema, which TRIG-5 must treat as unknown rather than as a streak).
mk_log() {
  local file=$1 age=$2 n=$3; shift 3
  local ts base
  ts=$(( $(date +%s) - age ))
  base=$(g rev-parse --short "HEAD~$n")
  : > "$file"
  if [ "$#" -eq 0 ]; then
    set -- null
  fi
  local a
  for a in "$@"; do
    printf '{"rotationId":"r-x","at":"x","ts":%d,"project":"%s","trigger":"self","prevHead":"%s","axis":%s}\n' \
      "$ts" "$PROJECT" "$base" "$a" >> "$file"
  done
}

# Four run stamps, all naming HEAD, all green — the shape TRIG-6 wants.
# Every case below inherits these unless it deliberately breaks one.
mk_stamps() {
  mkdir -p "$TMP/stamps"
  local n
  for n in determinism gmalloc file-size; do
    printf '{"tool":"%s","headSha":"%s","verdict":"ok"}\n' \
      "$n" "$REAL_SHA" > "$TMP/stamps/$n-latest.json"
  done
  # The sweep stamp carries counters: TRIG-7 re-derives its line from them.
  printf '{"tool":"sweep","headSha":"%s","verdict":"ok","harnessError":0,"pass":31277,"passTotal":36974,"bug":11555}\n' "$REAL_SHA" \
    > "$TMP/stamps/sweep-latest.json"
  # The axis reading stamp, dated now: TRIG-5 rejects a reading older than 14d, and one whose
  # comparator is not the pinned upstream (FIXTURE_UPSTREAM in run_case).
  printf '{"tool":"bench","headSha":"%s","benchRanAt":"%s","median":0.5067,"cells":46,"comparatorStamped":"1.4.2"}\n' \
    "$REAL_SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$TMP/stamps/bench-latest.json"
  READING_LINE=$(ROTATION_AXIS_JSON="$TMP/stamps/bench-latest.json" sh "$TMP/bin/axis_line.sh")
}

# The sweep line as the fixture command renders the stamp above.
SWEEP_LINE="sweep: head=REPLACED pass=31277 passTotal=36974 bug=11555 harnessError=0 conservation=n/a"

mk_handoff() {
  printf '%s\n' "## rotate-trigger" "" "$@" > "$TMP/handoff.md"
  # TRIG-7 reads the whole handoff, so every fixture carries the sweep
  # line unless the case is specifically about it.
  printf '%s\n' "${SWEEP_LINE/REPLACED/$REAL_SHA}" >> "$TMP/handoff.md"
}

# Every invocation points the kernel at the fixtures. Overridable per case
# through CONF / SWEEP_CMD / EXTRA_ENV.
CONF="$TMP/rotation.conf"
SWEEP_CMD="$TMP/bin/sweep_line.sh"
EXTRA_ENV=()
run_gate() {
  env ROTATION_PROJECT_DIR="$REPO" ROTATION_CONF="$CONF" ROTATION_PROJECT_SH=/dev/null \
      ROTATION_STATE_DIR="$TMP/state" HARDEV_ROTATIONS_LOG="$TMP/rot.jsonl" HARDEV_EVENTS_LOG="$TMP/events.jsonl" \
      HARDEV_HANDOFF_FILE="$TMP/handoff.md" ROTATION_STAMP_DIR="$TMP/stamps" \
      ROTATION_SWEEP_LINE_CMD="$SWEEP_CMD" ROTATION_AXIS_READING_CMD="$TMP/bin/axis_line.sh" \
      ROTATION_AXIS_READING_FRESH_CMD="$TMP/bin/fresh.sh" FIXTURE_UPSTREAM=1.4.2 \
      ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} "$@"
}
run_case() {
  local name=$1 want_exit=$2 want_line=$3
  local out rc
  out=$(run_gate bash "$GATE" 2>&1)
  rc=$?
  if [ "$rc" -eq "$want_exit" ] && printf '%s\n' "$out" | grep -qE "$want_line"; then
    printf 'ok   %s\n' "$name"
    pass=$(( pass + 1 ))
  else
    printf 'FAIL %s (exit=%d want=%d; wanted line /%s/)\n' "$name" "$rc" "$want_exit" "$want_line"
    printf '%s\n' "$out" | sed 's/^/       | /'
    fail=$(( fail + 1 ))
  fi
}
ok() { printf 'ok   %s\n' "$1"; pass=$(( pass + 1 )); }
bad() { printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; fail=$(( fail + 1 )); }

GOOD_AXIS="axis: A"
# Three entries: TRIG-1's second measure wants >= 3 things named, and a
# fixture that only ever carries one would make the happy path depend on
# the threshold never rising.
GOOD_CLOSED="closed: $REAL_SHA did a thing; $REAL_SHA2 did another; $REAL_SHA3 did a third"
GOOD_GATE="gate: 3773/0/4"

mk_stamps

# 1 — happy path: 12 commits, 2h wall, full section, four green stamps.
mk_log "$TMP/rot.jsonl" 7200 12
mk_handoff "$GOOD_AXIS" "$GOOD_CLOSED" "$GOOD_GATE"
run_case "1 happy path" 0 'TRIG-1 PASS'

# 2 — six commits is no longer enough.
mk_log "$TMP/rot.jsonl" 7200 6
run_case "2 too few commits" 1 'TRIG-1 FAIL'

# 3 — same six commits, but past the wall cap: the escape hatch.
mk_log "$TMP/rot.jsonl" 19000 6
run_case "3 over cap waives TRIG-1" 0 'TRIG-1 WAIVED'

# 4 — twelve commits inside twenty minutes is a batch of trivia.
mk_log "$TMP/rot.jsonl" 1200 12
run_case "4 under wall floor" 1 'TRIG-2 FAIL'

# 5 — no axis line.
mk_log "$TMP/rot.jsonl" 7200 12
mk_handoff "$GOOD_CLOSED" "$GOOD_GATE"
run_case "5 missing axis" 1 'TRIG-3 FAIL'

# 6 — a sha, but not one from this session.
mk_handoff "$GOOD_AXIS" "closed: $OLD_SHA ancient history" "$GOOD_GATE"
run_case "6 closed sha out of range" 1 'TRIG-3 FAIL'

# 7 — the gate is red.
mk_handoff "$GOOD_AXIS" "$GOOD_CLOSED" "gate: 3773/2/4"
run_case "7 red gate" 1 'TRIG-3 FAIL'

# 8 — a blacklisted phrasing (kernel list).
mk_handoff "$GOOD_AXIS" "$GOOD_CLOSED" "$GOOD_GATE" "the ROI is too low, stopping here"
run_case "8 blacklist phrase" 1 'TRIG-4 FAIL'

# 8b — a phrase the project added through ROTATION_BLACKLIST_EXTRA.
mk_conf "$TMP/conf-bl.conf" 'ROTATION_BLACKLIST_EXTRA=fresh session is safer;too much work'
mk_handoff "$GOOD_AXIS" "$GOOD_CLOSED" "$GOOD_GATE" "too much work, next round then"
CONF="$TMP/conf-bl.conf" run_case "8b project blacklist phrase" 1 'TRIG-4 FAIL.*too much work'
run_case "8c the same phrase passes without the project list" 0 'TRIG-4 PASS'

# 9 — seven prior rotations all on axis A, and this one too, unsettled.
mk_log "$TMP/rot.jsonl" 7200 12 '"A"' '"A"' '"A"' '"A"' '"A"' '"A"' '"A"' '"A"'
mk_handoff "$GOOD_AXIS" "$GOOD_CLOSED" "$GOOD_GATE"
run_case "9 axis skew unsettled" 1 'TRIG-5 FAIL'

# 10 — same skew, settled in writing, with the reading.
mk_handoff "$GOOD_AXIS" "$GOOD_CLOSED" "$GOOD_GATE" \
  "axes-review: E still 0%; C closed; D framing only. $READING_LINE"
run_case "10 axis skew settled" 0 'TRIG-5 PASS'

# ── TRIG-6 — the stamps ───────────────────────────────────────────────
mk_log "$TMP/rot.jsonl" 7200 12
mk_handoff "$GOOD_AXIS" "$GOOD_CLOSED" "$GOOD_GATE"

rm -f "$TMP/stamps/gmalloc-latest.json"
run_case "11 stamp missing" 1 'TRIG-6 FAIL.*missing: gmalloc'
mk_stamps

# The carry-forward this gate exists to stop: last rotation's answer,
# correct in itself, wearing this rotation's label.
printf '{"tool":"determinism","headSha":"%s","verdict":"ok"}\n' "$OLD_SHA" \
  > "$TMP/stamps/determinism-latest.json"
run_case "12 stamp from earlier session" 1 'TRIG-6 FAIL.*not from this session'
mk_stamps

# A dirty tree measures something that is not any commit.
printf '{"tool":"file_size_audit","headSha":"%s-dirty","verdict":"ok"}\n' "$REAL_SHA" \
  > "$TMP/stamps/file-size-latest.json"
run_case "13 stamp from a dirty tree" 1 'TRIG-6 FAIL.*not from this session'
mk_stamps

printf '{"tool":"gmalloc_scan","headSha":"%s","verdict":"fail"}\n' "$REAL_SHA" \
  > "$TMP/stamps/gmalloc-latest.json"
run_case "14 stamp verdict red" 1 'TRIG-6 FAIL.*red: gmalloc'
mk_stamps

# 14b — stamps written with the full 40-hex sha (what the stamp writers
# record) are fresh: the session's rev-list is matched by prefix either way.
for n in determinism gmalloc file-size; do
  printf '{"tool":"%s","headSha":"%s","verdict":"ok"}\n' "$n" "$(g rev-parse HEAD)" > "$TMP/stamps/$n-latest.json"
done
run_case "14b stamps naming HEAD by its full sha are fresh" 0 "TRIG-6 PASS.*determinism=$(g rev-parse HEAD)"
mk_stamps

# The legitimate carry-forward: the close planner found nothing on the
# check's trigger paths changed since the stamp's sha and wrote carriedTo.
# An old sha carried to exactly this HEAD is fresh (24); carried to an
# earlier commit of the session it is not — later commits could have
# touched the paths (25); and a carry never launders a red reading (26).
FULL_HEAD="$(g rev-parse HEAD)"
printf '{"tool":"build_determinism","headSha":"%s","verdict":"ok","carriedTo":"%s","carriedReason":"no trigger path changed"}\n' \
  "$OLD_SHA" "$FULL_HEAD" > "$TMP/stamps/determinism-latest.json"
run_case "24 stamp carried to HEAD" 0 'TRIG-6 PASS.*determinism='"$OLD_SHA"'→carried'
printf '{"tool":"build_determinism","headSha":"%s","verdict":"ok","carriedTo":"%s"}\n' \
  "$OLD_SHA" "$REAL_SHA2" > "$TMP/stamps/determinism-latest.json"
run_case "25 stamp carried to an earlier commit" 1 'TRIG-6 FAIL.*not from this session: determinism'
printf '{"tool":"build_determinism","headSha":"%s","verdict":"fail","carriedTo":"%s"}\n' \
  "$OLD_SHA" "$FULL_HEAD" > "$TMP/stamps/determinism-latest.json"
run_case "26 red stamp carried" 1 'TRIG-6 FAIL.*red: determinism'
mk_stamps

# 27 — an empty stamp list is a configuration with no evidence, not a pass.
mk_conf "$TMP/conf-nostamps.conf" 'ROTATION_STAMPS='
CONF="$TMP/conf-nostamps.conf" run_case "27 empty ROTATION_STAMPS fails" 1 'TRIG-6 FAIL.*ROTATION_STAMPS is empty'

# 28 — a stamp with no verdict key: unknown is not green.
printf '{"tool":"gmalloc_scan","headSha":"%s","harnessError":0}\n' "$REAL_SHA" \
  > "$TMP/stamps/gmalloc-latest.json"
run_case "28 stamp without verdict is red" 1 'TRIG-6 FAIL.*red: gmalloc\(no-verdict\)'
mk_stamps

# ── TRIG-7 — the sweep line ───────────────────────────────────────────
mk_log "$TMP/rot.jsonl" 7200 12

printf '%s\n' "## rotate-trigger" "" "$GOOD_AXIS" "$GOOD_CLOSED" "$GOOD_GATE" > "$TMP/handoff.md"
run_case "15 no sweep line" 1 "TRIG-7 FAIL.*no 'sweep:' line"

mk_handoff "$GOOD_AXIS" "$GOOD_CLOSED" "$GOOD_GATE"
sed -i '' 's/passTotal=36974/passTotal=36999/' "$TMP/handoff.md"
run_case "16 hand-edited counter" 1 'TRIG-7 FAIL.*disagrees.*passTotal=36974'

mk_handoff "$GOOD_AXIS" "$GOOD_CLOSED" "$GOOD_GATE"
run_case "17 pasted sweep line" 0 'TRIG-7 PASS'

# 29 — no sweep command configured: FAIL, not SKIP.
SWEEP_CMD= run_case "29 no sweep line command" 1 'TRIG-7 FAIL.*no sweep line configured'

# 30 — the sweep stamp is gone: FAIL, not SKIP ("stamp lost" must not look like a pass).
rm -f "$TMP/stamps/sweep-latest.json"
run_case "30 sweep stamp missing" 1 'TRIG-7 FAIL.*no sweep stamp'
mk_stamps

# ── TRIG-5 — the axis reading ──────────────────────────────────────────
# "not measured this round" is a true sentence that says nothing. The gate
# wants the number, and wants it recent and against the current comparator.
mk_log "$TMP/rot.jsonl" 7200 12 '"A"' '"A"' '"A"' '"A"' '"A"' '"A"' '"A"' '"A"'
mk_handoff "$GOOD_AXIS" "$GOOD_CLOSED" "$GOOD_GATE" \
  "axes-review: B not measured this round; E still 0%; C closed; D framing only"
run_case "18 review without the reading" 1 'TRIG-5 FAIL.*lacks the axis reading'

python3 -c 'import json,sys;json.dump({"tool":"bench","headSha":sys.argv[1],\
"benchRanAt":"2026-06-01T00:00:00Z","median":0.5067,"cells":46,"comparatorStamped":"1.4.2"},open(sys.argv[2],"w"))' \
  "$REAL_SHA" "$TMP/stamps/bench-latest.json"
mk_handoff "$GOOD_AXIS" "$GOOD_CLOSED" "$GOOD_GATE" "axes-review: $READING_LINE"
run_case "19 axis reading stale" 1 'TRIG-5 FAIL.*reading is [0-9]+d old'
mk_stamps

# 21 — the reading is recent and pasted, but taken against a comparator
# one release behind upstream: a ratio against last week's competitor.
python3 -c 'import json,sys;p=sys.argv[1];d=json.load(open(p));d["comparatorStamped"]="1.4.1";\
json.dump(d,open(p,"w"))' "$TMP/stamps/bench-latest.json"
OLD_CMP_LINE=$(ROTATION_AXIS_JSON="$TMP/stamps/bench-latest.json" sh "$TMP/bin/axis_line.sh")
mk_handoff "$GOOD_AXIS" "$GOOD_CLOSED" "$GOOD_GATE" "axes-review: $OLD_CMP_LINE"
run_case "21 reading against a stale comparator" 1 'TRIG-5 FAIL.*comparator is not current.*stamped=1.4.1'
mk_stamps

# 22 — the stamp has no comparator version at all: unknown is not current.
python3 -c 'import json,sys;p=sys.argv[1];d=json.load(open(p));d.pop("comparatorStamped");\
json.dump(d,open(p,"w"))' "$TMP/stamps/bench-latest.json"
NO_CMP_LINE=$(ROTATION_AXIS_JSON="$TMP/stamps/bench-latest.json" sh "$TMP/bin/axis_line.sh")
mk_handoff "$GOOD_AXIS" "$GOOD_CLOSED" "$GOOD_GATE" "axes-review: $NO_CMP_LINE"
run_case "22 reading without a comparator version" 1 'TRIG-5 FAIL.*comparator is not current.*status=unknown'
mk_stamps

# 20 — the count is met by slicing thinner; the closed list is not.
mk_log "$TMP/rot.jsonl" 7200 12
mk_handoff "$GOOD_AXIS" "closed: $REAL_SHA one thing only" "$GOOD_GATE"
run_case "20 twelve commits, one thing closed" 1 "TRIG-1 FAIL.*only 1 thing"

# 23 — agent-landed commits are not the main session's work. A pattern
# that matches every message turns twelve commits into zero; case 1
# (default pattern) is the other half: nothing real carries the trailer.
mk_log "$TMP/rot.jsonl" 7200 12
mk_handoff "$GOOD_AXIS" "$GOOD_CLOSED" "$GOOD_GATE"
EXTRA_ENV=(ROTATION_AGENT_ORIGIN_PATTERN=.)
run_case "23 agent-origin commits not counted" 1 'TRIG-1 FAIL.*commits=0 '
EXTRA_ENV=()

# ── the conf is the only source of thresholds ─────────────────────────
# 31 — a threshold in the environment is ignored: six commits still fail at the conf's N=12.
mk_log "$TMP/rot.jsonl" 7200 6
EXTRA_ENV=(ROTATION_TRIG1_MIN_COMMITS=1 HARDEV_TRIG1_MIN_COMMITS=1)
run_case "31 environment threshold ignored" 1 'TRIG-1 FAIL.*commits=6 < N=12'
EXTRA_ENV=()

# 32 — the same six commits pass when the conf itself says N=5.
mk_conf "$TMP/conf-low.conf" 'ROTATION_TRIG1_MIN_COMMITS=5'
CONF="$TMP/conf-low.conf" run_case "32 conf threshold takes effect" 0 'TRIG-1 PASS.*commits=6 ≥ N=5'

# 33 — no conf at all is a configuration error, not a gate result.
CONF="$TMP/does-not-exist.conf" run_case "33 missing rotation.conf" 2 'no rotation.conf'

# 34 — a conf written for another kernel major is refused.
mk_conf "$TMP/conf-v9.conf" 'ROTATION_CONF_KERNEL=9'
CONF="$TMP/conf-v9.conf" run_case "34 conf for another kernel major" 2 'written for kernel major 9'

# 35 — the row the trigger writes carries the effective conf.
mk_log "$TMP/rot.jsonl" 7200 12
run_gate bash -c '. "$1/lib.sh"; autorun_record_rotation r-conf-test self' _ "$BIN" >/dev/null 2>&1
row=$(tail -1 "$TMP/rot.jsonl" | python3 -c '
import json, sys
r = json.loads(sys.stdin.read())
t = r.get("thresholds") or {}
print(r.get("kernelVersion"), bool(r.get("confSha256")), t.get("trig1MinCommits"), t.get("trig2MaxWallSec"), t.get("axes"), t.get("stamps"), t.get("confSha256") == r.get("confSha256"))')
[ "$row" = "$(sed -nE 's/^ROTATION_KERNEL_VERSION="([^"]+)"$/\1/p' "$BIN/lib.sh") True 12 18000 A,B,C,D,E sweep determinism gmalloc file-size True" ] \
  && ok "35 recorded row carries kernelVersion / confSha256 / thresholds" \
  || bad "35 recorded row carries the effective conf" "got [$row]"

# 36 — an axis the conf does not list (case 35 appended a row at HEAD: rebuild the log first).
mk_log "$TMP/rot.jsonl" 7200 12
mk_handoff "axis: F" "$GOOD_CLOSED" "$GOOD_GATE"
run_case "36 axis outside ROTATION_AXES" 1 "TRIG-3 FAIL.*no valid 'axis:"

# 37 — the English heading is accepted by the default section regex.
printf '%s\n' "## rotate-trigger" "" "$GOOD_AXIS" "$GOOD_CLOSED" "$GOOD_GATE" "${SWEEP_LINE/REPLACED/$REAL_SHA}" > "$TMP/handoff.md"
run_case "37 English section heading" 0 'TRIG-3 PASS'

# 38 — the operator's override needs a terminal; a model's shell has none.
out=$(run_gate bash "$BIN/trigger.sh" manual </dev/null 2>&1); rc=$?
if [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q 'interactive terminal' && [ ! -f "$TMP/state/rotations.jsonl" ]; then
  ok "38 trigger.sh manual without a terminal is refused (exit 3, nothing written)"
else
  bad "38 trigger.sh manual without a terminal" "exit=$rc out=[$out]"
fi

# 39 — a --no-ff merge of a twelve-commit branch is one commit on the
# first-parent line: the floor is not met by merging a branch.
g checkout -q -b topic
for i in $(seq 1 12); do echo "$i" > "$REPO/t$i.txt"; g add "t$i.txt"; g commit -q -m "feat: topic $i"; done
g checkout -q develop
g merge -q --no-ff -m "merge: topic" topic
REAL_SHA="$(g rev-parse --short HEAD)"
mk_stamps
mk_log "$TMP/rot.jsonl" 7200 1
mk_handoff "$GOOD_AXIS" "closed: $REAL_SHA merged topic" "$GOOD_GATE"
run_case "39 merge counts as one first-parent commit" 1 'TRIG-1 FAIL.*commits=1 '

# ── TRIG-2 under ROTATION_TRIG2_MEASURE=active ─────────────────────────
# The events log is the fixture's: a round's start is whatever was written
# after the last self row's ts.
NOW=$(date +%s)
mk_events() {  # mk_events <seconds ago> <kind> <json members or ''> ... (triples)
  : > "$TMP/events.jsonl"
  while [ "$#" -ge 3 ]; do
    printf '{"at":"x","ts":%d,"kind":"%s","rotationId":"r-x","head":"x"%s}\n' "$(( NOW - $1 ))" "$2" "${3:+,$3}" >> "$TMP/events.jsonl"
    shift 3
  done
}
mk_conf "$TMP/conf-active.conf" 'ROTATION_TRIG2_MEASURE=active'
mk_log "$TMP/rot.jsonl" 7200 1
mk_handoff "$GOOD_AXIS" "closed: $REAL_SHA merged topic" "$GOOD_GATE"

mk_events 3000 rotation.start '"mode":"subagent","rotationAgent":"rot-1"'
CONF="$TMP/conf-active.conf" run_case "40 active measure reads rotation.start" 1 'TRIG-2 PASS active wall=50min inside'
mk_events 600 rotation.start '"mode":"subagent","rotationAgent":"rot-1"'
CONF="$TMP/conf-active.conf" run_case "41 active wall under the floor" 1 'TRIG-2 FAIL active wall=6[0-9][0-9]s \(10min\) < floor'
mk_events
CONF="$TMP/conf-active.conf" run_case "42 active wall unknown fails" 1 'TRIG-2 FAIL active wall unknown'
mk_events 4000 agent.start '"agent":{"name":"rot-1","role":"rotation","id":"ag-1"}' 3900 agent.start '"agent":{"name":"w1","role":"worker"}'
CONF="$TMP/conf-active.conf" run_case "43 active wall from the first rotation agent.start" 1 'TRIG-2 PASS active wall=66min inside'
mk_log "$TMP/rot.jsonl" 30000 1
mk_events 20000 rotation.start '"mode":"subagent","rotationAgent":"rot-1"'
CONF="$TMP/conf-active.conf" run_case "44 active wall past the cap waives TRIG-1" 0 'TRIG-1 WAIVED commits=1 closed=1 but active wall=200[0-9][0-9]s ≥ cap'
mk_conf "$TMP/conf-measure-bogus.conf" 'ROTATION_TRIG2_MEASURE=bogus'
CONF="$TMP/conf-measure-bogus.conf" run_case "45 unknown TRIG2 measure is a configuration error" 2 'ROTATION_TRIG2_MEASURE must be trigger or active'
mk_log "$TMP/rot.jsonl" 7200 1
mk_events 600 rotation.start '"mode":"subagent","rotationAgent":"rot-1"'
run_case "46 trigger measure ignores the events" 1 'TRIG-2 PASS wall=120min inside'

# ── the row's activeWallSec and managerCommits ──────────────────────────
# Round: self row 2h ago at the current HEAD; executor rot-1 ran from
# 6000s to 3000s ago and recorded rotation.start 5000s ago. Four commits
# land on the first-parent line afterwards: one inside the executor's
# interval, one by the manager, one by a parallel agent (Agent-Origin),
# and a --no-ff merge of a two-commit branch.
mk_log "$TMP/rot.jsonl" 7200 0
echo e1 > "$REPO/e1.txt"; g add e1.txt; GIT_COMMITTER_DATE="$(( NOW - 5500 )) +0000" g commit -q -m "feat: by the executor"
echo m1 > "$REPO/m1.txt"; g add m1.txt; GIT_COMMITTER_DATE="$(( NOW - 2000 )) +0000" g commit -q -m "fix: by the manager"
echo a1 > "$REPO/a1.txt"; g add a1.txt; GIT_COMMITTER_DATE="$(( NOW - 1500 )) +0000" g commit -q -m "feat: by an agent" -m "Agent-Origin: w1"
g checkout -q -b topic2
for i in 1 2; do echo "$i" > "$REPO/u$i.txt"; g add "u$i.txt"; GIT_COMMITTER_DATE="$(( NOW - 1200 )) +0000" g commit -q -m "feat: topic2 $i"; done
g checkout -q develop
GIT_COMMITTER_DATE="$(( NOW - 1000 )) +0000" g merge -q --no-ff -m "merge: topic2" topic2
row_measures() {  # record a row with the current fixtures and print "<activeWallSec> <managerCommits>"
  run_gate bash -c '. "$1/lib.sh"; autorun_record_rotation r-measures self' _ "$BIN" >/dev/null 2>&1
  python3 -c 'import json,sys; r=json.loads(open(sys.argv[1]).read().strip().split("\n")[-1]); print(r.get("activeWallSec"), r.get("managerCommits"))' "$TMP/rot.jsonl"
}
in_range() { [ "$1" != None ] && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; }  # the row's now is a few seconds after NOW
mk_events 6000 agent.start '"agent":{"name":"rot-1","role":"rotation","id":"ag-1"}' \
          5000 rotation.start '"mode":"subagent","rotationAgent":"rot-1","agent":{"name":"rot-1","id":"ag-1"}' \
          3000 agent.end '"agent":{"name":"rot-1","role":"rotation","id":"ag-1","status":"ok"}'
set -- $(row_measures)
in_range "$1" 5000 5060 && [ "$2" = 2 ] \
  && ok "47 row: activeWallSec from rotation.start ($1), managerCommits=2 (executor interval, Agent-Origin and the branch excluded; merge is one)" \
  || bad "47 row: activeWallSec / managerCommits" "got activeWallSec=$1 managerCommits=$2"
mk_log "$TMP/rot.jsonl" 7200 4
mk_events 6000 agent.start '"agent":{"name":"rot-1","role":"rotation","id":"ag-1"}'
set -- $(row_measures)
in_range "$1" 6000 6060 && [ "$2" = 0 ] \
  && ok "48 row: activeWallSec falls back to the first rotation agent.start ($1); an open executor interval runs to now" \
  || bad "48 row: activeWallSec from agent.start" "got activeWallSec=$1 managerCommits=$2"
mk_log "$TMP/rot.jsonl" 7200 4
mk_events
set -- $(row_measures)
[ "$1" = None ] && [ "$2" = 3 ] \
  && ok "49 row: no start event → activeWallSec null, managerCommits=3 (every first-parent commit without Agent-Origin)" \
  || bad "49 row: null active wall" "got activeWallSec=$1 managerCommits=$2"

# ── TRIG-8: the gate on record, not the gate in the handoff ─────────────
# The repository now ends in case 47's four first-parent commits (HEAD~4 = the
# first merge), three of them the main session's; a rules table whose check
# triggers on `*.txt` makes the range substrate, one on `src/**` makes it docs.
# Stamps and the handoff are rebuilt at this HEAD; the floors come down to 3 / 1.
REAL_SHA="$(g rev-parse --short HEAD)"
mk_stamps
GOOD_CLOSED="closed: $REAL_SHA merged topic2"
printf '#name\tpaths\tartifact\tstamp\tminutes\tmode\tsync_paths\tneeds\tshow\tregress\nsweep\t*.txt\t-\tsweep\t1\tsync\t-\t-\tpass\t-\n' > "$TMP/rules-txt.tsv"
printf '#name\tpaths\tartifact\tstamp\tminutes\tmode\tsync_paths\tneeds\tshow\tregress\nsweep\tsrc/**\t-\tsweep\t1\tsync\t-\t-\tpass\t-\n' > "$TMP/rules-src.tsv"
LOW='ROTATION_TRIG1_MIN_COMMITS=3'; LOWC='ROTATION_TRIG1_MIN_CLOSED=1'
mk_conf "$TMP/conf-trig8-off.conf" "$LOW" "$LOWC" "ROTATION_CLOSE_RULES=$TMP/rules-txt.tsv"
mk_conf "$TMP/conf-trig8.conf" "$LOW" "$LOWC" 'ROTATION_TRIG8_GATE_COVERAGE=on' "ROTATION_CLOSE_RULES=$TMP/rules-txt.tsv"
mk_conf "$TMP/conf-trig8-src.conf" "$LOW" "$LOWC" 'ROTATION_TRIG8_GATE_COVERAGE=on' "ROTATION_CLOSE_RULES=$TMP/rules-src.tsv"
mk_conf "$TMP/conf-trig8-bogus.conf" "$LOW" "$LOWC" 'ROTATION_TRIG8_GATE_COVERAGE=yes'
mk_conf "$TMP/conf-trig8-norules.conf" "$LOW" "$LOWC" 'ROTATION_TRIG8_GATE_COVERAGE=on'
mk_log "$TMP/rot.jsonl" 7200 4
mk_handoff "$GOOD_AXIS" "$GOOD_CLOSED" "$GOOD_GATE"
mk_events 3000 gate.end "\"gate\":{\"sha\":\"$REAL_SHA\",\"pass\":10,\"fail\":0,\"skip\":0}"
out=$(CONF="$TMP/conf-trig8-off.conf" run_gate bash "$GATE" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s\n' "$out" | grep -q 'TRIG-8'; then
  ok "50 TRIG-8 off by default: no TRIG-8 line, exit 0"
else
  bad "50 TRIG-8 off by default" "exit=$rc out=[$out]"
fi
CONF="$TMP/conf-trig8.conf" run_case "51 TRIG-8 on: gate.end of this round covers the substrate" 0 'TRIG-8 PASS substrateFiles=[1-9][0-9]* gateEnds=1 atHead=yes missing=no \(round r-x\)'
mk_events
CONF="$TMP/conf-trig8.conf" run_case "52 TRIG-8 on: substrate changed, no gate.end" 1 'TRIG-8 FAIL substrateFiles=[1-9][0-9]* gateEnds=0 atHead=no missing=yes — .*round r-x; run the gate through ROTATION_GATE_CMD'
CONF="$TMP/conf-trig8-src.conf" run_case "53 TRIG-8 on: nothing on a trigger path needs no gate" 0 'TRIG-8 PASS substrateFiles=0 gateEnds=0 atHead=no missing=no'
CONF="$TMP/conf-trig8-bogus.conf" run_case "54 unknown TRIG-8 switch value is a configuration error" 2 'ROTATION_TRIG8_GATE_COVERAGE must be on or off'
CONF="$TMP/conf-trig8-norules.conf" run_case "55 TRIG-8 on without a rules table" 1 'TRIG-8 FAIL no rules table \(ROTATION_CLOSE_RULES\)'

# ── TRIG-9: the round's filled close verdict has no red ─────────────────
# Same range and handoff as case 50 (which passes with TRIG-8 off); the round is r-x (the last rotations row).
mkdir -p "$TMP/verdicts"
mk_conf "$TMP/conf-trig9.conf" "$LOW" "$LOWC" 'ROTATION_TRIG9_VERDICT_RED=on'
mk_conf "$TMP/conf-trig9-bogus.conf" "$LOW" "$LOWC" 'ROTATION_TRIG9_VERDICT_RED=1'
EXTRA_ENV=(ROTATION_VERDICT_DIR="$TMP/verdicts")
printf '{"headSha":"%s","checks":[],"results":{"filledAt":"x","red":["clippy: total 1 → 22"],"amber":[]}}\n' "$(g rev-parse HEAD)" > "$TMP/verdicts/r-x.verdict.json"
out=$(CONF="$TMP/conf-trig8-off.conf" run_gate bash "$GATE" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s\n' "$out" | grep -q 'TRIG-9'; then
  ok "72 TRIG-9 off by default: no TRIG-9 line, a red verdict does not block, exit 0"
else
  bad "72 TRIG-9 off by default" "exit=$rc out=[$out]"
fi
rm -f "$TMP/verdicts/r-x.verdict.json"
CONF="$TMP/conf-trig9.conf" run_case "73 TRIG-9 on: no verdict for the round is a FAIL" 1 "TRIG-9 FAIL no close verdict for round r-x at $TMP/verdicts/r-x.verdict.json"
printf '{"headSha":"%s","checks":[]}\n' "$(g rev-parse HEAD)" > "$TMP/verdicts/r-x.verdict.json"
CONF="$TMP/conf-trig9.conf" run_case "74 TRIG-9 on: a verdict never filled is a FAIL" 1 'TRIG-9 FAIL close verdict .*r-x.verdict.json was never filled — run close_verdict_fill.sh r-x'
printf '{"headSha":"%s","checks":[],"results":{"filledAt":"x","red":["clippy: total 1 → 22","sweep: pass 100 → 90"],"amber":["bench: x"]}}\n' "$(g rev-parse HEAD)" > "$TMP/verdicts/r-x.verdict.json"
CONF="$TMP/conf-trig9.conf" run_case "75 TRIG-9 on: red in the verdict blocks, each red line named" 1 \
  "TRIG-9 FAIL close verdict of r-x \(head $(g rev-parse --short=9 HEAD)\) has 2 red: clippy: total 1 → 22; sweep: pass 100 → 90"
printf '{"headSha":"%s","checks":[],"results":{"filledAt":"x","red":[],"amber":["bench: x"]}}\n' "$(g rev-parse HEAD)" > "$TMP/verdicts/r-x.verdict.json"
CONF="$TMP/conf-trig9.conf" run_case "76 TRIG-9 on: red=0 passes" 0 'TRIG-9 PASS close verdict of r-x \(head [0-9a-f]{9}\): red=0 amber=1'
CONF="$TMP/conf-trig9-bogus.conf" run_case "77 unknown TRIG-9 switch value is a configuration error" 2 'ROTATION_TRIG9_VERDICT_RED must be on or off'
EXTRA_ENV=()

# ── observe mode: TRIG-1a / TRIG-2 computed and printed, not enforced ──
# The range is HEAD~4..HEAD: three first-parent commits of the main session (the fourth carries
# Agent-Origin), under the default floors N=12 / M=3.
mk_log "$TMP/rot.jsonl" 7200 4
THREE_CLOSED="closed: $REAL_SHA merged topic2; $(g rev-parse --short HEAD~2) by the manager; $(g rev-parse --short HEAD~3) by the executor"
mk_handoff "$GOOD_AXIS" "$THREE_CLOSED" "$GOOD_GATE"
mk_conf "$TMP/conf-observe1a.conf" 'ROTATION_TRIG1A_MODE=observe'
CONF="$TMP/conf-observe1a.conf" run_case "56 TRIG-1a observe: under N, enough closed, not blocked" 0 \
  'TRIG-1 OBSERVE commits=3 < N=12 — not enforced \(ROTATION_TRIG1A_MODE=observe\); closed=3 ≥ M=3'
run_case "57 the same under enforce is blocked" 1 'TRIG-1 FAIL commits=3 < N=12'
mk_handoff "$GOOD_AXIS" "closed: $REAL_SHA merged topic2" "$GOOD_GATE"
CONF="$TMP/conf-observe1a.conf" run_case "58 TRIG-1a observe does not relax TRIG-1b" 1 \
  'TRIG-1 FAIL commits=3 < N=12 \(observed, not enforced\) and only 1 thing\(s\) named'
mk_conf "$TMP/conf-observe2.conf" 'ROTATION_TRIG2_MODE=observe' 'ROTATION_TRIG1_MIN_COMMITS=3' 'ROTATION_TRIG1_MIN_CLOSED=1'
mk_conf "$TMP/conf-enforce2.conf" 'ROTATION_TRIG1_MIN_COMMITS=3' 'ROTATION_TRIG1_MIN_CLOSED=1'
mk_log "$TMP/rot.jsonl" 1200 4
CONF="$TMP/conf-observe2.conf" run_case "59 TRIG-2 observe: under the floor, not blocked" 0 \
  'TRIG-2 OBSERVE wall=1[0-9]{3}s \(20min\) < floor=30min — not enforced \(ROTATION_TRIG2_MODE=observe\)'
CONF="$TMP/conf-enforce2.conf" run_case "59e the same under enforce is blocked" 1 'TRIG-2 FAIL wall=1[0-9]{3}s \(20min\) < floor=30min'
mk_conf "$TMP/conf-observe2a.conf" 'ROTATION_TRIG2_MODE=observe' 'ROTATION_TRIG2_MEASURE=active' 'ROTATION_TRIG1_MIN_COMMITS=3' 'ROTATION_TRIG1_MIN_CLOSED=1'
mk_log "$TMP/rot.jsonl" 7200 4
mk_events
CONF="$TMP/conf-observe2a.conf" run_case "60 TRIG-2 observe: active wall unknown, not blocked" 0 \
  'TRIG-2 OBSERVE active wall unknown: .* — not enforced \(ROTATION_TRIG2_MODE=observe\)'
mk_conf "$TMP/conf-mode-bogus.conf" 'ROTATION_TRIG1A_MODE=watch'
CONF="$TMP/conf-mode-bogus.conf" run_case "61 unknown mode value is a configuration error" 2 'ROTATION_TRIG1A_MODE must be enforce or observe'

# ── the handoff heading is the project's; an alternation reads several ──
mk_conf "$TMP/conf-heading.conf" 'ROTATION_TRIGGER_SECTION=handover' 'ROTATION_TRIG1_MIN_COMMITS=3' 'ROTATION_TRIG1_MIN_CLOSED=1'
printf '%s\n' "## handover" "" "$GOOD_AXIS" "closed: $REAL_SHA merged topic2" "$GOOD_GATE" "${SWEEP_LINE/REPLACED/$REAL_SHA}" > "$TMP/handoff.md"
CONF="$TMP/conf-heading.conf" run_case "62 the conf's heading is read" 0 'TRIG-3 PASS axis=A'
printf '%s\n' "## rotate-trigger" "" "$GOOD_AXIS" "closed: $REAL_SHA merged topic2" "$GOOD_GATE" "${SWEEP_LINE/REPLACED/$REAL_SHA}" > "$TMP/handoff.md"
CONF="$TMP/conf-heading.conf" run_case "62b the kernel default heading is not read under that conf" 1 "TRIG-3 FAIL handoff has no '## <handover>' section"
mk_conf "$TMP/conf-low3.conf" 'ROTATION_TRIG1_MIN_COMMITS=3' 'ROTATION_TRIG1_MIN_CLOSED=1'
mk_conf "$TMP/conf-heading2.conf" 'ROTATION_TRIGGER_SECTION=handover|rotate-trigger' 'ROTATION_TRIG1_MIN_COMMITS=3' 'ROTATION_TRIG1_MIN_CLOSED=1'
printf '%s\n' "## handover" "" "$GOOD_AXIS" "closed: $REAL_SHA merged topic2" "$GOOD_GATE" "${SWEEP_LINE/REPLACED/$REAL_SHA}" > "$TMP/handoff.md"
CONF="$TMP/conf-heading2.conf" run_case "63 an alternation in the conf reads the other heading" 0 'TRIG-3 PASS axis=A'
mk_handoff "$GOOD_AXIS" "closed: $REAL_SHA merged topic2" "$GOOD_GATE"
CONF="$TMP/conf-heading2.conf" run_case "63b and the default heading too" 0 'TRIG-3 PASS axis=A'

# ── TRIG-4: the kernel's English list plus the project's additions ──
CONF="$TMP/conf-low3.conf" run_case "64 kernel blacklist alone: 7 patterns" 0 'TRIG-4 PASS 0 blacklist phrase hits \(7 patterns\)'
mk_conf "$TMP/conf-bl2.conf" 'ROTATION_TRIG1_MIN_COMMITS=3' 'ROTATION_TRIG1_MIN_CLOSED=1' 'ROTATION_BLACKLIST_EXTRA=later maybe;when time allows'
CONF="$TMP/conf-bl2.conf" run_case "64b two project additions: 9 patterns" 0 'TRIG-4 PASS 0 blacklist phrase hits \(9 patterns\)'
mk_handoff "$GOOD_AXIS" "closed: $REAL_SHA merged topic2" "$GOOD_GATE" "the ROI is low"
CONF="$TMP/conf-bl2.conf" run_case "64c a kernel phrase still hits with additions present" 1 'TRIG-4 FAIL blacklist hit: ROI'

# ── stats.sh --effect / --suggest ──────────────────────────────────────
# Three self rows: r-s1 (old row, closed by r-s2 which has no activeWallSec), r-s2 (closed by r-s3 with
# activeWallSec=3600), r-s3 open. r-s2's range is HEAD~4..HEAD = 3 main-session first-parent commits
# (case 47's e1 / m1 / merge2; a1 carries Agent-Origin); r-s1's is HEAD~8..HEAD~4 = 4.
SNOW=$(date +%s)
SP0=$(g rev-parse --short HEAD~8); SP1=$(g rev-parse --short HEAD~4); SP2=$(g rev-parse --short HEAD)
{
  printf '{"rotationId":"r-s1","at":"a1","ts":%d,"project":"%s","trigger":"self","prevHead":"%s"}\n' "$(( SNOW - 20000 ))" "$PROJECT" "$SP0"
  printf '{"rotationId":"r-s2","at":"a2","ts":%d,"project":"%s","trigger":"self","prevHead":"%s"}\n' "$(( SNOW - 10000 ))" "$PROJECT" "$SP1"
  printf '{"rotationId":"r-s3","at":"a3","ts":%d,"project":"%s","trigger":"self","prevHead":"%s","activeWallSec":3600}\n' "$(( SNOW - 100 ))" "$PROJECT" "$SP2"
} > "$TMP/stats-rot.jsonl"
{
  printf '{"at":"x","ts":%d,"kind":"rotation.start","rotationId":"r-s2","head":"x"}\n' "$(( SNOW - 9700 ))"
  printf '{"at":"x","ts":%d,"kind":"agent.start","rotationId":"r-s2","head":"x","agent":{"name":"rot-a","role":"rotation","id":"ag-a"}}\n' "$(( SNOW - 9690 ))"
  printf '{"at":"x","ts":%d,"kind":"manager.resume","rotationId":"r-s2","head":"x","manager":{"agent":{"id":"ag-a","name":"rot-a"},"reason":"quota"}}\n' "$(( SNOW - 8000 ))"
  printf '{"at":"x","ts":%d,"kind":"agent.start","rotationId":"r-s2","head":"x","agent":{"name":"rot-b","role":"rotation","id":"ag-b"}}\n' "$(( SNOW - 7000 ))"
  printf '{"at":"x","ts":%d,"kind":"agent.start","rotationId":"r-s2","head":"x","agent":{"name":"w1","role":"worker"}}\n' "$(( SNOW - 6000 ))"
} > "$TMP/stats-events.jsonl"
mkdir -p "$TMP/stats-verdicts"
printf '{"rotationId":"r-s2","results":{"filledAt":"x","red":["sweep: pass 100 → 97"],"amber":[]},"checks":[{"name":"sweep","stampFile":"sweep-latest.json","result":{"readings":[{"key":"pass","value":97,"previous":100,"delta":-3}]}}]}\n' > "$TMP/stats-verdicts/r-s2.verdict.json"
EXTRA_ENV=(HARDEV_ROTATIONS_LOG="$TMP/stats-rot.jsonl" HARDEV_EVENTS_LOG="$TMP/stats-events.jsonl" ROTATION_VERDICT_DIR="$TMP/stats-verdicts")
eff=$(run_gate bash "$BIN/stats.sh" --effect --json 2>&1); rc=$?
field() { printf '%s' "$eff" | python3 -c 'import json,sys; d=json.load(sys.stdin); r={x["rid"]:x for x in d["rounds"]}; print(r[sys.argv[1]].get(sys.argv[2]))' "$1" "$2"; }
if [ "$rc" -eq 0 ] && [ "$(field r-s2 commits)" = 3 ] && [ "$(field r-s2 activeWallSec)" = 3600 ] && [ "$(field r-s2 throughputPerHour)" = 3.0 ]; then
  ok "65 --effect: throughput = commits (Agent-Origin excluded) / active hour"
else
  bad "65 --effect throughput" "exit=$rc commits=$(field r-s2 commits) active=$(field r-s2 activeWallSec) thr=$(field r-s2 throughputPerHour)"
fi
[ "$(field r-s1 commits)" = 4 ] && [ "$(field r-s1 activeWallSec)" = None ] && [ "$(field r-s1 throughputPerHour)" = None ] \
  && ok "65n --effect: a closing row without activeWallSec gives throughput null" \
  || bad "65n --effect null throughput" "commits=$(field r-s1 commits) active=$(field r-s1 activeWallSec) thr=$(field r-s1 throughputPerHour)"
[ "$(field r-s2 regressions)" = 4 ] && [ "$(field r-s2 red)" = 1 ] && [ "$(field r-s2 sweepPassLost)" = 3 ] && [ "$(field r-s1 regressions)" = None ] \
  && ok "66 --effect: regressions = red 1 + sweep passes lost 3; null without a verdict" \
  || bad "66 --effect regressions" "r-s2=$(field r-s2 regressions) red=$(field r-s2 red) lost=$(field r-s2 sweepPassLost) r-s1=$(field r-s1 regressions)"
[ "$(field r-s2 gapSec)" = 300 ] && [ "$(field r-s1 gapSec)" = None ] \
  && ok "67 --effect: gap = trigger → rotation.start (300s); null without one" \
  || bad "67 --effect gap" "r-s2=$(field r-s2 gapSec) r-s1=$(field r-s1 gapSec)"
[ "$(field r-s2 restarts)" = 1 ] && [ "$(field r-s2 resumes)" = 1 ] && [ "$(field r-s1 restarts)" = None ] && [ "$(field r-s3 restarts)" = None ] \
  && ok "68 --effect: restarts = executor registrations − 1 (workers not counted), resumes 1; null without an executor" \
  || bad "68 --effect restarts" "r-s2 restarts=$(field r-s2 restarts) resumes=$(field r-s2 resumes) r-s1=$(field r-s1 restarts)"
out=$(run_gate bash "$BIN/stats.sh" --effect 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qE '^\| r-s2 \| a2 \| 3 \| 60\.0 min \| 3\.0 \| 4 \(1\+3\) \| 300s \| 1 \| 1 \|$' \
   && printf '%s\n' "$out" | grep -qE '^\| r-s1 \| a1 \| 4 \| null \| null \| null \| null \| null \| 0 \|$' \
   && printf '%s\n' "$out" | grep -qE '^\| r-s3 \(open\) \| a3 \| null ' \
   && printf '%s\n' "$out" | grep -qE '1 closed round\(s\) have no activeWallSec .*: null'; then
  ok "69 --effect table: the rounds' lines and the null note"
else
  bad "69 --effect table" "$out"
fi
out=$(run_gate bash "$BIN/stats.sh" --suggest 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qE '^- not enough rows yet: 17 more self rotation\(s\) before a suggestion$' \
   && ! printf '%s\n' "$out" | grep -q 'suggested N'; then
  ok "70 --suggest under the bootstrap count says how many more rounds"
else
  bad "70 --suggest insufficient" "exit=$rc $out"
fi
mk_conf "$TMP/conf-boot3.conf" 'ROTATION_BOOTSTRAP_ROUNDS=3'
out=$(CONF="$TMP/conf-boot3.conf" run_gate bash "$BIN/stats.sh" --suggest 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qE '^- n=2 · p10=3 · p50=4 · p90=4$' \
   && printf '%s\n' "$out" | grep -qE '^- suggested N = ⌊p50 × 0\.8⌋ = 3$' \
   && printf '%s\n' "$out" | grep -qE '^- cap: not yet — 1 of 3 rounds carry activeWallSec; 2 more needed$'; then
  ok "71 --suggest with enough rows: commits p10/p50/p90 and N; the cap waits for activeWallSec"
else
  bad "71 --suggest sufficient" "exit=$rc $out"
fi
mk_conf "$TMP/conf-boot1.conf" 'ROTATION_BOOTSTRAP_ROUNDS=1'
out=$(CONF="$TMP/conf-boot1.conf" run_gate bash "$BIN/stats.sh" --suggest 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qE '^- suggested cap = p90 = 3600s \(60\.0 min\)$'; then
  ok "71c --suggest: cap = active wall p90 once enough rows carry it"
else
  bad "71c --suggest cap" "exit=$rc $out"
fi
EXTRA_ENV=()

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
