#!/usr/bin/env bash
# bin/hardev: every noun + verb reaches the right kernel script with the right arguments (HARDEV_DRY_RUN=1
# prints the exec line instead of running it), the three global options, the project root lookup, self,
# and the shims `init.sh --shims hardev` writes.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"; BIN="$ROOT/bin"; H="$BIN/hardev"
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1: got [$2] want [$3]"; fi; }
has() { if printf '%s\n' "$2" | grep -qE -- "$3"; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1: [$2] lacks /$3/"; fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
T=$(cd "$T" && pwd)
mkdir -p "$T/none"
dry() { (cd "${CWD:-$T/none}" && env -u ROTATION_PROJECT_DIR -u ROTATION_LANE HARDEV_DRY_RUN=1 "$H" "$@" 2>&1); }
target() { printf '%s\n' "$1" | sed -n 's/^hardev-dry-run: .* exec //p'; }
field() { printf '%s\n' "$1" | sed -n "s/^hardev-dry-run: .*$2=\([^ ]*\) .*/\1/p"; }

# ── 1. every noun + verb → script + fixed arguments ─────────────────────
while IFS='|' read -r spelling want; do
  # shellcheck disable=SC2086
  out=$(dry $spelling)
  ok "1 $spelling" "$(target "$out")" "$want"
done <<EOF
init --force|$BIN/init.sh --force
onboard check|$BIN/onboard_check.sh
doctor --all|$BIN/doctor.sh --all
status|$BIN/lanes.sh
lane list|$BIN/lanes.sh
lane enter plat --share .dev|$BIN/lane_enter.sh plat --share .dev
lane close|$BIN/lane_close.sh
lane merge lane/p/r-1|$BIN/lane_merge.sh lane/p/r-1
lane merge --returned lane/p/r-1 why|$BIN/lane_merge.sh --returned lane/p/r-1 why
lane return lane/p/r-1 why abc|$BIN/lane_merge.sh --returned lane/p/r-1 why abc
event add foo k=v|$BIN/event.sh foo k=v
agent start w worker opus task|$BIN/agent_log.sh start w worker opus task
agent end w worker opus|$BIN/agent_log.sh end w worker opus
manager start|$BIN/manager_log.sh start
manager spawn a1 exec|$BIN/manager_log.sh spawn a1 exec
manager resume a1 quota|$BIN/manager_log.sh resume a1 quota
manager verify 1=pass 2=fail|$BIN/manager_log.sh verify 1=pass 2=fail
manager stop done|$BIN/manager_log.sh stop done
remote run mini make k=v|$BIN/remote_run.sh mini make k=v
run preflight -q|$BIN/adapter_run.sh preflight -q
run gate abc|$BIN/adapter_run.sh gate abc
run close-segment abc seg|$BIN/adapter_run.sh close-segment abc seg
run bench abc A|$BIN/adapter_run.sh bench abc A
close plan p h --explain|$BIN/close_plan.sh p h --explain
close fill r-1|$BIN/close_verdict_fill.sh r-1
close carry sweep abc why|$BIN/carry_stamp.sh sweep abc why
close report r-1 f.md|$BIN/report_save.sh r-1 f.md
trigger|$BIN/trigger.sh
trigger self|$BIN/trigger.sh self
trigger manual|$BIN/trigger.sh manual
trigger gate|$BIN/trig_gate.sh
trigger check r-1|$BIN/check.sh r-1
reap|$BIN/kill_stray_shells.sh
watch --once --stale 60|$BIN/watchdog.sh --once --stale 60
recover --no-probe|$BIN/recover.sh --no-probe
log --tail 3|$BIN/log.sh --tail 3
stats --tail 5|$BIN/stats.sh --tail 5
stats effect|$BIN/stats.sh --effect
stats suggest|$BIN/stats.sh --suggest
hook stop|$BIN/stop_hook.sh
hook subagent-stop|$BIN/subagent_stop_hook.sh
hook session-start|$BIN/session_start_hook.sh
self version|(built-in) self version
self path|(built-in) self path
self install|(built-in) self install
self uninstall|(built-in) self uninstall
EOF
ok "1 every table row has a case above" "$(grep -v '^#' "$BIN/commands.tsv" | grep -vc '^$')" "46"

# ── 2. global options ───────────────────────────────────────────────────
out=$(dry lane close --lane plat)
ok "2 --lane after the verb exports ROTATION_LANE" "$(field "$out" ROTATION_LANE)" "plat"
ok "2 … and is not passed on" "$(target "$out")" "$BIN/lane_close.sh"
out=$(dry --lane=plat doctor)
ok "2 --lane=NAME before the noun" "$(field "$out" ROTATION_LANE)" "plat"
out=$(dry init --lane plat --from main)
ok "2 init takes --lane as its own argument" "$(target "$out")" "$BIN/init.sh --lane plat --from main"
ok "2 … and nothing is exported" "$(field "$out" ROTATION_LANE)" "-"
out=$(dry onboard check --lane plat)
ok "2 onboard check takes --lane as its own argument" "$(target "$out")" "$BIN/onboard_check.sh --lane plat"
out=$(dry --lane Bad doctor); rc=$?
ok "2 a bad lane name: exit 2" "$rc" "2"
mkdir -p "$T/p/.claude/rotation"; : > "$T/p/.claude/rotation/rotation.conf"
out=$(dry --project "$T/p" doctor)
ok "2 --project exports the root" "$(field "$out" ROTATION_PROJECT_DIR)" "$T/p"
out=$(dry doctor --project "$T/p/.claude/..")
ok "2 --project after the noun, made absolute" "$(field "$out" ROTATION_PROJECT_DIR)" "$T/p"
out=$(dry --project "$T/nosuch" doctor); rc=$?
ok "2 --project with no such directory: exit 2" "$rc" "2"
out=$(dry --project "$T/p" init)
ok "2 a cwd command enters the --project directory" "$(printf '%s\n' "$out" | sed -n 's/^hardev-dry-run: cwd=\([^ ]*\) .*/\1/p')" "$T/p"
ok "2 … and exports no root" "$(field "$out" ROTATION_PROJECT_DIR)" "-"
for c in "recover --no-probe" "status" "lane list" "log" "stats effect"; do
  # shellcheck disable=SC2086
  out=$(dry $c --json)
  has "2 --json passes through to $c" "$(target "$out")" ' --json$'
done
for c in "doctor" "event add k" "stats" "trigger self" "self version"; do
  # shellcheck disable=SC2086
  out=$(dry --json $c); rc=$?
  ok "2 --json refused by $c: exit 2" "$rc" "2"
  has "2 … with the message" "$out" "^hardev: .* has no --json yet$"
done
out=$(dry stats -- --project foo --json)
ok "2 after -- nothing is a global option" "$(target "$out")" "$BIN/stats.sh --project foo --json"
ok "2 … and no root is set from it" "$(field "$out" ROTATION_PROJECT_DIR)" "-"

# ── 3. the project root ─────────────────────────────────────────────────
P="$T/proj"; mkdir -p "$P/.claude/rotation" "$P/sub/deeper"
git -C "$P" init -q -b main && git -C "$P" commit -q --allow-empty -m init
: > "$P/.claude/rotation/rotation.conf"
out=$(CWD="$P/sub/deeper" dry doctor)
ok "3 from a subdirectory: the project" "$(field "$out" ROTATION_PROJECT_DIR)" "$P"
mkdir -p "$P/.claude/worktrees/w"; git -C "$P/.claude/worktrees/w" init -q; git -C "$P/.claude/worktrees/w" commit -q --allow-empty -m w
out=$(CWD="$P/.claude/worktrees/w" dry doctor)
ok "3 from a nested repository inside the project: the project" "$(field "$out" ROTATION_PROJECT_DIR)" "$P"
git -C "$P" worktree add -q "$T/wt" -b lane 2>/dev/null
out=$(CWD="$T/wt" dry doctor)
ok "3 from a git worktree outside the project: the main tree" "$(field "$out" ROTATION_PROJECT_DIR)" "$(cd "$P" && pwd -P)"
mkdir -p "$T/wt/.claude/rotation"; : > "$T/wt/.claude/rotation/rotation.conf"
out=$(CWD="$T/wt" dry doctor)
ok "3 a worktree with its own .claude/rotation (lane enter): the worktree" "$(field "$out" ROTATION_PROJECT_DIR)" "$T/wt"
out=$(cd "$P/sub" && ROTATION_PROJECT_DIR="$T/elsewhere" HARDEV_DRY_RUN=1 "$H" doctor)
ok "3 an exported ROTATION_PROJECT_DIR is kept" "$(field "$out" ROTATION_PROJECT_DIR)" "$T/elsewhere"
out=$(dry doctor)
ok "3 no project found: nothing exported" "$(field "$out" ROTATION_PROJECT_DIR)" "-"
out=$(CWD="$P/sub" dry hook stop)
ok "3 a hook finds its own root" "$(field "$out" ROTATION_PROJECT_DIR)" "-"

# ── 4. errors ───────────────────────────────────────────────────────────
out=$(dry nosuch); rc=$?
ok "4 unknown noun: exit 2" "$rc" "2"
has "4 … names it" "$out" "^hardev: unknown command 'nosuch'"
has "4 … and prints the table" "$out" "^  lane close"
out=$(dry lane nosuch); rc=$?
ok "4 unknown verb: exit 2" "$rc" "2"
has "4 … names it" "$out" "^hardev: unknown verb 'nosuch' for 'lane'"
out=$(dry trigger nosuch); rc=$?
ok "4 a bare word that is no verb, on a noun with verbs: exit 2" "$rc" "2"
out=$(dry lane); rc=$?
ok "4 a noun without its verb: exit 2" "$rc" "2"
out=$(dry); rc=$?
ok "4 nothing: exit 2" "$rc" "2"
has "4 … prints the usage" "$out" "^usage: hardev <noun>"

# ── 5. help ─────────────────────────────────────────────────────────────
out=$("$H" help); rc=$?
ok "5 help: exit 0" "$rc" "0"
ok "5 help: one line per row" "$(printf '%s\n' "$out" | grep -c '^  [a-z]')" "46"
has "5 help marks --json" "$out" "^  recover \[--all\] \[--no-probe\] \[--json\] "
out=$("$H" lane help)
ok "5 lane help: the lane rows" "$(printf '%s\n' "$out" | awk '{print $1 $2}' | tr '\n' ' ')" "lanelist laneenter laneclose lanemerge lanereturn "
ok "5 help NOUN" "$("$H" help close | grep -c '^  close ')" "4"

# ── 6. self ─────────────────────────────────────────────────────────────
pj=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ROOT/.claude-plugin/plugin.json")
ok "6 self version = plugin.json version and conf format 1" "$("$H" self version)" "hardev $pj (conf format 1)"
ok "6 self version names the kernel's version" "$("$H" self version)" "hardev $(sed -n 's/^ROTATION_KERNEL_VERSION="\(.*\)"$/\1/p' "$BIN/lib.sh") (conf format 1)"
ok "6 self path" "$("$H" self path)" "$ROOT"
mp=$(python3 -c 'import json,sys; print([p["version"] for p in json.load(open(sys.argv[1]))["plugins"] if p["name"]=="rotation"][0])' "$ROOT/../.claude-plugin/marketplace.json" 2>/dev/null)
ok "6 marketplace.json carries the same version" "$mp" "$pj"
HM="$T/home"; mkdir -p "$HM"
out=$(HOME="$HM" PATH="/usr/bin:/bin" "$H" self install); rc=$?
ok "6 install: exit 0" "$rc" "0"
ok "6 install links ~/.local/bin/hardev" "$(readlink "$HM/.local/bin/hardev")" "$BIN/hardev"
has "6 install says PATH lacks ~/.local/bin" "$out" "is not on PATH"
out=$(HOME="$HM" PATH="$HM/.local/bin:/usr/bin:/bin" "$H" self install); rc=$?
ok "6 install again: exit 0" "$rc" "0"
has "6 … already linked, no PATH note" "$out" "already links"
ok "6 … no PATH note" "$(printf '%s\n' "$out" | grep -c 'not on PATH')" "0"
ok "6 the link runs hardev" "$(HOME="$HM" "$HM/.local/bin/hardev" self path)" "$ROOT"
rm "$HM/.local/bin/hardev"; ln -s /bin/echo "$HM/.local/bin/hardev"
out=$(HOME="$HM" "$H" self install 2>&1); rc=$?
ok "6 install over a foreign link: exit 1" "$rc" "1"
ok "6 … left alone" "$(readlink "$HM/.local/bin/hardev")" "/bin/echo"
out=$(HOME="$HM" "$H" self uninstall 2>&1); rc=$?
ok "6 uninstall of a foreign link: exit 1" "$rc" "1"
HOME="$HM" "$H" self install --force >/dev/null; rc=$?
ok "6 install --force replaces it" "$rc:$(readlink "$HM/.local/bin/hardev")" "0:$BIN/hardev"
HOME="$HM" "$H" self uninstall >/dev/null; rc=$?
ok "6 uninstall removes the link" "$rc:$([ -L "$HM/.local/bin/hardev" ] && echo still || echo gone)" "0:gone"
out=$("$H" self version extra 2>&1); rc=$?
ok "6 self version with an argument: exit 2" "$rc" "2"

# ── 7. exit codes pass through ──────────────────────────────────────────
out=$(cd "$T/none" && "$H" close carry only-one 2>&1); rc=$?
ok "7 the script's usage exit (2) passes through" "$rc" "2"
has "7 … with the script's own message" "$out" "^usage: carry_stamp.sh"
out=$(cd "$T/none" && "$H" lane enter plat 2>&1); rc=$?
ok "7 the script's exit 1 passes through" "$rc" "1"

# ── 8. init --shims ─────────────────────────────────────────────────────
S="$T/shimmed"; mkdir -p "$S"; git -C "$S" init -q && git -C "$S" commit -q --allow-empty -m init
(cd "$S" && CLAUDE_PLUGIN_ROOT="$ROOT" bash "$BIN/init.sh" --shims hardev >/dev/null 2>&1)
has "8 a hardev shim execs hardev" "$(cat "$S/.claude/rotation/event.sh")" '^exec "\$h" --project "\$ROTATION_PROJECT_DIR" event add -- "\$@"$'
out=$(cd "$S" && HARDEV_DRY_RUN=1 bash .claude/rotation/event.sh foo k=v)
ok "8 event.sh foo k=v → event add foo k=v" "$(target "$out")" "$BIN/event.sh foo k=v"
ok "8 … with the shim's root" "$(field "$out" ROTATION_PROJECT_DIR)" "$S"
while IFS='|' read -r s args want; do
  # shellcheck disable=SC2086
  out=$(cd "$S/.claude" && HARDEV_DRY_RUN=1 bash "$S/.claude/rotation/$s" $args 2>&1)
  ok "8 shim $s $args" "$(target "$out")" "$BIN/$want"
done <<EOF
trigger.sh|self|trigger.sh self
trigger.sh||trigger.sh
trig_gate.sh||trig_gate.sh
check.sh|r-1|check.sh r-1
close_plan.sh|--explain|close_plan.sh --explain
close_verdict_fill.sh|r-1|close_verdict_fill.sh r-1
carry_stamp.sh|x h why|carry_stamp.sh x h why
recover.sh|--json --no-probe|recover.sh --json --no-probe
watchdog.sh|--once|watchdog.sh --once
event.sh|k a=b|event.sh k a=b
agent_log.sh|end w worker opus|agent_log.sh end w worker opus
manager_log.sh|resume a1 wake|manager_log.sh resume a1 wake
report_save.sh|r-1 f|report_save.sh r-1 f
adapter_run.sh|bench abc|adapter_run.sh bench abc
remote_run.sh|h c k=v|remote_run.sh h c k=v
doctor.sh|--all|doctor.sh --all
stats.sh|--effect --json|stats.sh --effect --json
log.sh|--json|log.sh --json
kill_stray_shells.sh||kill_stray_shells.sh
onboard_check.sh||onboard_check.sh
lanes.sh|--json|lanes.sh --json
lane_close.sh||lane_close.sh
lane_merge.sh|--returned t why|lane_merge.sh --returned t why
EOF
ok "8 every shim has a case above" "$(cd "$S/.claude/rotation" && printf '%s\n' *.sh | grep -c .)" "24"
(cd "$S/.claude" && bash "$S/.claude/rotation/event.sh" cli.note note.kind=shim >/dev/null 2>&1)
ok "8 a real call through a hardev shim writes the project's event" "$(grep -c '"shim"' "$S/.claude/rotation-state/events.jsonl" 2>/dev/null)" "1"
(cd "$S" && CLAUDE_PLUGIN_ROOT="$ROOT" bash "$BIN/init.sh" --lane plat --shims hardev >/dev/null 2>&1)
out=$(cd "$S" && HARDEV_DRY_RUN=1 bash .claude/rotation-lanes/plat/onboard_check.sh)
ok "8 a lane's hardev shim exports the lane" "$(field "$out" ROTATION_LANE)" "plat"
ok "8 … and passes no --lane (as the legacy shim)" "$(target "$out")" "$BIN/onboard_check.sh"
ok "8 … with the project root" "$(field "$out" ROTATION_PROJECT_DIR)" "$S"
out=$(cd "$S" && HARDEV_DRY_RUN=1 PATH="$T/nopath:/usr/bin:/bin" bash -c 'echo /nonexistent > .claude/rotation/kernel.path; bash .claude/rotation/doctor.sh' 2>&1)
has "8 without kernel.path the shim falls back to hardev on PATH" "$out" "hardev: (command )?not found"
N="$T/noshims"; mkdir -p "$N"; git -C "$N" init -q && git -C "$N" commit -q --allow-empty -m init
(cd "$N" && CLAUDE_PLUGIN_ROOT="$ROOT" bash "$BIN/init.sh" --shims none >/dev/null 2>&1)
ok "8 --shims none: no shim" "$(cd "$N/.claude/rotation" && printf '%s\n' *.sh | grep -c .)" "1"
ok "8 … only project.sh" "$(cd "$N/.claude/rotation" && printf '%s\n' *.sh)" "project.sh"
L="$T/legacy"; mkdir -p "$L"; git -C "$L" init -q && git -C "$L" commit -q --allow-empty -m init
out=$(cd "$L" && CLAUDE_PLUGIN_ROOT="$ROOT" bash "$BIN/init.sh" 2>&1)
has "8 default stays legacy: the shim execs the kernel script" "$(cat "$L/.claude/rotation/event.sh")" '^exec "\$\(cat "\$d/kernel.path"\)/bin/event.sh" "\$@"$'
has "8 … and init's line is unchanged" "$out" "^init: 23 shims in .*/legacy/.claude/rotation$"
out=$(cd "$L" && bash "$BIN/init.sh" --shims bogus 2>&1); rc=$?
ok "8 --shims bogus: exit 2" "$rc" "2"

echo "cli_self_test: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
