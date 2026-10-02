#!/usr/bin/env bash
#
# rotation kernel — one whole round on the adapter command contract, end to end.
#
# A throwaway repository, a throwaway state directory, a project.sh whose four
# commands (gate / pre-flight / close segment / bench) are a few lines of bash
# each — no runner and no host: every job is local and its log a local file —
# and a copy of the kernel with its reaper stubbed (kill_stray_shells.sh walks
# the real process tree of whatever session runs this test; it is the one piece
# that cannot be pointed at a fixture). Everything else is the kernel as
# installed. No project name, adapter directory, comparator or runner is read.
#
# The round, in the order the protocol runs it:
#   agent_log.sh start … rotation      executor registered (agent.start, rotation.start)
#   adapter_run.sh preflight -q        PREFLIGHT PASS line, preflight.end
#   adapter_run.sh gate <HEAD>         `N pass / F fail / S skip` line, remote.start / gate.end / remote.end
#   close_plan.sh <prev> <HEAD>        the verdict: coverage ok, the sweep runs
#   adapter_run.sh close-segment …     remote.start / remote.end (kind close.plan), the sweep stamp at HEAD
#   close_verdict_fill.sh <rid>        red=0
#   report_save.sh <rid> <report>      the report filed beside the verdict; a second one refused
#   adapter_run.sh bench <HEAD> A      remote.start / remote.end (kind bench.A)
#   handoff, agent_log.sh end          the trigger section with the gate triple and the sweep line
#   trigger.sh self                    TRIG-1..8 PASS, a new rotations.jsonl row, the handoff archived
# Then the same round with a gate that prints its line but records no gate.end:
#   adapter_run.sh refuses the claim (exit 64), the plan says MISSING, fill is
#   red, trigger.sh self is blocked by TRIG-8 (on in this conf) and writes no row.
#
# exit: 0 every case passed · 1 otherwise

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KBIN="$(cd "$SCRIPT_DIR/../bin" && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/     | /'; }
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$3] got [$2]"; fi; }
expect_has() { if printf '%s\n' "$2" | grep -qE -- "$3"; then ok "$1"; else bad "$1 (wanted /$3/)" "$2"; fi; }
expect_not() { if printf '%s\n' "$2" | grep -qE -- "$3"; then bad "$1 (/$3/ present)" "$2"; else ok "$1"; fi; }
kinds() { python3 -c 'import json,sys; print(" ".join(json.loads(l)["kind"] for l in open(sys.argv[1]) if l.strip()))' "$1"; }

# the kernel under test: a copy with the reaper stubbed
KERNEL="$TMP/kernel"
mkdir -p "$KERNEL"
cp "$KBIN"/*.sh "$KBIN"/*.py "$KERNEL/"
printf '#!/bin/bash\necho "CLEAN: reaper stubbed for the self-test"\n' > "$KERNEL/kill_stray_shells.sh"
chmod +x "$KERNEL"/*.sh "$KERNEL"/*.py

# ── one round's fixture ─────────────────────────────────────────────────
# setup_round <name>: a repository with a substrate crate and three commits on it since the round
# opened, the round's row, the stamps as they stood when it opened, the conf (TRIG-8 on, floors low
# enough for three commits), the rules table (one check, sweep, on crates/**), and the four commands.
setup_round() {
  R="$TMP/$1"; REPO="$R/repo"; STATE="$R/state"; STAMPS="$R/stamps"; VERDICTS="$R/verdicts"; LOGS="$R/logs"; BIN="$R/bin"
  mkdir -p "$REPO/.claude" "$REPO/crates/x/src" "$STATE" "$STAMPS" "$VERDICTS" "$LOGS" "$BIN"
  g() { git -C "$REPO" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
  g init -q -b develop
  printf '.claude/\n' > "$REPO/.gitignore"
  echo a > "$REPO/crates/x/src/lib.rs"
  g add -A && g commit -q -m 'chore: seed'
  C0=$(g rev-parse HEAD)
  local i
  for i in 1 2 3; do
    echo "$i" >> "$REPO/crates/x/src/lib.rs"
    g add -A && g commit -q -m "perf: change $i"
  done
  HEAD=$(g rev-parse HEAD)
  printf '{"rotationId":"r-e2e-1","at":"x","ts":%s,"project":"%s","trigger":"self","prevHead":"%s"}\n' \
    "$(( $(date +%s) - 3600 ))" "$(basename "$REPO")" "${C0:0:9}" > "$STATE/rotations.jsonl"
  printf '{"tool":"sweep","ranAt":"2026-01-01T00:00:00Z","headSha":"%s","headShaSource":"arg","verdict":"ok","harnessError":0,"pass":100,"passTotal":120}\n' "$C0" > "$STAMPS/sweep-latest.json"
  cp "$STAMPS/sweep-latest.json" "$STAMPS/stamps.jsonl"
  printf '#name\tpaths\tartifact\tstamp\tminutes\tmode\tsync_paths\tneeds\tshow\tregress\nsweep\tcrates/**\t-\tsweep\t1\tsync\t-\t-\tpass,passTotal\tpass:down\n' > "$R/rules.tsv"
  cat > "$R/rotation.conf" <<EOF
ROTATION_CONF_KERNEL=1
ROTATION_TRIG1_MIN_COMMITS=3
ROTATION_TRIG1_MIN_CLOSED=1
ROTATION_TRIG2_MIN_WALL_SEC=1800
ROTATION_TRIG2_MAX_WALL_SEC=18000
ROTATION_TRIG5_SAME_AXIS_MAX=8
ROTATION_TRIG5_BENCH_MAX_AGE_DAYS=14
ROTATION_TRIG8_GATE_COVERAGE=on
ROTATION_AXES=A,B
ROTATION_STAMPS=sweep
ROTATION_SWEEP_STAMP=sweep
ROTATION_CLOSE_RULES=$R/rules.tsv
EOF
  # the project's adapter: directories and the four commands; no probe and no remote grep (no runner)
  cat > "$R/project.sh" <<EOF
export ROTATION_STAMP_DIR="$STAMPS"
export ROTATION_VERDICT_DIR="$VERDICTS"
export ROTATION_SWEEP_LINE_CMD="$BIN/sweep_line.sh"
export ROTATION_GATE_CMD="$BIN/gate.sh"
export ROTATION_PREFLIGHT_CMD="$BIN/preflight.sh"
export ROTATION_CLOSE_SEGMENT_CMD="$BIN/segment.sh"
export ROTATION_BENCH_CMD="$BIN/bench.sh"
EOF
  cat > "$BIN/sweep_line.sh" <<'EOF'
#!/bin/sh
# the project's sweep line: the stamp's counters; exit 2 when there is no stamp
f="${ROTATION_SWEEP_JSON:-${HARDEV_SWEEP_JSON:-}}"
[ -f "$f" ] || exit 2
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("sweep: head=%s pass=%s passTotal=%s harnessError=%s" % (d["headSha"], d["pass"], d["passTotal"], d["harnessError"]))' "$f"
EOF
  cat > "$BIN/gate.sh" <<EOF
#!/bin/bash
# a gate with no runner: start on record, the summary line into a local log, the end on record
# (E2E_GATE_NO_END=1: the gate ran, the executor saw the line, nothing recorded it — the hand-written ssh)
set -u
sha=\$1; log="$LOGS/gate-\$sha.log"
"$KERNEL/event.sh" remote.start remote.kind=gate "remote.sha=\$sha" "remote.log=\$log" 'remote.marker=[0-9]+ pass / [0-9]+ fail / [0-9]+ skip' >/dev/null
echo "12 pass / 0 fail / 1 skip" > "\$log"
if [ "\${E2E_GATE_NO_END:-0}" != 1 ]; then
  "$KERNEL/event.sh" gate.end "gate=raw:{\"sha\":\"\$sha\",\"pass\":12,\"fail\":0,\"skip\":1,\"log\":\"\$log\",\"host\":null}" >/dev/null
  "$KERNEL/event.sh" remote.end remote.kind=gate "remote.sha=\$sha" "remote.log=\$log" remote.status=ok >/dev/null
fi
echo "gate \$sha: \$(cat "\$log") · log=\$log"
EOF
  cat > "$BIN/preflight.sh" <<EOF
#!/bin/bash
set -u
quick=false; [ "\${1:-}" = -q ] && quick=true
head=\$(git -C "$REPO" rev-parse HEAD)
"$KERNEL/event.sh" preflight.end preflight.result=pass "preflight.quick=raw:\$quick" "preflight.parent=\$head" "preflight.sha=\$head" 'preflight.files=raw:[]' 'preflight.reasons=raw:[]' >/dev/null
echo "PREFLIGHT PASS"
EOF
  cat > "$BIN/segment.sh" <<EOF
#!/bin/bash
# a close segment with no runner: the sweep stamp at this head and its history row, between start and end on record
set -u
head=\$1; seg=\$2; log="$LOGS/rc-seg-\$head-\$seg.log"
"$KERNEL/event.sh" remote.start "remote.kind=close.\$seg" "remote.sha=\$head" "remote.log=\$log" "remote.marker=^DONE segment=\$seg head=\$head " >/dev/null
printf '{"tool":"sweep","ranAt":"%s","headSha":"%s","headShaSource":"arg","verdict":"ok","harnessError":0,"pass":101,"passTotal":121}\n' "\$(date -u +%FT%TZ)" "\$head" > "$STAMPS/sweep-latest.json"
cat "$STAMPS/sweep-latest.json" >> "$STAMPS/stamps.jsonl"
echo "DONE segment=\$seg head=\$head rc=0" > "\$log"
"$KERNEL/event.sh" remote.end "remote.kind=close.\$seg" "remote.sha=\$head" "remote.log=\$log" remote.status=ok remote.rc=int:0 >/dev/null
cat "\$log"
EOF
  cat > "$BIN/bench.sh" <<EOF
#!/bin/bash
set -u
sha=\$1; seg="\${2:-A}"; log="$LOGS/bench-\$sha-\$seg.log"
"$KERNEL/event.sh" remote.start "remote.kind=bench.\$seg" "remote.sha=\$sha" "remote.log=\$log" 'remote.marker=^BENCH-SEGMENT-DONE rc=' >/dev/null
echo "BENCH-SEGMENT-DONE rc=0" > "\$log"
"$KERNEL/event.sh" remote.end "remote.kind=bench.\$seg" "remote.sha=\$sha" "remote.log=\$log" remote.status=ok remote.rc=int:0 >/dev/null
echo "bench segment \$seg: rc=0 log=\$log"
EOF
  chmod +x "$BIN"/*.sh
  EV="$STATE/events.jsonl"
}
# every kernel call points at this round's fixture; the four commands inherit the same environment
kenv() { env ROTATION_PROJECT_DIR="$REPO" ROTATION_CONF="$R/rotation.conf" ROTATION_PROJECT_SH="$R/project.sh" ROTATION_STATE_DIR="$STATE" "$@"; }

# ── the round ───────────────────────────────────────────────────────────
# round <name> <gate-records-end 1|0>
round() {
  local name=$1 recorded=$2 out rc tag
  tag="[$name]"
  setup_round "$name"

  out=$(ROTATION_AGENT_ID=ag-e2e kenv "$KERNEL/agent_log.sh" start rot-e2e rotation m "the round" 2>&1); rc=$?
  expect_eq "$tag executor registered" "$rc" 0
  expect_has "$tag agent.start and rotation.start on record" "$(kinds "$EV")" '^agent.start rotation.start$'
  [ -f "$STATE/manager.active" ] && ok "$tag manager.active written" || bad "$tag manager.active missing"

  out=$(kenv "$KERNEL/adapter_run.sh" preflight -q 2>&1); rc=$?
  expect_eq "$tag pre-flight through adapter_run exits 0" "$rc" 0
  expect_has "$tag pre-flight terminal line" "$out" '^PREFLIGHT PASS$'
  expect_has "$tag preflight.end on record" "$(kinds "$EV")" 'preflight.end$'

  out=$(E2E_GATE_NO_END=$(( 1 - recorded )) kenv "$KERNEL/adapter_run.sh" gate "$HEAD" 2>&1); rc=$?
  if [ "$recorded" -eq 1 ]; then
    expect_eq "$tag gate through adapter_run exits 0" "$rc" 0
    expect_has "$tag gate terminal line" "$out" '12 pass / 0 fail / 1 skip'
    expect_has "$tag remote.start gate.end remote.end on record" "$(kinds "$EV")" 'remote.start gate.end remote.end$'
    expect_has "$tag gate.end names the sha" "$(tail -2 "$EV" | head -1)" "\"sha\": ?\"$HEAD\""
  else
    expect_eq "$tag gate without gate.end: adapter_run refuses the claim (64)" "$rc" 64
    expect_has "$tag adapter_run names what is missing" "$out" 'without its record: event gate.end'
    expect_not "$tag no gate.end on record" "$(kinds "$EV")" 'gate.end'
  fi

  out=$(kenv "$KERNEL/close_plan.sh" "$C0" "$HEAD" 2>&1); rc=$?
  expect_eq "$tag close_plan exits 0" "$rc" 0
  expect_has "$tag the sweep runs (crates/** changed)" "$out" 'run=\[sweep\]'
  if [ "$recorded" -eq 1 ]; then
    expect_has "$tag plan: gate coverage ok" "$out" 'gate: substrateFiles=1 gateEnds=1 ok'
  else
    expect_has "$tag plan: gate coverage MISSING" "$out" 'gate: substrateFiles=1 gateEnds=0 MISSING'
    expect_has "$tag verdict §1 says the gate events are missing" "$(cat "$VERDICTS/r-e2e-1.verdict.md")" 'gate events this round: \*\*missing\*\*'
  fi
  expect_has "$tag close.plan on record" "$(kinds "$EV")" 'close.plan$'

  out=$(kenv "$KERNEL/adapter_run.sh" close-segment "$HEAD" plan "$VERDICTS/r-e2e-1.verdict.json" 2>&1); rc=$?
  expect_eq "$tag close segment through adapter_run exits 0" "$rc" 0
  expect_has "$tag segment terminal line" "$out" "^DONE segment=plan head=$HEAD rc=0$"
  expect_has "$tag remote.start / remote.end of the segment on record" "$(kinds "$EV")" 'remote.start remote.end$'
  expect_has "$tag the segment left the sweep stamp at HEAD" "$(cat "$STAMPS/sweep-latest.json")" "\"headSha\": ?\"$HEAD\""

  out=$(kenv "$KERNEL/close_verdict_fill.sh" r-e2e-1 2>&1); rc=$?
  expect_eq "$tag close_verdict_fill exits 0" "$rc" 0

  if [ "$recorded" -eq 1 ]; then
    expect_has "$tag fill: nothing red" "$out" 'red=0'
  else
    expect_has "$tag fill: the missing gate.end is red" "$out" 'red=1'
    expect_has "$tag fill: the red line names the gate command contract" "$out" 'RED +gate: .*ROTATION_GATE_CMD'
  fi

  # the executor's report is filed under the rotation it closed, beside the verdict, once
  printf 'ROTATION-CLOSED rid=r-e2e-1 head=%s\n\nreport body\n' "$HEAD" > "$R/report.md"
  out=$(kenv "$KERNEL/report_save.sh" r-e2e-1 "$R/report.md" 2>&1); rc=$?
  expect_eq "$tag report_save.sh files the report (exit 0)" "$rc" 0
  expect_eq "$tag the report sits beside the verdict, verbatim" "$(cat "$VERDICTS/r-e2e-1.md" 2>/dev/null)" "$(cat "$R/report.md")"
  expect_has "$tag report.saved on record" "$(kinds "$EV")" 'report.saved$'
  out=$(kenv "$KERNEL/report_save.sh" r-e2e-1 "$R/report.md" 2>&1); rc=$?
  expect_eq "$tag a second report for the same rotation is refused (exit 1)" "$rc" 1
  expect_has "$tag the refusal names the file" "$out" "report_save: $VERDICTS/r-e2e-1.md exists"

  out=$(kenv "$KERNEL/adapter_run.sh" bench "$HEAD" A 2>&1); rc=$?
  expect_eq "$tag bench through adapter_run exits 0" "$rc" 0
  expect_has "$tag bench segment on record" "$(tail -1 "$EV")" '"kind": ?"bench.A"'

  # the handoff: the triple as the gate printed it, the sweep line as the sweep command renders the stamp
  local sweep_line
  sweep_line=$(ROTATION_SWEEP_JSON="$STAMPS/sweep-latest.json" sh "$BIN/sweep_line.sh")
  printf '# handoff\n\nHEAD %s\n\n## rotate-trigger\n\naxis: A\nclosed: %s the three changes\ngate: 12/0/1\n%s\n' "$HEAD" "${HEAD:0:9}" "$sweep_line" > "$REPO/.claude/handoff.md"
  kenv "$KERNEL/agent_log.sh" end rot-e2e rotation m >/dev/null 2>&1

  out=$(kenv "$KERNEL/trigger.sh" self 2>&1); rc=$?
  if [ "$recorded" -eq 1 ]; then
    expect_eq "$tag trigger.sh self releases (exit 0)" "$rc" 0
    expect_has "$tag TRIG-8 PASS on the recorded gate" "$out" 'TRIG-8 PASS substrateFiles=1 gateEnds=1 atHead=yes missing=no \(round r-e2e-1\)'
    expect_not "$tag no TRIG FAIL" "$out" 'TRIG-[0-9] FAIL'
    expect_has "$tag the rotation is recorded" "$out" '^rotation r-[0-9]+-[0-9a-f]{4} triggered \(self\)'
    expect_eq "$tag rotations.jsonl grew by one row" "$(grep -c . "$STATE/rotations.jsonl")" 2
    expect_eq "$tag the new row carries the TRIG-8 switch and opens at HEAD" \
      "$(tail -1 "$STATE/rotations.jsonl" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["thresholds"]["trig8GateCoverage"], sys.argv[1].startswith(d["prevHead"]))' "$HEAD")" "on True"
    expect_has "$tag trigger.result PASS on record" "$(grep '"kind":"trigger.result"' "$EV" | tail -1)" '"result": ?"PASS"'
    [ -f "$STATE/handoff/$(tail -1 "$STATE/rotations.jsonl" | python3 -c 'import json,sys; print(json.load(sys.stdin)["rotationId"])').md" ] \
      && ok "$tag handoff archived under the new id" || bad "$tag handoff not archived" "$(ls -R "$STATE")"
    out=$(kenv "$KERNEL/recover.sh" 2>&1); rc=$?
    expect_eq "$tag recover.sh after the close: IDLE (local jobs all ended, no probe configured)" "$(printf '%s\n' "$out" | tail -1)" "IDLE"
    expect_has "$tag recover.sh says no probe is configured" "$out" 'remote probe: ROTATION_REMOTE_PROBE_CMD not set'
  else
    expect_eq "$tag trigger.sh self is blocked (exit 1)" "$rc" 1
    expect_has "$tag TRIG-8 FAIL names the missing gate.end" "$out" 'TRIG-8 FAIL substrateFiles=1 gateEnds=0 atHead=no missing=yes — .*no gate.end event belongs to round r-e2e-1; run the gate through ROTATION_GATE_CMD'
    expect_has "$tag TRIG-FAILED is TRIG-8 alone" "$out" '^TRIG-FAILED: TRIG-8$'
    expect_eq "$tag rotations.jsonl did not grow" "$(grep -c . "$STATE/rotations.jsonl")" 1
    expect_has "$tag trigger.result FAIL on record with TRIG-8" "$(grep '"kind":"trigger.result"' "$EV" | tail -1)" '"failed": ?\["TRIG-8"\]'
  fi
}

round recorded 1
round unrecorded 0

echo
echo "e2e_self_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
