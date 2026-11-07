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
#   init.sh --from     copies a lane's three files with that lane's name replaced in every spelling that
#                      names it, prints the count; an unknown source lane is exit 1, --from without --lane exit 2
#   lanes.sh           one line per lane (first lane first, named), branch / rid / executors; --json an array
#   --all              doctor / recover / watchdog run every lane under `== lane <name> ==`, exit = the highest
#   lane_close.sh      in the lane's worktree: merge the base, the hook, the trigger (stubbed), the tag, the inbox
#                      row, lane.ready; refused off the lane's branch; a blocked trigger tags nothing; a conflict
#                      exits 3 naming the file
#   lane_merge.sh      merge.start / merge.end around a --no-ff merge of the tag; a conflict exits 3 and records
#                      status conflict; --returned records lane.returned and writes the inbox row
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
expect_not() { if printf '%s\n' "$2" | grep -qE -- "$3"; then bad "$1 (/$3/ present)" "$2"; else ok "$1"; fi; }

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

# ── cold start: the first executor of a lane gets a round id before any row exists ─
LANE2="$REPO/.claude/rotation-lanes/c"
(cd "$REPO" && CLAUDE_PLUGIN_ROOT="$ROOT" bash "$KBIN/init.sh" --lane c >/dev/null 2>&1)
out=$(cd "$REPO" && ROTATION_AGENT_ID=ag-c1 CLAUDE_CODE_SESSION_ID=s bash .claude/rotation-lanes/c/agent_log.sh start c-01 rotation opus "first" 2>&1)
CEV="$REPO/.claude/rotation-state/lanes/c/events.jsonl"
crid=$(cat "$REPO/.claude/rotation-state/lanes/c/rotation.current" 2>/dev/null)
expect_has "cold start: agent_log minted a round id" "$crid" '^r-[0-9]+-[0-9a-f]{4}$'
expect_eq "cold start: rotation.start carries that id" "$(grep -c "\"kind\":\"rotation.start\".*\"rotationId\":\"$crid\"" "$CEV")" 1
expect_eq "cold start: autorun_current_rotation_id answers it" "$(cd "$REPO" && ROTATION_LANE=c bash -c '. .claude/rotation/lib.sh; autorun_current_rotation_id')" "$crid"
printf '{"rotationId":"r-9-abcd","ts":2,"trigger":"self","project":"repo","prevHead":"x"}\n' > "$REPO/.claude/rotation-state/lanes/c/rotations.jsonl"
expect_eq "once a row exists the row wins over rotation.current" "$(cd "$REPO" && ROTATION_LANE=c bash -c '. .claude/rotation/lib.sh; autorun_current_rotation_id')" "r-9-abcd"
LANE3="$REPO/.claude/rotation-lanes/d"
(cd "$REPO" && CLAUDE_PLUGIN_ROOT="$ROOT" bash "$KBIN/init.sh" --lane d >/dev/null 2>&1)
(cd "$REPO" && ROTATION_ROTATION_ID=r-1793403061-ead6 ROTATION_AGENT_ID=ag-d1 bash .claude/rotation-lanes/d/agent_log.sh start d-01 rotation opus "adopt" >/dev/null 2>&1)
expect_eq "cold start: ROTATION_ROTATION_ID is adopted" "$(cat "$REPO/.claude/rotation-state/lanes/d/rotation.current")" "r-1793403061-ead6"
out=$(cd "$REPO" && ROTATION_ROTATION_ID=bogus ROTATION_AGENT_ID=ag-d2 bash .claude/rotation-lanes/d/agent_log.sh start d-02 rotation opus "bad" 2>&1); rc=$?
expect_eq "cold start: a malformed ROTATION_ROTATION_ID is refused only when still cold (here a marker exists: accepted)" "$rc" 0
expect_eq "main lane: no rotation.current is ever written while rows exist" "$([ -e "$REPO/.claude/rotation-state/rotation.current" ] && echo yes || echo no)" no

# ── a lane driven from the main tree is judged at its branch, not at the main tree's HEAD ─
printf 'export ROTATION_BASE_BRANCH=lane/b\n' >> "$LANE/project.sh"
echo c > "$REPO/c.txt"; g add -A; g commit -q -m "feat: main lane moves on"
MSHA=$(g rev-parse --short HEAD)
expect_eq "autorun_git_head in lane mode from the main tree: the lane branch's head" "$(cd "$REPO" && ROTATION_LANE=b bash -c '. .claude/rotation/lib.sh; autorun_git_head')" "$WSHA"

# ── event.sh refuses to write the first lane's log from inside a lane's tree ─
out=$(cd "$WT" && bash .claude/rotation/event.sh harness.note note.kind=guard-wt 2>&1); rc=$?
expect_eq "event.sh in lane b's worktree without ROTATION_LANE: refused (exit 2)" "$rc" 2
expect_has "the refusal names the lane's shim" "$out" "run it through the lane's shim .claude/rotation-lanes/b/event.sh"
expect_eq "nothing written to either log" "$(grep -c 'guard-wt' "$MEV" "$LEV" | awk -F: '{s += $2} END {print s}')" 0
out=$(cd "$WT" && bash "$KBIN/event.sh" harness.note note.kind=guard-wt 2>&1); rc=$?
expect_eq "the kernel's event.sh called by path from the worktree: refused too" "$rc" 2
mkdir -p "$REPO/.claude/lanes/b/sub"
out=$(cd "$REPO/.claude/lanes/b/sub" && bash "$KBIN/event.sh" harness.note note.kind=guard-dir 2>&1); rc=$?
expect_eq "a directory under .claude/lanes/b/: refused" "$rc:$(grep -c 'guard-dir' "$MEV")" "2:0"
rm -rf "$REPO/.claude/lanes"
(cd "$WT" && bash .claude/rotation-lanes/b/event.sh harness.note note.kind=guard-shim >/dev/null 2>&1); rc=$?
expect_eq "through the lane's shim from the worktree: written to the lane's log" "$rc:$(grep -c 'guard-shim' "$LEV")" "0:1"
(cd "$REPO" && bash .claude/rotation/event.sh harness.note note.kind=guard-main >/dev/null 2>&1); rc=$?
expect_eq "the first lane's shim from the main tree: written to its log" "$rc:$(grep -c 'guard-main' "$MEV")" "0:1"
expect_eq "autorun_git_head in the main lane: HEAD" "$(cd "$REPO" && bash -c '. .claude/rotation/lib.sh; autorun_git_head')" "$MSHA"
printf '{"rotationId":"r-7-beef","ts":1,"trigger":"self","project":"repo","prevHead":"%s"}\n' "$WSHA" > "$REPO/.claude/rotation-state/lanes/b/rotations.jsonl"
printf 'rotation=r-7-beef executor=x id=ag-x since=t session=s\n' > "$REPO/.claude/rotation-state/lanes/b/manager.active"
fc=$(cd "$REPO" && bash .claude/rotation-lanes/b/recover.sh --json --no-probe 2>/dev/null | python3 -c 'import json,sys; s=json.load(sys.stdin); print((s.get("foreign") or {}).get("count"), (s.get("head") or "").split(" ")[0])')
expect_eq "recover in lane mode: a main-lane commit is not a foreign commit of the lane; head is the lane's" "$fc" "0 $WSHA"

# ── TRIG-5 needs `need` prior rows before a same-axis streak can fire ─────
printf '{"rotationId":"r-7-beef","ts":1,"trigger":"self","project":"repo","prevHead":"%s","axis":"A"}\n{"rotationId":"r-8-beef","ts":2,"trigger":"self","project":"repo","prevHead":"%s","axis":"A"}\n' "$SHA" "$SHA" > "$REPO/.claude/rotation-state/lanes/b/rotations.jsonl"
printf '# lane handoff\n\nHEAD %s\n\n## rotate-trigger\n\naxis: A\nclosed: %s first\ngate: 1/0/0\n' "$SHA" "$SHA" > "$LANE/handoff.md"
t5=$(cd "$REPO" && bash .claude/rotation-lanes/b/trig_gate.sh 2>&1 | grep -E '^TRIG-5 ')
expect_has "TRIG-5 with 2 prior same-axis rows (need 7): PASS, not a streak" "$t5" '^TRIG-5 PASS .*only 2 prior'

# ── the first lane is a peer: named by ROTATION_LANE_NAME, its events carry the name ─
printf 'ROTATION_LANE_NAME=substrate\n' >> "$REPO/.claude/rotation/rotation.conf"
(cd "$REPO" && bash .claude/rotation/event.sh harness.note note.kind=named-first >/dev/null 2>&1)
expect_eq "first lane with ROTATION_LANE_NAME: its event carries the name" "$(grep -c 'named-first.*' "$MEV"):$(grep 'named-first' "$MEV" | grep -c '"lane":"substrate"')" "1:1"
expect_eq "first lane with ROTATION_LANE_NAME: paths unchanged" "$(cd "$REPO" && bash -c '. .claude/rotation/lib.sh; echo "$STATE_DIR"')" "$REPO/.claude/rotation-state"

# ── K2: init.sh --lane <name> --from <lane> ─────────────────────────────
cat >> "$LANE/rotation.conf" <<'EOF'
# lane `b` — rotation-lanes/b, lanes/b, lane-b, lane/b, lane b; not lane/bx nor lanes/b2
ROTATION_CLOSE_RULES=.claude/rotation-lanes/b/close_rules.tsv
EOF
out=$(cd "$REPO" && CLAUDE_PLUGIN_ROOT="$ROOT" bash "$KBIN/init.sh" --lane q --from b 2>&1); rc=$?
expect_eq "init --from: exit 0" "$rc" 0
QC="$REPO/.claude/rotation-lanes/q/rotation.conf"
expect_has "init --from: the replacement count is printed" "$out" 'rotation\.conf copied from lane b — 7 replacement\(s\) b → q'
expect_has "init --from: every spelling naming the lane is replaced" "$(grep '^# lane' "$QC")" '^# lane `q` — rotation-lanes/q, lanes/q, lane-q, lane/q, lane q; not lane/bx nor lanes/b2$'
expect_eq "init --from: a path to the lane's rules points at the new lane" "$(grep '^ROTATION_CLOSE_RULES' "$QC" | tail -1)" "ROTATION_CLOSE_RULES=.claude/rotation-lanes/q/close_rules.tsv"
expect_has "init --from: project.sh comes from lane b (its base branch, renamed)" "$(cat "$REPO/.claude/rotation-lanes/q/project.sh")" 'ROTATION_BASE_BRANCH=lane/q'
expect_eq "init --from: the source lane is untouched" "$(grep -c 'rotation-lanes/b/close_rules' "$LANE/rotation.conf")" 1
out=$(cd "$REPO" && CLAUDE_PLUGIN_ROOT="$ROOT" bash "$KBIN/init.sh" --lane r --from nosuch 2>&1); rc=$?
expect_eq "init --from: an unknown source lane exits 1" "$rc:$([ -d "$REPO/.claude/rotation-lanes/r" ] && echo made || echo none)" "1:none"
out=$(cd "$REPO" && CLAUDE_PLUGIN_ROOT="$ROOT" bash "$KBIN/init.sh" --from b 2>&1); rc=$?
expect_eq "init --from without --lane: usage (exit 2)" "$rc" 2
out=$(cd "$REPO" && CLAUDE_PLUGIN_ROOT="$ROOT" bash "$KBIN/init.sh" --lane s 2>&1); rc=$?
expect_eq "init --lane without --from: still copies the first lane's conf" "$rc:$(cmp -s "$REPO/.claude/rotation-lanes/s/rotation.conf" "$REPO/.claude/rotation/rotation.conf" && echo same)" "0:same"
expect_eq "init: the new commands have shims" \
  "$(for f in lanes.sh lane_close.sh lane_merge.sh onboard_check.sh; do [ -x "$REPO/.claude/rotation-lanes/s/$f" ] && printf 1 || printf 0; done)" 1111

# ── K3: lanes.sh and the --all modes ────────────────────────────────────
out=$(cd "$REPO" && bash .claude/rotation/lanes.sh 2>&1); rc=$?
expect_eq "lanes.sh: exit 0, one line per lane, the first lane first under its name, then the windows" "$rc:$(printf '%s\n' "$out" | awk '{print $1}' | tr '\n' ' ')" "0:substrate b c d q s windows: "
expect_eq "lanes.sh: no window open" "$(printf '%s\n' "$out" | tail -1)" "windows: none open"
(cd "$REPO" && bash .claude/rotation-lanes/b/window.sh open bench --host mini --until +600 >/dev/null)
out=$(cd "$REPO" && bash .claude/rotation/lanes.sh 2>&1)
expect_has "lanes.sh: a window lane b opened shows on the windows line" "$(printf '%s\n' "$out" | tail -1)" "windows: bench\\(host=mini until="
(cd "$REPO" && bash .claude/rotation-lanes/b/window.sh close bench >/dev/null)
expect_has "lanes.sh: lane b's branch and rid" "$(printf '%s\n' "$out" | grep '^b ')" 'branch=lane/b rid=r-[0-9a-z-]+ head=[0-9a-f]+ '
expect_has "lanes.sh: lane c's running executor and its manager marker" "$(printf '%s\n' "$out" | grep '^c ')" 'last=rotation\.start@[0-9T:Z-]+ executors=1:c-01\(ag-c1\) manager=yes$'
expect_has "lanes.sh: the first lane has no executor" "$(printf '%s\n' "$out" | grep '^substrate ')" 'executors=0 manager=no$'
js=$(cd "$REPO" && bash .claude/rotation/lanes.sh --json | python3 -c 'import json,sys; a=json.load(sys.stdin); print(len(a), a[0]["value"] == "", a[2]["executors"][0]["id"], a[1]["branch"])')
expect_eq "lanes.sh --json: an array, the first lane's value empty, executors and branch carried" "$js" "6 True ag-c1 lane/b"
out=$(cd "$REPO" && bash .claude/rotation/lanes.sh --bogus 2>&1); rc=$?
expect_eq "lanes.sh: an unknown option is usage (exit 2)" "$rc" 2

out=$(cd "$REPO" && bash .claude/rotation/doctor.sh --all 2>&1); rc=$?
expect_eq "doctor --all: one header per lane" "$(printf '%s\n' "$out" | grep -c '^== lane ')" 6
expect_eq "doctor --all: each lane's verdict line follows its header" "$(printf '%s\n' "$out" | grep -cE '^DOCTOR (PASS|FAIL)')" 6
expect_eq "doctor --all: exit is the worst (these fixtures have no adapter commands: 1)" "$rc" 1
expect_has "doctor --all: a lane's run is that lane's" "$(printf '%s\n' "$out" | sed -n '/^== lane c ==/,/^== lane d ==/p')" '^PASS lane c '
out=$(cd "$REPO" && bash .claude/rotation-lanes/b/doctor.sh --all 2>&1)
expect_eq "doctor --all through a lane's shim: still every lane" "$(printf '%s\n' "$out" | grep -c '^== lane ')" 6
out=$(cd "$REPO" && bash .claude/rotation/recover.sh --all --no-probe 2>&1); rc=$?
expect_eq "recover --all: exit 0, one header and one action line per lane" \
  "$rc:$(printf '%s\n' "$out" | grep -c '^== lane '):$(printf '%s\n' "$out" | grep -cE '^(RESUME|CLEAN|RESPAWN|IDLE)')" "0:6:6"
out=$(cd "$REPO" && bash .claude/rotation/recover.sh --all --json --no-probe 2>&1)
expect_eq "recover --all --json: one JSON page per lane" "$(printf '%s\n' "$out" | grep -c '^{')" 6
worst=0
for l in "" b c d q s; do
  (cd "$REPO" && ROTATION_LANE=$l bash .claude/rotation/watchdog.sh --once >/dev/null 2>&1); r=$?
  [ "$r" -le "$worst" ] || worst=$r
done
out=$(cd "$REPO" && bash .claude/rotation/watchdog.sh --all --once 2>&1); rc=$?
expect_eq "watchdog --all --once: exit is the highest of the lanes' own (here $worst)" "$rc" "$worst"
expect_eq "watchdog --all --once: every lane's line under its header" "$(printf '%s\n' "$out" | grep -c '^== lane ')" 6
expect_has "watchdog --all --once: lane d runs two executors" "$(printf '%s\n' "$out" | sed -n '/^== lane d ==/,/^== lane q ==/p')" '^MULTI-EXECUTOR n=2'
out=$(cd "$REPO" && bash .claude/rotation/watchdog.sh --all --interval 1 2>&1); rc=$?
expect_eq "watchdog --all: the first pass with a hit exits with it" "$rc" "$worst"
expect_has "watchdog --all: the hit lane is printed under its header" "$out" '== lane d =='
expect_not "watchdog --all: lanes without a hit are not printed" "$out" '^OK '
out=$(cd "$REPO" && bash .claude/rotation/watchdog.sh --once 2>&1); rc=$?
expect_not "watchdog without --all: no lane headers" "$out" '^== lane '

# ── K4: lane_close.sh and lane_merge.sh ─────────────────────────────────
# a second project whose kernel is a copy with the trigger stubbed (its gate is TRIG-1..9 against stamps
# and rows; lane_close only has to call it and act on its exit)
KP="$TMP/kplug"; mkdir -p "$KP/bin"; cp "$KBIN"/*.sh "$KBIN"/*.py "$KP/bin/"
cat > "$KP/bin/trigger.sh" <<'EOF'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
[ "${STUB_TRIGGER_RC:-0}" = 0 ] || { echo "TRIG-1 FAIL stub"; exit 1; }
next=r-2000000000-abcd
autorun_record_event rotation.end trigger=self "next=$next"
printf '%s\n' "$next" > "$INTENT_FILE"
printf '{"rotationId":"%s","trigger":"self","project":"p","commitsInSession":3}\n' "$next" >> "$ROTATIONS_LOG"
echo "rotation $next triggered (self, stub)"
EOF
P="$TMP/proj"; mkdir -p "$P"
gp() { git -C "$P" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
gp init -q -b develop
printf '.claude/\n' > "$P/.gitignore"; echo x > "$P/x.txt"; gp add -A; gp commit -q -m "feat: first"
(cd "$P" && CLAUDE_PLUGIN_ROOT="$KP" bash "$KP/bin/init.sh" >/dev/null 2>&1)
(cd "$P" && CLAUDE_PLUGIN_ROOT="$KP" bash "$KP/bin/init.sh" --lane p >/dev/null 2>&1)
PL="$P/.claude/rotation-lanes/p"
printf 'export ROTATION_BASE_BRANCH=lane/p\n' >> "$PL/project.sh"
printf 'ROTATION_INBOX_INSERT_LINE=3\nROTATION_LANE_CLOSE_HOOK=touch .claude/hook-ran\n' >> "$PL/rotation.conf"
printf 'ROTATION_INBOX_INSERT_LINE=3\n' >> "$P/.claude/rotation/rotation.conf"
printf '# inbox\n\n| date | rule | where |\n|---|---|---|\n| old | row | x |\n' > "$P/.claude/autorun-inbox.md"
printf 'r-1999999999-0001\n' > "$P/.claude/rotation-state/lanes/p/rotation.current"
(cd "$P" && bash .claude/rotation-lanes/p/event.sh gate.end 'gate=raw:{"sha":"x","pass":7,"fail":0,"skip":1}' >/dev/null)
PW="$TMP/pwt"
gp worktree add -q -b lane/p "$PW" develop
gw() { git -C "$PW" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
echo p > "$PW/p.txt"; gw add -A; gw commit -q -m "feat: lane work"
(cd "$PW" && bash "$KP/bin/lane_enter.sh" p >/dev/null 2>&1)
echo d > "$P/d.txt"; gp add -A; gp commit -q -m "feat: develop moves on"

out=$(cd "$P" && bash .claude/rotation-lanes/p/lane_close.sh 2>&1); rc=$?
expect_eq "lane_close off the lane's branch (main tree on develop): exit 1" "$rc" 1
out=$(cd "$PW" && bash .claude/rotation/lane_close.sh 2>&1); rc=$?
expect_eq "lane_close through the first lane's shim: usage (exit 2)" "$rc" 2
# step 0: the trace check refuses before anything is merged
PHEAD=$(gw rev-parse HEAD)
echo t1 > "$PW/t1.txt"; gw add -A; gw commit -q -m "fix: picked from a worker" -m "Agent-Origin: w-pick"
TSHA=$(gw rev-parse --short=9 HEAD)
out=$(cd "$PW" && bash .claude/rotation-lanes/p/lane_close.sh 2>&1); rc=$?
expect_eq "trace check: an Agent-Origin trailer is refused (exit 1, no tag)" "$rc:$(gp tag -l 'lane/p/*' | wc -l | tr -d ' ')" "1:0"
expect_has "trace check: the commit is named" "$out" "^lane_close: commit $TSHA carries a trace:$"
expect_has "trace check: the trailer line is shown" "$out" '^  3:Agent-Origin: w-pick$'
expect_not "trace check: nothing merged" "$out" '^lane_close: 1 merge'
expect_eq "trace check: the lane's HEAD is unchanged" "$(gw rev-parse --short=9 HEAD)" "$TSHA"
gw reset -q --hard "$PHEAD"
echo t2 > "$PW/t2.txt"; gw add -A; gw commit -q -m "feat: lane thing" -m "Generated with some tool"
out=$(cd "$PW" && bash .claude/rotation-lanes/p/lane_close.sh 2>&1); rc=$?
expect_eq "trace check: 'Generated with' in a message is refused (exit 1)" "$rc" 1
expect_has "trace check: that line is shown" "$out" '^  3:Generated with some tool$'
gw reset -q --hard "$PHEAD"
printf 'ROTATION_HANDOFF_SECTIONS=架构影响|rotate-trigger|下一步\n' >> "$PL/rotation.conf"
printf '# lane handoff\n\n## rotate-trigger\n\naxis: A\n' > "$PL/handoff.md"
out=$(cd "$PW" && bash .claude/rotation-lanes/p/lane_close.sh 2>&1); rc=$?
expect_eq "handoff check: missing sections are refused (exit 1, no tag)" "$rc:$(gp tag -l 'lane/p/*' | wc -l | tr -d ' ')" "1:0"
expect_has "handoff check: the missing titles are listed" "$(printf '%s\n' "$out" | grep -A2 'lacks section')" '^  架构影响$'
expect_has "handoff check: every missing title, not just the first" "$out" '^  下一步$'
expect_not "handoff check: a present title is not listed" "$out" '^  rotate-trigger$'
expect_not "handoff check: nothing merged" "$out" '^lane_close: 1 merge'
printf '# lane handoff\n\n### 本轮的架构影响\n\nnone\n\n## rotate-trigger\n\naxis: A\n\n**下一步**: x\n' > "$PL/handoff.md"
out=$(cd "$PW" && STUB_TRIGGER_RC=1 bash .claude/rotation-lanes/p/lane_close.sh 2>&1); rc=$?
expect_eq "lane_close with the trigger blocked: exit 1, no tag" "$rc:$(gp tag -l 'lane/p/*' | wc -l | tr -d ' ')" "1:0"
expect_has "clean commits and handoff: past step 0 to the merge" "$out" '^lane_close: 1 merge develop into lane/p$'
expect_has "lane_close blocked: the gate's lines are shown" "$out" 'TRIG-1 FAIL stub'
rm -f "$PW/.claude/hook-ran"
out=$(cd "$PW" && bash .claude/rotation-lanes/p/lane_close.sh 2>&1); rc=$?
TAGP=lane/p/r-1999999999-0001
expect_eq "lane_close: exit 0" "$rc" 0
expect_has "lane_close: last line" "$(printf '%s\n' "$out" | tail -1)" "^LANE READY $TAGP head=[0-9a-f]+$"
expect_eq "lane_close: the tag is the closed round's, at the worktree's HEAD" "$(gp rev-parse "$TAGP^{commit}")" "$(gw rev-parse HEAD)"
expect_eq "lane_close: develop was merged into the lane (two parents, the message)" \
  "$(gw log -1 --format='%p|%s' "$TAGP" | awk -F'|' '{print split($1, a, " ") "|" $2}')" "2|merge: develop into lane/p"
expect_eq "lane_close: the hook ran in the worktree" "$([ -e "$PW/.claude/hook-ran" ] && echo yes)" yes
expect_eq "lane_close: the inbox row at line 3 (the main tree's inbox, through the link)" "$(sed -n 3p "$P/.claude/autorun-inbox.md")" \
  "| $(date +%F) | $TAGP ready · 3 commit · gate 7/0/1 | .claude/rotation-lanes/p/handoff.md |"
expect_eq "lane_close: the rest of the inbox is kept" "$(sed -n '1p;4p;6p' "$P/.claude/autorun-inbox.md" | tr '\n' '~')" "# inbox~| date | rule | where |~| old | row | x |~"
PEV="$P/.claude/rotation-state/lanes/p/events.jsonl"
ready=$(grep '"kind":"lane.ready"' "$PEV" | python3 -c 'import json,sys; e=json.loads(sys.stdin.readline()); r=e["ready"]; print(e["tag"], e["lane"], r["rid"], r["commits"], r["gate"]["pass"], r["gate"]["fail"], r["gate"]["skip"], r["mergedFrom"], r["inboxLine"], r["handoff"], r["head"] == e["head"])')
expect_eq "lane_close: lane.ready carries tag, rid, commits, gate, base, inbox line, handoff" "$ready" \
  "$TAGP p r-1999999999-0001 3 7 0 1 develop 3 .claude/rotation-lanes/p/handoff.md True"

out=$(cd "$P" && bash .claude/rotation/lane_merge.sh "$TAGP" 2>&1); rc=$?
expect_eq "lane_merge: exit 0" "$rc" 0
MEVP="$P/.claude/rotation-state/events.jsonl"
expect_eq "lane_merge: a --no-ff merge commit on develop with the message" \
  "$(gp log -1 --format='%p|%s' | awk -F'|' '{print split($1, a, " ") "|" $2}')" "2|merge: $TAGP into develop"
chain=$(python3 -c '
import json, sys
ev = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
s = [e for e in ev if e["kind"] == "lane.merge.start"][-1]; e = [e for e in ev if e["kind"] == "lane.merge.end"][-1]
print(s["tag"] == e["tag"] == sys.argv[2], s["merge"]["baseHead"] == e["merge"]["baseHead"], e["merge"]["status"], e["merge"]["commit"] == sys.argv[3], s["merge"]["tagHead"] == sys.argv[4])' \
  "$MEVP" "$TAGP" "$(gp rev-parse --short HEAD)" "$(gp rev-parse --short "$TAGP^{commit}")")
expect_eq "lane_merge: merge.start / merge.end share the tag and base head, end has the merge commit" "$chain" "True True ok True True"
out=$(cd "$P" && bash .claude/rotation/lane_merge.sh lane/p/r-nosuch 2>&1); rc=$?
expect_eq "lane_merge: no such tag is exit 1" "$rc" 1
out=$(cd "$P" && bash .claude/rotation/lane_merge.sh notatag 2>&1); rc=$?
expect_eq "lane_merge: not a lane tag is usage (exit 2)" "$rc" 2

# conflicts: the lane and develop change the same line
gw merge -q --ff-only develop 2>/dev/null || gw merge -q --no-edit develop
echo lane > "$PW/x.txt"; gw commit -q -am "fix: lane side"
echo dev > "$P/x.txt"; gp commit -q -am "fix: develop side"
out=$(cd "$PW" && bash .claude/rotation-lanes/p/lane_close.sh 2>&1); rc=$?
expect_eq "lane_close with a conflicting base: exit 3" "$rc" 3
expect_has "lane_close conflict: the file is named" "$out" '^  x\.txt$'
gw merge --abort
gp tag lane/p/r-conflict-0001 lane/p
out=$(cd "$P" && bash .claude/rotation/lane_merge.sh lane/p/r-conflict-0001 2>&1); rc=$?
expect_eq "lane_merge with a conflict: exit 3" "$rc" 3
expect_eq "lane_merge conflict: merge.end records the conflict, no commit" \
  "$(grep '"kind":"lane.merge.end"' "$MEVP" | tail -1 | python3 -c 'import json,sys; e=json.loads(sys.stdin.readline()); print(e["tag"], e["merge"]["status"], e["merge"]["commit"])')" "lane/p/r-conflict-0001 conflict None"
gp merge --abort

REV=$(gp rev-parse --short HEAD)
out=$(cd "$P" && bash .claude/rotation/lane_merge.sh --returned "$TAGP" "build regressed" "$REV" 2>&1); rc=$?
expect_eq "lane_merge --returned: exit 0" "$rc" 0
expect_eq "lane_merge --returned: lane.returned carries tag, reason, revert" \
  "$(grep '"kind":"lane.returned"' "$MEVP" | python3 -c 'import json,sys; e=json.loads(sys.stdin.readline()); print(e["tag"], "|", e["returned"]["reason"], "|", e["returned"]["revert"])')" "$TAGP | build regressed | $REV"
expect_eq "lane_merge --returned: the inbox row at line 3" "$(sed -n 3p "$P/.claude/autorun-inbox.md")" \
  "| $(date +%F) | $TAGP returned · build regressed · revert $REV | .claude/rotation-lanes/p/handoff.md |"
out=$(cd "$P" && bash .claude/rotation/lane_merge.sh --returned "$TAGP" "x" deadbeef0 2>&1); rc=$?
expect_eq "lane_merge --returned: an unknown revert commit is exit 1" "$rc" 1

echo "lanes_self_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
