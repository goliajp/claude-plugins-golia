#!/usr/bin/env bash
#
# rotation kernel — check.sh self-test.
#
# A throwaway repository with its own handoff and rotations.jsonl
# (ROTATION_PROJECT_DIR / ROTATION_STATE_DIR); the project this kernel is
# installed in is never touched.
#
#   case 1: GREEN happy path                    → exit 0, INV-1..6 all PASS or SKIP
#   case 2: INV-1 (stale handoff.md mtime)      → exit 1, INV-1 FAIL line
#   case 3: INV-2 (dirty working tree)          → exit 1, INV-2 FAIL line
#   case 4: INV-5 (duplicate rotation_id)       → exit 1, INV-5 FAIL line
#   case 5: INV-3 (gate pass count dropped)     → exit 1, INV-3 FAIL line
#   case 6: INV-4 (handoff without the section) → exit 1, INV-4 FAIL line
#   case 7: INV-4 reads the heading rotation.conf names → exit 0
#   case 8: INV-6 agent worktrees vs open agents  → FAIL listing the extra path; PASS while its agent is open;
#           a worktree elsewhere is not counted; ROTATION_WORKTREE_CHECK=0 → SKIP
#
# Exit: 0 if all cases behave as expected; 1 otherwise.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$(cd "$SCRIPT_DIR/../bin" && pwd)"
CHECK="$BIN/check.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

REPO="$TMP/repo"
mkdir -p "$REPO/.claude" "$TMP/state"
g() { git -C "$REPO" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
g init -q -b develop
echo a > "$REPO/a.txt"; g add a.txt; g commit -q -m "feat: first"
SHA=$(g rev-parse --short HEAD)
HANDOFF="$REPO/.claude/handoff.md"
ROT="$TMP/state/rotations.jsonl"

mk_handoff() {  # mk_handoff <heading> <gate line>
  printf '# handoff\n\nHEAD %s\n\n## %s\n\naxis: A\nclosed: %s did a thing\n%s\n' "$SHA" "$1" "$SHA" "$2" > "$HANDOFF"
}
mk_row() {  # mk_row <rid> <conformanceBefore>
  printf '{"rotationId":"%s","at":"x","ts":1,"project":"repo","trigger":"self","prevHead":"%s","conformanceBefore":"%s"}\n' "$1" "$SHA" "$2" > "$ROT"
}

pass=0
fail=0

run_case() {
  # run_case <name> <expected_exit> <expected_grep_pattern_or_empty> <args...>
  local name=$1 expected_exit=$2 pattern=$3
  shift 3
  local out rc
  out=$(ROTATION_PROJECT_DIR="$REPO" ROTATION_STATE_DIR="$TMP/state" ROTATION_CONF="${CONF:-/dev/null}" ROTATION_PROJECT_SH=/dev/null \
        "$CHECK" "$@" 2>&1) && rc=0 || rc=$?
  if [ "$rc" -ne "$expected_exit" ]; then
    printf 'FAIL %s: expected exit=%d, got exit=%d\n' "$name" "$expected_exit" "$rc"
    printf '%s\n' "  output:" "$out" | sed 's/^/    /'
    fail=$((fail + 1))
    return
  fi
  if [ -n "$pattern" ] && ! printf '%s' "$out" | grep -q -- "$pattern"; then
    printf 'FAIL %s: exit ok but output missing pattern "%s"\n' "$name" "$pattern"
    printf '%s\n' "  output:" "$out" | sed 's/^/    /'
    fail=$((fail + 1))
    return
  fi
  printf 'PASS %s\n' "$name"
  pass=$((pass + 1))
}

# ── case 1 — GREEN happy path ───────────────────────────────────────────
echo "[case 1] GREEN happy path → exit 0 + all INV PASS/SKIP"
mk_handoff "rotate-trigger" "gate: 10/0/0"
mk_row r-prev "9/0/0"
run_case "case-1 GREEN happy" 0 "INV-3 PASS"

# ── case 2 — INV-1 stale handoff ────────────────────────────────────────
echo "[case 2] INV-1 stale handoff (-200s mtime) → exit 1 + INV-1 FAIL"
touch -t "$(date -v-200S +%Y%m%d%H%M.%S)" "$HANDOFF"
run_case "case-2 INV-1 stale" 1 "INV-1 FAIL"
touch -m "$HANDOFF"

# ── case 3 — INV-2 dirty tree ───────────────────────────────────────────
echo "[case 3] INV-2 dirty tree (untracked file) → exit 1 + INV-2 FAIL"
echo x > "$REPO/stray.txt"
run_case "case-3 INV-2 dirty" 1 "INV-2 FAIL"
rm -f "$REPO/stray.txt"

# ── case 4 — INV-5 duplicate rotation_id ────────────────────────────────
echo "[case 4] INV-5 duplicate rotation_id → exit 1 + INV-5 FAIL"
run_case "case-4 INV-5 dup-id" 1 "INV-5 FAIL" r-prev
run_case "case-4b INV-5 fresh id" 0 "INV-5 PASS" r-new

# ── case 5 — INV-3 pass count dropped ───────────────────────────────────
echo "[case 5] INV-3 gate pass count below the prior row → exit 1 + INV-3 FAIL"
mk_row r-prev "11/0/0"
run_case "case-5 INV-3 regression" 1 "INV-3 FAIL"
mk_row r-prev "9/0/0"

# ── case 6 — INV-4 phantom handoff ──────────────────────────────────────
echo "[case 6] INV-4 handoff without the trigger section → exit 1 + INV-4 FAIL"
printf '# handoff\n\nHEAD %s\n' "$SHA" > "$HANDOFF"
run_case "case-6 INV-4 no section" 1 "INV-4 FAIL"

# ── case 7 — INV-4 reads the project's heading ──────────────────────────
echo "[case 7] INV-4 accepts the heading rotation.conf names → exit 0"
printf 'ROTATION_CONF_KERNEL=1\nROTATION_TRIGGER_SECTION=handover|rotate-trigger\n' > "$TMP/heading.conf"
mk_handoff "handover" "gate: 10/0/0"
CONF="$TMP/heading.conf" run_case "case-7 INV-4 project heading" 0 "INV-4 PASS"
run_case "case-7b INV-4 that heading is not read without the conf" 1 "INV-4 FAIL"

# ── case 8 — INV-6 agent worktrees ──────────────────────────────────────
echo "[case 8] INV-6 an agent worktree with no open agent → exit 1 + INV-6 FAIL"
mk_handoff "rotate-trigger" "gate: 10/0/0"
EV="$TMP/state/events.jsonl"
NOW=$(date +%s)
printf '{"rotationId":"r-a","ts":%d,"trigger":"self","prevHead":"%s"}\n{"rotationId":"r-b","ts":%d,"trigger":"self","prevHead":"%s"}\n' \
  "$((NOW - 3000))" "$SHA" "$((NOW - 1000))" "$SHA" > "$ROT"
g worktree add -q --detach "$REPO/.claude/worktrees/agent-w1" HEAD
g worktree add -q --detach "$TMP/elsewhere" HEAD
WT1=$(cd "$REPO/.claude/worktrees/agent-w1" && pwd -P)
: > "$EV"
run_case "case-8 INV-6 no open agent" 1 "INV-6 FAIL agent worktrees 1 > open agents 0"
run_case "case-8b the extra worktree is listed" 1 "^  .*/.claude/worktrees/agent-w1$"
printf '{"kind":"agent.start","ts":%d,"agent":{"name":"w1","role":"worker","worktree":"%s"}}\n' "$((NOW - 5000))" "$WT1" >> "$EV"
run_case "case-8c an agent started before the previous row does not count" 1 "INV-6 FAIL"
printf '{"kind":"agent.start","ts":%d,"agent":{"name":"w1","role":"worker","worktree":"%s"}}\n' "$((NOW - 2000))" "$WT1" >> "$EV"
run_case "case-8d its agent open since the previous row: PASS (the worktree elsewhere is not counted)" 0 "INV-6 PASS agent worktrees 1 <= open agents 1"
g worktree add -q --detach "$REPO/.claude/worktrees/agent-w2" HEAD
run_case "case-8e a second worktree, one agent: FAIL" 1 "INV-6 FAIL agent worktrees 2 > open agents 1"
run_case "case-8f only the worktree no open agent records is listed" 1 "/.claude/worktrees/agent-w2$"
out=$(ROTATION_PROJECT_DIR="$REPO" ROTATION_STATE_DIR="$TMP/state" ROTATION_CONF=/dev/null ROTATION_PROJECT_SH=/dev/null "$CHECK" 2>&1)
if printf '%s\n' "$out" | grep -q 'agent-w1$'; then printf 'FAIL case-8g the owned worktree is listed\n'; fail=$((fail + 1)); else printf 'PASS case-8g the owned worktree is not listed\n'; pass=$((pass + 1)); fi
g worktree remove --force "$REPO/.claude/worktrees/agent-w2"
printf '{"kind":"agent.end","ts":%d,"agent":{"name":"w1","role":"worker"}}\n' "$((NOW - 10))" >> "$EV"
run_case "case-8h its agent ended: FAIL" 1 "INV-6 FAIL agent worktrees 1 > open agents 0"
printf 'ROTATION_CONF_KERNEL=1\nROTATION_WORKTREE_CHECK=0\n' > "$TMP/nowt.conf"
CONF="$TMP/nowt.conf" run_case "case-8i ROTATION_WORKTREE_CHECK=0: SKIP" 0 "INV-6 SKIP ROTATION_WORKTREE_CHECK=0"
g worktree remove --force "$REPO/.claude/worktrees/agent-w1"
run_case "case-8j no agent worktree left: PASS" 0 "INV-6 PASS agent worktrees 0 <= open agents 0"

echo
echo "self-test: $pass pass · $fail fail"
[ "$fail" -eq 0 ]
