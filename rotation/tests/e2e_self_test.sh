#!/usr/bin/env bash
#
# rotation kernel — one whole round on the adapter command contract, end to end.
#
# A throwaway repository, a throwaway state directory, a project.sh whose four
# commands (gate / pre-flight / close segment / bench) are a few lines of bash
# each — no runner and no host: every job is local and its log a local file —
# and a copy of the kernel with its reaper stubbed (kill_stray_shells.sh ends
# real processes registered in the real session that runs this test; it is the
# one piece that cannot be pointed at a fixture). Everything else is the kernel as
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
# After the recorded round the Stop hook runs from a subdirectory with the intent
# pending: a dirty tree keeps the intent (INV-2 red), a clean one consumes it.
# Then a third round is interrupted in every way the recovery tools know, with the
# real scripts writing the events (the clock is the scripts' own; thresholds are
# lowered through --stale and ROTATION_WAKE_AFTER, never by waiting them out):
#   session lost       recover.sh from the registering session → RESUME <id>; from another
#                      session → RESPAWN …(id,mismatch); without a session id → (id,no-session)
#   executor silent    registered and never wrote again → watchdog STALE (11) once --stale passed
#   remote job lost    remote.start with no remote.end: marker in the local log → the page offers
#                      the command that records the end (and running it closes the job); no
#                      marker → not-seen, nothing offered
#   WAKE               executor.waiting on a worker whose agent.end arrived → WAKE (10); no waiting
#                      but a remote.end followed by silence for ROTATION_WAKE_AFTER → WAKE
#   QUOTA              quota.hit whose reset passed and nothing after → QUOTA (12); manager.resume
#                      answers it
#   MULTI-EXECUTOR     a second running executor → exit 15; ending it clears the flag
#   FOREIGN-COMMIT     marker present, executor ended, a commit on the main tree after → exit 14
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
ROTATION_WAKE_AFTER=${E2E_WAKE_AFTER:-300}
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
# (E2E_SEG_HANG=1: the session died right after the start — no log, no end;
#  E2E_SEG_NO_END=1: the job finished and wrote its terminal line, nobody recorded the end)
set -u
head=\$1; seg=\$2; log="$LOGS/rc-seg-\$head-\$seg.log"
"$KERNEL/event.sh" remote.start "remote.kind=close.\$seg" "remote.sha=\$head" "remote.log=\$log" "remote.marker=^DONE segment=\$seg head=\$head " >/dev/null
[ "\${E2E_SEG_HANG:-0}" = 1 ] && exit 0
printf '{"tool":"sweep","ranAt":"%s","headSha":"%s","headShaSource":"arg","verdict":"ok","harnessError":0,"pass":101,"passTotal":121}\n' "\$(date -u +%FT%TZ)" "\$head" > "$STAMPS/sweep-latest.json"
cat "$STAMPS/sweep-latest.json" >> "$STAMPS/stamps.jsonl"
echo "DONE segment=\$seg head=\$head rc=0" > "\$log"
if [ "\${E2E_SEG_NO_END:-0}" != 1 ]; then
  "$KERNEL/event.sh" remote.end "remote.kind=close.\$seg" "remote.sha=\$head" "remote.log=\$log" remote.status=ok remote.rc=int:0 >/dev/null
fi
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
# the same as the session whose id is $1 (empty = no session id, as outside Claude Code)
senv() { local s=$1; shift; kenv env CLAUDE_CODE_SESSION_ID="$s" "$@"; }
# a hook as Claude Code runs it: in the session's cwd — a subdirectory of the repository, which is also what
# CLAUDE_PROJECT_DIR holds — with no ROTATION_PROJECT_DIR, so the root has to come from git
henv() { ( cd "$REPO/crates/x" && env CLAUDE_PROJECT_DIR="$REPO/crates/x" ROTATION_CONF="$R/rotation.conf" ROTATION_PROJECT_SH="$R/project.sh" ROTATION_STATE_DIR="$STATE" "$@" ); }
stop_payload() { printf '{"session_id":"s1","hook_event_name":"Stop","stop_hook_active":false}'; }

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

    # the Stop hook at the next turn ends: the intent trigger.sh left is consumed only when INV-1..5 are green
    local rid
    rid=$(cat "$REPO/.claude/autorun-intent" 2>/dev/null)
    expect_has "$tag trigger.sh left the intent with the new id" "$rid" '^r-[0-9]+-[0-9a-f]{4}$'
    echo stray > "$REPO/crates/x/stray.txt"
    out=$(stop_payload | henv bash "$KERNEL/stop_hook.sh" 2>&1); rc=$?
    expect_eq "$tag Stop hook with the intent pending and a dirty tree: exit 0" "$rc" 0
    expect_has "$tag red: INV-2 names the dirty tree" "$out" '^INV-2 FAIL tree dirty: 1 entry$'
    expect_has "$tag red: the intent is kept for the next turn end" "$out" "^stop_hook: rotation $rid blocked by INV check · intent kept$"
    [ -f "$REPO/.claude/autorun-intent" ] && ok "$tag red: the intent file is still there" || bad "$tag red: the intent file is gone"
    rm "$REPO/crates/x/stray.txt"
    out=$(stop_payload | henv bash "$KERNEL/stop_hook.sh" 2>&1); rc=$?
    expect_eq "$tag Stop hook with a clean tree: exit 0" "$rc" 0
    expect_has "$tag green: INV-3 compares the handoff triple with the row trigger.sh wrote" "$out" '^INV-3 PASS current 12/0/1 >= prior 12/0/1$'
    expect_has "$tag green: the intent is consumed" "$out" "^stop_hook: rotation $rid green · INV-1..5 pass · intent consumed$"
    [ -e "$REPO/.claude/autorun-intent" ] && bad "$tag green: the intent file remains" || ok "$tag green: the intent file is gone"
    [ -e "$REPO/crates/x/.claude" ] && bad "$tag the hook took CLAUDE_PROJECT_DIR for the root" || ok "$tag the hook ran from a subdirectory and used the git top level"
  else
    expect_eq "$tag trigger.sh self is blocked (exit 1)" "$rc" 1
    expect_has "$tag TRIG-8 FAIL names the missing gate.end" "$out" 'TRIG-8 FAIL substrateFiles=1 gateEnds=0 atHead=no missing=yes — .*no gate.end event belongs to round r-e2e-1; run the gate through ROTATION_GATE_CMD'
    expect_has "$tag TRIG-FAILED is TRIG-8 alone" "$out" '^TRIG-FAILED: TRIG-8$'
    expect_eq "$tag rotations.jsonl did not grow" "$(grep -c . "$STATE/rotations.jsonl")" 1
    expect_has "$tag trigger.result FAIL on record with TRIG-8" "$(grep '"kind":"trigger.result"' "$EV" | tail -1)" '"failed": ?\["TRIG-8"\]'
  fi
}


# ── the interrupted round ───────────────────────────────────────────────
# The fixture's commits are a day old, so only what this section does counts as activity and nothing on
# the main tree answers a remote.end by accident. ROTATION_WAKE_AFTER is 2 s here (conf-only key).
interruption() {
  local tag='[interrupted]' out rc cmd seg_log
  E2E_WAKE_AFTER=2 GIT_COMMITTER_DATE="$(( $(date +%s) - 86400 )) +0000" setup_round interrupted
  w() { senv sess-mgr "$KERNEL/watchdog.sh" --once "$@"; }
  page() { senv "$1" "$KERNEL/recover.sh" 2>&1; }

  # session lost: the executor can be continued only from the session that registered it
  out=$(ROTATION_AGENT_ID=ag-x senv sess-mgr "$KERNEL/agent_log.sh" start rot-x rotation m "the round" 2>&1); rc=$?
  expect_eq "$tag executor registered from session sess-mgr" "$rc" 0
  expect_has "$tag manager.active carries the executor id and the session" "$(cat "$STATE/manager.active")" ' id=ag-x since=.* session=sess-mgr$'
  out=$(page sess-mgr)
  expect_eq "$tag recover.sh in the registering session: RESUME by id" "$(tail -1 <<<"$out")" "RESUME ag-x"
  expect_has "$tag page: the session ids match" "$out" '^executor session: registered=sess-mgr current=sess-mgr → match$'
  out=$(page sess-new)
  expect_eq "$tag recover.sh in another session: RESPAWN, the executor is a leftover" "$(tail -1 <<<"$out")" "RESPAWN executor leftover=executor:rot-x(ag-x,mismatch)"
  expect_has "$tag page: the mismatch" "$out" '^executor session: registered=sess-mgr current=sess-new → mismatch$'
  expect_eq "$tag recover.sh without a session id: RESPAWN, no-session" "$(page '' | tail -1)" "RESPAWN executor leftover=executor:rot-x(ag-x,no-session)"
  expect_eq "$tag --json carries the same action" \
    "$(senv sess-new "$KERNEL/recover.sh" --json | python3 -c 'import json,sys; s=json.load(sys.stdin); print(s["action"], s["session"]["verdict"])')" \
    "RESPAWN executor leftover=executor:rot-x(ag-x,mismatch) mismatch"

  # executor silent: registered, then nothing — STALE once --stale seconds passed (1800 by default; 2 here)
  out=$(w); rc=$?
  expect_eq "$tag watchdog right after the registration: OK" "$rc" 0
  expect_has "$tag OK line" "$out" '^OK '
  sleep 2
  out=$(w --stale 2); rc=$?
  expect_eq "$tag no event since the registration for --stale seconds: STALE (11)" "$rc" 11
  expect_has "$tag STALE line: the last sign of life is the registration" "$out" '^STALE no event and no commit for [0-9]+ s \(last: event rotation.start at .*\) · agent=ag-x$'

  # remote job lost: a segment whose end nobody recorded
  seg_log="$LOGS/rc-seg-$HEAD-plan.log"
  out=$(E2E_SEG_NO_END=1 kenv "$KERNEL/adapter_run.sh" close-segment "$HEAD" plan "$VERDICTS/none.json" 2>&1); rc=$?
  expect_eq "$tag a segment that ran without recording its end: adapter_run refuses the claim (64)" "$rc" 64
  expect_has "$tag adapter_run names the missing event" "$out" 'without its record: event remote.end'
  out=$(page sess-new)
  expect_has "$tag page: the job is open, local (no host), its marker already in the log" "$out" "^  kind=close.plan sha=$HEAD log=$seg_log host=— started=.* terminal=seen$"
  expect_has "$tag page: the command that records the end" "$out" "^    collect: bash $KERNEL/event.sh remote.end remote.kind=close.plan remote.sha=$HEAD remote.log=$seg_log remote.status=ok$"
  expect_has "$tag leftover names the finished job" "$(tail -1 <<<"$out")" "remote:close.plan@$HEAD\(seen\)"
  out=$(E2E_SEG_HANG=1 kenv "$KERNEL/adapter_run.sh" close-segment "$HEAD" checks "$VERDICTS/none.json" 2>&1); rc=$?
  expect_eq "$tag a segment lost right after its start: refused too (64)" "$rc" 64
  out=$(page sess-new)
  expect_has "$tag page: a job with no marker in its log is still running (not-seen)" "$out" "^  kind=close.checks sha=$HEAD log=$LOGS/rc-seg-$HEAD-checks.log host=— started=.* terminal=not-seen$"
  expect_not "$tag page: nothing to collect for the running job" "$out" 'remote.kind=close.checks'
  expect_has "$tag remote jobs with no recorded end: 2" "$out" '^remote jobs with no recorded end: 2$'
  cmd=$(sed -n 's/^    collect: //p' <<<"$out" | head -1)
  kenv sh -c "$cmd" >/dev/null; rc=$?
  expect_eq "$tag running the offered command records the end (exit 0)" "$rc" 0
  out=$(page sess-new)
  expect_not "$tag the collected job is closed" "$out" "remote:close.plan@"
  expect_has "$tag the running job stays open" "$(tail -1 <<<"$out")" "remote:close.checks@$HEAD\(not-seen\)"
  kenv "$KERNEL/event.sh" remote.end remote.kind=close.checks "remote.sha=$HEAD" "remote.log=$LOGS/rc-seg-$HEAD-checks.log" remote.status=abandoned >/dev/null
  expect_has "$tag an abandoned end closes the running job" "$(page sess-new)" '^remote jobs with no recorded end: 0$'

  # WAKE on a wait the executor recorded: the worker's agent.end arrives
  ROTATION_AGENT_ID=ag-w1 kenv "$KERNEL/agent_log.sh" start w1 worker m "a task" >/dev/null
  kenv "$KERNEL/event.sh" executor.waiting workers=list:w1 >/dev/null
  w --wake 0 >/dev/null; rc=$?
  expect_eq "$tag no WAKE while the awaited worker runs" "$rc" 0
  kenv "$KERNEL/agent_log.sh" end w1 worker m "a task" >/dev/null
  out=$(w --wake 0); rc=$?
  expect_eq "$tag the worker ended: WAKE (10)" "$rc" 10
  expect_has "$tag WAKE line names the worker and the executor" "$out" '^WAKE workers=w1 is done, executor silent [0-9]+ s since .* · agent=ag-x$'
  expect_has "$tag page: the wait is satisfied" "$(page sess-mgr)" '^executor.waiting: .* for workers w1 · still waiting=yes · satisfied=yes$'

  # WAKE without a wait on record: a remote.end followed by silence for ROTATION_WAKE_AFTER
  kenv "$KERNEL/adapter_run.sh" preflight -q >/dev/null 2>&1
  out=$(kenv "$KERNEL/adapter_run.sh" close-segment "$HEAD" plan "$VERDICTS/none.json" 2>&1); rc=$?
  expect_eq "$tag a segment with its end on record (exit 0)" "$rc" 0
  w >/dev/null; rc=$?
  expect_eq "$tag no WAKE right after the remote.end" "$rc" 0
  sleep 2
  out=$(w); rc=$?
  expect_eq "$tag remote.end and nothing from the executor for ROTATION_WAKE_AFTER: WAKE (10)" "$rc" 10
  expect_has "$tag WAKE line counts from the remote.end" "$out" "^WAKE remote.end kind=close.plan sha=$HEAD log=$seg_log is on record and no executor event followed for [0-9]+ s since remote.end .* · agent=ag-x$"
  expect_has "$tag page: the silence after the remote.end, the configured wait" "$(page sess-mgr)" "^last remote.end: .* kind=close.plan sha=$HEAD · executor moved since=no · wake after 2 s$"

  # QUOTA: the reset passed and nothing followed; the manager continuing the executor answers it
  kenv "$KERNEL/event.sh" quota.hit "quota.resets=int:$(( $(date +%s) - 1 ))" quota.agent=ag-x >/dev/null
  out=$(w); rc=$?
  expect_eq "$tag quota.hit whose reset passed, nothing after: QUOTA (12)" "$rc" 12
  expect_has "$tag QUOTA line" "$out" '^QUOTA resets=.* passed, no event since .* · agent=ag-x$'
  senv sess-mgr "$KERNEL/manager_log.sh" resume ag-x quota rot-x >/dev/null
  w >/dev/null; rc=$?
  expect_eq "$tag manager.resume recorded: no QUOTA, and the WAKE clock restarted" "$rc" 0
  expect_has "$tag page: the quota is answered" "$(page sess-mgr)" '^quota.hit: .* agent=ag-x resets=.* · due=yes · events since=yes$'

  # MULTI-EXECUTOR: a second running executor of the round
  ROTATION_AGENT_ID=ag-y senv sess-mgr "$KERNEL/agent_log.sh" start rot-y rotation m "a second executor" >/dev/null
  out=$(w); rc=$?
  expect_eq "$tag two running executors: MULTI-EXECUTOR (15)" "$rc" 15
  expect_has "$tag MULTI-EXECUTOR line names both" "$out" '^MULTI-EXECUTOR n=2 executors=rot-x\(ag-x\),rot-y\(ag-y\) · one rotation executor at a time, end the stale one$'
  expect_has "$tag page flags more than one" "$(page sess-mgr)" '^running rotation executors: 2 — rot-x\(ag-x\), rot-y\(ag-y\) · MORE THAN ONE'
  ROTATION_AGENT_STATUS=abandoned kenv "$KERNEL/agent_log.sh" end rot-y rotation m "a second executor" >/dev/null
  w >/dev/null; rc=$?
  expect_eq "$tag the second executor ended: no MULTI-EXECUTOR" "$rc" 0
  expect_has "$tag page counts one executor again" "$(page sess-mgr)" '^running rotation executors: 1 — rot-x\(ag-x\)$'

  # FOREIGN-COMMIT: the executor ended, the marker stays, and the main tree gets a commit
  kenv "$KERNEL/agent_log.sh" end rot-x rotation m "the round" >/dev/null
  [ -f "$STATE/manager.active" ] && ok "$tag the marker stays after a plain end: the round is still managed" || bad "$tag the marker vanished on a plain end"
  w >/dev/null; rc=$?
  expect_eq "$tag no FOREIGN-COMMIT: HEAD predates the executor's end" "$rc" 0
  sleep 1
  echo 4 >> "$REPO/crates/x/src/lib.rs"
  g add -A && g commit -q -m 'chore: a commit while no executor runs'
  out=$(w); rc=$?
  expect_eq "$tag a commit after the executor ended: FOREIGN-COMMIT (14)" "$rc" 14
  expect_has "$tag FOREIGN-COMMIT line: the count past prevHead and the reason" "$out" '^FOREIGN-COMMIT n=4 head=[0-9a-f]+ chore: a commit while no executor runs · HEAD committed at .*, after the last executor event .*, and no executor is running · agent=—$'
  out=$(page sess-mgr)
  expect_has "$tag page counts the foreign commits" "$out" '^foreign commits: 4 on the main tree with no running executor — HEAD committed at'
  expect_has "$tag leftover names them" "$(tail -1 <<<"$out")" '^RESPAWN executor leftover=foreign-commits:4;'
  ROTATION_MANAGER_IDLE=1 kenv "$KERNEL/agent_log.sh" end rot-x rotation m "the round" >/dev/null
  w >/dev/null; rc=$?
  expect_eq "$tag the manager went idle (marker removed): the check does not run" "$rc" 0
  expect_has "$tag page says so" "$(page sess-mgr)" '^foreign commits: not checked \(no manager marker\)$'
}

round recorded 1
round unrecorded 0
interruption

echo
echo "e2e_self_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
