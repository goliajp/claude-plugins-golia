#!/usr/bin/env bash
#
# rotation kernel — close_plan.sh / close_verdict_fill.sh self-test.
#
# A throwaway git repository, a rules table shaped like the project's, and
# stamps written by hand; every path the planner can take is exercised
# without touching production state (all locations are redirected through
# the ROTATION_* / HARDEV_* overrides).
#
# Cases:
#   1  docs-only rotation                → every check carried, release "next"
#   2  a runtime crate changed           → sweep / gmalloc / bench run, determinism carried,
#                                          release "sync-then-next-async" (size is sync)
#   3  a stamp missing                   → that check runs even on a docs-only rotation
#   4  a dirty stamp                     → runs
#   5  a red stamp                       → runs, and sync
#   6  bench harness changed             → bench turns sync (sync_paths)
#   7  re-plan of the same range         → verdict reused, not rewritten
#   8  carry applied (carry_stamp.sh)    → stamp carries carriedTo, history row carried:true,
#                                          re-plan reads it as current
#   9  fill: ran at HEAD, pass bucket dropped → RED in the verdict
#  10  fill: carried stamp                → "carried" status, no regression
#  11  the project's real rules table parses and plans (only when one is installed)
#  12  substrate range with no gate.end   → plan says MISSING, verdict §1 says so, fill RED;
#                                          a docs-only range is clean without a gate
#  13  a stamp without a verdict key      → runs, and RED on fill
#  14  an empty rules table               → exit 2
#  15  no message table                     → the verdict in the kernel's English
#  16  a project's message table            → the same verdict in that table's words (plan and fill)
#  17  a table with an unknown key          → exit 2
#  18  a check switched off in the conf     → ROTATION_CLOSE_CHECKS_OFF drops its row from plan and verdict;
#                                          on, it runs; fill reads its `total:up` regression red (197 → 198)
#                                          and a drop (198 → 190) ok; an unknown name in the switch → exit 2
#  19  fill: a check planned to run whose stamp never reached HEAD → amber (never ok); a carried-by-plan
#                                          check with an old stamp is not
#  20  fill: the baseline is the last stamp at or before the round's start (prevSha), never a mid-round
#                                          stamp; the section header names the baseline sha
#
# Everything runs against the fixture: ROTATION_PROJECT_DIR / ROTATION_CONF=/dev/null /
# ROTATION_PROJECT_SH=/dev/null, so the installed project's conf and adapter are never read.
#
# Exit: 0 if all cases behave as expected; 1 otherwise.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$(cd "$SCRIPT_DIR/../bin" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLAN="$BIN/close_plan.sh"
FILL="$BIN/close_verdict_fill.sh"
CARRY="$BIN/carry_stamp.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0

REPO="$TMP/repo"
mkdir -p "$REPO" "$TMP/stamps" "$TMP/verdicts"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name t
mkdir -p "$REPO/crates/alpha-str/src" "$REPO/crates/alpha-core/src" "$REPO/docs" "$REPO/bench/harness"
echo a > "$REPO/crates/alpha-str/src/lib.rs"
echo a > "$REPO/crates/alpha-core/src/lib.rs"
echo a > "$REPO/docs/a.md"
echo a > "$REPO/bench/harness/main.rs"
git -C "$REPO" add -A && git -C "$REPO" commit -qm 'chore: seed'
C0="$(git -C "$REPO" rev-parse HEAD)"

cat > "$TMP/rules.tsv" <<'TSV'
#name	paths	artifact	stamp	minutes	mode	sync_paths	needs	show	regress
release-build	-	-	-	2	-	-	-	-	-
sweep	crates/**;!crates/alpha-bench/**	release-tr	sweep	9	async	-	release-build	pass,passTotal,harnessError	pass:down;passTotal:down;harnessError:nonzero
determinism	crates/alpha-core/**	iter-tr	determinism:build_determinism	4	async	-	-	cases,nondeterministic	nondeterministic:nonzero
gmalloc	crates/**	iter-tr	gmalloc:gmalloc_scan	8	async	-	-	offenders	offenders:nonzero
bench	crates/**;bench/**	release-tr	bench	18	async	bench/**	release-build	medianVsBunAot	-
size	crates/**	-	size:file_size_audit	0.1	sync	-	-	filesNew	filesNew:nonzero
TSV

commit() {  # commit <path> <message>
  echo "$RANDOM" >> "$REPO/$1"
  git -C "$REPO" add -A && git -C "$REPO" commit -qm "$2"
}

mk_stamps() {  # mk_stamps <sha>: every stamp green at that sha
  local sha=$1 n
  for n in determinism:build_determinism gmalloc:gmalloc_scan size:file_size_audit bench:bench; do
    printf '{"tool":"%s","ranAt":"2026-10-01T00:00:00Z","headSha":"%s","headShaSource":"arg","verdict":"ok","cases":5,"nondeterministic":0,"offenders":0,"filesNew":0,"medianVsBunAot":0.5}\n' \
      "${n#*:}" "$sha" > "$TMP/stamps/${n%:*}-latest.json"
  done
  printf '{"tool":"sweep","ranAt":"2026-10-01T00:00:00Z","headSha":"%s","verdict":"ok","harnessError":0,"pass":100,"passTotal":120}\n' "$sha" \
    > "$TMP/stamps/sweep-latest.json"
  : > "$TMP/stamps/stamps.jsonl"
}
gate_end() {  # gate_end <sha>: the gate ran green on that commit (what the project's ROTATION_GATE_CMD records)
  printf '{"at":"x","ts":%s,"kind":"gate.end","rotationId":"r-test-1","head":"x","gate":{"sha":"%s","pass":10,"fail":0,"skip":0}}\n' \
    "$(date +%s)" "$1" >> "$TMP/events.jsonl"
}

# every kernel call points at the fixtures and away from the installed project's conf / adapter
KENV=(ROTATION_PROJECT_DIR="$REPO" ROTATION_CONF=/dev/null ROTATION_PROJECT_SH=/dev/null ROTATION_REPO="$REPO"
      HARDEV_STAMP_DIR="$TMP/stamps" ROTATION_STAMP_HISTORY="$TMP/stamps/stamps.jsonl" ROTATION_VERDICT_DIR="$TMP/verdicts"
      HARDEV_ROTATIONS_LOG="$TMP/rot.jsonl" HARDEV_EVENTS_LOG="$TMP/events.jsonl")
run_plan() {  # run_plan <args...> → stdout, exit in $rc. RID=auto lets the planner resolve the id from rotations.jsonl
  local rid=(--rid "${RID:-r-test-1}")
  [ "${RID:-}" = auto ] && rid=()
  env "${KENV[@]}" ROTATION_CONF="${CONF:-/dev/null}" ROTATION_CLOSE_RULES="${RULES:-$TMP/rules.tsv}" bash "$PLAN" "$@" ${rid[@]+"${rid[@]}"} 2>&1
}
run_fill() {
  env "${KENV[@]}" ROTATION_CONF="${CONF:-/dev/null}" ROTATION_CLOSE_RULES="${RULES:-$TMP/rules.tsv}" bash "$FILL" "$@" 2>&1
}
run_carry() {
  env "${KENV[@]}" ROTATION_CLOSE_RULES="$TMP/rules.tsv" bash "$CARRY" "$@" 2>&1
}

check() {  # check <name> <output> <exit> <want_exit> <regex>...
  local name=$1 out=$2 rc=$3 want=$4; shift 4
  local ok=1 re
  [ "$rc" -eq "$want" ] || ok=0
  for re in "$@"; do
    printf '%s\n' "$out" | grep -qE -- "$re" || ok=0
  done
  if [ "$ok" -eq 1 ]; then
    printf 'ok   %s\n' "$name"; pass=$(( pass + 1 ))
  else
    printf 'FAIL %s (exit=%d want=%d; wanted %s)\n' "$name" "$rc" "$want" "$*"
    printf '%s\n' "$out" | sed 's/^/       | /'
    fail=$(( fail + 1 ))
  fi
}

printf '{"rotationId":"r-test-1","at":"x","ts":1,"project":"repo","trigger":"self","prevHead":"%s"}\n' "${C0:0:9}" > "$TMP/rot.jsonl"

# 1 — docs only: nothing on any trigger path, every check carried, straight into the next rotation
mk_stamps "$C0"
commit docs/a.md 'docs: words'
H1="$(git -C "$REPO" rev-parse HEAD)"
out=$(RID=auto run_plan "$C0" "$H1" --explain); rc=$?
check "1 docs-only: all carried, next (rid from rotations.jsonl)" "$out" "$rc" 0 'verdict: .*/r-test-1\.verdict\.md' \
  'run=\[\] carry=\[release-build sweep determinism gmalloc bench size\]' \
  'release: next ' 'sweep +carry — no change on trigger paths since [0-9a-f]{9}'
grep -q 'everything carried, straight into the next rotation' "$TMP/verdicts/r-test-1.verdict.md" \
  && { echo "ok   1m verdict says everything carried"; pass=$(( pass + 1 )); } \
  || { echo "FAIL 1m verdict wording"; fail=$(( fail + 1 )); }

# 1b — the empty rotation (stamps already at HEAD) is also "next", worded as current
mk_stamps "$H1"
rm -f "$TMP/verdicts"/*
out=$(RID=auto run_plan --explain); rc=$?
check "1b no shas given: open rotation from its row; all current: next" "$out" "$rc" 0 'run=\[\]' 'release: next ' 'sweep +at HEAD'

# 1c — a stamp naming HEAD by a short sha (older stamps) is current all the same: the planner expands it
mk_stamps "${H1:0:9}"
rm -f "$TMP/verdicts"/*
out=$(RID=auto run_plan --explain); rc=$?
check "1c short-sha stamp at HEAD is current" "$out" "$rc" 0 'run=\[\]' 'sweep +at HEAD'

# 2 — a runtime crate changed: sweep / gmalloc / bench run, determinism carries
mk_stamps "$H1"
rm -f "$TMP/verdicts"/*
commit crates/alpha-str/src/lib.rs 'perf: str'
H2="$(git -C "$REPO" rev-parse HEAD)"
out=$(run_plan "$H1" "$H2" --explain); rc=$?
check "2 runtime crate: sweep/gmalloc/bench run, determinism carried" "$out" "$rc" 0 \
  'run=\[release-build sweep gmalloc bench size\] carry=\[determinism\]' \
  'release: sync-then-next-async ' 'crates/alpha-str/src/lib.rs  ← crates/\*\*' 'determinism +carry'
V2="$TMP/verdicts/r-test-1.verdict.json"
[ -f "$V2" ] && python3 -c 'import json,sys; v=json.load(open(sys.argv[1])); assert v["release"]["sync"]==["size"]; assert v["release"]["async"]==["release-build","sweep","gmalloc","bench"]' "$V2" \
  && { echo "ok   2j verdict json sync/async columns"; pass=$(( pass + 1 )); } \
  || { echo "FAIL 2j verdict json sync/async columns"; fail=$(( fail + 1 )); }
grep -q '^## 4 Release' "$TMP/verdicts/r-test-1.verdict.md" && grep -q '^## 2 Decision' "$TMP/verdicts/r-test-1.verdict.md" \
  && { echo "ok   2m verdict markdown has the four sections"; pass=$(( pass + 1 )); } \
  || { echo "FAIL 2m verdict markdown sections"; fail=$(( fail + 1 )); }

# 3 — a stamp missing runs even on a docs-only rotation
mk_stamps "$H2"
rm -f "$TMP/verdicts"/* "$TMP/stamps/gmalloc-latest.json"
commit docs/a.md 'docs: more'
H3="$(git -C "$REPO" rev-parse HEAD)"
out=$(run_plan "$H2" "$H3" --explain); rc=$?
check "3 missing stamp runs" "$out" "$rc" 0 'run=\[gmalloc\]' 'gmalloc +run.*no stamp'

# 4 — a dirty stamp runs
mk_stamps "$H2"
rm -f "$TMP/verdicts"/*
printf '{"tool":"build_determinism","ranAt":"x","headSha":"%s-dirty","verdict":"ok"}\n' "${H2:0:9}" > "$TMP/stamps/determinism-latest.json"
out=$(run_plan "$H2" "$H3" --explain); rc=$?
check "4 dirty stamp runs" "$out" "$rc" 0 'determinism +run.*dirty tree'

# 5 — a red stamp runs, and sync
mk_stamps "$H2"
rm -f "$TMP/verdicts"/*
printf '{"tool":"gmalloc_scan","ranAt":"x","headSha":"%s","verdict":"fail","offenders":2}\n' "$H2" > "$TMP/stamps/gmalloc-latest.json"
out=$(run_plan "$H2" "$H3" --explain); rc=$?
check "5 red stamp runs sync" "$out" "$rc" 0 'gmalloc +run \(sync: last round.s reading unresolved\)' 'sync=[0-9.]+min \[gmalloc\]'

# 6 — bench harness changed: bench turns sync
mk_stamps "$H3"
rm -f "$TMP/verdicts"/*
commit bench/harness/main.rs 'perf: harness'
H4="$(git -C "$REPO" rev-parse HEAD)"
out=$(run_plan "$H3" "$H4" --explain); rc=$?
check "6 bench harness: bench sync" "$out" "$rc" 0 'bench +run \(sync: sync path hit: bench/harness/main.rs\)' \
  'run=\[release-build bench\]' 'release-build +run \(sync'

# 7 — re-plan of the same range reuses the verdict
out=$(run_plan "$H3" "$H4"); rc=$?
check "7 re-plan reuses" "$out" "$rc" 0 '^verdict exists:'
n_events=$(grep -c '"close.plan"' "$TMP/events.jsonl")
[ "$n_events" -eq 8 ] && { echo "ok   7e one close.plan event per fresh plan ($n_events)"; pass=$(( pass + 1 )); } \
  || { echo "FAIL 7e close.plan events: $n_events, want 8"; fail=$(( fail + 1 )); }

# 8 — carry applied: stamp carries carriedTo, history row carried:true, re-plan reads it as current
mk_stamps "$H3"
rm -f "$TMP/verdicts"/*
out=$(run_carry determinism "$H4" "no change on trigger paths since ${H3:0:9}"); rc=$?
check "8 carry_stamp writes the carry" "$out" "$rc" 0 "carriedTo=${H4:0:9}"
grep -q '"stamp.carried"' "$TMP/events.jsonl" && { echo "ok   8e stamp.carried event recorded"; pass=$(( pass + 1 )); } \
  || { echo "FAIL 8e stamp.carried event"; fail=$(( fail + 1 )); }
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["headSha"]==sys.argv[2]; assert d["carriedTo"]==sys.argv[3]; assert d["carriedReason"]' \
  "$TMP/stamps/determinism-latest.json" "$H3" "$H4" \
  && grep -q '"carried":true' "$TMP/stamps/stamps.jsonl" \
  && { echo "ok   8s stamp keeps headSha, history row carried:true"; pass=$(( pass + 1 )); } \
  || { echo "FAIL 8s carried stamp shape"; fail=$(( fail + 1 )); }
out=$(run_carry determinism "$H4" again); rc=$?
check "8i carry is idempotent" "$out" "$rc" 0 'already: carried'
out=$(run_carry gmalloc "$H3" x); rc=$?
check "8c carry to the measured sha is a no-op" "$out" "$rc" 0 'same: stamp already measured'
printf '{"tool":"gmalloc_scan","ranAt":"x","headSha":"%s","offenders":0}\n' "$H3" > "$TMP/stamps/gmalloc-latest.json"
out=$(run_carry gmalloc "$H4" x); rc=$?
check "8v a stamp without a verdict is not carried" "$out" "$rc" 1 'refuse: stamp has no verdict'
mk_stamps "$H3"
run_carry determinism "$H4" "no change on trigger paths since ${H3:0:9}" >/dev/null
out=$(run_plan "$H3" "$H4" --explain); rc=$?
check "8p re-plan sees the carry as current" "$out" "$rc" 0 'determinism +at HEAD — carried to HEAD \(no change'

# 9 — fill: sweep ran at HEAD with the pass bucket down → RED. The range H3..H4 changed the bench harness
# (a substrate path), so a gate.end for H4 is recorded first: without it the gate coverage itself is red (case 12)
mk_stamps "$H3"
rm -f "$TMP/verdicts"/*
gate_end "$H4"
printf '{"tool":"sweep","ranAt":"2026-10-01T00:00:00Z","headSha":"%s","verdict":"ok","harnessError":0,"pass":100,"passTotal":120,"file":"x"}\n' "$H3" > "$TMP/stamps/stamps.jsonl"
printf '{"tool":"sweep","ranAt":"2026-10-01T01:00:00Z","headSha":"%s","verdict":"ok","harnessError":0,"pass":97,"passTotal":121}\n' "$H4" > "$TMP/stamps/sweep-latest.json"
out=$(run_plan "$H3" "$H4"); rc=$?
check "9p plan sees the gate.end (coverage ok)" "$out" "$rc" 0 'gate: substrateFiles=1 gateEnds=1 ok'
out=$(run_fill r-test-1); rc=$?
check "9 fill flags a pass regression red" "$out" "$rc" 0 'red=1' 'RED +sweep: pass 100 → 97'
grep -qF 'pass=97(-3) passTotal=121(+1)' "$TMP/verdicts/r-test-1.verdict.md" && grep -qF 'Regressions (red)' "$TMP/verdicts/r-test-1.verdict.md" \
  && { echo "ok   9m verdict section 3 carries readings and the red line"; pass=$(( pass + 1 )); } \
  || { echo "FAIL 9m verdict section 3"; sed -n '/results:begin/,/results:end/p' "$TMP/verdicts/r-test-1.verdict.md"; fail=$(( fail + 1 )); }
n_res=$(grep -c '"close.result"' "$TMP/events.jsonl")
[ "$n_res" -eq 1 ] && { echo "ok   9e close.result event"; pass=$(( pass + 1 )); } || { echo "FAIL 9e close.result events: $n_res"; fail=$(( fail + 1 )); }

# 10 — fill: a carried stamp reads as carried, no regression
run_carry determinism "$H4" "no change on trigger paths since ${H3:0:9}" >/dev/null
out=$(run_fill r-test-1); rc=$?
check "10 fill reports carried stamps" "$out" "$rc" 0 'red=1'
grep -qE '^\| determinism \| carried from '"${H3:0:9}" "$TMP/verdicts/r-test-1.verdict.md" \
  && { echo "ok   10m carried row in section 3"; pass=$(( pass + 1 )); } \
  || { echo "FAIL 10m carried row"; grep '^| determinism' "$TMP/verdicts/r-test-1.verdict.md"; fail=$(( fail + 1 )); }

# 12 — a substrate range with no gate.end at all: the plan says so, the verdict says so, fill turns it red
mk_stamps "$H3"
rm -f "$TMP/verdicts"/*
: > "$TMP/events.jsonl"
out=$(run_plan "$H3" "$H4"); rc=$?
check "12p plan reports missing gate coverage" "$out" "$rc" 0 'gate: substrateFiles=1 gateEnds=0 MISSING'
grep -q 'gate events this round: \*\*missing\*\*' "$TMP/verdicts/r-test-1.verdict.md" \
  && { echo "ok   12m verdict section 1 says the gate events are missing"; pass=$(( pass + 1 )); } \
  || { echo "FAIL 12m verdict section 1 gate line"; grep 'gate' "$TMP/verdicts/r-test-1.verdict.md"; fail=$(( fail + 1 )); }
out=$(run_fill r-test-1); rc=$?
check "12 fill turns a missing gate.end red" "$out" "$rc" 0 'red=1' 'RED +gate: 1 substrate file\(s\) changed in the range and no gate.end'
# a docs-only range needs no gate: nothing is red
mk_stamps "$H2"
rm -f "$TMP/verdicts"/*
out=$(run_plan "$H2" "$H3"); rc=$?
check "12d docs-only range: coverage ok without a gate" "$out" "$rc" 0 'gate: substrateFiles=0 gateEnds=0 ok'
out=$(run_fill r-test-1); rc=$?
check "12f docs-only fill is clean" "$out" "$rc" 0 'red=0'

# 13 — a stamp without a verdict key: planned as run, red on fill
mk_stamps "$H3"
rm -f "$TMP/verdicts"/*
gate_end "$H4"
printf '{"tool":"gmalloc_scan","ranAt":"x","headSha":"%s","offenders":0}\n' "$H4" > "$TMP/stamps/gmalloc-latest.json"
out=$(run_plan "$H3" "$H4" --explain); rc=$?
check "13p a stamp without verdict runs" "$out" "$rc" 0 'gmalloc +run.*stamp has no verdict'
out=$(run_fill r-test-1); rc=$?
check "13 a stamp without verdict is red" "$out" "$rc" 0 'RED +gmalloc: verdict=missing'

# 14 — an empty rules table cannot plan
printf '#name\tpaths\tartifact\tstamp\tminutes\tmode\tsync_paths\tneeds\tshow\tregress\n' > "$TMP/empty.tsv"
rm -f "$TMP/verdicts"/*
out=$(RULES="$TMP/empty.tsv" run_plan "$H3" "$H4"); rc=$?
check "14 empty rules table is refused" "$out" "$rc" 2 'no rules'

# 11 — the shipped example rules table parses and plans against the fixture repo
REAL_RULES="${ROTATION_CLOSE_RULES:-$PLUGIN_ROOT/templates/close_rules.tsv.example}"
if [ -f "$REAL_RULES" ]; then
  rm -f "$TMP/verdicts"/*
  mk_stamps "$H1"
  out=$(RULES="$REAL_RULES" run_plan "$H1" "$H2" --explain); rc=$?
  check "11 example rules table parses and plans against the fixture repo" "$out" "$rc" 0 \
    ' run' ' carry'
else
  echo "FAIL 11 no rules table at $REAL_RULES"; fail=$(( fail + 1 ))
fi

# 15 — no message table: the verdict in the kernel's English
mk_stamps "$H3"
rm -f "$TMP/verdicts"/*
: > "$TMP/events.jsonl"
gate_end "$H4"
out=$(run_plan "$H3" "$H4"); rc=$?
check "15 kernel default: English release word" "$out" "$rc" 0 'release: sync-then-next · finish, then open ·'
grep -q '^## 1 What this rotation changed' "$TMP/verdicts/r-test-1.verdict.md" && grep -q '^## 4 Release' "$TMP/verdicts/r-test-1.verdict.md" \
  && grep -q '^- gate events this round: 1 gate.end, the last commit has a gate; substrate files 1$' "$TMP/verdicts/r-test-1.verdict.md" \
  && { echo "ok   15m English verdict headings and gate line"; pass=$(( pass + 1 )); } \
  || { echo "FAIL 15m English verdict"; head -20 "$TMP/verdicts/r-test-1.verdict.md"; fail=$(( fail + 1 )); }

# 16 — a project's message table (tests/fixtures/messages.alt.conf, or ROTATION_MESSAGES_FIXTURE): the same
# verdict in that table's words, for the plan and the fill; the expected strings are read from the table itself
TABLE="${ROTATION_MESSAGES_FIXTURE:-$SCRIPT_DIR/fixtures/messages.alt.conf}"
if [ -f "$TABLE" ]; then
  tv() { sed -n "s/^$1=//p" "$TABLE"; }
  printf 'ROTATION_CONF_KERNEL=1\nROTATION_MESSAGES=%s\n' "$TABLE" > "$TMP/conf-msgs.conf"
  rm -f "$TMP/verdicts"/*
  out=$(CONF="$TMP/conf-msgs.conf" run_plan "$H3" "$H4" --explain); rc=$?
  check "16 message table: release word and decision words from the table" "$out" "$rc" 0 \
    "release: sync-then-next · $(tv form_sync_then_next) ·" "bench +$(tv decision_run) \($(tv mode_sync): " "sweep +$(tv decision_carry) — "
  grep -qF "$(tv h_changes)" "$TMP/verdicts/r-test-1.verdict.md" && grep -qF "$(tv h_release)" "$TMP/verdicts/r-test-1.verdict.md" \
    && ! grep -q '^## 4 Release' "$TMP/verdicts/r-test-1.verdict.md" \
    && { echo "ok   16m verdict headings from the table, none from the kernel"; pass=$(( pass + 1 )); } \
    || { echo "FAIL 16m verdict headings from the table"; grep '^## ' "$TMP/verdicts/r-test-1.verdict.md"; fail=$(( fail + 1 )); }
  out=$(CONF="$TMP/conf-msgs.conf" run_fill r-test-1); rc=$?
  check "16f fill under the table" "$out" "$rc" 0 'red=0'
  # bench was planned to run and its stamp is still at H3: the amber line, in the table's words (case 19)
  grep -qF "$(tv results_amber | sed 's/{items}.*//')" "$TMP/verdicts/r-test-1.verdict.md" && grep -qF "| sweep | $(tv status_pending) |" "$TMP/verdicts/r-test-1.verdict.md" \
    && grep -qF "| bench | $(tv status_pending) |" "$TMP/verdicts/r-test-1.verdict.md" && grep -qF "| $(tv flag_amber) status |" "$TMP/verdicts/r-test-1.verdict.md" \
    && { echo "ok   16r section 3 in the table's words"; pass=$(( pass + 1 )); } \
    || { echo "FAIL 16r section 3 wording"; sed -n '/results:begin/,/results:end/p' "$TMP/verdicts/r-test-1.verdict.md"; fail=$(( fail + 1 )); }
else
  echo "skip 16 no message table at $TABLE"
fi

# 17 — a table naming a key the kernel does not have is a configuration error
printf 'form_next=x\nno_such_key=y\n' > "$TMP/bad-msgs.conf"
printf 'ROTATION_CONF_KERNEL=1\nROTATION_MESSAGES=%s\n' "$TMP/bad-msgs.conf" > "$TMP/conf-badmsgs.conf"
rm -f "$TMP/verdicts"/*
out=$(CONF="$TMP/conf-badmsgs.conf" run_plan "$H3" "$H4"); rc=$?
check "17 unknown message key is refused" "$out" "$rc" 2 'not a message key: no_such_key=y'

# 18 — a check switched off in rotation.conf: the rules table gains a `lint` row (a count that may not grow),
# and ROTATION_CLOSE_CHECKS_OFF=lint drops it from the plan and the verdict; without the switch it runs
cp "$TMP/rules.tsv" "$TMP/rules-lint.tsv"
printf 'lint\tcrates/**\t-\tlint:lint_count\t3\tsync\t-\t-\ttotal,distinctLints\ttotal:up\n' >> "$TMP/rules-lint.tsv"
lint_stamp() {  # lint_stamp <sha> <total> [ranAt]: the lint stamp, verdict ok (the table judges the count)
  printf '{"tool":"lint_count","ranAt":"%s","headSha":"%s","headShaSource":"arg","verdict":"ok","total":%s,"distinctLints":4,"lints":{"a":1}}\n' \
    "${3:-2026-10-01T00:00:00Z}" "$1" "$2" > "$TMP/stamps/lint-latest.json"
}
printf 'ROTATION_CONF_KERNEL=1\n' > "$TMP/conf-on.conf"
printf 'ROTATION_CONF_KERNEL=1\nROTATION_CLOSE_CHECKS_OFF=lint\n' > "$TMP/conf-off.conf"
mk_stamps "$H1"
lint_stamp "$H1" 197
rm -f "$TMP/verdicts"/*
out=$(CONF="$TMP/conf-on.conf" RULES="$TMP/rules-lint.tsv" run_plan "$H1" "$H2" --explain); rc=$?
check "18 switch absent: the lint check runs on a crate change" "$out" "$rc" 0 \
  'run=\[release-build sweep gmalloc bench size lint\]' 'lint +run \(sync: rules table\)'
grep -q '^| lint |' "$TMP/verdicts/r-test-1.verdict.md" \
  && { echo "ok   18m verdict lists the lint row"; pass=$(( pass + 1 )); } \
  || { echo "FAIL 18m verdict lint row"; fail=$(( fail + 1 )); }
rm -f "$TMP/verdicts"/*
out=$(CONF="$TMP/conf-off.conf" RULES="$TMP/rules-lint.tsv" run_plan "$H1" "$H2" --explain); rc=$?
check "18o switch on (ROTATION_CLOSE_CHECKS_OFF=lint): the row is not planned" "$out" "$rc" 0 \
  'run=\[release-build sweep gmalloc bench size\]'
! grep -q '^| lint ' "$TMP/verdicts/r-test-1.verdict.md" && ! grep -q '"name": "lint"' "$TMP/verdicts/r-test-1.verdict.json" \
  && { echo "ok   18n a switched-off check is in neither verdict file"; pass=$(( pass + 1 )); } \
  || { echo "FAIL 18n switched-off check leaked into the verdict"; grep -n lint "$TMP/verdicts/r-test-1.verdict.md"; fail=$(( fail + 1 )); }
# fill under the switch absent: the count grew 197 → 198 → red; dropped to 190 → ok
rm -f "$TMP/verdicts"/*
: > "$TMP/events.jsonl"
gate_end "$H2"
mk_stamps "$H2"
printf '{"tool":"lint_count","ranAt":"2026-10-01T00:00:00Z","headSha":"%s","verdict":"ok","total":197,"distinctLints":4,"file":"x"}\n' "$H1" > "$TMP/stamps/stamps.jsonl"
lint_stamp "$H2" 198 2026-10-01T01:00:00Z
out=$(CONF="$TMP/conf-on.conf" RULES="$TMP/rules-lint.tsv" run_plan "$H1" "$H2"); rc=$?
check "18p plan for the fill (lint at HEAD, others at HEAD)" "$out" "$rc" 0 'run=\[\]'
out=$(CONF="$TMP/conf-on.conf" RULES="$TMP/rules-lint.tsv" run_fill r-test-1); rc=$?
check "18r 197 → 198: the count grew, red" "$out" "$rc" 0 'red=1' 'RED +lint: total 197 → 198'
lint_stamp "$H2" 190 2026-10-01T01:00:00Z
out=$(CONF="$TMP/conf-on.conf" RULES="$TMP/rules-lint.tsv" run_fill r-test-1); rc=$?
check "18g 197 → 190: the count fell, ok" "$out" "$rc" 0 'red=0' 'amber=0'
grep -qE '^\| lint \| ran \| [0-9a-f]{9} \| total=190\(-7\) distinctLints=4\(\+0\) \| — \| ok \|' "$TMP/verdicts/r-test-1.verdict.md" \
  && { echo "ok   18t section 3 shows the count with its delta"; pass=$(( pass + 1 )); } \
  || { echo "FAIL 18t lint row in section 3"; grep '^| lint' "$TMP/verdicts/r-test-1.verdict.md"; fail=$(( fail + 1 )); }
# the switch naming a check the table does not have is a configuration error
printf 'ROTATION_CONF_KERNEL=1\nROTATION_CLOSE_CHECKS_OFF=nosuch\n' > "$TMP/conf-badoff.conf"
rm -f "$TMP/verdicts"/*
out=$(CONF="$TMP/conf-badoff.conf" RULES="$TMP/rules-lint.tsv" run_plan "$H1" "$H2"); rc=$?
check "18x switch naming an unknown check is refused" "$out" "$rc" 2 'ROTATION_CLOSE_CHECKS_OFF names a check the table does not have: nosuch'

# 19 — fill: a check the plan decided to run whose stamp never reached HEAD is at least amber. H3..H4 changed the
# bench harness: bench runs, everything else carries. With the stamps left where they were, bench is "not at
# HEAD" and amber; sweep (planned carry, stamp also old) is not — the plan never asked for it
mk_stamps "$H3"
rm -f "$TMP/verdicts"/*
: > "$TMP/events.jsonl"
gate_end "$H4"
out=$(run_plan "$H3" "$H4"); rc=$?
check "19p bench runs, the rest carries" "$out" "$rc" 0 'run=\[release-build bench\]'
out=$(run_fill r-test-1); rc=$?
check "19 a planned run whose stamp is not at HEAD is amber, not ok" "$out" "$rc" 0 'red=0 amber=1' \
  "amber +bench: planned to run, stamp not at HEAD \(sha ${H3:0:9}\)"
grep -qE '^\| bench \| not at HEAD \| [0-9a-f]{9} \| .* \| amber status \|' "$TMP/verdicts/r-test-1.verdict.md" \
  && grep -qE '^\| sweep \| not at HEAD \| [0-9a-f]{9} \| .* \| ok \|' "$TMP/verdicts/r-test-1.verdict.md" \
  && { echo "ok   19m section 3: bench amber status, sweep (planned carry) ok"; pass=$(( pass + 1 )); } \
  || { echo "FAIL 19m section 3 rows"; grep -E '^\| (bench|sweep) ' "$TMP/verdicts/r-test-1.verdict.md"; fail=$(( fail + 1 )); }
# the stamp missing altogether for a planned run is amber the same way
rm -f "$TMP/stamps/bench-latest.json"
out=$(run_fill r-test-1); rc=$?
check "19n a planned run with no stamp at all is amber" "$out" "$rc" 0 'amber=1' 'amber +bench: planned to run, stamp no stamp'
# once the segment wrote the stamp at HEAD, the amber is gone
printf '{"tool":"bench","ranAt":"2026-10-01T02:00:00Z","headSha":"%s","headShaSource":"arg","verdict":"ok","medianVsBunAot":0.5}\n' "$H4" > "$TMP/stamps/bench-latest.json"
out=$(run_fill r-test-1); rc=$?
check "19r the stamp at HEAD clears it" "$out" "$rc" 0 'red=0 amber=0'

# 20 — fill: the baseline is the round's start, never a mid-round stamp. Round B0..E2 with a mid commit M1:
# history holds sweep at B0 (pass 100) and a mid-round sweep at M1 (pass 120, a lighter-load reading); the
# final stamp at E2 reads 100 again. Against the mid-round stamp that is a regression; against the round's
# start it is not — and the start is the baseline. 90 at the end is a regression against 100, not 120.
B0="$(git -C "$REPO" rev-parse HEAD)"
commit crates/alpha-core/src/lib.rs 'perf: mid-round'
M1="$(git -C "$REPO" rev-parse HEAD)"
commit docs/a.md 'docs: end of round'
E2="$(git -C "$REPO" rev-parse HEAD)"
mk_stamps "$E2"
rm -f "$TMP/verdicts"/*
: > "$TMP/events.jsonl"
gate_end "$E2"
printf '{"tool":"sweep","ranAt":"2026-10-01T00:00:00Z","headSha":"%s","verdict":"ok","harnessError":0,"pass":100,"passTotal":120,"file":"x"}\n' "$B0" > "$TMP/stamps/stamps.jsonl"
printf '{"tool":"sweep","ranAt":"2026-10-01T01:00:00Z","headSha":"%s","verdict":"ok","harnessError":0,"pass":120,"passTotal":140,"file":"x"}\n' "$M1" >> "$TMP/stamps/stamps.jsonl"
printf '{"tool":"sweep","ranAt":"2026-10-01T02:00:00Z","headSha":"%s","verdict":"ok","harnessError":0,"pass":100,"passTotal":120}\n' "$E2" > "$TMP/stamps/sweep-latest.json"
out=$(run_plan "$B0" "$E2"); rc=$?
check "20p plan over the round" "$out" "$rc" 0 'gate: substrateFiles=1 gateEnds=1 ok'
out=$(run_fill r-test-1); rc=$?
check "20 end equal to the round's start is not red, whatever a mid-round stamp read" "$out" "$rc" 0 'red=0 amber=0'
prev_sha=$(python3 -c 'import json,sys; v=json.load(open(sys.argv[1])); print(next(c["result"]["previousSha"] for c in v["checks"] if c["name"]=="sweep"))' "$TMP/verdicts/r-test-1.verdict.json")
[ "$prev_sha" = "$B0" ] && { echo "ok   20b the sweep baseline is the round's start, not the mid-round stamp"; pass=$(( pass + 1 )); } \
  || { echo "FAIL 20b baseline sha: $prev_sha (want $B0, mid $M1)"; fail=$(( fail + 1 )); }
grep -qF "baseline sha ${B0:0:9}" "$TMP/verdicts/r-test-1.verdict.md" \
  && { echo "ok   20m section 3 header names the baseline sha"; pass=$(( pass + 1 )); } \
  || { echo "FAIL 20m section 3 header"; grep -n 'Filled' "$TMP/verdicts/r-test-1.verdict.md"; fail=$(( fail + 1 )); }
printf '{"tool":"sweep","ranAt":"2026-10-01T02:00:00Z","headSha":"%s","verdict":"ok","harnessError":0,"pass":90,"passTotal":120}\n' "$E2" > "$TMP/stamps/sweep-latest.json"
out=$(run_fill r-test-1); rc=$?
check "20r end below the round's start is red against the start's reading" "$out" "$rc" 0 'red=1' 'RED +sweep: pass 100 → 90'
# only a mid-round stamp in the history: nothing at or before the start to judge against, no regression line
printf '{"tool":"sweep","ranAt":"2026-10-01T01:00:00Z","headSha":"%s","verdict":"ok","harnessError":0,"pass":120,"passTotal":140,"file":"x"}\n' "$M1" > "$TMP/stamps/stamps.jsonl"
out=$(run_fill r-test-1); rc=$?
check "20n a history with only mid-round stamps gives no baseline and no red" "$out" "$rc" 0 'red=0 amber=0'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
