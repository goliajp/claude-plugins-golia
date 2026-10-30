#!/usr/bin/env bash
#
# rotation kernel — lanes: a second instance of the protocol in one project.
#
# A throwaway repository wired as the main lane and as lane `b`:
#   init.sh --lane     the lane's shims export the lane and resolve the root three levels up; the lane's
#                      conf / project.sh / rules are copies of the main lane's; the handoff is created
#   isolation          an event through the lane's shim lands in the lane's state with "lane":"b" and
#                      the main lane's events.jsonl is not touched; a main-lane event carries no lane
#   stop_hook          the main lane's hook (no ROTATION_LANE) consumes a lane's intent through the
#                      lane child, and the main lane's intent is judged on its own
#   subagent_stop_hook an agent registered in the lane's events gets its agent.end in the lane's
#                      events, written by the main lane's hook
#   lane_enter.sh      inside a worktree: .claude/ is a directory of links (own worktrees/, handoff
#                      → the lane's), the shared directory is linked, a shim through the links resolves
#                      the project root to the worktree (the event's head is the worktree's HEAD);
#                      refused on the main tree
#
# exit: 0 every case passed · 1 otherwise

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KBIN="$ROOT/bin"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/     | /'; }
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$3] got [$2]"; fi; }
expect_has() { if printf '%s\n' "$2" | grep -qE -- "$3"; then ok "$1"; else bad "$1 (wanted /$3/)" "$2"; fi; }

# physical paths throughout: lane_enter.sh derives the main tree from git, which gives the
# physical path (/private/var vs /var on macOS), and the links must compare equal to it
TMP=$(cd "$TMP" && pwd -P)
REPO="$TMP/repo"
mkdir -p "$REPO"
g() { git -C "$REPO" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
g init -q -b develop
printf '.claude/\n.dev/\n' > "$REPO/.gitignore"
echo a > "$REPO/a.txt"; g add -A; g commit -q -m "feat: first"
SHA=$(g rev-parse --short HEAD)
mkdir -p "$REPO/.dev"; echo tool > "$REPO/.dev/tool.txt"

# ── init: main lane, then lane b ─────────────────────────────────────────
(cd "$REPO" && CLAUDE_PLUGIN_ROOT="$ROOT" bash "$KBIN/init.sh" >/dev/null 2>&1)
out=$(cd "$REPO" && CLAUDE_PLUGIN_ROOT="$ROOT" bash "$KBIN/init.sh" --lane b 2>&1); rc=$?
expect_eq "init --lane: exit 0" "$rc" 0
LANE="$REPO/.claude/rotation-lanes/b"
expect_eq "init --lane: shims, conf, project.sh, rules, handoff present" \
  "$(for f in event.sh trigger.sh doctor.sh lib.sh rotation.conf project.sh close_rules.tsv handoff.md; do [ -e "$LANE/$f" ] && printf 1 || printf 0; done)" "11111111"
expect_has "init --lane: the shim exports the lane" "$(cat "$LANE/event.sh")" '^export ROTATION_LANE=b$'
expect_has "init --lane: the shim's root is three levels up" "$(cat "$LANE/event.sh")" 'cd "\$d/\.\./\.\./\.\."'
expect_has "init --lane: the shim reads the main lane's kernel.path" "$(cat "$LANE/event.sh")" 'rotation/kernel\.path'
expect_eq "init --lane: conf copied from the main lane's" "$(cmp -s "$LANE/rotation.conf" "$REPO/.claude/rotation/rotation.conf" && echo same)" same
expect_eq "init --lane: the lane's state directory exists" "$([ -d "$REPO/.claude/rotation-state/lanes/b" ] && echo yes)" yes
out=$(cd "$REPO" && CLAUDE_PLUGIN_ROOT="$ROOT" bash "$KBIN/init.sh" --lane 'B ad' 2>&1); rc=$?
expect_eq "init --lane: a bad lane name is refused (exit 2)" "$rc" 2
out=$(cd "$REPO" && ROTATION_LANE=b bash -c '. .claude/rotation/lib.sh 2>&1; echo "$PROJECT_ROTATION_DIR|$STATE_DIR|$HANDOFF_FILE|$INTENT_FILE"')
expect_eq "lib.sh with ROTATION_LANE: every path follows the lane" "$out" \
  "$LANE|$REPO/.claude/rotation-state/lanes/b|$LANE/handoff.md|$LANE/autorun-intent"
out=$(cd "$REPO" && bash -c '. .claude/rotation/lib.sh 2>&1; echo "$PROJECT_ROTATION_DIR|$STATE_DIR|$HANDOFF_FILE|$INTENT_FILE"')
expect_eq "lib.sh without ROTATION_LANE: the single-lane layout" "$out" \
  "$REPO/.claude/rotation|$REPO/.claude/rotation-state|$REPO/.claude/handoff.md|$REPO/.claude/autorun-intent"
out=$(cd "$REPO" && ROTATION_LANE='x y' bash -c '. .claude/rotation/lib.sh' 2>&1); rc=$?
expect_eq "lib.sh: a bad lane name exits 2" "$rc" 2

# ── isolation of the event logs ──────────────────────────────────────────
(cd "$REPO" && bash .claude/rotation-lanes/b/event.sh harness.note note.kind=in-lane >/dev/null 2>&1)
(cd "$REPO" && bash .claude/rotation/event.sh harness.note note.kind=in-main >/dev/null 2>&1)
LEV="$REPO/.claude/rotation-state/lanes/b/events.jsonl"
MEV="$REPO/.claude/rotation-state/events.jsonl"
expect_eq "lane event: in the lane's log, tagged with the lane" "$(grep -c '"kind":"harness.note".*"lane":"b".*in-lane' "$LEV")" 1
expect_eq "lane event: not in the main lane's log" "$(grep -c 'in-lane' "$MEV")" 0
expect_eq "main event: in the main lane's log, no lane field" "$(grep -c 'in-main' "$MEV"):$(grep -c '"lane"' "$MEV")" "1:0"

# ── hooks: the main lane's hook serves the lanes ─────────────────────────
henv() { ( cd "$REPO" && env CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$REPO" CLAUDE_CODE_SESSION_ID=sess-L "$@" ); }
stop_payload() { printf '{"session_id":"s1","hook_event_name":"Stop","stop_hook_active":false}'; }
# the lane's intent with a handoff that passes INV-1..5, the main lane with none
printf 'r-lane-1\n' > "$LANE/autorun-intent"
printf '# lane handoff\n\nHEAD %s\n\n## rotate-trigger\n\naxis: A\nclosed: %s first\ngate: 1/0/0\n' "$SHA" "$SHA" > "$LANE/handoff.md"
printf '{"rotationId":"r-lane-1","ts":1,"trigger":"self","project":"repo","prevHead":"%s"}\n' "$SHA" > "$REPO/.claude/rotation-state/lanes/b/rotations.jsonl"
out=$(stop_payload | henv bash "$KBIN/stop_hook.sh" 2>&1); rc=$?
expect_eq "stop hook (main lane): exit 0" "$rc" 0
expect_has "stop hook: the lane's intent is judged by the lane child" "$out" 'rotation r-lane-1 (green|blocked)'
[ -e "$LANE/autorun-intent" ] && lane_intent=kept || lane_intent=consumed
expect_has "stop hook: the lane's verdict matches what happened to its intent" "$out $lane_intent" '(green.*consumed|blocked.*kept)'
[ -e "$REPO/.claude/autorun-intent" ] && bad "stop hook: a main-lane intent appeared" || ok "stop hook: the main lane has no intent and none was made"
# a registered lane agent: the main lane's hook writes its agent.end into the lane's events
(cd "$REPO" && ROTATION_AGENT_ID=ag-lane-w1 bash .claude/rotation-lanes/b/agent_log.sh start w-lane worker opus "lane work" >/dev/null 2>&1)
payload() { printf '{"session_id":"s1","hook_event_name":"SubagentStop","agent_id":"%s","agent_type":"general-purpose","agent_transcript_path":"/t/%s.jsonl"}' "$1" "$1"; }
out=$(payload ag-lane-w1 | henv bash "$KBIN/subagent_stop_hook.sh" 2>&1); rc=$?
expect_eq "subagent stop hook (main lane): exit 0" "$rc" 0
expect_eq "subagent stop hook: the lane agent's end is in the lane's events" "$(grep -c '"kind":"agent.end".*ag-lane-w1' "$LEV")" 1
expect_eq "subagent stop hook: nothing about it in the main lane's events" "$(grep -c 'ag-lane-w1' "$MEV")" 0
out=$(payload ag-lane-w1 | henv bash "$KBIN/subagent_stop_hook.sh" 2>&1)
expect_eq "subagent stop hook: a second stop writes no second end" "$(grep -c '"kind":"agent.end".*ag-lane-w1' "$LEV")" 1

# ── lane_enter.sh in a worktree ─────────────────────────────────────────
printf 'ROTATION_LANE_SHARED_DIRS=.dev\n' >> "$LANE/rotation.conf"
WT="$TMP/wt"
g worktree add -q -b lane/b "$WT" develop
echo b > "$WT/b.txt"; git -C "$WT" -c user.name=t -c user.email=t@t -c commit.gpgsign=false add -A
git -C "$WT" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m "feat: lane work"
WSHA=$(git -C "$WT" rev-parse --short HEAD)
out=$(cd "$REPO" && bash "$KBIN/lane_enter.sh" b 2>&1); rc=$?
expect_eq "lane_enter on the main tree: refused (exit 1)" "$rc" 1
out=$(cd "$WT" && bash "$KBIN/lane_enter.sh" b 2>&1); rc=$?
expect_eq "lane_enter in the worktree: exit 0" "$rc" 0
expect_eq "lane_enter: .claude is a directory of its own with its own worktrees/" \
  "$([ -d "$WT/.claude" ] && [ ! -L "$WT/.claude" ] && [ -d "$WT/.claude/worktrees" ] && [ ! -L "$WT/.claude/worktrees" ] && echo yes)" yes
expect_eq "lane_enter: rotation/, rotation-lanes/, rotation-state/ are links to the main tree's" \
  "$(for d in rotation rotation-lanes rotation-state; do [ "$(readlink "$WT/.claude/$d")" = "$REPO/.claude/$d" ] && printf 1 || printf 0; done)" 111
expect_eq "lane_enter: handoff.md links to the lane's handoff" "$(readlink "$WT/.claude/handoff.md")" "$LANE/handoff.md"
[ -e "$WT/.claude/autorun-intent" ] && bad "lane_enter: the main lane's intent was linked" || ok "lane_enter: no autorun-intent link"
expect_eq "lane_enter: the shared directory from the conf is linked" "$(readlink "$WT/.dev")" "$REPO/.dev"
out=$(cd "$WT" && bash "$KBIN/lane_enter.sh" b 2>&1); rc=$?
expect_has "lane_enter: idempotent (0 links the second time)" "$out" ' 0 link\(s\) made'
(cd "$WT" && bash .claude/rotation-lanes/b/event.sh harness.note note.kind=from-wt >/dev/null 2>&1)
expect_eq "a shim through the links: the event's head is the worktree's HEAD, in the lane's log" \
  "$(grep 'from-wt' "$LEV" | grep -c "\"head\":\"$WSHA\"")" 1
out=$(cd "$WT" && bash -c '. .claude/rotation-lanes/b/lib.sh 2>&1; echo "$PROJECT_DIR"')
expect_eq "lib.sh through the links: the project root is the worktree" "$out" "$WT"

echo "lanes_self_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
