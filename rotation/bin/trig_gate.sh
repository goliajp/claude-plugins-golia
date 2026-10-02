#!/usr/bin/env bash
#
# rotation kernel — TRIG-1..8 pre-trigger gate.
#
# Run by `trigger.sh self` before it generates a rotation_id and writes
# any state. Governs whether a self-initiated rotation is *legitimate*
# to trigger in the first place. Mirror of `check.sh` (INV-1..5) which
# governs whether an already-triggered rotation may *execute*.
#
# Spec: README.md → "TRIG-1..7 spec". Every threshold comes from the
# project's rotation.conf (loaded by lib.sh); the environment is ignored
# for them, and trigger.sh writes the effective values into the row.
#
# ── 2026-09-07 rewrite ────────────────────────────────────────────────
# The four gates as shipped in P2.0 all pointed the same way — against
# rotating *too early* — so in practice only TRIG-1 ever bit, and it had
# turned into a quota rather than a floor. Measured over the last 60
# rotations before this rewrite (reconstructed from `prevHead`, since
# `commitsInSession` was hardcoded null — see lib.sh):
#
#   commits/rotation  min 5 · p10 5 · p50 6 · p90 8 · max 9   (0/60 below 5)
#   wall (min)               p10 95 · p50 125 · p90 221
#   triggerReason            d: 606 / a: 133 / c: 2 / b: 2    (81.6% = d)
#
# Left edge glued to the threshold, nothing below it, nothing far above:
# the gate had become the target. So each gate now owns a different
# question:
#
#   TRIG-1  the floor      — is there enough work in this session?
#                            Two measures, because one of them is
#                            dilutable (2026-09-09, see below).
#   TRIG-2  both edges     — too fast to be real / too long to stay sharp
#                            (and it is the ONLY escape hatch, see below)
#   TRIG-3  the content    — which axis, what closed, what the gate reads
#   TRIG-4  the wording    — the known procrastination phrasings
#   TRIG-5  the allocation — is one axis starving the others?
#   TRIG-6  the evidence   — were the mechanical checks actually run,
#                            on THIS source?
#   TRIG-7  the transcript — does the handoff's sweep line still say what
#                            the sweep said?
#   TRIG-8  the coverage   — did a gate run on this round's substrate at all?
#                            Read from the gate.end events the gate command
#                            records, not from the handoff. Off until the
#                            project's rotation.conf turns it on.
#
# TRIG-6 (2026-09-09) closes the structural hole the other five share:
# every one of them reads what the handoff *says*. TRIG-3 checks the
# `gate:` triple for F=0 and never asks whether N is a real number; the
# lines about the other checks are free text. So "it was not run", "it
# ran on the previous HEAD" and "last rotation's number got carried
# forward" are all invisible — and the project's incident log records
# that class at least five times, including a sweep that stayed dark for
# five rotations while six pass regressions piled up. The checks now
# leave committed JSON stamps carrying the sha of the source they
# measured, and the gate reads those instead.
#
# Why N went 5 -> 12: every rotation pays a fixed cost that does not
# scale with commits (the close checks, ~18 min of machine time, plus
# writing the handoff and rebuilding context on the far side). At p50
# (6 commits / 125 min) that machine floor alone is 14.7% of the
# rotation. Solving wall(N) = 18.4 + N * 17.8 from the measured p50:
# N=12 gives 232 min (7.9%), N=20 gives 374 min (4.9%). Doubling to 12
# takes most of the recoverable overhead; going to 20 pushes wall past
# the observed p90 into a region no rotation has ever been measured in,
# and drift in exactly that region is the only reason rotations exist.
#
# Why TRIG-1 grew a second measure (2026-09-09). Eight rotations under
# N=12 produced commit counts of 13,13,14,13,13,13,14,13 — eight of eight
# glued to the threshold. The rotations really did get bigger, but the
# commit granularity got finer under the gate (median commit size 127 ->
# 94 lines): a count of commits is dilutable by construction. `closed:`
# entries are not, or not nearly as much — each one has to name a sha
# from this session AND say what it closed, in a sentence that has to
# survive being read. The commit floor stays as the backstop.
#
# Why TRIG-2 inverted: with a 12-commit floor, a rotation that spends
# five hours on one hard problem can be unable to close at all.
# `trigger.sh manual` is the operator's override and is not a path the
# agent may take, so the escape has to be mechanical: past the wall cap
# the commit floor is waived. The same number doubles as "this session
# is long enough that drift now outweighs amortisation". The floor
# catches the opposite failure — twelve trivial commits inside half an
# hour.
#
# Usage:
#   trig_gate.sh
#
# No arguments — gate inputs are HEAD, rotations.jsonl tail, handoff
# content (all resolved via lib.sh) and rotation.conf.
#
# Exit codes:
#   0  — all TRIGs PASS
#   1  — at least one TRIG FAIL; stderr summarises with `TRIG-FAILED: TRIG-x ...`
#   2  — internal / configuration error (rotation.conf missing or
#        incomplete, a switch with an unknown value, stamp dir unset,
#        project dir unreadable)
#
# stdout: one line per TRIG, `TRIG-N STATE one-line-detail`. STATE is
# one of PASS / FAIL / SKIP / WAIVED / OBSERVE. Lines are stable for
# greppability by trigger.sh and self-test assertions.
#
# OBSERVE (2026-10-02): TRIG-1a (the commit floor) and TRIG-2 are the two
# gates whose thresholds are a project's own rhythm, calibrated from its
# rows. Until a project has rows to calibrate from, rotation.conf may set
# ROTATION_TRIG1A_MODE / ROTATION_TRIG2_MODE to `observe`: the gate is
# computed and printed as it would be judged, trigger.sh records it in the
# trigger.result event, and it does not block. TRIG-1b (things closed) and
# the content / evidence gates do not depend on rhythm and always enforce.
# `stats.sh --suggest` turns the observed rows into thresholds.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

# ── Configuration (rotation.conf only; see lib.sh) ────────────────────
if [ -n "$ROTATION_CONF_ERROR" ]; then
  echo "trig_gate: $ROTATION_CONF_ERROR" >&2
  exit 2
fi
conf_missing=""
for k in ROTATION_TRIG1_MIN_COMMITS ROTATION_TRIG1_MIN_CLOSED ROTATION_TRIG2_MIN_WALL_SEC ROTATION_TRIG2_MAX_WALL_SEC ROTATION_TRIG5_SAME_AXIS_MAX ROTATION_TRIG5_BENCH_MAX_AGE_DAYS; do
  eval "v=\${$k:-}"
  case "$v" in ''|*[!0-9]*) conf_missing="$conf_missing $k" ;; esac
done
if [ -n "$conf_missing" ]; then
  echo "trig_gate: rotation.conf ($ROTATION_CONF_FILE) must set integer values for:$conf_missing" >&2
  exit 2
fi
TRIG1_MIN_COMMITS="$ROTATION_TRIG1_MIN_COMMITS"
TRIG1_MIN_CLOSED="$ROTATION_TRIG1_MIN_CLOSED"              # named things closed, see below
TRIG2_MIN_WALL_SEC="$ROTATION_TRIG2_MIN_WALL_SEC"          # floor
TRIG2_MAX_WALL_SEC="$ROTATION_TRIG2_MAX_WALL_SEC"          # cap → waives TRIG-1
TRIG5_SAME_AXIS_MAX="$ROTATION_TRIG5_SAME_AXIS_MAX"        # consecutive same-axis rotations
TRIG5_BENCH_MAX_AGE_DAYS="$ROTATION_TRIG5_BENCH_MAX_AGE_DAYS"  # axis reading staleness
COLD_START_WINDOW="${ROTATION_COLD_START_WINDOW:-25}"
# Which wall TRIG-2 judges: `trigger` (default) is the time since the last
# self trigger, idle gap included; `active` is the time since the round's
# active start (rotation.start, else the first rotation agent.start — see
# lib.sh autorun_round_measures), and a round without that event cannot
# pass TRIG-2 under it. Anything else is a configuration error.
TRIG2_MEASURE="${ROTATION_TRIG2_MEASURE:-trigger}"
case "$TRIG2_MEASURE" in
  trigger|active) ;;
  *) echo "trig_gate: ROTATION_TRIG2_MEASURE must be trigger or active, got '$TRIG2_MEASURE' ($ROTATION_CONF_FILE)" >&2; exit 2 ;;
esac
WALL_LABEL=wall
[ "$TRIG2_MEASURE" = active ] && WALL_LABEL="active wall"
# enforce (default) judges; observe computes, prints and records but does not block
TRIG1A_MODE="${ROTATION_TRIG1A_MODE:-enforce}"
TRIG2_MODE="${ROTATION_TRIG2_MODE:-enforce}"
for k in TRIG1A_MODE TRIG2_MODE; do
  eval "v=\${$k}"
  case "$v" in
    enforce|observe) ;;
    *) echo "trig_gate: ROTATION_$k must be enforce or observe, got '$v' ($ROTATION_CONF_FILE)" >&2; exit 2 ;;
  esac
done
# TRIG-8 is a judging change and ships off: `off` emits no line, `on` judges.
TRIG8_GATE_COVERAGE="${ROTATION_TRIG8_GATE_COVERAGE:-off}"
case "$TRIG8_GATE_COVERAGE" in
  on|off) ;;
  *) echo "trig_gate: ROTATION_TRIG8_GATE_COVERAGE must be on or off, got '$TRIG8_GATE_COVERAGE' ($ROTATION_CONF_FILE)" >&2; exit 2 ;;
esac
STAMP_DIR="${HARDEV_STAMP_DIR:-${ROTATION_STAMP_DIR:-}}"   # where the run stamps live
if [ -z "$STAMP_DIR" ]; then
  echo "trig_gate: ROTATION_STAMP_DIR unset (project.sh)" >&2
  exit 2
fi
AXIS_STAMP="${ROTATION_AXIS_STAMP:-}"
SWEEP_STAMP="${ROTATION_SWEEP_STAMP:-}"

# Blacklist phrases (case-insensitive). Each entry = one extended regex;
# if any matches anywhere inside the handoff's trigger section, TRIG-4
# FAILs. The kernel carries the language-neutral core (curated from
# cases#rotate-as-procrastination); a project adds its own through
# ROTATION_BLACKLIST_EXTRA (`;`-separated) in rotation.conf.
TRIG4_BLACKLIST=(
  'prep work done'
  'audit (complete|already)'
  'audit-only'
  'substantial work'
  'complexity'
  'ROI'
  'sub-milestone'
)
if [ -n "${ROTATION_BLACKLIST_EXTRA:-}" ]; then
  IFS=';' read -r -a extra_bl <<< "$ROTATION_BLACKLIST_EXTRA"
  for p in "${extra_bl[@]}"; do
    [ -n "$p" ] && TRIG4_BLACKLIST+=("$p")
  done
fi

failed=()
waive_trig1=0
wall_sec=""
active_wall_missing=0

emit() {
  printf '%s %s %s\n' "$1" "$2" "$3"
}

# Resolve wall time first: TRIG-2's upper edge decides whether TRIG-1 is
# waived, so it must be computed before TRIG-1 is judged (output order
# stays 1..7 — each line carries its own ID, so emit order is free).
resolve_wall() {
  local row last_ts now
  row=$(autorun_last_self_row)
  [ -n "$row" ] || return
  if [ "$TRIG2_MEASURE" = active ]; then
    wall_sec=$(autorun_round_measures | cut -f1)
    if [ -z "$wall_sec" ]; then
      active_wall_missing=1
      return
    fi
  else
    last_ts=$(printf '%s\n' "$row" | cut -f1)
    now=$(date +%s)
    wall_sec=$(( now - last_ts ))
  fi
  if [ "$wall_sec" -ge "$TRIG2_MAX_WALL_SEC" ]; then
    waive_trig1=1
  fi
}

# The commit range for this session, as `<base>..HEAD`. Falls back to a
# COLD_START_WINDOW-commit window on cold start so TRIG-3's sha check
# still has ground to stand on.
session_range() {
  local row last_head
  row=$(autorun_last_self_row)
  last_head=$(printf '%s\n' "$row" | cut -f2)
  if [ -n "$last_head" ]; then
    printf '%s..HEAD\n' "$last_head"
  else
    printf 'HEAD~%s..HEAD\n' "$COLD_START_WINDOW"
  fi
}

# The `closed:` block — from the `closed:` line up to the next keyed line.
# It wraps in practice (one entry per thing closed, each a sha plus a
# sentence), so it cannot be read with `head -1`.
closed_block() {
  autorun_handoff_trigger_section | awk '
    /^[[:space:]]*[Cc]losed:/ { inblk = 1; print; next }
    inblk && /^[[:space:]]*[A-Za-z-]+:/ { inblk = 0 }
    inblk { print }
  '
}

# Shas on the closed block that really belong to this session, deduped.
closed_session_shas() {
  local range shas tok seen=""
  range=$(session_range)
  shas=$(autorun_main_session_revs "$range" 2>/dev/null) || return
  [ -n "$shas" ] || return
  for tok in $(closed_block | grep -oE '\b[0-9a-f]{7,40}\b'); do
    case " $seen " in *" $tok "*) continue ;; esac
    if printf '%s\n' "$shas" | grep -q "^$tok"; then
      seen="$seen $tok"
    fi
  done
  printf '%s\n' $seen
}

# ── TRIG-1 — session commit count ≥ N, and ≥ M things named closed ────
# Cold start (no prior self row) → SKIP. Over the wall cap → WAIVED.
# The count follows the first-parent line only (lib.sh): a merge brings
# its branch into the range, and one merge must not meet the floor alone.
check_trig1() {
  local count
  count=$(autorun_commits_since_last_self)
  if [ -z "$count" ]; then
    emit TRIG-1 SKIP "no prior self rotation (cold start)"
    return
  fi
  local closed_n
  closed_n=$(closed_session_shas | wc -w | tr -d ' ')
  if [ "$waive_trig1" -eq 1 ]; then
    emit TRIG-1 WAIVED "commits=$count closed=$closed_n but ${WALL_LABEL}=${wall_sec}s ≥ cap=${TRIG2_MAX_WALL_SEC}s"
    return
  fi
  if [ "$count" -lt "$TRIG1_MIN_COMMITS" ]; then
    if [ "$TRIG1A_MODE" = observe ]; then
      # the floor is watched, not enforced; the second measure still is
      if [ "$closed_n" -lt "$TRIG1_MIN_CLOSED" ]; then
        emit TRIG-1 FAIL "commits=$count < N=$TRIG1_MIN_COMMITS (observed, not enforced) and only $closed_n thing(s) named on 'closed:' (need ≥$TRIG1_MIN_CLOSED from this session)"
        failed+=(TRIG-1)
        return
      fi
      emit TRIG-1 OBSERVE "commits=$count < N=$TRIG1_MIN_COMMITS — not enforced (ROTATION_TRIG1A_MODE=observe); closed=$closed_n ≥ M=$TRIG1_MIN_CLOSED"
      return
    fi
    emit TRIG-1 FAIL "commits=$count < N=$TRIG1_MIN_COMMITS (need ≥$TRIG1_MIN_COMMITS, or ${WALL_LABEL} ≥ $(( TRIG2_MAX_WALL_SEC / 60 ))min)"
    failed+=(TRIG-1)
    return
  fi
  # The second measure. A commit count is met by slicing the same work
  # thinner; a `closed:` entry has to name a sha and say what it closed.
  if [ "$closed_n" -lt "$TRIG1_MIN_CLOSED" ]; then
    emit TRIG-1 FAIL "commits=$count ≥ N=$TRIG1_MIN_COMMITS but only $closed_n thing(s) named on 'closed:' (need ≥$TRIG1_MIN_CLOSED from this session)"
    failed+=(TRIG-1)
    return
  fi
  emit TRIG-1 PASS "commits=$count ≥ N=$TRIG1_MIN_COMMITS, closed=$closed_n ≥ M=$TRIG1_MIN_CLOSED"
}

# ── TRIG-2 — wall time inside [floor, cap] ────────────────────────────
# Floor: twelve commits inside half an hour is not a session, it is a
# batch of trivia. Cap: past it the rotation is long enough that drift
# outweighs amortisation, so closing is not merely allowed but signalled
# — and TRIG-1 is waived so it can actually close.
check_trig2() {
  if [ -z "$wall_sec" ]; then
    if [ "$active_wall_missing" -eq 1 ]; then
      # under the active measure a round with no recorded start has no wall; unknown is not a pass
      if [ "$TRIG2_MODE" = observe ]; then
        emit TRIG-2 OBSERVE "active wall unknown: this round has no rotation.start and no agent.start with role=rotation (ROTATION_TRIG2_MEASURE=active) — not enforced (ROTATION_TRIG2_MODE=observe)"
        return
      fi
      emit TRIG-2 FAIL "active wall unknown: this round has no rotation.start and no agent.start with role=rotation (ROTATION_TRIG2_MEASURE=active)"
      failed+=(TRIG-2)
      return
    fi
    emit TRIG-2 SKIP "no prior self rotation (cold start)"
    return
  fi
  local mins=$(( wall_sec / 60 ))
  if [ "$wall_sec" -lt "$TRIG2_MIN_WALL_SEC" ]; then
    if [ "$TRIG2_MODE" = observe ]; then
      emit TRIG-2 OBSERVE "${WALL_LABEL}=${wall_sec}s (${mins}min) < floor=$(( TRIG2_MIN_WALL_SEC / 60 ))min — not enforced (ROTATION_TRIG2_MODE=observe)"
      return
    fi
    emit TRIG-2 FAIL "${WALL_LABEL}=${wall_sec}s (${mins}min) < floor=$(( TRIG2_MIN_WALL_SEC / 60 ))min"
    failed+=(TRIG-2)
    return
  fi
  if [ "$wall_sec" -ge "$TRIG2_MAX_WALL_SEC" ]; then
    emit TRIG-2 PASS "${WALL_LABEL}=${mins}min ≥ cap=$(( TRIG2_MAX_WALL_SEC / 60 ))min — close now, TRIG-1 waived"
    return
  fi
  emit TRIG-2 PASS "${WALL_LABEL}=${mins}min inside [$(( TRIG2_MIN_WALL_SEC / 60 )), $(( TRIG2_MAX_WALL_SEC / 60 ))]min"
}

# ── TRIG-3 — the section carries content, not a restatement of TRIG-1 ─
# Requires three lines inside the trigger section (heading matching
# ROTATION_TRIGGER_SECTION):
#   axis:   <one of ROTATION_AXES>[,...]   which axis this rotation served
#   closed: <sha> <what>                   at least one sha from THIS session's range
#   gate:   <N>/<F>/<S>                    the gate's pass/fail/skip triple, F must be 0
# The sha requirement is the part that cannot be satisfied by wording:
# a rotation with nothing to point at cannot name a commit of its own.
check_trig3() {
  if [ ! -f "$HANDOFF_FILE" ]; then
    emit TRIG-3 FAIL "handoff missing at $HANDOFF_FILE"
    failed+=(TRIG-3)
    return
  fi
  local body axis closed_line gate_line
  body=$(autorun_handoff_trigger_section)
  if [ -z "$body" ]; then
    emit TRIG-3 FAIL "handoff has no '## <$TRIGGER_SECTION_RE>' section"
    failed+=(TRIG-3)
    return
  fi

  axis=$(autorun_trigger_axis)
  if [ -z "$axis" ]; then
    emit TRIG-3 FAIL "no valid 'axis: <${AXES_ALT}>[,...]' line"
    failed+=(TRIG-3)
    return
  fi

  closed_line=$(closed_block)
  if [ -z "$closed_line" ]; then
    emit TRIG-3 FAIL "no 'closed: <sha> <what>' line (axis=$axis)"
    failed+=(TRIG-3)
    return
  fi

  # At least one hex token on the closed line must name a commit inside
  # this session's range.
  local range shas tok hit=""
  range=$(session_range)
  shas=$(git -C "$PROJECT_DIR" rev-list "$range" 2>/dev/null)
  if [ -z "$shas" ]; then
    emit TRIG-3 FAIL "git rev-list $range returned nothing — cannot verify 'closed:'"
    failed+=(TRIG-3)
    return
  fi
  for tok in $(printf '%s\n' "$closed_line" | grep -oE '\b[0-9a-f]{7,40}\b'); do
    if printf '%s\n' "$shas" | grep -q "^$tok"; then
      hit="$tok"
      break
    fi
  done
  if [ -z "$hit" ]; then
    emit TRIG-3 FAIL "no sha on the 'closed:' line belongs to $range"
    failed+=(TRIG-3)
    return
  fi

  gate_line=$(printf '%s\n' "$body" | grep -oE '^[[:space:]]*gate:[[:space:]]*[0-9]+/[0-9]+/[0-9]+' | head -1)
  if [ -z "$gate_line" ]; then
    emit TRIG-3 FAIL "no 'gate: <N>/<F>/<S>' line (axis=$axis, closed=$hit)"
    failed+=(TRIG-3)
    return
  fi
  local triple fails
  triple=$(printf '%s\n' "$gate_line" | grep -oE '[0-9]+/[0-9]+/[0-9]+')
  fails=$(printf '%s\n' "$triple" | cut -d/ -f2)
  if [ "$fails" -ne 0 ]; then
    emit TRIG-3 FAIL "gate=$triple has $fails fail — a rotation does not close red"
    failed+=(TRIG-3)
    return
  fi
  emit TRIG-3 PASS "axis=$axis closed=$hit gate=$triple"
}

# ── TRIG-4 — blacklist phrase guard ────────────────────────────────────
check_trig4() {
  if [ ! -f "$HANDOFF_FILE" ]; then
    emit TRIG-4 FAIL "handoff missing at $HANDOFF_FILE"
    failed+=(TRIG-4)
    return
  fi
  local body hits=()
  body=$(autorun_handoff_trigger_section)
  if [ -z "$body" ]; then
    emit TRIG-4 SKIP "no trigger section (TRIG-3 already FAIL)"
    return
  fi
  local p
  for p in "${TRIG4_BLACKLIST[@]}"; do
    if printf '%s\n' "$body" | grep -iqE "$p"; then
      hits+=("$p")
    fi
  done
  if [ "${#hits[@]}" -eq 0 ]; then
    emit TRIG-4 PASS "0 blacklist phrase hits (${#TRIG4_BLACKLIST[@]} patterns)"
  else
    emit TRIG-4 FAIL "blacklist hit: ${hits[*]}"
    failed+=(TRIG-4)
  fi
}

# ── TRIG-5 — axis skew must be settled, not silent ────────────────────
# If the previous TRIG5_SAME_AXIS_MAX-1 self rotations all served the
# same axis as this one, the handoff must carry an `axes-review:` line —
# a written account of where the other axes stand and why they stay
# untouched for another rotation.
#
# It does NOT force an axis switch. Which axis to work is the operator's
# call, and this gate has no business overriding it. What it removes is
# the silence: through one September every rotation served one axis
# while another sat still for a month and a third had never been
# started, and that only surfaced when a full report was asked for.
# Under this gate it surfaces every TRIG5_SAME_AXIS_MAX rotations, in
# writing, whether or not anyone asks.
check_trig5() {
  local axis
  axis=$(autorun_trigger_axis)
  if [ -z "$axis" ]; then
    emit TRIG-5 SKIP "no axis on this rotation (TRIG-3 already FAIL)"
    return
  fi
  local need=$(( TRIG5_SAME_AXIS_MAX - 1 ))
  local prior
  prior=$(python3 - "$ROTATIONS_LOG" "$(autorun_project_name)" "$need" <<'PY'
import json, sys
log, project, need = sys.argv[1], sys.argv[2], int(sys.argv[3])
rows = []
try:
    with open(log) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            if r.get("project") != project or r.get("trigger") != "self":
                continue
            rows.append(r)
except FileNotFoundError:
    pass
tail = rows[-need:] if need > 0 else []
# Rows written before the axis field existed carry None; an unknown axis
# breaks the streak rather than extending it — the gate needs `need`
# rows of real evidence before it can fire.
print(",".join((r.get("axis") or "?") for r in tail))
PY
)
  if [ -z "$prior" ]; then
    emit TRIG-5 PASS "no prior axis history yet"
    return
  fi
  local same=1 a
  local IFS=,
  for a in $prior; do
    if [ "$a" != "$axis" ]; then
      same=0
      break
    fi
  done
  unset IFS
  if [ "$same" -eq 0 ]; then
    emit TRIG-5 PASS "axis=$axis; prior $need = [$prior] not all the same"
    return
  fi
  if ! autorun_handoff_trigger_section | grep -iqE '^[[:space:]]*axes-review:'; then
    emit TRIG-5 FAIL "axis=$axis for $TRIG5_SAME_AXIS_MAX consecutive rotations — handoff needs an 'axes-review:' line stating where the other axes stand and why they wait"
    failed+=(TRIG-5)
    return
  fi
  # A review that says "not measured this round" is true and says nothing.
  # The number has to stand next to it: a review sentence can be
  # individually correct for months while the reading it is about has not
  # moved. So the review carries the reading itself (ROTATION_AXIS_STAMP,
  # rendered by ROTATION_AXIS_READING_CMD), and the reading may not be
  # arbitrarily old nor taken against a comparator that has since moved
  # (ROTATION_AXIS_READING_FRESH_CMD). A project without these is not
  # exempt: an unconfigured reading is not a current one.
  if [ -z "$AXIS_STAMP" ] || [ -z "${ROTATION_AXIS_READING_CMD:-}" ]; then
    emit TRIG-5 FAIL "axes-review present but no axis reading is configured (ROTATION_AXIS_STAMP in rotation.conf, ROTATION_AXIS_READING_CMD in project.sh)"
    failed+=(TRIG-5)
    return
  fi
  local reading_json="$STAMP_DIR/$AXIS_STAMP-latest.json"
  if [ ! -f "$reading_json" ]; then
    emit TRIG-5 FAIL "axes-review present but no $reading_json — produce the axis reading stamp first"
    failed+=(TRIG-5)
    return
  fi
  local reading_line age_days
  reading_line=$(HARDEV_BENCH_JSON="$reading_json" ROTATION_AXIS_JSON="$reading_json" bash "$ROTATION_AXIS_READING_CMD" 2>/dev/null)
  age_days=$(python3 -c '
import json, sys, datetime
d = json.load(open(sys.argv[1]))
t = d.get("benchRanAt") or d.get("ranAt")
try:
    when = datetime.datetime.strptime(t, "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=datetime.timezone.utc)
except (TypeError, ValueError):
    print(9999); raise SystemExit
print(int((datetime.datetime.now(datetime.timezone.utc) - when).total_seconds() // 86400))
' "$reading_json" 2>/dev/null)
  if [ -z "$age_days" ] || [ "$age_days" -gt "$TRIG5_BENCH_MAX_AGE_DAYS" ]; then
    emit TRIG-5 FAIL "axis reading is ${age_days:-?}d old (max $TRIG5_BENCH_MAX_AGE_DAYS) — rerun it and regenerate $AXIS_STAMP-latest.json"
    failed+=(TRIG-5)
    return
  fi
  if [ -n "${ROTATION_AXIS_READING_FRESH_CMD:-}" ]; then
    local fresh_line fresh_rc
    fresh_line=$(HARDEV_BENCH_JSON="$reading_json" ROTATION_AXIS_JSON="$reading_json" HARDEV_BUN_HOSTS=none ROTATION_FRESH_HOSTS=none \
      bash "$ROTATION_AXIS_READING_FRESH_CMD" 2>/dev/null)
    fresh_rc=$?
    if [ "$fresh_rc" -ne 0 ]; then
      emit TRIG-5 FAIL "axis reading's comparator is not current: ${fresh_line:-the freshness command gave no output} — update the comparator, rerun the reading, regenerate $AXIS_STAMP-latest.json"
      failed+=(TRIG-5)
      return
    fi
  else
    fresh_line=""
  fi
  local tok body missing=()
  body=$(tr '\n' ' ' < "$HANDOFF_FILE")
  for tok in ${reading_line#*: }; do
    case "$body" in
      *"$tok"*) ;;
      *) missing+=("$tok") ;;
    esac
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    emit TRIG-5 FAIL "axes-review lacks the axis reading (${missing[*]}) — paste the output of $ROTATION_AXIS_READING_CMD"
    failed+=(TRIG-5)
    return
  fi
  emit TRIG-5 PASS "axis=$axis for $TRIG5_SAME_AXIS_MAX rotations; axes-review carries the axis reading (${age_days}d old${fresh_line:+; ${fresh_line#*: }})"
}

# ── TRIG-6 — the mechanical checks ran, on this session's source ───────
# One stamp per name in ROTATION_STAMPS, <name>-latest.json under the
# stamp dir, five fixed keys: tool / ranAt / headSha / headShaSource /
# verdict (the write side is the project's stamp writer).
#
# A stamp counts only when its headSha is a commit in THIS session, the
# tree was clean when it was written, and its verdict is `ok`. A `-dirty`
# stamp measured something that is not any commit; a sha from an earlier
# session is last rotation's answer wearing this rotation's label — the
# exact carry-forward this gate exists to stop; a stamp without a verdict
# is an unknown reading, and unknown is not green. An empty stamp list is
# not "nothing to check" — it is a configuration with no evidence, and it
# FAILs.
#
# One carry-forward is legitimate: the close planner (close_plan.sh)
# found nothing on the check's trigger paths changed between the stamp's
# sha and HEAD, and carry_stamp.sh wrote `carriedTo: <HEAD>` into the
# stamp with the reason. That is a mechanical inference from the rules
# table, recorded in the stamp, and distinguishable from the accidental
# kind: the headSha still names what was measured, and the carry must
# point at exactly this HEAD — a carry to an earlier commit of the session
# was decided before later commits could have touched the paths.
check_trig6() {
  local range shas missing=() stale=() red=() fresh=() head
  local names
  names=$(printf '%s' "${ROTATION_STAMPS:-}" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  if [ -z "$names" ]; then
    emit TRIG-6 FAIL "ROTATION_STAMPS is empty in rotation.conf — a close with no stamps has no evidence"
    failed+=(TRIG-6)
    return
  fi
  range=$(session_range)
  shas=$(git -C "$PROJECT_DIR" rev-list "$range" 2>/dev/null)
  if [ -z "$shas" ]; then
    emit TRIG-6 SKIP "git rev-list $range returned nothing"
    return
  fi
  head=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null)
  local name file sha verdict carried
  for name in $names; do
    file="$STAMP_DIR/$name-latest.json"
    if [ ! -f "$file" ]; then
      missing+=("$name")
      continue
    fi
    sha=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("headSha") or "")' "$file" 2>/dev/null)
    verdict=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("verdict") or "")' "$file" 2>/dev/null)
    carried=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("carriedTo") or "")' "$file" 2>/dev/null)
    if [ -z "$sha" ] || [ "${sha%-dirty}" != "$sha" ]; then
      stale+=("$name(${sha:-no-sha})")
    elif [ -z "$verdict" ]; then
      red+=("$name(no-verdict)")
    elif [ -n "$carried" ] && [ "${head#"$carried"}" != "$head" ] && git -C "$PROJECT_DIR" cat-file -e "$sha^{commit}" 2>/dev/null; then
      # carried to this HEAD by the planner: the reading stands, the verdict must still be green
      if [ "$verdict" != "ok" ]; then
        red+=("$name($verdict)")
      else
        fresh+=("$name=${sha}→carried")
      fi
    elif ! printf '%s\n' "$shas" | grep -q "^$sha"; then
      stale+=("$name($sha)")
    elif [ "$verdict" != "ok" ]; then
      red+=("$name($verdict)")
    else
      fresh+=("$name=$sha")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ] || [ "${#stale[@]}" -gt 0 ] || [ "${#red[@]}" -gt 0 ]; then
    local msg=""
    [ "${#missing[@]}" -gt 0 ] && msg="missing: ${missing[*]}; "
    [ "${#stale[@]}" -gt 0 ] && msg="${msg}not from this session: ${stale[*]}; "
    [ "${#red[@]}" -gt 0 ] && msg="${msg}red: ${red[*]}; "
    emit TRIG-6 FAIL "${msg}run them on the final HEAD (or carry them by the close plan) and commit the stamps"
    failed+=(TRIG-6)
    return
  fi
  emit TRIG-6 PASS "${#fresh[@]}/${#fresh[@]} stamps from this session (${fresh[*]})"
}

# ── TRIG-7 — the handoff's sweep line matches the sweep ────────────────
# The close restates the main instrument's counters and deltas every
# rotation. Both halves have gone wrong while looking entirely normal —
# one rotation computed the deltas against the runner's stale copy of the
# baseline and produced a plausible, well-formed, completely false diff
# that took a rotation of A/B to disprove.
#
# ROTATION_SWEEP_LINE_CMD derives the line from the committed stamp
# (ROTATION_SWEEP_STAMP), with the baseline taken from the project's
# history. This gate re-derives it and requires every token to appear in
# the handoff. A pasted line cannot disagree; a hand-edited one does. The
# cheapest way to stop transcription errors is to stop transcribing, and
# this is the half that makes sure it happened. A project that has not
# configured the command, or whose stamp is missing, FAILs here rather
# than skipping: "not configured" and "stamp lost" must never look like a
# pass.
check_trig7() {
  if [ ! -f "$HANDOFF_FILE" ]; then
    emit TRIG-7 FAIL "handoff missing at $HANDOFF_FILE"
    failed+=(TRIG-7)
    return
  fi
  if [ -z "$SWEEP_STAMP" ] || [ -z "${ROTATION_SWEEP_LINE_CMD:-}" ]; then
    emit TRIG-7 FAIL "no sweep line configured (ROTATION_SWEEP_STAMP in rotation.conf, ROTATION_SWEEP_LINE_CMD in project.sh)"
    failed+=(TRIG-7)
    return
  fi
  if [ ! -f "$ROTATION_SWEEP_LINE_CMD" ]; then
    emit TRIG-7 FAIL "sweep line command not found: $ROTATION_SWEEP_LINE_CMD"
    failed+=(TRIG-7)
    return
  fi
  local want rc
  want=$(HARDEV_SWEEP_JSON="$STAMP_DIR/$SWEEP_STAMP-latest.json" ROTATION_SWEEP_JSON="$STAMP_DIR/$SWEEP_STAMP-latest.json" \
         bash "$ROTATION_SWEEP_LINE_CMD" 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 2 ] || [ -z "$want" ]; then
    emit TRIG-7 FAIL "no sweep stamp to derive the line from ($STAMP_DIR/$SWEEP_STAMP-latest.json; command exit $rc)"
    failed+=(TRIG-7)
    return
  fi
  if [ "$rc" -ne 0 ]; then
    emit TRIG-7 FAIL "conservation broken in the sweep itself: ${want#sweep: }"
    failed+=(TRIG-7)
    return
  fi
  # Compare token sets, not the literal line: the handoff is prose and the
  # line gets wrapped. Every token the script produces must be present.
  local handoff_body missing=() tok
  handoff_body=$(tr '\n' ' ' < "$HANDOFF_FILE")
  case "$handoff_body" in
    *"sweep:"*) ;;
    *) emit TRIG-7 FAIL "handoff carries no 'sweep:' line — paste the output of $ROTATION_SWEEP_LINE_CMD"
       failed+=(TRIG-7); return ;;
  esac
  for tok in ${want#sweep: }; do
    case "$handoff_body" in
      *"$tok"*) ;;
      *) missing+=("$tok") ;;
    esac
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    emit TRIG-7 FAIL "handoff sweep line disagrees with the stamp on: ${missing[*]}"
    failed+=(TRIG-7)
    return
  fi
  emit TRIG-7 PASS "sweep line matches the stamp (${want#sweep: head=})"
}

# ── TRIG-8 — a gate ran on this round's substrate, on record ───────────
# TRIG-3 reads the `gate:` triple the handoff states and never asks where
# it came from. The gate command the project registers (ROTATION_GATE_CMD,
# README, the adapter command contract) records a gate.end event for every gate it runs,
# and the close planner's section 1 is built from those. This gate reads
# the same facts (close_lib.py coverage): the round's range changed files
# on some check's trigger paths in the rules table, and no gate.end of this
# round exists (by rotation id, or by a sha in the range) → the F=0 in the
# handoff has no record behind it. A docs-only range needs no gate. Off by
# default: turning it on changes what the gate decides, so a project does
# that in a gap between rounds (rotation.conf ROTATION_TRIG8_GATE_COVERAGE).
check_trig8() {
  [ "$TRIG8_GATE_COVERAGE" = on ] || return
  local row prev head rid
  row=$(autorun_last_self_row)
  if [ -z "$row" ]; then
    emit TRIG-8 SKIP "no prior self rotation (cold start)"
    return
  fi
  prev=$(printf '%s\n' "$row" | cut -f2)
  head=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null)
  rid=$(autorun_current_rotation_id)
  if [ -z "${ROTATION_CLOSE_RULES:-}" ] || [ ! -f "$ROTATION_CLOSE_RULES" ]; then
    emit TRIG-8 FAIL "no rules table (ROTATION_CLOSE_RULES) — which paths count as substrate is unknown"
    failed+=(TRIG-8)
    return
  fi
  local cov rc
  cov=$(ROTATION_REPO="$PROJECT_DIR" ROTATION_CLOSE_RULES="$ROTATION_CLOSE_RULES" \
        ROTATION_ROTATIONS_LOG="$ROTATIONS_LOG" ROTATION_EVENTS_LOG="$EVENTS_LOG" \
        python3 "$SCRIPT_DIR/close_lib.py" coverage "$prev" "$head" "$rid" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    emit TRIG-8 FAIL "cannot read the gate coverage of $prev..HEAD: $cov"
    failed+=(TRIG-8)
    return
  fi
  case "$cov" in
    *"missing=yes"*)
      emit TRIG-8 FAIL "$cov — the range changed substrate and no gate.end event belongs to round $rid; run the gate through ROTATION_GATE_CMD"
      failed+=(TRIG-8)
      return ;;
  esac
  emit TRIG-8 PASS "$cov (round $rid)"
}

resolve_wall
check_trig1
check_trig2
check_trig3
check_trig4
check_trig5
check_trig6
check_trig7
check_trig8

if [ "${#failed[@]}" -gt 0 ]; then
  echo "TRIG-FAILED: ${failed[*]}" >&2
  exit 1
fi
exit 0
