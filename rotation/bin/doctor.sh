#!/usr/bin/env bash
#
# rotation kernel — is the kernel wired to this project? Run once after
# adopting (and after a kernel upgrade): every contract the kernel relies on
# is checked and reported on its own line.
#
# usage: doctor.sh | doctor.sh --all
#   --all   every lane of the project in turn (the first lane, then each .claude/rotation-lanes/<lane>/), each
#           run's output after a `== lane <name> ==` line; the exit code is the highest of the runs
#
# Output: one line per check, `PASS|FAIL|WARN <item> <detail>`; WARN never
# fails the run. Last line `DOCTOR PASS kernel=<x.y.z> conf=<sha256, 12 hex>`
# or `DOCTOR FAIL n=<failed checks>`. A doctor.result event records the
# verdict (doctor.result, doctor.failed, doctor.kernel, doctor.confSha256).
#
# What is checked:
#   conf          rotation.conf present and parsed; ROTATION_CONF_KERNEL (before any dot) equals the kernel's
#                 conf format ROTATION_CONF_FORMAT, not its version; the integer thresholds, the mode keys (trigger|active, enforce|observe,
#                 on|off), AXES / STAMPS / SWEEP_STAMP non-empty, CLOSE_RULES set
#   project.sh    present, parses (bash -n), the required variables set: ROTATION_STAMP_DIR, ROTATION_VERDICT_DIR,
#                 ROTATION_SWEEP_LINE_CMD, ROTATION_GATE_CMD, ROTATION_PREFLIGHT_CMD, ROTATION_CLOSE_SEGMENT_CMD,
#                 ROTATION_BENCH_CMD
#   cmd.*         every ROTATION_*_CMD set: a path must be an executable file, a bare word must be on PATH
#   probe.*       the four heavy commands (gate / pre-flight / close segment / bench) are NOT run; each is
#                 called with the one argument `--doctor-probe`, which no contract accepts, and must exit 2
#                 (usage) without doing anything
#   shape.*       the read-only commands are run: the sweep line exits 2 without a stamp and prints a
#                 `sweep: head=` line with one; the axis reading prints a line carrying `ran=`
#   state / stamp / verdict directories writable (a temporary file, removed), events.jsonl appendable
#   rules         the close rules table parses (close_lib.py load_rules) and is not empty
#   executors     running rotation executors of this round ≤ 1 (recover.sh's reading)
#   git           a work tree; the base branch (ROTATION_BASE_BRANCH, else the current branch) exists
#   plan.*        onboard_check.sh's steps 3, 5 and 7: plan.queue (the queue table), plan.l4 (the L4 trigger
#                 predicates, no percentage), plan.handoff (the trigger section's axis: / closed: / gate:); a plan
#                 file or handoff that does not exist yet is a WARN
#
# exit: 0 every check passed · 1 a check failed · 2 usage

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

if [ "${1:-}" = --all ] && [ "$#" -eq 1 ]; then
  . "$SCRIPT_DIR/lane_lib.sh"
  autorun_run_all "$SCRIPT_DIR/doctor.sh"
  exit $?
fi
[ "$#" -eq 0 ] || { echo "usage: doctor.sh | doctor.sh --all" >&2; exit 2; }
# a lane says so first: every path below is that lane's (docs/lanes.md)
[ -z "$ROTATION_LANE" ] || echo "PASS lane $ROTATION_LANE ($PROJECT_ROTATION_DIR; state $STATE_DIR)"

nfail=0
failed=()
pass() { printf 'PASS %s %s\n' "$1" "$2"; }
warn() { printf 'WARN %s %s\n' "$1" "$2"; }
fail() { printf 'FAIL %s %s\n' "$1" "$2"; nfail=$((nfail + 1)); failed+=("$1"); }
# a directory the kernel must be able to write: create and remove one temporary file in it
writable_dir() { local t; t=$(mktemp "$1/.doctor.XXXXXX" 2>/dev/null) || return 1; rm -f "$t"; }
is_int() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
# the command a ROTATION_*_CMD names: a path must be an executable file, a bare word must resolve on PATH
cmd_ok() {
  local first=${1%% *}
  case "$first" in
    */*) [ -f "$first" ] && [ -x "$first" ] ;;
    *) command -v "$first" >/dev/null 2>&1 ;;
  esac
}

# ── rotation.conf ───────────────────────────────────────────────────────
conf_parsed=1
case "$ROTATION_CONF_ERROR" in
  '') pass conf "$ROTATION_CONF_FILE sha256=${ROTATION_CONF_SHA256:0:12}" ;;
  *'written for conf format'*) pass conf "$ROTATION_CONF_FILE sha256=${ROTATION_CONF_SHA256:0:12}" ;;
  *) fail conf "$ROTATION_CONF_ERROR"; conf_parsed=0 ;;
esac

if [ "$conf_parsed" -eq 1 ]; then
  conf_kernel="${ROTATION_CONF_KERNEL:-}"
  if [ -z "$conf_kernel" ]; then
    fail conf.kernel "ROTATION_CONF_KERNEL missing (kernel $ROTATION_KERNEL_VERSION reads conf format $ROTATION_CONF_FORMAT; write $ROTATION_CONF_FORMAT)"
  elif [ "${conf_kernel%%.*}" != "$ROTATION_CONF_FORMAT" ]; then
    fail conf.kernel "rotation.conf is written for conf format ${conf_kernel%%.*}, kernel $ROTATION_KERNEL_VERSION reads conf format $ROTATION_CONF_FORMAT"
  else
    # a digit after the dot is a kernel minor recorded before 2.0.0; it is not compared
    pass conf.kernel "conf format $ROTATION_CONF_FORMAT · kernel $ROTATION_KERNEL_VERSION"
  fi

  keys_bad=0
  for k in ROTATION_TRIG1_MIN_COMMITS ROTATION_TRIG1_MIN_CLOSED ROTATION_TRIG2_MIN_WALL_SEC ROTATION_TRIG2_MAX_WALL_SEC ROTATION_TRIG5_SAME_AXIS_MAX ROTATION_TRIG5_BENCH_MAX_AGE_DAYS; do
    eval "v=\${$k:-}"
    is_int "$v" || { fail "conf.$k" "must be an integer, got '$v'"; keys_bad=1; }
  done
  for k in ROTATION_COLD_START_WINDOW ROTATION_BOOTSTRAP_ROUNDS ROTATION_WORKER_STALE; do
    eval "v=\${$k:-}"
    [ -z "$v" ] || is_int "$v" || { fail "conf.$k" "must be an integer when set, got '$v'"; keys_bad=1; }
  done
  # read from the file: nothing reads the key any more, so a value in the environment means nothing either
  grep -qE '^[[:space:]]*ROTATION_WAKE_AFTER[[:space:]]*=' "$ROTATION_CONF_FILE" 2>/dev/null \
    && warn conf.ROTATION_WAKE_AFTER "is no longer read: watchdog.sh --wake sets the wait after a remote.end too; delete the line"
  case "${ROTATION_TRIG2_MEASURE:-trigger}" in trigger|active) ;; *) fail conf.ROTATION_TRIG2_MEASURE "must be trigger or active, got '$ROTATION_TRIG2_MEASURE'"; keys_bad=1 ;; esac
  for k in ROTATION_TRIG1A_MODE ROTATION_TRIG2_MODE; do
    eval "v=\${$k:-enforce}"
    case "$v" in enforce|observe) ;; *) fail "conf.$k" "must be enforce or observe, got '$v'"; keys_bad=1 ;; esac
  done
  case "${ROTATION_TRIG8_GATE_COVERAGE:-off}" in on|off) ;; *) fail conf.ROTATION_TRIG8_GATE_COVERAGE "must be on or off, got '$ROTATION_TRIG8_GATE_COVERAGE'"; keys_bad=1 ;; esac
  case "${ROTATION_TRIG9_VERDICT_RED:-off}" in on|off) ;; *) fail conf.ROTATION_TRIG9_VERDICT_RED "must be on or off, got '$ROTATION_TRIG9_VERDICT_RED'"; keys_bad=1 ;; esac
  [ -n "$(printf '%s' "${ROTATION_AXES:-}" | tr -d ' ,')" ] || { fail conf.ROTATION_AXES "must name at least one axis"; keys_bad=1; }
  [ -n "$(printf '%s' "${ROTATION_STAMPS:-}" | tr -d ' ')" ] || { fail conf.ROTATION_STAMPS "must name at least one stamp (TRIG-6 fails on an empty list)"; keys_bad=1; }
  [ -n "${ROTATION_SWEEP_STAMP:-}" ] || { fail conf.ROTATION_SWEEP_STAMP "must name the sweep stamp (TRIG-7 fails without it)"; keys_bad=1; }
  [ -n "${ROTATION_CLOSE_RULES:-}" ] || { fail conf.ROTATION_CLOSE_RULES "must point at the close rules table"; keys_bad=1; }
  [ "$keys_bad" -eq 1 ] || pass conf.keys "thresholds integer, modes legal, axes=${ROTATION_AXES} stamps=${ROTATION_STAMPS} sweepStamp=${ROTATION_SWEEP_STAMP}"
fi

# ── project.sh ──────────────────────────────────────────────────────────
if [ ! -f "$PROJECT_SH" ]; then
  fail project.sh "missing: $PROJECT_SH"
elif ! bash -n "$PROJECT_SH" 2>/dev/null; then
  fail project.sh "does not parse: $PROJECT_SH"
else
  pass project.sh "$PROJECT_SH"
fi

vars_bad=0
for k in ROTATION_STAMP_DIR ROTATION_VERDICT_DIR ROTATION_SWEEP_LINE_CMD ROTATION_GATE_CMD ROTATION_PREFLIGHT_CMD ROTATION_CLOSE_SEGMENT_CMD ROTATION_BENCH_CMD; do
  eval "v=\${$k:-}"
  [ -n "$v" ] || { fail "project.$k" "not set (project.sh)"; vars_bad=1; }
done
[ "$vars_bad" -eq 1 ] || pass project.vars "the required variables are set"

# every command registered, whatever its name
for k in $(env | grep -oE '^ROTATION_[A-Z0-9_]*_CMD=' | tr -d = | sort); do
  eval "v=\${$k:-}"
  [ -n "$v" ] || continue
  if cmd_ok "$v"; then
    pass "cmd.$k" "${v%% *}"
  else
    fail "cmd.$k" "not an executable file or not on PATH: ${v%% *}"
  fi
done

# the heavy commands: only the usage path, never the work
for k in ROTATION_GATE_CMD ROTATION_PREFLIGHT_CMD ROTATION_CLOSE_SEGMENT_CMD ROTATION_BENCH_CMD; do
  eval "v=\${$k:-}"
  [ -n "$v" ] && [ -f "${v%% *}" ] || continue
  bash "${v%% *}" --doctor-probe >/dev/null 2>&1 </dev/null
  rc=$?
  if [ "$rc" -eq 2 ]; then
    pass "probe.$k" "exits 2 on an unknown argument"
  else
    fail "probe.$k" "exit $rc on an unknown argument, want 2 (usage) — the command must reject before it runs anything"
  fi
done

# ── output shapes of the read-only commands ─────────────────────────────
STAMP_DIR="${ROTATION_STAMP_DIR:-}"
if [ -n "${ROTATION_SWEEP_LINE_CMD:-}" ] && [ -f "$ROTATION_SWEEP_LINE_CMD" ]; then
  nostamp="$SCRIPT_DIR/.doctor-no-such-stamp.json"
  HARDEV_SWEEP_JSON="$nostamp" ROTATION_SWEEP_JSON="$nostamp" bash "$ROTATION_SWEEP_LINE_CMD" >/dev/null 2>&1 </dev/null
  rc=$?
  if [ "$rc" -ne 2 ]; then
    fail shape.sweep-line "exit $rc without a stamp, want 2"
  elif [ -n "$STAMP_DIR" ] && [ -n "${ROTATION_SWEEP_STAMP:-}" ] && [ -f "$STAMP_DIR/$ROTATION_SWEEP_STAMP-latest.json" ]; then
    stamp="$STAMP_DIR/$ROTATION_SWEEP_STAMP-latest.json"
    line=$(HARDEV_SWEEP_JSON="$stamp" ROTATION_SWEEP_JSON="$stamp" bash "$ROTATION_SWEEP_LINE_CMD" 2>/dev/null </dev/null)
    rc=$?
    if [ "$rc" -eq 0 ] && printf '%s\n' "$line" | grep -qE '^sweep: head='; then
      pass shape.sweep-line "exit 2 without a stamp; with one: ${line:0:60}"
    else
      fail shape.sweep-line "with $stamp: exit $rc, line '${line:0:80}' (want exit 0 and a line starting 'sweep: head=')"
    fi
  else
    warn shape.sweep-line "exit 2 without a stamp; no ${ROTATION_SWEEP_STAMP:-?}-latest.json in ${STAMP_DIR:-?} yet, the line shape is not checked"
  fi
fi

if [ -z "${ROTATION_AXIS_READING_CMD:-}" ]; then
  warn shape.axis-reading "ROTATION_AXIS_READING_CMD not set (TRIG-5 fails once the same axis has run ${ROTATION_TRIG5_SAME_AXIS_MAX:-?} rotations in a row)"
elif [ -f "$ROTATION_AXIS_READING_CMD" ]; then
  if [ -z "${ROTATION_AXIS_STAMP:-}" ]; then
    warn shape.axis-reading "ROTATION_AXIS_STAMP not set in rotation.conf, the reading is not checked"
  elif [ -n "$STAMP_DIR" ] && [ -f "$STAMP_DIR/$ROTATION_AXIS_STAMP-latest.json" ]; then
    stamp="$STAMP_DIR/$ROTATION_AXIS_STAMP-latest.json"
    line=$(HARDEV_BENCH_JSON="$stamp" ROTATION_AXIS_JSON="$stamp" bash "$ROTATION_AXIS_READING_CMD" 2>/dev/null </dev/null)
    rc=$?
    if [ "$rc" -eq 0 ] && printf '%s\n' "$line" | grep -qE '(^| )ran='; then
      pass shape.axis-reading "line carries ran=: ${line:0:60}"
    else
      fail shape.axis-reading "with $stamp: exit $rc, line '${line:0:80}' (want exit 0 and a line carrying ran=)"
    fi
  else
    warn shape.axis-reading "no $ROTATION_AXIS_STAMP-latest.json in ${STAMP_DIR:-?} yet, the line shape is not checked"
  fi
fi

# ── directories and the event log ───────────────────────────────────────
mkdir -p "$STATE_DIR" 2>/dev/null
if [ -d "$STATE_DIR" ] && writable_dir "$STATE_DIR"; then
  pass state.dir "$STATE_DIR"
else
  fail state.dir "not a writable directory: $STATE_DIR"
fi
if [ -f "$EVENTS_LOG" ]; then
  if [ -w "$EVENTS_LOG" ]; then pass state.events "appendable: $EVENTS_LOG"; else fail state.events "not writable: $EVENTS_LOG"; fi
elif [ -d "$(dirname "$EVENTS_LOG")" ] && [ -w "$(dirname "$EVENTS_LOG")" ]; then
  pass state.events "will be created: $EVENTS_LOG"
else
  fail state.events "cannot be created: $EVENTS_LOG"
fi
if [ -n "$STAMP_DIR" ]; then
  if [ -d "$STAMP_DIR" ] && writable_dir "$STAMP_DIR"; then
    pass stamp.dir "$STAMP_DIR"
  else
    fail stamp.dir "not a writable directory: $STAMP_DIR"
  fi
fi
if [ -n "${ROTATION_VERDICT_DIR:-}" ]; then
  if [ -d "$ROTATION_VERDICT_DIR" ]; then
    if writable_dir "$ROTATION_VERDICT_DIR"; then pass verdict.dir "$ROTATION_VERDICT_DIR"; else fail verdict.dir "not writable: $ROTATION_VERDICT_DIR"; fi
  elif [ -d "$(dirname "$ROTATION_VERDICT_DIR")" ] && [ -w "$(dirname "$ROTATION_VERDICT_DIR")" ]; then
    pass verdict.dir "will be created: $ROTATION_VERDICT_DIR"
  else
    fail verdict.dir "cannot be created: $ROTATION_VERDICT_DIR"
  fi
fi

# ── the close rules table, through the planner's own loader ─────────────
if [ -n "${ROTATION_CLOSE_RULES:-}" ]; then
  rules_out=$(cd "$SCRIPT_DIR" && ROTATION_CLOSE_RULES="$ROTATION_CLOSE_RULES" PYTHONDONTWRITEBYTECODE=1 python3 -c \
    'import close_lib; r = close_lib.load_rules(); print(len(r), " ".join(x["name"] for x in r))' 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    pass rules "${rules_out%% *} rules: ${rules_out#* } ($ROTATION_CLOSE_RULES)"
  else
    fail rules "$(printf '%s\n' "$rules_out" | tail -1)"
  fi
fi

# ── one executor at a time (recover_lib's reading) ──────────────────────
scene=$(bash "$SCRIPT_DIR/recover.sh" --json --no-probe 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  fail executors "recover.sh --json --no-probe exit $rc: $(printf '%s\n' "$scene" | tail -1)"
else
  ex=$(printf '%s\n' "$scene" | python3 -c '
import json, sys
s = json.load(sys.stdin)
ex = s.get("executors") or []
print(len(ex), " ".join("%s(%s)" % (a.get("name"), a.get("id") or "no-id") for a in ex))')
  n=${ex%% *}
  if [ "$n" -le 1 ]; then
    pass executors "running rotation executors: $n${ex#"$n"}"
  else
    fail executors "running rotation executors: $n —${ex#"$n"} (the protocol runs one; end the stale one with agent_log.sh)"
  fi
fi

# ── git ─────────────────────────────────────────────────────────────────
if git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  pass git "$PROJECT_DIR @ $(autorun_git_head)"
  base="${ROTATION_BASE_BRANCH:-$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)}"
  if [ -z "$base" ] || [ "$base" = HEAD ]; then
    fail git.base "detached HEAD and ROTATION_BASE_BRANCH not set"
  elif git -C "$PROJECT_DIR" rev-parse --verify --quiet "refs/heads/$base" >/dev/null; then
    pass git.base "$base"
  else
    fail git.base "branch does not exist: $base"
  fi
else
  fail git "not a git work tree: $PROJECT_DIR"
fi

# ── the plan's shape (onboarding steps 3, 5 and 7) ──────────────────────
plan_out=$(bash "$SCRIPT_DIR/onboard_check.sh" --doctor 2>&1)
rc=$?
if [ "$rc" -gt 1 ]; then
  fail plan "onboard_check.sh --doctor exit $rc: $(printf '%s\n' "$plan_out" | tail -1)"
else
  while IFS= read -r line; do
    case "$line" in
      'FAIL '*) line=${line#FAIL }; fail "${line%% *}" "${line#* }" ;;
      'PASS '*|'WARN '*) printf '%s\n' "$line" ;;
    esac
  done <<PLAN
$plan_out
PLAN
fi

# ── verdict ─────────────────────────────────────────────────────────────
result=PASS
[ "$nfail" -eq 0 ] || result=FAIL
summary=$(python3 -c '
import json, sys
print(json.dumps({"result": sys.argv[1], "failed": [x for x in sys.argv[2].split(" ") if x],
                  "kernel": sys.argv[3], "confSha256": sys.argv[4] or None}))' \
  "$result" "${failed[*]+"${failed[*]}"}" "$ROTATION_KERNEL_VERSION" "$ROTATION_CONF_SHA256")
autorun_record_event doctor.result "doctor=raw:$summary"

if [ "$nfail" -eq 0 ]; then
  echo "DOCTOR PASS kernel=$ROTATION_KERNEL_VERSION conf=${ROTATION_CONF_SHA256:0:12}"
  exit 0
fi
echo "DOCTOR FAIL n=$nfail"
exit 1
