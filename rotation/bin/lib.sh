# rotation kernel — common bash helpers.
#
# Source me, don't run me:
#   . "$(dirname "$0")/lib.sh"
#
# Conventions:
#   - All paths absolute; never trust CWD (the kernel may be invoked from
#     anywhere — Stop hook, agent turn, operator shell).
#   - Zero external deps beyond macOS-built-in (python3 / shasum / git /
#     date / awk). No jq, no perl one-liners.
#   - Functions return strings via stdout; errors via stderr; exit codes
#     reserved for callers that explicitly opt in.
#   - The kernel knows no project. Everything project-specific arrives
#     through two files in the project's `.claude/rotation/`: `project.sh`
#     (commands and directories, sourced) and `rotation.conf` (plain
#     key=value: the thresholds, axes, stamp list, rules table). The kernel
#     itself lives in the plugin directory; the project reaches it through
#     the two-line shims `init.sh` writes beside those two files.

# shellcheck shell=bash

set -u

ROTATION_KERNEL_VERSION="1.1.2"

# ── Path discovery ──────────────────────────────────────────────────────
# AUTORUN_DIR = the kernel directory (this file's parent, the plugin's bin/).
# The project root is the git top level of the working directory the kernel
# is invoked from: a hook runs in the session's cwd, a shim in the operator's,
# and either may be a subdirectory of the repository (the hook environment's
# CLAUDE_PROJECT_DIR is that cwd, not the root, so it is not used). A
# self-test gives the root explicitly (ROTATION_PROJECT_DIR) and points it at
# a throwaway repository.
AUTORUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${ROTATION_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
CLAUDE_DIR="$PROJECT_DIR/.claude"
# the project's side of the contract: project.sh, rotation.conf, the shims, kernel.path
PROJECT_ROTATION_DIR="$CLAUDE_DIR/rotation"
# State is kept apart from the code so that replacing the kernel never
# touches what it recorded: rotations.jsonl, events.jsonl, manager.active and
# the archived handoffs live under ROTATION_STATE_DIR.
STATE_DIR="${ROTATION_STATE_DIR:-$CLAUDE_DIR/rotation-state}"
# Both logs and the handoff are overridable so the gates can be exercised
# against fixtures (see the self-tests) without touching production state.
# Unset in every real invocation. HARDEV_* are the older spellings.
ROTATIONS_LOG="${HARDEV_ROTATIONS_LOG:-${ROTATION_ROTATIONS_LOG:-$STATE_DIR/rotations.jsonl}}"
EVENTS_LOG="${HARDEV_EVENTS_LOG:-${ROTATION_EVENTS_LOG:-$STATE_DIR/events.jsonl}}"
EVENTS_LOG_DEFAULT="$STATE_DIR/events.jsonl"
MANAGER_ACTIVE_FILE="$STATE_DIR/manager.active"
INTENT_FILE="$CLAUDE_DIR/autorun-intent"
HANDOFF_FILE="${HARDEV_HANDOFF_FILE:-${ROTATION_HANDOFF_FILE:-$CLAUDE_DIR/handoff.md}}"

# ── Project adapter ─────────────────────────────────────────────────────
# project.sh: the ROTATION_* commands and directories the kernel calls out
# to (stamp dir, sweep line, axis reading, remote probe, after-write hook).
# Absent = kernel defaults. A self-test points this at /dev/null.
PROJECT_SH="${ROTATION_PROJECT_SH:-$PROJECT_ROTATION_DIR/project.sh}"
# shellcheck disable=SC1090
[ -f "$PROJECT_SH" ] && . "$PROJECT_SH"

# ── rotation.conf ───────────────────────────────────────────────────────
# The frozen configuration face: thresholds, axes, blacklist additions, the
# stamp list, the rules table, the kernel major it was written for. Only
# this file may set the keys below — the environment is cleared for them
# first, so a value cannot be slipped in from a shell. trigger.sh writes the
# effective values and the file's sha256 into every rotations.jsonl row.
ROTATION_CONF_FILE="${ROTATION_CONF:-$PROJECT_ROTATION_DIR/rotation.conf}"
ROTATION_CONF_ONLY_KEYS="ROTATION_TRIG1_MIN_COMMITS ROTATION_TRIG1_MIN_CLOSED ROTATION_TRIG2_MIN_WALL_SEC ROTATION_TRIG2_MAX_WALL_SEC ROTATION_TRIG2_MEASURE ROTATION_TRIG5_SAME_AXIS_MAX ROTATION_TRIG5_BENCH_MAX_AGE_DAYS ROTATION_COLD_START_WINDOW ROTATION_AXES ROTATION_BLACKLIST_EXTRA ROTATION_STAMPS ROTATION_AXIS_STAMP ROTATION_SWEEP_STAMP ROTATION_TRIGGER_SECTION ROTATION_TRIG8_GATE_COVERAGE ROTATION_TRIG1A_MODE ROTATION_TRIG2_MODE ROTATION_BOOTSTRAP_ROUNDS ROTATION_MESSAGES ROTATION_CONF_KERNEL ROTATION_CLOSE_CHECKS_OFF ROTATION_WAKE_AFTER"
ROTATION_CONF_SHA256=""
ROTATION_CONF_ERROR=""

autorun_load_conf() {
  local k line key val
  for k in $ROTATION_CONF_ONLY_KEYS; do unset "$k"; done
  if [ ! -f "$ROTATION_CONF_FILE" ]; then
    ROTATION_CONF_ERROR="no rotation.conf at $ROTATION_CONF_FILE"
    return
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) ROTATION_CONF_ERROR="not key=value: '$line' in $ROTATION_CONF_FILE"; return ;; esac
    key=$(printf '%s' "${line%%=*}" | tr -d '[:space:]')
    val=${line#*=}
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    case "$key" in
      ROTATION_[A-Z0-9_]*) ;;
      *) ROTATION_CONF_ERROR="key '$key' is not a ROTATION_* key ($ROTATION_CONF_FILE)"; return ;;
    esac
    # file and directory keys may be written relative to the project root
    case "$key" in
      ROTATION_CLOSE_RULES|ROTATION_STAMP_DIR|ROTATION_VERDICT_DIR|ROTATION_STAMP_HISTORY|ROTATION_HANDOFF_HISTORY|ROTATION_MESSAGES)
        case "$val" in /*|'') ;; *) val="$PROJECT_DIR/$val" ;; esac ;;
    esac
    export "$key=$val"
  done < "$ROTATION_CONF_FILE"
  ROTATION_CONF_SHA256=$(shasum -a 256 "$ROTATION_CONF_FILE" 2>/dev/null | awk '{print $1}')
  if [ -n "${ROTATION_CONF_KERNEL:-}" ] && [ "${ROTATION_CONF_KERNEL%%.*}" != "${ROTATION_KERNEL_VERSION%%.*}" ]; then
    ROTATION_CONF_ERROR="rotation.conf is written for kernel major ${ROTATION_CONF_KERNEL%%.*}, this kernel is $ROTATION_KERNEL_VERSION"
  fi
}
autorun_load_conf

# Derived from the conf (kernel defaults when the conf is silent).
# The handoff section the gates read, as an extended regex on the heading
# text: `rotate-trigger`; a project that writes the heading in its own words
# sets ROTATION_TRIGGER_SECTION in rotation.conf.
TRIGGER_SECTION_RE="${ROTATION_TRIGGER_SECTION:-rotate-trigger}"
# The axis letters as an alternation for grep -E (`A|B|C|D|E`).
AXES_ALT=$(printf '%s' "${ROTATION_AXES:-A,B,C,D,E}" | tr -d ' ' | tr ',' '|')
# where trigger.sh archives the handoff each new session starts from
HANDOFF_HISTORY="${ROTATION_HANDOFF_HISTORY:-$STATE_DIR/handoff}"

# The effective configuration as one JSON object (written into every
# rotations.jsonl row and the trigger.result event).
autorun_conf_json() {
  python3 - "$ROTATION_KERNEL_VERSION" "$ROTATION_CONF_SHA256" <<'PY'
import json, os, sys
env = os.environ
def num(k):
    v = env.get(k)
    try:
        return int(v) if v not in (None, "") else None
    except ValueError:
        return v
print(json.dumps({
    "kernel": sys.argv[1], "confSha256": sys.argv[2] or None,
    "trig1MinCommits": num("ROTATION_TRIG1_MIN_COMMITS"), "trig1MinClosed": num("ROTATION_TRIG1_MIN_CLOSED"),
    "trig2MinWallSec": num("ROTATION_TRIG2_MIN_WALL_SEC"), "trig2MaxWallSec": num("ROTATION_TRIG2_MAX_WALL_SEC"),
    "trig2Measure": env.get("ROTATION_TRIG2_MEASURE") or "trigger",
    "trig8GateCoverage": env.get("ROTATION_TRIG8_GATE_COVERAGE") or "off",
    "trig1aMode": env.get("ROTATION_TRIG1A_MODE") or "enforce", "trig2Mode": env.get("ROTATION_TRIG2_MODE") or "enforce",
    "bootstrapRounds": num("ROTATION_BOOTSTRAP_ROUNDS") if env.get("ROTATION_BOOTSTRAP_ROUNDS") else 20,
    "trig5SameAxisMax": num("ROTATION_TRIG5_SAME_AXIS_MAX"), "trig5AxisReadingMaxAgeDays": num("ROTATION_TRIG5_BENCH_MAX_AGE_DAYS"),
    "coldStartWindow": num("ROTATION_COLD_START_WINDOW"),
    "axes": env.get("ROTATION_AXES"), "stamps": env.get("ROTATION_STAMPS"),
    "axisStamp": env.get("ROTATION_AXIS_STAMP"), "sweepStamp": env.get("ROTATION_SWEEP_STAMP"),
    "closeRules": env.get("ROTATION_CLOSE_RULES"),
    "closeChecksOff": env.get("ROTATION_CLOSE_CHECKS_OFF") or None,
    "wakeAfterSec": num("ROTATION_WAKE_AFTER") if env.get("ROTATION_WAKE_AFTER") else 300,
}, ensure_ascii=False, separators=(",", ":")))
PY
}

# ── Identity ────────────────────────────────────────────────────────────
# rotation_id = r-<unix-ts>-<4 hex from $RANDOM>
# Unique enough: a session triggering more than once per second per
# project is operator error; the random suffix collapses the same-second
# case to 1/65536.
autorun_new_id() {
  local ts rnd
  ts=$(date +%s)
  rnd=$(printf '%04x' $(( RANDOM & 0xffff )))
  printf 'r-%s-%s\n' "$ts" "$rnd"
}

# RFC-3339 UTC timestamp, no deps.
autorun_now_iso() {
  date -u +'%Y-%m-%dT%H:%M:%SZ'
}

# ── Project state probes ────────────────────────────────────────────────
# The name rows in rotations.jsonl are filtered by. Defaults to the
# directory name; a project whose checkout is named differently sets
# ROTATION_PROJECT_NAME (project.sh or rotation.conf).
autorun_project_name() {
  printf '%s\n' "${ROTATION_PROJECT_NAME:-$(basename "$PROJECT_DIR")}"
}

autorun_git_head() {
  git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown
}

# Returns mtime-age in seconds, or empty string if file missing.
autorun_file_age_sec() {
  local f=$1
  if [ ! -f "$f" ]; then
    echo ""
    return
  fi
  local mtime now
  mtime=$(stat -f %m "$f" 2>/dev/null) || { echo ""; return; }
  now=$(date +%s)
  echo $(( now - mtime ))
}

autorun_handoff_sha() {
  if [ ! -f "$HANDOFF_FILE" ]; then
    echo ""
    return
  fi
  local sum
  sum=$(shasum -a 256 "$HANDOFF_FILE" 2>/dev/null | awk '{print $1}')
  [ -n "$sum" ] && printf 'sha256:%s\n' "$sum" || echo ""
}

# Read the gate triple `N/F/S` from the handoff's rotate-trigger section
# `gate:` line (part of the TRIG-3 contract). Empty when the line is
# absent — never fabricated.
#
# 2026-09-07: this used to probe a memory-file layout two profile
# generations old, returned "" on every call, and the jsonl field was null
# in every row since. A probe aimed at a world that no longer exists fails
# in exactly the shape of "this rotation had no data". The source is now a
# line the agent writes by hand in the very section TRIG-3 already
# validates: a measured value with an owner.
autorun_gate_triple_now() {
  autorun_handoff_trigger_section \
    | grep -oE '^[[:space:]]*gate:[[:space:]]*[0-9]+/[0-9]+/[0-9]+' \
    | head -1 \
    | grep -oE '[0-9]+/[0-9]+/[0-9]+'
}

# ── JSON line emit ──────────────────────────────────────────────────────
# Build a JSON object literal via Python (macOS ships python3); this
# guarantees correct escaping for the handoff sha / project name / etc.
# Args are key=value pairs; values are emitted as strings unless they
# match an explicit `int:` / `null:` / `raw:` prefix.
autorun_emit_jsonl() {
  python3 - "$@" <<'PY'
import json, sys
out = {}
for arg in sys.argv[1:]:
    if "=" not in arg:
        continue
    k, v = arg.split("=", 1)
    if v == "" or v == "null":
        out[k] = None
    elif v.startswith("int:"):
        try:
            out[k] = int(v[4:])
        except ValueError:
            out[k] = None
    elif v.startswith("raw:"):
        # Already valid JSON literal (e.g. nested object); paste through.
        try:
            out[k] = json.loads(v[4:])
        except ValueError:
            out[k] = v[4:]
    else:
        out[k] = v
print(json.dumps(out, ensure_ascii=False, separators=(",", ":")))
PY
}

# The rotation now in progress: the intent file when one is pending, else
# the id of the last row in rotations.jsonl (every trigger opens the next
# session under the id it just wrote). Empty on a cold start.
autorun_current_rotation_id() {
  local rid=""
  [ -f "$INTENT_FILE" ] && rid=$(head -1 "$INTENT_FILE" | tr -d '[:space:]')
  if [ -z "$rid" ] && [ -f "$ROTATIONS_LOG" ]; then
    rid=$(python3 - "$ROTATIONS_LOG" <<'PY'
import json, sys
last = ""
for line in open(sys.argv[1]):
    line = line.strip()
    if line:
        try:
            last = json.loads(line).get("rotationId") or last
        except json.JSONDecodeError:
            pass
print(last)
PY
)
  fi
  printf '%s\n' "$rid"
}

# The project's hook after state changed (a dashboard repack, say). Runs
# only when the events log is the production one — a self-test redirecting
# the log must not trigger project side effects. Never fails the caller.
autorun_after_write() {
  [ -n "${ROTATION_AFTER_WRITE_CMD:-}" ] || return 0
  [ "$EVENTS_LOG" = "$EVENTS_LOG_DEFAULT" ] || return 0
  sh -c "$ROTATION_AFTER_WRITE_CMD" >/dev/null 2>&1 || true
}

# Append one event to events.jsonl: kind, the rotation in progress, HEAD at
# this moment, and whatever k=v the caller adds (raw:{...} for nested JSON).
# Schema is append-only: keys are never renamed or removed.
autorun_record_event() {
  local kind=$1
  shift
  local line
  line=$(autorun_emit_jsonl \
    "at=$(autorun_now_iso)" \
    "ts=int:$(date +%s)" \
    "kind=$kind" \
    "rotationId=$(autorun_current_rotation_id)" \
    "head=$(autorun_git_head)" \
    "$@")
  mkdir -p "$(dirname "$EVENTS_LOG")"
  printf '%s\n' "$line" >> "$EVENTS_LOG"
  autorun_after_write
}

# Last `trigger=self` row for this project from rotations.jsonl, as
# `ts<TAB>prevHead`.  Empty when no such row exists (cold start).
# Single source of truth: trig_gate.sh sources this instead of carrying
# its own copy — two spellings of one query is how they drift apart.
autorun_last_self_row() {
  if [ ! -f "$ROTATIONS_LOG" ]; then
    echo ""
    return
  fi
  python3 - "$ROTATIONS_LOG" "$(autorun_project_name)" <<'PY'
import json, sys
log, project = sys.argv[1], sys.argv[2]
last = None
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
            last = r
except FileNotFoundError:
    pass
if last and last.get("ts") is not None and last.get("prevHead"):
    print(str(last["ts"]) + "\t" + last["prevHead"])
PY
}

# Commits in a range that the main session itself made. Work landed by a
# parallel agent carries an `Agent-Origin: <agent>` trailer and is not the
# main session's work, so it never counts toward TRIG-1 or `closed:`
# (2026-09-16: rotation task/commit counts recognise the main session
# only). Only the first-parent line is counted: a `--no-ff` merge brings
# its whole branch into the range, and one merge must not satisfy a
# commit floor by itself. The pattern is overridable so the self-test can
# exercise the exclusion against real history without writing commits.
AGENT_ORIGIN_PATTERN="${ROTATION_AGENT_ORIGIN_PATTERN:-${HARDEV_AGENT_ORIGIN_PATTERN:-^Agent-Origin:}}"

autorun_main_session_revs() {
  git -C "$PROJECT_DIR" rev-list --first-parent --invert-grep -E --grep="$AGENT_ORIGIN_PATTERN" "$1"
}

# Commit count for the current session: `<last self prevHead>..HEAD`.
# Empty on cold start or when git cannot answer — callers decide what an
# unknown means (TRIG-1 SKIPs it; the jsonl records null).
autorun_commits_since_last_self() {
  local row last_head revs
  row=$(autorun_last_self_row)
  [ -n "$row" ] || { echo ""; return; }
  last_head=$(printf '%s\n' "$row" | cut -f2)
  [ -n "$last_head" ] || { echo ""; return; }
  revs=$(autorun_main_session_revs "$last_head..HEAD" 2>/dev/null) || { echo ""; return; }
  printf '%s\n' "$revs" | grep -c .
}

# The two measures of the round that end at this moment, read from the
# events written since the last self row: `activeWallSec<TAB>managerCommits`,
# either field empty when unknown (callers record empty as null, never 0).
#
#   activeWallSec   now − ts of the round's latest `rotation.start`; without
#                   one, now − ts of the round's first `agent.start` whose
#                   agent.role is `rotation`; without either, unknown. The
#                   trigger-to-trigger wall counts the idle gap between the
#                   handover and the executor actually starting; this does not.
#   managerCommits  commits in <last self prevHead>..HEAD on the first-parent
#                   line, without an Agent-Origin trailer, whose committer
#                   time falls inside no executor's running interval. An
#                   interval is an `agent.start` with agent.role=rotation up
#                   to the next `agent.end` of the same agent name, or to now
#                   when no end was recorded; bounds are inclusive. What is
#                   left is work the main tree received from the manager (or
#                   anyone else) while no executor was running.
#
# The round's events are those with ts ≥ the last self row's ts. On a cold
# start (no self row) both are unknown.
autorun_round_measures() {
  local row last_ts last_head
  row=$(autorun_last_self_row)
  [ -n "$row" ] || { printf '\t\n'; return; }
  last_ts=$(printf '%s\n' "$row" | cut -f1)
  last_head=$(printf '%s\n' "$row" | cut -f2)
  python3 - "$EVENTS_LOG" "$last_ts" "$(date +%s)" "$PROJECT_DIR" "$last_head" "$AGENT_ORIGIN_PATTERN" <<'PY'
import json, subprocess, sys
log, round_ts, now, repo, prev, origin = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5], sys.argv[6]
events = []
try:
    with open(log) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(e.get("ts"), int) and e["ts"] >= round_ts:
                events.append(e)
except FileNotFoundError:
    pass
events.sort(key=lambda e: e["ts"])

# active wall
start_ts = None
for e in reversed(events):
    if e.get("kind") == "rotation.start":
        start_ts = e["ts"]
        break
if start_ts is None:
    for e in events:
        if e.get("kind") == "agent.start" and (e.get("agent") or {}).get("role") == "rotation":
            start_ts = e["ts"]
            break
active = str(now - start_ts) if start_ts is not None else ""

# executor running intervals
intervals, open_by_name = [], {}
for e in events:
    k = e.get("kind")
    a = e.get("agent") or {}
    if a.get("role") != "rotation":
        continue
    if k == "agent.start":
        if a.get("name") in open_by_name:
            intervals.append((open_by_name.pop(a["name"]), e["ts"]))
        open_by_name[a.get("name")] = e["ts"]
    elif k == "agent.end" and a.get("name") in open_by_name:
        intervals.append((open_by_name.pop(a["name"]), e["ts"]))
intervals += [(s, now) for s in open_by_name.values()]

r = subprocess.run(["git", "-C", repo, "rev-list", "--first-parent", "--invert-grep", "-E", f"--grep={origin}",
                    "--format=%ct", f"{prev}..HEAD"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
if r.returncode != 0:
    print(active + "\t")
    raise SystemExit
manager = 0
for line in r.stdout.split("\n"):
    if not line or line.startswith("commit "):
        continue
    ct = int(line)
    if not any(s <= ct <= e for s, e in intervals):
        manager += 1
print(active + "\t" + str(manager))
PY
}

# The `axis:` line from the handoff rotate-trigger section, normalised to
# uppercase comma-separated axis names (`A`, or `A,E`). Empty if absent or
# naming an axis outside ROTATION_AXES. TRIG-5 reads it back out of
# rotations.jsonl to see axis skew over time.
autorun_trigger_axis() {
  autorun_handoff_trigger_section \
    | grep -iE "^[[:space:]]*axis:[[:space:]]*($AXES_ALT)([[:space:]]*,[[:space:]]*($AXES_ALT))*[[:space:]]*\$" \
    | head -1 \
    | sed -E 's/^[[:space:]]*[Aa][Xx][Ii][Ss]:[[:space:]]*//; s/[[:space:]]//g' \
    | tr '[:lower:]' '[:upper:]'
}

# Extract the body of the handoff's rotate-trigger markdown section: lines
# between the `## ` heading matching TRIGGER_SECTION_RE and the next `## `
# heading. Empty if the section is absent or the handoff is missing. Used
# by TRIG-3 / TRIG-4 (trig_gate.sh) and by autorun_record_rotation.
autorun_handoff_trigger_section() {
  if [ ! -f "$HANDOFF_FILE" ]; then
    return
  fi
  awk -v re="^## .*($TRIGGER_SECTION_RE)" '
    $0 ~ re { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section { print }
  ' "$HANDOFF_FILE"
}

# Extract the closed-enum letter from the `reason: <a|b|c|d>` line inside
# the handoff trigger section. Outputs single lowercase letter or empty.
autorun_trigger_reason() {
  autorun_handoff_trigger_section \
    | grep -iE '^[[:space:]]*reason:[[:space:]]*[abcd][[:space:]]*$' \
    | head -1 \
    | awk '{ gsub(/[[:space:]]/, ""); sub(/^[Rr][Ee][Aa][Ss][Oo][Nn]:/, ""); print tolower($0) }'
}

# Append a rotation line to rotations.jsonl. Creates the file on first
# write. trigger= self | manual | hook | daemon (future). triggerReason
# is best-effort from handoff; null when absent (manual triggers may
# legitimately have no handoff reason). The effective configuration goes
# into the same row (kernelVersion / confSha256 / thresholds; schema is
# append-only).
autorun_record_rotation() {
  local rotation_id=$1
  local trigger=$2
  local at ts head handoff_sha handoff_age conf reason axis commits

  at=$(autorun_now_iso)
  ts=$(date +%s)
  head=$(autorun_git_head)
  handoff_sha=$(autorun_handoff_sha)
  handoff_age=$(autorun_file_age_sec "$HANDOFF_FILE")
  conf=$(autorun_gate_triple_now)
  reason=$(autorun_trigger_reason)
  axis=$(autorun_trigger_axis)
  # 2026-09-07: `commitsInSession` was the literal string "null" here —
  # hardcoded, never once populated across 909 rows, while trig_gate.sh
  # computed exactly this number on every single call and discarded it.
  commits=$(autorun_commits_since_last_self)
  # the round's active wall and the commits no executor accounts for (null when unknown)
  local measures active_wall manager_commits
  measures=$(autorun_round_measures)
  active_wall=$(printf '%s\n' "$measures" | cut -f1)
  manager_commits=$(printf '%s\n' "$measures" | cut -f2)

  local line
  line=$(autorun_emit_jsonl \
    "rotationId=$rotation_id" \
    "at=$at" \
    "ts=int:$ts" \
    "project=$(autorun_project_name)" \
    "trigger=$trigger" \
    "prevHead=$head" \
    "handoffSha=$handoff_sha" \
    "handoffAgeSec=${handoff_age:+int:$handoff_age}" \
    "conformanceBefore=$conf" \
    "commitsInSession=${commits:+int:$commits}" \
    "axis=$axis" \
    "triggerReason=$reason" \
    "kernelVersion=$ROTATION_KERNEL_VERSION" \
    "confSha256=$ROTATION_CONF_SHA256" \
    "thresholds=raw:$(autorun_conf_json)" \
    "activeWallSec=${active_wall:+int:$active_wall}" \
    "managerCommits=${manager_commits:+int:$manager_commits}")

  mkdir -p "$(dirname "$ROTATIONS_LOG")"
  printf '%s\n' "$line" >> "$ROTATIONS_LOG"
}
