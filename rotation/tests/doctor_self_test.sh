#!/usr/bin/env bash
#
# rotation kernel — doctor.sh against a throwaway project.
#
# A temporary repository, state directory, stamps, rules table, conf and a
# project.sh whose commands are a few lines of bash each (the four heavy ones
# only know how to reject `--doctor-probe`). The wired-up fixture must pass;
# then one thing at a time is removed or broken and the doctor must FAIL the
# run, name that item, and record the verdict. Nothing of this project is
# read: the kernel is pointed at the fixture through ROTATION_PROJECT_DIR /
# ROTATION_CONF / ROTATION_PROJECT_SH / ROTATION_STATE_DIR.
#
# exit: 0 every case passed · 1 otherwise

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KBIN="$(cd "$SCRIPT_DIR/../bin" && pwd)"
TMP=$(mktemp -d)
cleanup() { chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/     | /'; }
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$3] got [$2]"; fi; }
expect_has() { if printf '%s\n' "$2" | grep -qE -- "$3"; then ok "$1"; else bad "$1 (wanted /$3/)" "$2"; fi; }
expect_not() { if printf '%s\n' "$2" | grep -qE -- "$3"; then bad "$1 (/$3/ present)" "$2"; else ok "$1"; fi; }
last() { printf '%s\n' "$1" | tail -1; }
nfails() { printf '%s\n' "$1" | grep -c '^FAIL '; }
KERNEL_VERSION=$(sed -nE 's/^ROTATION_KERNEL_VERSION="([^"]+)"$/\1/p' "$KBIN/lib.sh")
KERNEL_MINOR=$(printf '%s' "$KERNEL_VERSION" | cut -d. -f2)

# ── the fixture ─────────────────────────────────────────────────────────
# setup <name>: a repository on develop with one commit, the round's row, a sweep stamp and an axis stamp,
# a one-row rules table, the conf, and a project.sh registering seven commands
setup() {
  R="$TMP/$1"; REPO="$R/repo"; STATE="$R/state"; STAMPS="$R/stamps"; VERDICTS="$R/verdicts"; BIN="$R/bin"
  mkdir -p "$REPO/.claude" "$STATE" "$STAMPS" "$VERDICTS" "$BIN"
  g() { git -C "$REPO" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
  g init -q -b develop
  printf '.claude/\n' > "$REPO/.gitignore"
  echo a > "$REPO/a.txt"
  g add -A && g commit -q -m 'chore: seed'
  C0=$(g rev-parse HEAD)
  printf '{"rotationId":"r-doc-1","at":"x","ts":%s,"project":"%s","trigger":"self","prevHead":"%s"}\n' \
    "$(( $(date +%s) - 3600 ))" "$(basename "$REPO")" "${C0:0:9}" > "$STATE/rotations.jsonl"
  printf '{"tool":"sweep","ranAt":"2026-01-01T00:00:00Z","headSha":"%s","verdict":"ok","harnessError":0,"pass":100,"passTotal":120}\n' "$C0" > "$STAMPS/sweep-latest.json"
  printf '{"tool":"bench","ranAt":"2026-01-01T00:00:00Z","headSha":"%s","verdict":"ok","median":0.5}\n' "$C0" > "$STAMPS/bench-latest.json"
  printf '#name\tpaths\tartifact\tstamp\tminutes\tmode\tsync_paths\tneeds\tshow\tregress\nsweep\tcrates/**\t-\tsweep\t1\tsync\t-\t-\tpass,passTotal\tpass:down\n' > "$R/rules.tsv"
  cat > "$R/rotation.conf" <<EOF
ROTATION_CONF_KERNEL=1
ROTATION_TRIG1_MIN_COMMITS=12
ROTATION_TRIG1_MIN_CLOSED=3
ROTATION_TRIG2_MIN_WALL_SEC=1800
ROTATION_TRIG2_MAX_WALL_SEC=18000
ROTATION_TRIG5_SAME_AXIS_MAX=8
ROTATION_TRIG5_BENCH_MAX_AGE_DAYS=14
ROTATION_AXES=A,B
ROTATION_STAMPS=sweep
ROTATION_AXIS_STAMP=bench
ROTATION_SWEEP_STAMP=sweep
ROTATION_CLOSE_RULES=$R/rules.tsv
EOF
  cat > "$R/project.sh" <<EOF
export ROTATION_STAMP_DIR="$STAMPS"
export ROTATION_VERDICT_DIR="$VERDICTS"
export ROTATION_SWEEP_LINE_CMD="$BIN/sweep_line.sh"
export ROTATION_AXIS_READING_CMD="$BIN/axis_line.sh"
export ROTATION_GATE_CMD="$BIN/gate.sh"
export ROTATION_PREFLIGHT_CMD="$BIN/preflight.sh"
export ROTATION_CLOSE_SEGMENT_CMD="$BIN/segment.sh"
export ROTATION_BENCH_CMD="$BIN/bench.sh"
EOF
  cat > "$BIN/sweep_line.sh" <<'EOF'
#!/bin/sh
f="${ROTATION_SWEEP_JSON:-${HARDEV_SWEEP_JSON:-}}"
[ -f "$f" ] || exit 2
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("sweep: head=%s pass=%s passTotal=%s" % (d["headSha"], d["pass"], d["passTotal"]))' "$f"
EOF
  cat > "$BIN/axis_line.sh" <<'EOF'
#!/bin/sh
f="${ROTATION_AXIS_JSON:-${HARDEV_BENCH_JSON:-}}"
[ -f "$f" ] || exit 2
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("bench: head=%s median=%s ran=%s" % (d["headSha"], d["median"], d["ranAt"]))' "$f"
EOF
  local c
  for c in gate preflight segment bench; do
    cat > "$BIN/$c.sh" <<'EOF'
#!/bin/sh
# a heavy command that only knows its usage: anything it does not recognise exits 2 before any work
case "${1:-}" in ''|-*) echo "usage: $0 <sha>" >&2; exit 2 ;; esac
echo "ran $*"
EOF
  done
  chmod +x "$BIN"/*.sh
  EV="$STATE/events.jsonl"
}
doctor() { env ROTATION_PROJECT_DIR="$REPO" ROTATION_CONF="$R/rotation.conf" ROTATION_PROJECT_SH="$R/project.sh" ROTATION_STATE_DIR="$STATE" bash "$KBIN/doctor.sh" "$@" 2>&1; }
drop_key() { grep -v "^$2=" "$R/rotation.conf" > "$R/c.tmp" && mv "$R/c.tmp" "$R/rotation.conf"; }
set_key() { drop_key _ "$2"; echo "$2=$3" >> "$R/rotation.conf"; }
last_event() { tail -1 "$EV" | python3 -c 'import json,sys; e=json.load(sys.stdin); d=e["doctor"]; print(e["kind"], d["result"], ",".join(d["failed"]), d["kernel"], d["confSha256"])'; }

# ── 1. the wired-up fixture passes ──────────────────────────────────────
setup good
out=$(doctor); rc=$?
expect_eq "1 wired-up fixture: exit 0" "$rc" 0
expect_eq "1 last line names the kernel and the conf" "$(last "$out")" "DOCTOR PASS kernel=$KERNEL_VERSION conf=$(shasum -a 256 "$R/rotation.conf" | cut -c1-12)"
expect_not "1 no FAIL line" "$out" '^FAIL '
expect_has "1 the four heavy commands were probed, not run" "$out" '^PASS probe.ROTATION_GATE_CMD'
expect_has "1 sweep line shape checked with the stamp" "$out" '^PASS shape.sweep-line .*sweep: head='
expect_has "1 axis reading shape checked" "$out" '^PASS shape.axis-reading'
expect_has "1 rules table parsed" "$out" '^PASS rules 1 rules: sweep'
expect_has "1 executors counted" "$out" '^PASS executors running rotation executors: 0'
expect_has "1 base branch" "$out" '^PASS git.base develop$'
expect_eq "1 doctor.result event: PASS, nothing failed, kernel, conf sha" "$(last_event)" "doctor.result PASS  $KERNEL_VERSION $(shasum -a 256 "$R/rotation.conf" | cut -c1-64)"

# ── 2. a required threshold removed ─────────────────────────────────────
setup nothreshold
drop_key _ ROTATION_TRIG1_MIN_COMMITS
out=$(doctor); rc=$?
expect_eq "2 missing threshold: exit 1" "$rc" 1
expect_has "2 the key is named" "$out" '^FAIL conf.ROTATION_TRIG1_MIN_COMMITS must be an integer'
expect_eq "2 last line counts one failure" "$(last "$out")" "DOCTOR FAIL n=1"
expect_has "2 doctor.result records the failed item" "$(last_event)" '^doctor.result FAIL conf.ROTATION_TRIG1_MIN_COMMITS '

# ── 3. a mode key outside its set, a non-integer, an empty axes list, no stamps ──
setup badmodes
set_key _ ROTATION_TRIG2_MEASURE bogus
set_key _ ROTATION_TRIG1A_MODE sometimes
set_key _ ROTATION_TRIG8_GATE_COVERAGE yes
set_key _ ROTATION_TRIG2_MIN_WALL_SEC 30m
set_key _ ROTATION_WAKE_AFTER 5min
set_key _ ROTATION_AXES ' , '
drop_key _ ROTATION_STAMPS
out=$(doctor); rc=$?
expect_eq "3 illegal values: exit 1" "$rc" 1
expect_has "3 non-integer wake wait named" "$out" '^FAIL conf.ROTATION_WAKE_AFTER must be an integer when set, got .5min.'
expect_has "3 TRIG2_MEASURE named" "$out" '^FAIL conf.ROTATION_TRIG2_MEASURE must be trigger or active, got .bogus.'
expect_has "3 TRIG1A_MODE named" "$out" '^FAIL conf.ROTATION_TRIG1A_MODE must be enforce or observe'
expect_has "3 TRIG8 named" "$out" '^FAIL conf.ROTATION_TRIG8_GATE_COVERAGE must be on or off'
expect_has "3 non-integer named" "$out" '^FAIL conf.ROTATION_TRIG2_MIN_WALL_SEC must be an integer, got .30m.'
expect_has "3 empty axes named" "$out" '^FAIL conf.ROTATION_AXES'
expect_has "3 empty stamp list named" "$out" '^FAIL conf.ROTATION_STAMPS'
expect_eq "3 the count matches the FAIL lines" "$(last "$out")" "DOCTOR FAIL n=$(nfails "$out")"

# ── 4. conf written for another kernel major ────────────────────────────
setup major
set_key _ ROTATION_CONF_KERNEL 2
out=$(doctor); rc=$?
expect_eq "4 other major: exit 1" "$rc" 1
expect_has "4 conf.kernel names both" "$out" "^FAIL conf.kernel rotation.conf is written for kernel major 2, this kernel is $KERNEL_VERSION"
expect_has "4 the keys are still checked under a major mismatch" "$out" '^PASS conf.keys'

# ── 5. same major, other minor: a warning only ──────────────────────────
setup minor
set_key _ ROTATION_CONF_KERNEL "${KERNEL_VERSION%%.*}.$(( KERNEL_MINOR + 7 ))"
out=$(doctor); rc=$?
expect_eq "5 other minor: exit 0" "$rc" 0
expect_has "5 WARN conf.kernel" "$out" "^WARN conf.kernel rotation.conf is written for kernel ${KERNEL_VERSION%%.*}.$(( KERNEL_MINOR + 7 )), this kernel is $KERNEL_VERSION"
expect_has "5 DOCTOR PASS" "$out" '^DOCTOR PASS kernel='
setup sameminor
set_key _ ROTATION_CONF_KERNEL "${KERNEL_VERSION%%.*}.$KERNEL_MINOR"
out=$(doctor); rc=$?
expect_eq "5 same minor spelled out: exit 0" "$rc" 0
expect_has "5 PASS conf.kernel" "$out" '^PASS conf.kernel'

# ── 6. a required command not registered ────────────────────────────────
setup nogate
grep -v ROTATION_GATE_CMD "$R/project.sh" > "$R/p.tmp" && mv "$R/p.tmp" "$R/project.sh"
out=$(doctor); rc=$?
expect_eq "6 gate not registered: exit 1" "$rc" 1
expect_has "6 project.ROTATION_GATE_CMD named" "$out" '^FAIL project.ROTATION_GATE_CMD not set'
expect_not "6 no cmd/probe line for the unregistered command" "$out" 'ROTATION_GATE_CMD (exits|not an executable)'
expect_eq "6 one failure" "$(last "$out")" "DOCTOR FAIL n=1"

# ── 7. a command that is not executable, a command that would run on the probe ──
setup noexec
chmod -x "$BIN/preflight.sh"
printf '#!/bin/sh\necho "running the whole bench on $*"\n' > "$BIN/bench.sh"
out=$(doctor); rc=$?
expect_eq "7 exit 1" "$rc" 1
expect_has "7 non-executable named" "$out" '^FAIL cmd.ROTATION_PREFLIGHT_CMD not an executable file'
expect_has "7 a command that accepts the probe is refused" "$out" '^FAIL probe.ROTATION_BENCH_CMD exit 0 on an unknown argument, want 2'
expect_eq "7 two failures" "$(last "$out")" "DOCTOR FAIL n=2"

# ── 8. the rules table emptied ──────────────────────────────────────────
setup norules
head -1 "$R/rules.tsv" > "$R/r.tmp" && mv "$R/r.tmp" "$R/rules.tsv"
out=$(doctor); rc=$?
expect_eq "8 empty rules: exit 1" "$rc" 1
expect_has "8 rules named with the planner's reason" "$out" '^FAIL rules close_plan: .*no rules'
setup badrules
printf 'sweep\tcrates/**\n' >> "$R/rules.tsv"
out=$(doctor); rc=$?
expect_has "8 a malformed row is named with its line" "$out" '^FAIL rules close_plan: .*rules.tsv:3: 2 columns, want 10'
setup badoff
set_key _ ROTATION_CLOSE_CHECKS_OFF nosuch
out=$(doctor); rc=$?
expect_eq "8 a switched-off check the table lacks: exit 1" "$rc" 1
expect_has "8 the switch is named with the unknown check" "$out" '^FAIL rules close_plan: ROTATION_CLOSE_CHECKS_OFF names a check the table does not have: nosuch'
setup goodoff
printf 'size\tcrates/**\t-\tsize:size_audit\t1\tsync\t-\t-\tfilesNew\tfilesNew:nonzero\n' >> "$R/rules.tsv"
set_key _ ROTATION_CLOSE_CHECKS_OFF size
out=$(doctor); rc=$?
expect_eq "8 a switched-off check the table has: exit 0" "$rc" 0
expect_has "8 the rules line counts the rows left on" "$out" '^PASS rules 1 rules: sweep '

# ── 9. two running executors ────────────────────────────────────────────
setup two
ROTATION_AGENT_ID=id-one env ROTATION_PROJECT_DIR="$REPO" ROTATION_CONF="$R/rotation.conf" ROTATION_PROJECT_SH="$R/project.sh" ROTATION_STATE_DIR="$STATE" bash "$KBIN/agent_log.sh" start rot-one rotation m "first" >/dev/null 2>&1
ROTATION_AGENT_ID=id-two env ROTATION_PROJECT_DIR="$REPO" ROTATION_CONF="$R/rotation.conf" ROTATION_PROJECT_SH="$R/project.sh" ROTATION_STATE_DIR="$STATE" bash "$KBIN/agent_log.sh" start rot-two rotation m "second" >/dev/null 2>&1
out=$(doctor); rc=$?
expect_eq "9 two executors: exit 1" "$rc" 1
expect_has "9 both are named" "$out" '^FAIL executors running rotation executors: 2 — rot-one\(id-one\) rot-two\(id-two\)'
env ROTATION_PROJECT_DIR="$REPO" ROTATION_CONF="$R/rotation.conf" ROTATION_PROJECT_SH="$R/project.sh" ROTATION_STATE_DIR="$STATE" bash "$KBIN/agent_log.sh" end rot-one rotation m >/dev/null 2>&1
out=$(doctor); rc=$?
expect_eq "9 one ended: exit 0" "$rc" 0
expect_has "9 the one left is named" "$out" '^PASS executors running rotation executors: 1 rot-two\(id-two\)'

# ── 10. output shapes ───────────────────────────────────────────────────
setup shapes
printf '#!/bin/sh\necho "sweep: head=none"\n' > "$BIN/sweep_line.sh"
printf '#!/bin/sh\necho "bench: head=x median=0.5"\n' > "$BIN/axis_line.sh"
out=$(doctor); rc=$?
expect_eq "10 exit 1" "$rc" 1
expect_has "10 sweep line that prints without a stamp" "$out" '^FAIL shape.sweep-line exit 0 without a stamp, want 2'
expect_has "10 axis reading without ran=" "$out" '^FAIL shape.axis-reading .*want exit 0 and a line carrying ran='
setup nostamps
rm "$STAMPS/sweep-latest.json" "$STAMPS/bench-latest.json"
out=$(doctor); rc=$?
expect_eq "10 no stamps yet: exit 0" "$rc" 0
expect_has "10 sweep line shape WARN without a stamp" "$out" '^WARN shape.sweep-line exit 2 without a stamp; no sweep-latest.json'
expect_has "10 axis reading WARN without a stamp" "$out" '^WARN shape.axis-reading no bench-latest.json'
setup noaxis
grep -v ROTATION_AXIS_READING_CMD "$R/project.sh" > "$R/p.tmp" && mv "$R/p.tmp" "$R/project.sh"
out=$(doctor); rc=$?
expect_eq "10 no axis reading command: exit 0" "$rc" 0
expect_has "10 WARN names the variable" "$out" '^WARN shape.axis-reading ROTATION_AXIS_READING_CMD not set'

# ── 11. project.sh missing ──────────────────────────────────────────────
setup noproject
rm "$R/project.sh"
out=$(doctor); rc=$?
expect_eq "11 exit 1" "$rc" 1
expect_has "11 project.sh named" "$out" '^FAIL project.sh missing: '
expect_has "11 every required variable is named" "$out" '^FAIL project.ROTATION_BENCH_CMD not set'
expect_eq "11 the count matches the FAIL lines" "$(last "$out")" "DOCTOR FAIL n=$(nfails "$out")"
expect_has "11 doctor.result lists them all" "$(last_event)" '^doctor.result FAIL project.sh,project.ROTATION_STAMP_DIR,.*project.ROTATION_BENCH_CMD '

# ── 12. a directory the kernel cannot write ─────────────────────────────
setup readonly
chmod 555 "$STAMPS"
out=$(doctor); rc=$?
chmod 755 "$STAMPS"
expect_eq "12 exit 1" "$rc" 1
expect_has "12 stamp.dir named" "$out" '^FAIL stamp.dir not a writable directory'

# ── 13. no rotation.conf at all ─────────────────────────────────────────
setup noconf
rm "$R/rotation.conf"
out=$(doctor); rc=$?
expect_eq "13 exit 1" "$rc" 1
expect_has "13 conf named" "$out" '^FAIL conf no rotation.conf at '
expect_not "13 no key lines when the conf did not load" "$out" '^FAIL conf\.ROTATION_'
expect_has "13 doctor.result has a null conf sha" "$(last_event)" '^doctor.result FAIL conf '"$KERNEL_VERSION"' None$'

# ── 14. git ─────────────────────────────────────────────────────────────
setup detached
git -C "$REPO" checkout -q --detach
out=$(doctor); rc=$?
expect_eq "14 detached HEAD without a base branch: exit 1" "$rc" 1
expect_has "14 git.base named" "$out" '^FAIL git.base detached HEAD and ROTATION_BASE_BRANCH not set'
echo 'export ROTATION_BASE_BRANCH=develop' >> "$R/project.sh"
out=$(doctor); rc=$?
expect_eq "14 base branch given: exit 0" "$rc" 0
echo 'export ROTATION_BASE_BRANCH=nope' >> "$R/project.sh"
out=$(doctor); rc=$?
expect_has "14 a base branch that does not exist" "$out" '^FAIL git.base branch does not exist: nope'

# ── 15. usage ───────────────────────────────────────────────────────────
setup usage
out=$(doctor --bogus); rc=$?
expect_eq "15 unknown argument: exit 2" "$rc" 2
expect_eq "15 nothing recorded" "$([ -f "$EV" ] && echo yes || echo no)" no

echo
echo "doctor_self_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
