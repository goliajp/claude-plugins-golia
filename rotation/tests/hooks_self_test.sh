#!/usr/bin/env bash
#
# rotation kernel — the three hook scripts against a throwaway project.
#
# A temporary repository (the hooks resolve the project root from their
# working directory, as Claude Code runs them — a subdirectory here, with
# CLAUDE_PROJECT_DIR pointing at that same subdirectory, as the platform sets
# it), a throwaway state directory, and the hook payloads written by hand in
# the shape the platform sends:
#   session_start_hook.sh   writes kernel.path under the git top level (never under the cwd) on startup
#                           and on resume; prints the recovery page only on resume while manager.active
#                           exists, and the page's last action follows the session id (RESUME from the
#                           session that registered the executor, RESPAWN from another); writes nothing
#                           in a project that has no .claude/rotation/
#   subagent_stop_hook.sh   a registered executor's id → agent.stop; a registered worker's id → one
#                           agent.end (not a second one); an unknown id → nothing
#   stop_hook.sh            no intent → exit 0 and no event; an intent with a dirty tree → kept (INV-2
#                           red); an intent with a clean tree → consumed
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
kinds() { [ -f "$1" ] && python3 -c 'import json,sys; print(" ".join(json.loads(l)["kind"] for l in open(sys.argv[1]) if l.strip()))' "$1" || echo "(none)"; }

REPO="$TMP/repo"; STATE="$TMP/state"; PLUGIN="$TMP/plugin"
mkdir -p "$REPO/.claude/rotation" "$REPO/sub" "$STATE" "$PLUGIN"
g() { git -C "$REPO" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
g init -q -b develop
printf '.claude/\n' > "$REPO/.gitignore"
echo a > "$REPO/a.txt"; g add -A; g commit -q -m "feat: first"
SHA=$(g rev-parse --short HEAD)
EV="$STATE/events.jsonl"
# the hooks run in the session's cwd — a subdirectory here, and CLAUDE_PROJECT_DIR is that cwd, as the
# platform sets it — to show the root comes from git; SESSION is the session's id (CLAUDE_CODE_SESSION_ID)
SESSION=sess-A
henv() { ( cd "$REPO/sub" && env ROTATION_STATE_DIR="$STATE" ROTATION_CONF=/dev/null ROTATION_PROJECT_SH=/dev/null CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PROJECT_DIR="$REPO/sub" CLAUDE_CODE_SESSION_ID="$SESSION" "$@" ); }

# ── session start: kernel.path on every start, the page on resume only ──
out=$(printf '{"session_id":"s1","hook_event_name":"SessionStart","source":"startup"}' | henv bash "$KBIN/session_start_hook.sh"); rc=$?
expect_eq "startup: exit 0" "$rc" 0
expect_eq "startup: kernel.path holds CLAUDE_PLUGIN_ROOT" "$(cat "$REPO/.claude/rotation/kernel.path")" "$PLUGIN"
expect_eq "startup: prints nothing" "$out" ""
[ -e "$REPO/sub/.claude" ] && bad "startup: wrote under CLAUDE_PROJECT_DIR (the cwd) instead of the git top level" || ok "startup: nothing under the cwd — the root is the git top level, not CLAUDE_PROJECT_DIR"
printf 'rotation=r-1 executor=rot id=ag-1 since=x session=s0\n' > "$STATE/manager.active"
out=$(printf '{"session_id":"s1","hook_event_name":"SessionStart","source":"startup"}' | henv bash "$KBIN/session_start_hook.sh")
expect_eq "startup with the manager marker: still silent" "$out" ""
out=$(printf '{"session_id":"s1","hook_event_name":"SessionStart","source":"resume","seconds_since_last_response":24}' | henv bash "$KBIN/session_start_hook.sh")
expect_has "resume with the marker: the recovery page" "$out" '^== rotation manager was active'
expect_has "resume: the page ends with the action line" "$out" '== act on the last line above'
rm "$STATE/manager.active"
out=$(printf '{"source":"resume"}' | henv bash "$KBIN/session_start_hook.sh")
expect_eq "resume without the marker: silent" "$out" ""
rm "$REPO/.claude/rotation/kernel.path"
echo "/old/plugin" > "$REPO/.claude/rotation/kernel.path"
printf '{"source":"startup"}' | henv bash "$KBIN/session_start_hook.sh" >/dev/null
expect_eq "a new start replaces a stale kernel.path" "$(cat "$REPO/.claude/rotation/kernel.path")" "$PLUGIN"
# a project that never ran init.sh gets no kernel.path
rm -r "$REPO/.claude/rotation"
out=$(printf '{"source":"startup"}' | henv bash "$KBIN/session_start_hook.sh"); rc=$?
expect_eq "no .claude/rotation/: exit 0" "$rc" 0
[ -e "$REPO/.claude/rotation/kernel.path" ] && bad "no .claude/rotation/: nothing written" || ok "no .claude/rotation/: nothing written"
mkdir -p "$REPO/.claude/rotation"

# ── subagent stop: registered ids are put on record ────────────────────
: > "$EV"
ROTATION_AGENT_ID=ag-exec henv bash "$KBIN/agent_log.sh" start rot-1 rotation m "the round" >/dev/null
ROTATION_AGENT_ID=ag-w1 henv bash "$KBIN/agent_log.sh" start w1 worker m "a task" >/dev/null
expect_eq "fixture: start events" "$(kinds "$EV")" "agent.start rotation.start agent.start"
payload() { printf '{"session_id":"s1","hook_event_name":"SubagentStop","agent_id":"%s","agent_type":"general-purpose","agent_transcript_path":"/t/%s.jsonl","last_assistant_message":"done"}' "$1" "$1"; }
out=$(payload ag-nobody | henv bash "$KBIN/subagent_stop_hook.sh"); rc=$?
expect_eq "unknown id: exit 0" "$rc" 0
expect_eq "unknown id: nothing recorded" "$(kinds "$EV")" "agent.start rotation.start agent.start"
out=$(payload ag-w1 | henv bash "$KBIN/subagent_stop_hook.sh"); rc=$?
expect_eq "worker id: exit 0" "$rc" 0
expect_eq "worker id: agent.end recorded" "$(kinds "$EV")" "agent.start rotation.start agent.start agent.end"
expect_eq "worker agent.end names the worker, status ok, the hook as its source" \
  "$(tail -1 "$EV" | python3 -c 'import json,sys; e=json.load(sys.stdin); a=e["agent"]; print(a["name"], a["role"], a["id"], a["status"], e["hook"]["event"], e["hook"]["agentType"])')" \
  "w1 worker ag-w1 ok SubagentStop general-purpose"
payload ag-w1 | henv bash "$KBIN/subagent_stop_hook.sh" >/dev/null
expect_eq "worker id again: no second agent.end" "$(kinds "$EV")" "agent.start rotation.start agent.start agent.end"
out=$(payload ag-exec | henv bash "$KBIN/subagent_stop_hook.sh"); rc=$?
expect_eq "executor id: exit 0" "$rc" 0
expect_eq "executor id: agent.stop recorded" "$(kinds "$EV")" "agent.start rotation.start agent.start agent.end agent.stop"
expect_eq "agent.stop names the executor" \
  "$(tail -1 "$EV" | python3 -c 'import json,sys; e=json.load(sys.stdin); a=e["agent"]; print(a["name"], a["role"], a["id"], e["hook"]["transcript"])')" \
  "rot-1 rotation ag-exec /t/ag-exec.jsonl"
payload ag-exec | henv bash "$KBIN/subagent_stop_hook.sh" >/dev/null
expect_eq "executor id again (a SendMessage reply): a second agent.stop" "$(kinds "$EV")" "agent.start rotation.start agent.start agent.end agent.stop agent.stop"
# the watchdog reads the hook's agent.end as the worker being done
henv bash "$KBIN/event.sh" executor.waiting workers=list:w1 >/dev/null
out=$(henv bash "$KBIN/watchdog.sh" --once --wake 0); rc=$?
expect_eq "watchdog: the hook's agent.end satisfies the wait → WAKE (10)" "$rc" 10
expect_has "watchdog names the wake" "$out" '^WAKE'
# no events file at all: silent
out=$(payload ag-w1 | env ROTATION_STATE_DIR="$TMP/empty-state" ROTATION_PROJECT_DIR="$REPO" ROTATION_CONF=/dev/null ROTATION_PROJECT_SH=/dev/null bash "$KBIN/subagent_stop_hook.sh"); rc=$?
expect_eq "no events.jsonl: exit 0, nothing written" "$rc $([ -e "$TMP/empty-state/events.jsonl" ] && echo yes || echo no)" "0 no"

# ── session start on resume: the page's action follows the session id ──
# rot-1 (ag-exec) is still registered as running, from sess-A (henv's default); agent_log.sh wrote the marker
expect_has "fixture: the marker names the executor and sess-A" "$(cat "$STATE/manager.active")" 'executor=rot-1 id=ag-exec since=.* session=sess-A$'
out=$(printf '{"source":"resume"}' | henv bash "$KBIN/session_start_hook.sh")
expect_eq "resume in the session that registered the executor: the page ends in RESUME" "$(printf '%s\n' "$out" | tail -2 | head -1)" "RESUME ag-exec"
out=$(printf '{"source":"resume"}' | SESSION=sess-B henv bash "$KBIN/session_start_hook.sh")
expect_eq "resume in another session: RESPAWN, the executor is a leftover" "$(printf '%s\n' "$out" | tail -2 | head -1)" "RESPAWN executor leftover=executor:rot-1(ag-exec,mismatch)"
expect_has "the page states both ids" "$out" '^executor session: registered=sess-A current=sess-B → mismatch$'
out=$(printf '{"source":"resume"}' | SESSION= henv bash "$KBIN/session_start_hook.sh")
expect_eq "resume with no session id: RESPAWN, no-session" "$(printf '%s\n' "$out" | tail -2 | head -1)" "RESPAWN executor leftover=executor:rot-1(ag-exec,no-session)"

# ── stop: no intent → nothing ──────────────────────────────────────────
stop_payload() { printf '{"session_id":"s1","hook_event_name":"Stop","stop_hook_active":false}'; }
n=$(grep -c . "$EV")
out=$(stop_payload | henv bash "$KBIN/stop_hook.sh" 2>&1); rc=$?
expect_eq "stop without an intent: exit 0, silent" "$rc [$out]" "0 []"
expect_eq "stop without an intent: no event" "$(grep -c . "$EV")" "$n"

# ── stop: with an intent pending, INV-1..5 decide whether it is consumed ─
INTENT="$REPO/.claude/autorun-intent"
printf 'r-hook-1\n' > "$INTENT"
printf '# handoff\n\nHEAD %s\n\n## rotate-trigger\n\naxis: A\nclosed: %s first\ngate: 1/0/0\n' "$SHA" "$SHA" > "$REPO/.claude/handoff.md"
echo x > "$REPO/sub/stray.txt"
out=$(stop_payload | henv bash "$KBIN/stop_hook.sh" 2>&1); rc=$?
expect_eq "stop with an intent and a dirty tree: exit 0" "$rc" 0
expect_has "red: INV-2 names the dirty tree" "$out" '^INV-2 FAIL tree dirty: 1 entry$'
expect_has "red: the intent is kept" "$out" '^stop_hook: rotation r-hook-1 blocked by INV check · intent kept$'
expect_eq "red: the intent file is still there" "$(cat "$INTENT")" "r-hook-1"
rm "$REPO/sub/stray.txt"
out=$(stop_payload | henv bash "$KBIN/stop_hook.sh" 2>&1); rc=$?
expect_eq "stop with an intent and a clean tree: exit 0" "$rc" 0
expect_has "green: INV-1..5 pass" "$out" '^stop_hook: rotation r-hook-1 green · INV-1..5 pass · intent consumed$'
[ -e "$INTENT" ] && bad "green: the intent file remains" || ok "green: the intent file is gone"
expect_eq "stop wrote no event" "$(grep -c . "$EV")" "$n"

echo
echo "hooks_self_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
