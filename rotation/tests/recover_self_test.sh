#!/usr/bin/env bash
#
# Self-test for recover.sh / watchdog.sh / event.sh / agent_log.sh ids,
# and for kill_stray_shells.sh ending only registered pids: a throwaway
# repository, hand-written events, fake probe commands and a throwaway
# process tree. Nothing here reaches a remote host or the project's own logs.
#
# exit: 0 every case passed · 1 otherwise

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$(cd "$SCRIPT_DIR/../bin" && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"
EV="$TMP/events.jsonl"
ROT="$TMP/rotations.jsonl"
NOW=$(date +%s)
pass=0
fail=0

ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; [ -z "${2:-}" ] || printf '     %s\n' "$2"; }
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$3] got [$2]"; fi; }
expect_has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "[$3] not in [$2]" ;; esac; }
expect_not() { case "$2" in *"$3"*) bad "$1" "[$3] present in [$2]" ;; *) ok "$1" ;; esac; }

g() { git -C "$REPO" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
# the fixture's commits are a day old, so only what a case adds counts as recent activity
export GIT_COMMITTER_DATE="$((NOW - 86400)) +0000"
mkdir -p "$REPO"
g init -q -b develop
echo a > "$REPO/a.txt"; g add a.txt; g commit -q -m "feat: first"
C0=$(g rev-parse --short HEAD)
echo b > "$REPO/b.txt"; g add b.txt; g commit -q -m "feat: second"
printf '{"rotationId":"r-test","at":"x","ts":%s,"project":"repo","trigger":"self","prevHead":"%s"}\n' "$((NOW - 3600))" "$C0" > "$ROT"

cat > "$TMP/fake_grep.sh" <<'EOF'
#!/bin/sh
# stands in for the remote marker check: the "remote" log is a local file
[ -f "$1" ] || exit 1
grep -qE -- "$2" "$1"
EOF
chmod +x "$TMP/fake_grep.sh"

# ev <seconds ago> <kind> [<json members>]
ev() {
  local ts=$((NOW - $1))
  printf '{"at":"%s","ts":%s,"kind":"%s","rotationId":"r-test","head":"x"%s}\n' \
    "$(date -u -r "$ts" +%Y-%m-%dT%H:%M:%SZ)" "$ts" "$2" "${3:+,$3}" >> "$EV"
}
reset() { : > "$EV"; }
# MARKER: the manager marker the FOREIGN-COMMIT check keys on; absent for every case but its own
MARKER="$TMP/no-marker"
# SESSION: the session id the scripts under test run in (CLAUDE_CODE_SESSION_ID); empty = not in a session
SESSION=sess-A
run() {
  ROTATION_PROJECT_DIR="$REPO" ROTATION_CONF=/dev/null ROTATION_PROJECT_SH=/dev/null ROTATION_STATE_DIR="$TMP/state" \
    ROTATION_REPO="$REPO" HARDEV_EVENTS_LOG="$EV" HARDEV_ROTATIONS_LOG="$ROT" ROTATION_BASE_BRANCH=develop \
    ROTATION_MANAGER_ACTIVE="$MARKER" CLAUDE_CODE_SESSION_ID="$SESSION" ROTATION_CONF="${CONF:-/dev/null}" \
    ROTATION_REMOTE_PROBE_CMD='echo probe-ok' ROTATION_REMOTE_GREP_CMD="${GREP_CMD:-$TMP/fake_grep.sh}" \
    ROTATION_REMOTE_COLLECT_CMD="${COLLECT_CMD:-}" ROTATION_CLAUDE_CONFIG_DIRS="$TMP/cfg-a:$TMP/cfg-b" "$@"
}
action() { run "$BIN/recover.sh" | tail -1; }
watch() { run "$BIN/watchdog.sh" --once "$@"; }
agent() { printf '"agent":{"name":"%s","role":"%s","model":"m"%s}' "$1" "$2" "${3:+,$3}"; }

# ── recover: the four actions ───────────────────────────────────────────
reset
ev 3500 rotation.end '"trigger":"self"'
expect_eq "recover IDLE" "$(action)" "IDLE"

reset
ev 3000 agent.start "$(agent rotation-1 rotation '"id":"ag-123"')"
expect_eq "recover RESUME by id" "$(action)" "RESUME ag-123"
echo x > "$REPO/dirty.txt"
expect_eq "recover RESUME wins over a dirty tree" "$(action)" "RESUME ag-123"
rm "$REPO/dirty.txt"

reset
ev 3000 agent.start "$(agent rotation-1 rotation)"
expect_eq "an executor registered without an id cannot be resumed: RESPAWN" "$(action)" "RESPAWN executor leftover=executor:rotation-1(no-id)"

# ── recover: RESUME only from the session that registered the executor ──
# an agent.start without the managerSession field predates it: taken as this session, and the page says so
reset
ev 3000 agent.start "$(agent rotation-1 rotation '"id":"ag-1"')"
out=$(run "$BIN/recover.sh")
expect_eq "no managerSession on the event (older): RESUME" "$(printf '%s\n' "$out" | tail -1)" "RESUME ag-1"
expect_has "page marks the session as not recorded" "$out" "executor session: registered=not recorded"
reset
ev 3000 agent.start "$(agent rotation-1 rotation '"id":"ag-1"'),\"managerSession\":\"sess-A\""
out=$(run "$BIN/recover.sh")
expect_eq "same session: RESUME" "$(printf '%s\n' "$out" | tail -1)" "RESUME ag-1"
expect_has "page shows the match" "$out" "executor session: registered=sess-A current=sess-A → match"
SESSION=sess-B
out=$(run "$BIN/recover.sh")
expect_eq "another session: RESPAWN with the executor as leftover" "$(printf '%s\n' "$out" | tail -1)" "RESPAWN executor leftover=executor:rotation-1(ag-1,mismatch)"
expect_has "page shows the mismatch" "$out" "registered=sess-A current=sess-B → mismatch"
SESSION=
expect_eq "no session id here: RESPAWN" "$(action)" "RESPAWN executor leftover=executor:rotation-1(ag-1,no-session)"
SESSION=sess-A
reset
ev 3000 agent.start "$(agent rotation-1 rotation '"id":"ag-1"'),\"managerSession\":null"
expect_eq "registered with a null session: RESPAWN" "$(action)" "RESPAWN executor leftover=executor:rotation-1(ag-1,no-session)"
echo x > "$REPO/dirty.txt"
expect_eq "an unreachable executor does not outrank a dirty tree" "$(action)" "CLEAN main tree first"
rm "$REPO/dirty.txt"
expect_eq "--json carries the session verdict" \
  "$(run "$BIN/recover.sh" --json --no-probe | python3 -c 'import json,sys; s=json.load(sys.stdin)["session"]; print(s["verdict"], s["current"], s["registered"])')" "no-session sess-A None"

reset
ev 7200 agent.start "$(agent rotation-0 rotation '"id":"ag-old"')"
ev 3500 rotation.end '"trigger":"self"'
expect_eq "an executor left open by an earlier round is not resumed" "$(action)" "IDLE"

reset
ev 3000 agent.start "$(agent rotation-1 rotation '"id":"ag-123"')"
ev 2000 agent.end "$(agent rotation-1 rotation '"status":"fail"')"
echo x > "$REPO/dirty.txt"
out=$(run "$BIN/recover.sh")
expect_eq "recover CLEAN" "$(printf '%s\n' "$out" | tail -1)" "CLEAN main tree first"
expect_has "recover lists the dirty file" "$out" "?? dirty.txt"
rm "$REPO/dirty.txt"

g worktree add -q -b agent-w1 "$TMP/wt-w1" develop
echo w > "$TMP/wt-w1/w.txt"
git -C "$TMP/wt-w1" add w.txt
git -C "$TMP/wt-w1" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m "feat: worker change"
echo "4874 pass / 0 fail / 4 skip" > "$TMP/gate-abc.log"
ev 1900 agent.start "$(agent w1 worker "\"id\":\"ag-w1\",\"worktree\":\"$TMP/wt-w1\"")"
ev 1800 remote.start "\"remote\":{\"kind\":\"gate\",\"sha\":\"abc\",\"log\":\"$TMP/gate-abc.log\",\"marker\":\"[0-9]+ pass / [0-9]+ fail\",\"host\":\"h\"}"
ev 1700 remote.start "\"remote\":{\"kind\":\"sweep\",\"sha\":\"abc\",\"log\":\"$TMP/sweep.log\",\"marker\":\"DONE\",\"host\":\"h\"}"
out=$(run "$BIN/recover.sh")
last=$(printf '%s\n' "$out" | tail -1)
expect_has "recover RESPAWN" "$last" "RESPAWN executor leftover="
expect_has "leftover names the worktree and its commit count" "$last" "worktree:wt-w1(+1)"
expect_has "leftover: remote job whose marker is in the log" "$last" "remote:gate@abc(seen)"
expect_has "leftover: remote job still running" "$last" "remote:sweep@abc(not-seen)"
expect_has "leftover: live worker with its id" "$last" "worker:w1(ag-w1)"
expect_has "leftover: the executor that ended badly" "$last" "executor:rotation-1(fail)"
expect_has "page shows the worktree's commit" "$out" "feat: worker change"
expect_has "page shows the probe output" "$out" "probe-ok"
expect_has "page shows this round's commit count" "$out" "commits 1 (main 1 · agent 0)"
json=$(run "$BIN/recover.sh" --json)
expect_eq "--json carries the same action" \
  "$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["action"])')" "$last"
expect_has "--no-probe leaves the terminal state unknown" "$(run "$BIN/recover.sh" --no-probe | tail -1)" "remote:gate@abc(unknown)"
ev 1600 remote.end "\"remote\":{\"kind\":\"gate\",\"sha\":\"abc\",\"log\":\"$TMP/gate-abc.log\",\"status\":\"ok\"}"
ev 1500 gate.end "\"gate\":{\"sha\":\"abc\",\"pass\":1,\"fail\":0,\"skip\":0,\"log\":\"$TMP/sweep.log\"}"
expect_not "remote.end / gate.end close their remote.start" "$(action)" "remote:"
g worktree remove --force "$TMP/wt-w1"
g branch -q -D agent-w1

# ── watchdog: the four exits ────────────────────────────────────────────
reset
ev 10 preflight.end '"preflight":{"result":"PASS"}'
out=$(watch); expect_eq "watchdog quiet → exit 0" "$?" "0"
expect_has "watchdog quiet line" "$out" "OK "

reset
ev 400 executor.waiting "\"remote\":{\"log\":\"$TMP/gate-abc.log\",\"marker\":\"[0-9]+ pass / [0-9]+ fail\"}"
out=$(watch); expect_eq "WAKE: remote marker seen → exit 10" "$?" "10"
expect_has "WAKE line" "$out" "WAKE remote=$TMP/gate-abc.log"
watch --wake 900 >/dev/null; expect_eq "WAKE holds until --wake seconds passed" "$?" "0"
reset
ev 400 executor.waiting "\"remote\":{\"log\":\"$TMP/sweep.log\",\"marker\":\"DONE\"}"
watch >/dev/null; expect_eq "no WAKE while the marker is absent" "$?" "0"
reset
ev 400 executor.waiting "\"remote\":{\"log\":\"$TMP/gate-abc.log\",\"marker\":\"[0-9]+ pass\"}"
ev 350 preflight.end '"preflight":{"result":"PASS"}'
watch >/dev/null; expect_eq "no WAKE once the executor recorded something later" "$?" "0"

# ── WAKE without an executor.waiting: a remote.end of this round and nothing from the executor after it ──
reset
ev 400 remote.end "\"remote\":{\"kind\":\"close.checks\",\"sha\":\"abc\",\"log\":\"$TMP/seg.log\",\"status\":\"ok\"}"
out=$(watch); expect_eq "WAKE: remote.end 400 s ago, no event since → exit 10" "$?" "10"
expect_has "WAKE line names the ended job" "$out" "WAKE remote.end kind=close.checks sha=abc log=$TMP/seg.log is on record and no executor event followed for"
expect_has "WAKE line says the clock started at the remote.end" "$out" " s since remote.end "
expect_has "recover shows the silence after the remote.end" "$(run "$BIN/recover.sh")" " kind=close.checks sha=abc · executor moved since=no · wake after 300 s"
reset
ev 100 remote.end "\"remote\":{\"kind\":\"close.checks\",\"sha\":\"abc\",\"log\":\"$TMP/seg.log\",\"status\":\"ok\"}"
watch >/dev/null; expect_eq "no WAKE inside the 300 s default" "$?" "0"
reset
ev 400 remote.end "\"remote\":{\"kind\":\"close.checks\",\"sha\":\"abc\",\"log\":\"$TMP/seg.log\",\"status\":\"ok\"}"
ev 350 preflight.end '"preflight":{"result":"PASS"}'
watch >/dev/null; expect_eq "no WAKE once the executor recorded an event after the remote.end" "$?" "0"
expect_has "recover shows what moved" "$(run "$BIN/recover.sh")" "executor moved since=yes (event preflight.end)"
reset
ev 400 remote.end "\"remote\":{\"kind\":\"close.checks\",\"sha\":\"abc\",\"log\":\"$TMP/seg.log\",\"status\":\"ok\"}"
ev 350 manager.start '"managerSession":"sess-A"'
ev 340 agent.start "$(agent seg-1 manager)"
ev 330 manager.verify '"managerSession":"sess-A","manager":{"checks":{"1":"pass"},"result":"pass"}'
watch >/dev/null; expect_eq "WAKE still due: the manager's own events are not the executor moving" "$?" "10"
reset
ev 1000 remote.end "\"remote\":{\"kind\":\"gate\",\"sha\":\"abc\",\"log\":\"$TMP/gate-abc.log\",\"status\":\"ok\"}"
ev 100 manager.resume '"managerSession":"sess-A","manager":{"agent":{"id":"ag-1"},"reason":"wake"}'
watch >/dev/null; expect_eq "no WAKE within 300 s of a manager.resume: the clock restarts there" "$?" "0"
expect_has "recover shows the restarted clock" "$(run "$BIN/recover.sh")" "clock restarted by manager.resume"
reset
ev 1000 remote.end "\"remote\":{\"kind\":\"gate\",\"sha\":\"abc\",\"log\":\"$TMP/gate-abc.log\",\"status\":\"ok\"}"
ev 400 manager.resume '"managerSession":"sess-A","manager":{"agent":{"id":"ag-1"},"reason":"wake"}'
out=$(watch); expect_eq "WAKE again 300 s after the manager.resume with nothing from the executor" "$?" "10"
expect_has "WAKE line counts from the manager.resume" "$out" " s since manager.resume "
reset
ev 7200 remote.end "\"remote\":{\"kind\":\"gate\",\"sha\":\"old\",\"log\":\"$TMP/old.log\",\"status\":\"ok\"}"
ev 100 preflight.end '"preflight":{"result":"PASS"}'
watch >/dev/null; expect_eq "a remote.end from before this round is not a WAKE" "$?" "0"
expect_has "recover says the round has no remote.end" "$(run "$BIN/recover.sh")" "last remote.end: none this round"
printf 'ROTATION_CONF_KERNEL=1\nROTATION_WAKE_AFTER=1000\n' > "$TMP/wake.conf"
reset
ev 400 remote.end "\"remote\":{\"kind\":\"close.checks\",\"sha\":\"abc\",\"log\":\"$TMP/seg.log\",\"status\":\"ok\"}"
CONF="$TMP/wake.conf" watch >/dev/null; expect_eq "ROTATION_WAKE_AFTER=1000 in the conf: 400 s is not yet a WAKE" "$?" "0"
expect_has "recover shows the configured wait" "$(CONF="$TMP/wake.conf" run "$BIN/recover.sh")" "wake after 1000 s"
ROTATION_WAKE_AFTER=1 watch >/dev/null 2>&1; expect_eq "ROTATION_WAKE_AFTER from the environment is ignored (conf-only): still a WAKE at 300" "$?" "10"

reset
ev 900 agent.start "$(agent w1 worker)"
ev 900 agent.start "$(agent w2 worker)"
ev 800 executor.waiting '"workers":["w1","w2"]'
ev 700 agent.end "$(agent w1 worker '"status":"ok"')"
watch >/dev/null; expect_eq "no WAKE while a listed worker is still running" "$?" "0"
ev 400 agent.end "$(agent w2 worker '"status":"ok"')"
out=$(watch); expect_eq "WAKE: every listed worker ended → exit 10" "$?" "10"
expect_has "WAKE workers line" "$out" "WAKE workers=w1,w2"

reset
ev 2000 preflight.end '"preflight":{"result":"PASS"}'
out=$(watch); expect_eq "STALE → exit 11" "$?" "11"
expect_has "STALE line" "$out" "STALE no event and no commit for"
watch --stale 3000 >/dev/null; expect_eq "STALE respects --stale" "$?" "0"
g worktree add -q -b agent-w2 "$TMP/wt-w2" develop
GIT_COMMITTER_DATE="$((NOW - 60)) +0000" git -C "$TMP/wt-w2" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m "feat: worker progress"
watch >/dev/null; expect_eq "no STALE: no event, but a fresh commit in a worktree" "$?" "0"
g worktree remove --force "$TMP/wt-w2"; g branch -q -D agent-w2
watch >/dev/null; expect_eq "STALE again once neither events nor commits are recent" "$?" "11"
GIT_COMMITTER_DATE="$((NOW - 60)) +0000" g commit -q --allow-empty -m "feat: executor progress"
watch >/dev/null; expect_eq "no STALE: no event, but a fresh commit on the main tree" "$?" "0"
expect_has "recover shows the same last activity" "$(run "$BIN/recover.sh")" "· commit on the main tree"
# the fresh commit (NOW-60) also answers a remote.end: the executor is at work
reset
ev 400 remote.end "\"remote\":{\"kind\":\"close.checks\",\"sha\":\"abc\",\"log\":\"$TMP/seg.log\",\"status\":\"ok\"}"
watch >/dev/null; expect_eq "no WAKE after a remote.end when the main tree got a commit since" "$?" "0"
expect_has "recover names the commit as the movement" "$(run "$BIN/recover.sh")" "executor moved since=yes (commit on the main tree)"

reset
ev 100 quota.hit "\"quota\":{\"resets\":$((NOW - 10)),\"agent\":\"ag-123\"}"
out=$(watch); expect_eq "QUOTA: reset time passed → exit 12" "$?" "12"
expect_has "QUOTA line names the agent" "$out" "agent=ag-123"
reset
ev 100 quota.hit "\"quota\":{\"resets\":\"$(date -u -r $((NOW + 600)) +%Y-%m-%dT%H:%M:%SZ)\"}"
watch >/dev/null; expect_eq "no QUOTA before the reset time" "$?" "0"
reset
ev 100 quota.hit "\"quota\":{\"resets\":$((NOW - 50))}"
ev 20 agent.start "$(agent rotation-1 rotation)"
watch >/dev/null; expect_eq "no QUOTA once an event followed" "$?" "0"
# the manager continuing the executor (manager.resume) answers the quota.hit; its other bookkeeping does not
reset
ev 100 quota.hit "\"quota\":{\"resets\":$((NOW - 50)),\"agent\":\"ag-1\"}"
ev 20 manager.resume '"managerSession":"sess-A","manager":{"agent":{"id":"ag-1"},"reason":"quota"}'
watch >/dev/null; expect_eq "no QUOTA once the manager recorded manager.resume" "$?" "0"
expect_has "recover shows the quota as answered" "$(run "$BIN/recover.sh")" "events since=yes"
reset
ev 100 quota.hit "\"quota\":{\"resets\":$((NOW - 50)),\"agent\":\"ag-1\"}"
ev 20 agent.start "$(agent seg-1 manager)"
ev 15 manager.verify '"managerSession":"sess-A","manager":{"checks":{"1":"pass"},"result":"pass"}'
watch >/dev/null; expect_eq "QUOTA still due after a manager segment and a manager.verify" "$?" "12"
# the same for WAKE: a manager.resume after the awaited marker counts as the executor having moved
reset
ev 400 executor.waiting "\"remote\":{\"log\":\"$TMP/gate-abc.log\",\"marker\":\"[0-9]+ pass\"}"
ev 350 manager.resume '"managerSession":"sess-A","manager":{"agent":{"id":"ag-1"},"reason":"wake"}'
watch >/dev/null; expect_eq "no WAKE once the manager recorded manager.resume" "$?" "0"
reset
ev 400 executor.waiting "\"remote\":{\"log\":\"$TMP/gate-abc.log\",\"marker\":\"[0-9]+ pass\"}"
ev 350 manager.start '"managerSession":"sess-A"'
watch >/dev/null; expect_eq "WAKE still due after a manager.start" "$?" "10"

# ── MULTI-EXECUTOR: the protocol runs one rotation executor at a time ──
reset
ev 300 agent.start "$(agent rotation-1 rotation '"id":"ag-1"')"
ev 200 agent.start "$(agent rotation-2 rotation '"id":"ag-2"')"
out=$(watch); expect_eq "MULTI-EXECUTOR: two running executors → exit 15" "$?" "15"
expect_has "MULTI-EXECUTOR line names both" "$out" "MULTI-EXECUTOR n=2 executors=rotation-1(ag-1),rotation-2(ag-2)"
ev 100 quota.hit "\"quota\":{\"resets\":$((NOW - 50))}"
watch >/dev/null; expect_eq "MULTI-EXECUTOR outranks QUOTA" "$?" "15"
out=$(run "$BIN/recover.sh")
expect_has "recover page flags more than one executor" "$out" "running rotation executors: 2 — rotation-1(ag-1), rotation-2(ag-2) · MORE THAN ONE"
ev 50 agent.end "$(agent rotation-1 rotation '"status":"abandoned"')"
watch >/dev/null; expect_eq "no MULTI-EXECUTOR once the stale one is ended" "$?" "0"
expect_has "recover page counts one executor" "$(run "$BIN/recover.sh")" "running rotation executors: 1 — rotation-2(ag-2)"
reset
ev 300 agent.start "$(agent rotation-1 rotation '"id":"ag-1"')"
ev 200 agent.start "$(agent rotation-1 rotation '"id":"ag-1b"')"
watch >/dev/null; expect_eq "re-registering the same name supersedes, not MULTI-EXECUTOR" "$?" "0"

reset
ev 1500 preflight.end '"preflight":{"result":"PASS"}'
echo x > "$REPO/stray.txt"
watch --stale 99999 >/dev/null; expect_eq "no DIRTY for a file written just now" "$?" "0"
touch -t "$(date -r $((NOW - 700)) +%Y%m%d%H%M.%S)" "$REPO/stray.txt"
out=$(watch --stale 99999); expect_eq "DIRTY → exit 13" "$?" "13"
expect_has "DIRTY line names the file" "$out" "files=stray.txt"
ev 60 preflight.end '"preflight":{"result":"PASS"}'
watch --stale 99999 >/dev/null; expect_eq "no DIRTY when the executor has been active since" "$?" "0"
rm "$REPO/stray.txt"

# the loop itself: a hit ends it; staleness is counted from its own start, not from an old log
# ── FOREIGN-COMMIT: a commit on the main tree that no running executor accounts for ──
# HEAD is now "feat: executor progress" (committed NOW-60), one first-parent commit past the round's prevHead.
reset
touch "$TMP/manager.active"
MARKER="$TMP/manager.active"
out=$(watch); expect_eq "FOREIGN-COMMIT: marker present, no executor ever registered → exit 14" "$?" "14"
expect_has "FOREIGN-COMMIT line" "$out" "FOREIGN-COMMIT n=2 head="
expect_has "recover page counts the foreign commits" "$(run "$BIN/recover.sh")" "foreign commits: 2 on the main tree"
expect_has "recover leftover names them" "$(action)" "foreign-commits:2"
reset
ev 200 agent.start "$(agent rotation-1 rotation '"id":"ag-1"')"
watch >/dev/null; expect_eq "no FOREIGN-COMMIT while an executor is registered as running" "$?" "0"
reset
ev 200 agent.start "$(agent rotation-1 rotation '"id":"ag-1"')"
ev 120 agent.end "$(agent rotation-1 rotation '"status":"ok"')"
out=$(watch); expect_eq "FOREIGN-COMMIT: HEAD committed after the executor ended → exit 14" "$?" "14"
expect_has "FOREIGN-COMMIT names the executor's last event" "$out" "after the last executor event"
reset
ev 200 agent.start "$(agent rotation-1 rotation '"id":"ag-1"')"
ev 30 agent.end "$(agent rotation-1 rotation '"status":"ok"')"
watch >/dev/null; expect_eq "no FOREIGN-COMMIT when the commit landed while the executor ran" "$?" "0"
MARKER="$TMP/no-marker"
reset
watch >/dev/null; expect_eq "no FOREIGN-COMMIT without the manager marker" "$?" "0"
expect_has "recover says the check did not run without the marker" "$(run "$BIN/recover.sh")" "foreign commits: not checked"

reset
ev 100 quota.hit "\"quota\":{\"resets\":$((NOW - 10))}"
run "$BIN/watchdog.sh" --interval 1 >/dev/null; expect_eq "loop exits on a hit" "$?" "12"
reset
ev 5000 preflight.end '"preflight":{"result":"PASS"}'
t0=$(date +%s)
out=$(run "$BIN/watchdog.sh" --interval 1 --stale 2); rc=$?
expect_eq "loop STALE → exit 11" "$rc" "11"
[ $(( $(date +%s) - t0 )) -ge 2 ] && ok "loop counts staleness from its own start" || bad "loop counts staleness from its own start"
run "$BIN/watchdog.sh" --bogus >/dev/null 2>&1; expect_eq "watchdog usage error → exit 2" "$?" "2"
before=$(g status --porcelain | wc -l | tr -d ' ')
expect_eq "watchdog and recover left the tree untouched" "$before" "0"

# ── event.sh and agent_log.sh write what the readers read ───────────────
reset
run "$BIN/event.sh" remote.start remote.kind=gate remote.sha=abc "remote.log=$TMP/gate-abc.log" 'remote.marker=[0-9]+ pass' >/dev/null
expect_eq "event.sh remote.start" "$?" "0"
run "$BIN/event.sh" executor.waiting workers=list:w1,w2 >/dev/null
run "$BIN/event.sh" quota.hit "quota.resets=int:$((NOW - 5))" quota.agent=ag-9 >/dev/null
shape=$(python3 - "$EV" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
print(rows[0]["kind"], rows[0]["remote"]["kind"], rows[0]["remote"]["marker"], rows[1]["workers"], type(rows[2]["quota"]["resets"]).__name__, rows[2]["quota"]["agent"])
PY
)
expect_eq "event.sh nests dotted keys and types values" "$shape" "remote.start gate [0-9]+ pass ['w1', 'w2'] int ag-9"
out=$(watch); expect_eq "an event.sh quota.hit is read back as QUOTA" "$?" "12"
expect_has "recover reads the same log (waiting and quota lines)" "$(run "$BIN/recover.sh")" "quota.hit: "
run "$BIN/event.sh" quota.hit resets=1 >/dev/null 2>&1; expect_eq "event.sh refuses a quota.hit without quota.resets" "$?" "2"
run "$BIN/event.sh" remote.start remote.kind=gate >/dev/null 2>&1; expect_eq "event.sh refuses remote.start without a log" "$?" "2"
run "$BIN/event.sh" executor.waiting >/dev/null 2>&1; expect_eq "event.sh refuses an empty executor.waiting" "$?" "2"
run "$BIN/event.sh" Bad >/dev/null 2>&1; expect_eq "event.sh refuses a malformed kind" "$?" "2"
expect_eq "refused events were not written" "$(wc -l < "$EV" | tr -d ' ')" "3"

reset
run "$BIN/agent_log.sh" start w9 worker m "task" >/dev/null
run env ROTATION_AGENT_ID=ag-77 ROTATION_AGENT_WORKTREE=/wt/w9 ROTATION_AGENT_SCRATCH=/s/w9 ROTATION_AGENT_GATE_LOG=/tmp/g.log \
  "$BIN/agent_log.sh" start w10 worker m "task" >/dev/null
shape=$(python3 - "$EV" <<'PY'
import json, sys
a, b = [json.loads(l)["agent"] for l in open(sys.argv[1])]
print("id" in a, b["id"], b["worktree"], b["scratch"], b["gateLog"])
PY
)
expect_eq "agent_log.sh: ids only when given, old call unchanged" "$shape" "False ag-77 /wt/w9 /s/w9 /tmp/g.log"
run "$BIN/agent_log.sh" start rot-x rotation m "task" >/dev/null 2>&1
expect_eq "agent_log.sh refuses a rotation start without ROTATION_AGENT_ID" "$?" "2"
expect_eq "the refused start wrote nothing" "$(wc -l < "$EV" | tr -d ' ')" "2"
[ -f "$TMP/state/manager.active" ] && bad "refused start must not write the manager marker" || ok "refused start leaves no manager marker"
run env ROTATION_AGENT_ID=ag-rot "$BIN/agent_log.sh" start rot-x rotation m "task" >/dev/null
expect_eq "agent_log.sh records a rotation start with an id" "$?" "0"
shape=$(python3 - "$EV" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
print(" ".join(r["kind"] for r in rows))
s = [r for r in rows if r["kind"] == "rotation.start"]
print(s[0]["mode"], s[0]["rotationAgent"], s[0]["agent"]["name"], s[0]["agent"]["id"], s[0]["rotationId"]) if s else print("none")
PY
)
expect_eq "a rotation start also records rotation.start; worker starts do not" "$(printf '%s' "$shape" | head -1)" "agent.start agent.start agent.start rotation.start"
expect_eq "rotation.start carries mode, the executor name and its id" "$(printf '%s' "$shape" | tail -1)" "subagent rot-x rot-x ag-rot r-test"
expect_has "the manager marker carries the executor id" "$(cat "$TMP/state/manager.active")" "id=ag-rot"
expect_has "the manager marker carries the session" "$(cat "$TMP/state/manager.active")" "session=sess-A"
expect_eq "recover resumes it by id" "$(action)" "RESUME ag-rot"
shape=$(python3 - "$EV" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
print(" ".join(f"{r['kind']}:{r['managerSession']}" if "managerSession" in r else f"{r['kind']}:-" for r in rows))
PY
)
expect_eq "agent_log.sh records managerSession on the rotation start and rotation.start, not on worker starts" \
  "$shape" "agent.start:- agent.start:- agent.start:sess-A rotation.start:sess-A"
SESSION=sess-B
expect_has "from another session the same executor is RESPAWN" "$(action)" "RESPAWN executor leftover=executor:rot-x(ag-rot,mismatch);"
SESSION=sess-A
run env ROTATION_MANAGER_IDLE=1 "$BIN/agent_log.sh" end rot-x rotation m "task" >/dev/null
[ -f "$TMP/state/manager.active" ] && bad "idle end removes the manager marker" || ok "idle end removes the manager marker"
reset
SESSION=
run env ROTATION_AGENT_ID=ag-n "$BIN/agent_log.sh" start rot-n rotation m "task" >/dev/null
expect_eq "no session id when registering: managerSession is null" \
  "$(python3 -c 'import json,sys; r=json.loads(open(sys.argv[1]).readline()); print("managerSession" in r, r["managerSession"])' "$EV")" "True None"
SESSION=sess-A
expect_eq "an executor registered with a null session is not resumed" "$(action)" "RESPAWN executor leftover=executor:rot-n(ag-n,no-session)"

# ── manager_log.sh: the manager session's five events ───────────────────
reset
run "$BIN/manager_log.sh" start >/dev/null; expect_eq "manager_log.sh start" "$?" "0"
run "$BIN/manager_log.sh" spawn ag-1 rotation-1 >/dev/null; expect_eq "manager_log.sh spawn" "$?" "0"
run "$BIN/manager_log.sh" resume ag-1 quota >/dev/null; expect_eq "manager_log.sh resume" "$?" "0"
run "$BIN/manager_log.sh" verify 1=pass 2=pass 3=fail 4=pass >/dev/null; expect_eq "manager_log.sh verify" "$?" "0"
run "$BIN/manager_log.sh" stop user-stop >/dev/null; expect_eq "manager_log.sh stop" "$?" "0"
shape=$(python3 - "$EV" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
print(" ".join(r["kind"] for r in rows))
print(" ".join(str(r["managerSession"]) for r in rows))
sp, rs, vf, st = rows[1]["manager"], rows[2]["manager"], rows[3]["manager"], rows[4]["manager"]
print(sp["agent"]["id"], sp["agent"]["name"], rs["agent"]["id"], "name" in rs["agent"], rs["reason"])
print(vf["result"], vf["failed"], vf["checks"]["3"], len(vf["checks"]), st["reason"])
PY
)
expect_eq "the five kinds in order" "$(printf '%s\n' "$shape" | sed -n 1p)" "manager.start manager.spawn manager.resume manager.verify manager.stop"
expect_eq "every manager event carries the session" "$(printf '%s\n' "$shape" | sed -n 2p)" "sess-A sess-A sess-A sess-A sess-A"
expect_eq "spawn / resume carry the agent and the reason" "$(printf '%s\n' "$shape" | sed -n 3p)" "ag-1 rotation-1 ag-1 False quota"
expect_eq "verify carries every check, the failed list and the overall result" "$(printf '%s\n' "$shape" | sed -n 4p)" "fail ['3'] fail 4 user-stop"
SESSION=
run "$BIN/manager_log.sh" start >/dev/null
expect_eq "manager.start outside a session writes managerSession null" \
  "$(tail -1 "$EV" | python3 -c 'import json,sys; r=json.load(sys.stdin); print("managerSession" in r, r["managerSession"])')" "True None"
SESSION=sess-A
run "$BIN/manager_log.sh" resume ag-1 bored >/dev/null 2>&1; expect_eq "manager_log.sh refuses an unknown resume reason" "$?" "2"
run "$BIN/manager_log.sh" resume >/dev/null 2>&1; expect_eq "manager_log.sh refuses a resume without an agent" "$?" "2"
run "$BIN/manager_log.sh" verify 1=maybe >/dev/null 2>&1; expect_eq "manager_log.sh refuses a verify result that is not pass|fail" "$?" "2"
run "$BIN/manager_log.sh" verify >/dev/null 2>&1; expect_eq "manager_log.sh refuses an empty verify" "$?" "2"
run "$BIN/manager_log.sh" pause >/dev/null 2>&1; expect_eq "manager_log.sh refuses an unknown verb" "$?" "2"
run "$BIN/event.sh" manager.spawn managerSession=sess-A >/dev/null 2>&1; expect_eq "event.sh refuses manager.spawn without an agent id" "$?" "2"
run "$BIN/event.sh" manager.start >/dev/null 2>&1; expect_eq "event.sh refuses a manager event without managerSession" "$?" "2"
run "$BIN/event.sh" manager.pause managerSession=sess-A >/dev/null 2>&1; expect_eq "event.sh refuses an unknown manager kind" "$?" "2"
expect_eq "refused manager events were not written" "$(wc -l < "$EV" | tr -d ' ')" "6"

# ── kill_stray_shells.sh: only the pids this round registered die; the watchdog and other agents' shells live ──
# A throwaway process tree whose root's comm contains "claude" (bash under a symlink named so; the
# reaper walks up to the first such ancestor). Under it, Bash-tool-like shells (the shell-snapshots
# marker on their command line): one the executor registered (process.start with its pid in a
# throwaway events log), one registered and then ended (process.end), one nobody registered (another
# agent's), one registered under an earlier round's id, and one running a watchdog.sh. A sleeper
# started outside the fake session is registered too: a pid that is not under the session is STALE.
RT="$TMP/reaper"; mkdir -p "$RT/kernel"
ln -s /bin/bash "$RT/claude-sim"
printf '#!/bin/bash\nsleep 300\n' > "$RT/kernel/watchdog.sh"
cp "$BIN/kill_stray_shells.sh" "$RT/kernel/"
REV="$RT/events.jsonl"
sleep 300 & outside=$!
cat > "$RT/tree.sh" <<EOF
reg() { printf '{"at":"x","ts":$NOW,"kind":"%s","rotationId":"%s","head":"x","process":{"pid":%s,"what":"t"}}\n' "\$1" "\$3" "\$2" >> "$REV"; }
/bin/zsh -c 'true shell-snapshots; sleep 300; :' >/dev/null 2>&1 & mine=\$!
/bin/zsh -c 'true shell-snapshots; sleep 300; :' >/dev/null 2>&1 & ended=\$!
/bin/zsh -c 'true shell-snapshots; sleep 300; :' >/dev/null 2>&1 & other=\$!
/bin/zsh -c 'true shell-snapshots; bash $RT/kernel/watchdog.sh; :' >/dev/null 2>&1 & wd=\$!
/bin/zsh -c 'true shell-snapshots; sleep 300; :' >/dev/null 2>&1 & lastround=\$!
: > "$REV"
reg process.start \$mine r-test
reg process.start \$ended r-test; reg process.end \$ended r-test
reg process.start $outside r-test
reg process.start \$lastround r-old
sleep 1
ROTATION_EVENTS_LOG="$REV" ROTATION_REAP_ROTATION_ID=r-test ROTATION_REAP_REMOTE_CMD="touch $RT/remote-reaped" \
  bash "$RT/kernel/kill_stray_shells.sh" > "$RT/reaper.out" 2>&1; echo "rc=\$?" > "$RT/reaper.rc"
sleep 1
alive() { kill -0 "\$1" 2>/dev/null && echo alive || echo dead; }
echo "mine=\$(alive \$mine) ended=\$(alive \$ended) other=\$(alive \$other) watchdog=\$(alive \$wd) lastround=\$(alive \$lastround)"
down() { local c; for c in \$(pgrep -P "\$1"); do down "\$c"; done; kill "\$1" 2>/dev/null; }
down "\$mine"; down "\$ended"; down "\$other"; down "\$wd"; down "\$lastround"
EOF
tree=$("$RT/claude-sim" "$RT/tree.sh" 2>/dev/null)
expect_eq "reaper: the registered shell dies; the ended, the unregistered, the earlier round's and the watchdog shell live" \
  "$tree" "mine=dead ended=alive other=alive watchdog=alive lastround=alive"
expect_eq "reaper: KILL lines name the registered shell and its child only" "$(grep -c '^KILL ' "$RT/reaper.out")" "2"
expect_has "reaper: the registered pid outside the session is STALE, not killed" "$(cat "$RT/reaper.out")" "STALE $outside"
expect_eq "reaper: the sleeper outside the session is alive" "$(kill -0 "$outside" 2>/dev/null && echo alive || echo dead)" "alive"
expect_has "reaper: reports the count" "$(cat "$RT/reaper.out")" "REAPED 2"
expect_eq "reaper: exits 0" "$(cat "$RT/reaper.rc")" "rc=0"
expect_eq "reaper: session mode runs the remote reap command" "$([ -e "$RT/remote-reaped" ] && echo ran || echo no)" "ran"
kill "$outside" 2>/dev/null
# manager mode: manager.active in the state directory. Registered pids are still this round's own and die;
# the remote pattern reap is skipped (workers' remote jobs match the same patterns). An empty registry is CLEAN.
mkdir -p "$RT/state-managed"; echo "rotation=r-x executor=e id=a since=t session=s" > "$RT/state-managed/manager.active"
rm -f "$RT/remote-reaped"
cat > "$RT/tree2.sh" <<EOF
reg() { printf '{"at":"x","ts":$NOW,"kind":"%s","rotationId":"%s","head":"x","process":{"pid":%s,"what":"t"}}\n' "\$1" "\$3" "\$2" >> "$REV"; }
/bin/zsh -c 'true shell-snapshots; sleep 300; :' >/dev/null 2>&1 & mine=\$!
/bin/zsh -c 'true shell-snapshots; sleep 300; :' >/dev/null 2>&1 & other=\$!
/bin/zsh -c 'true shell-snapshots; bash $RT/kernel/watchdog.sh; :' >/dev/null 2>&1 & wd=\$!
: > "$REV"
reg process.start \$mine r-test
sleep 1
ROTATION_STATE_DIR="$RT/state-managed" ROTATION_EVENTS_LOG="$REV" ROTATION_REAP_ROTATION_ID=r-test ROTATION_REAP_REMOTE_CMD="touch $RT/remote-reaped" \
  bash "$RT/kernel/kill_stray_shells.sh" > "$RT/reaper2.out" 2>&1; echo "rc=\$?" > "$RT/reaper2.rc"
sleep 1
alive() { kill -0 "\$1" 2>/dev/null && echo alive || echo dead; }
echo "mine=\$(alive \$mine) other=\$(alive \$other) watchdog=\$(alive \$wd)"
: > "$REV"
ROTATION_STATE_DIR="$RT/state-managed" ROTATION_EVENTS_LOG="$REV" ROTATION_REAP_ROTATION_ID=r-test \
  bash "$RT/kernel/kill_stray_shells.sh" > "$RT/reaper3.out" 2>&1
sleep 1
echo "other=\$(alive \$other) watchdog=\$(alive \$wd)"
down() { local c; for c in \$(pgrep -P "\$1"); do down "\$c"; done; kill "\$1" 2>/dev/null; }
down "\$mine"; down "\$other"; down "\$wd"
EOF
tree2=$("$RT/claude-sim" "$RT/tree2.sh" 2>/dev/null)
expect_eq "reaper: manager mode — the registered shell dies, the other agent's shell and the watchdog live" \
  "$tree2" "$(printf 'mine=dead other=alive watchdog=alive\nother=alive watchdog=alive')"
expect_has "reaper: manager mode skips the remote reap and says so" "$(cat "$RT/reaper2.out")" "SKIP remote reap: manager mode"
expect_eq "reaper: manager mode did not run the remote reap command" "$([ -e "$RT/remote-reaped" ] && echo ran || echo no)" "no"
expect_eq "reaper: manager mode exits 0" "$(cat "$RT/reaper2.rc")" "rc=0"
expect_has "reaper: an empty registry is CLEAN" "$(cat "$RT/reaper3.out")" "CLEAN: no registered process"
expect_not "reaper: an empty registry kills nothing" "$(cat "$RT/reaper3.out")" "KILL"
# the registration itself: event.sh accepts process.start / process.end with a pid and refuses them without
run "$BIN/event.sh" process.start process.pid=int:4242 process.what=gate >/dev/null 2>&1; expect_eq "event.sh records process.start with a pid" "$?" "0"
expect_eq "process.start row carries the pid" "$(tail -1 "$EV" | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r["kind"], r["process"]["pid"], r["process"]["what"])')" "process.start 4242 gate"
run "$BIN/event.sh" process.end process.pid=int:4242 >/dev/null 2>&1; expect_eq "event.sh records process.end" "$?" "0"
run "$BIN/event.sh" process.start process.what=gate >/dev/null 2>&1; expect_eq "event.sh refuses process.start without a pid" "$?" "2"
run "$BIN/event.sh" process.start process.pid=4242 >/dev/null 2>&1; expect_eq "event.sh refuses a pid that is not int:" "$?" "2"

# ── a job recorded without a host is local: its log is read here, the remote grep is never called ──
# never.sh stands in for a remote grep that must not run (exit 7 = unknown, which would show as `(unknown)`)
printf '#!/bin/sh\nexit 7\n' > "$TMP/never.sh"; chmod +x "$TMP/never.sh"
MARKER="$TMP/no-marker"; SESSION=sess-A
reset
ev 3500 rotation.end '"trigger":"self"'
ev 900 remote.start "\"remote\":{\"kind\":\"close.plan\",\"sha\":\"abc\",\"log\":\"$TMP/local-seg.log\",\"marker\":\"^DONE segment=plan \"}"
GREP_CMD="$TMP/never.sh"
local_action() { run "$BIN/recover.sh" | tail -1; }
expect_eq "local job (no host), no log yet: not-seen without calling the remote grep" "$(local_action)" "RESPAWN executor leftover=remote:close.plan@abc(not-seen)"
echo "START plan" > "$TMP/local-seg.log"
expect_eq "local job, log without the marker: not-seen" "$(local_action)" "RESPAWN executor leftover=remote:close.plan@abc(not-seen)"
echo "DONE segment=plan head=abc rc=0" >> "$TMP/local-seg.log"
expect_eq "local job, marker in the local log: seen" "$(local_action)" "RESPAWN executor leftover=remote:close.plan@abc(seen)"
expect_has "page prints the local job without a host" "$(run "$BIN/recover.sh")" "kind=close.plan sha=abc log=$TMP/local-seg.log host=— "
ev 400 executor.waiting "\"remote\":{\"log\":\"$TMP/local-seg.log\",\"marker\":\"^DONE segment=plan \"}"
out=$(watch); expect_eq "WAKE on a local job's marker (no host) → exit 10" "$?" "10"
ev 1100 remote.start "\"remote\":{\"kind\":\"gate\",\"sha\":\"abd\",\"log\":\"$TMP/with-host.log\",\"marker\":\"DONE\",\"host\":\"h\"}"
expect_has "a job with a host still goes through the remote grep (unknown here)" "$(local_action)" "remote:gate@abd(unknown)"

# ── a finished job nobody recorded the end of: the page offers the commands that collect it ──
# collect.sh stands in for the project's ROTATION_REMOTE_COLLECT_CMD: it knows where a gate leaves its results and
# nothing else (prints nothing for other kinds)
cat > "$TMP/collect.sh" <<'EOF'
#!/bin/sh
# <kind> <sha> <log> <host> <rotationId>
[ "$1" = gate ] || exit 0
echo "fetch-gate-results $2 from $4 log=$3 round=$5"
echo "record-gate-end $2"
EOF
chmod +x "$TMP/collect.sh"
GREP_CMD="$TMP/fake_grep.sh"
reset
ev 3500 rotation.end '"trigger":"self"'
ev 900 remote.start "\"remote\":{\"kind\":\"gate\",\"sha\":\"abc\",\"log\":\"$TMP/gate-abc.log\",\"marker\":\"[0-9]+ pass\",\"host\":\"h\"}"
ev 800 remote.start "\"remote\":{\"kind\":\"close.plan\",\"sha\":\"abc\",\"log\":\"$TMP/local-seg.log\",\"marker\":\"^DONE segment=plan \"}"
ev 700 remote.start "\"remote\":{\"kind\":\"sweep\",\"sha\":\"abc\",\"log\":\"$TMP/sweep.log\",\"marker\":\"DONE\",\"host\":\"h\"}"
out=$(COLLECT_CMD="$TMP/collect.sh" run "$BIN/recover.sh")
expect_has "page: the project's collect commands for a kind it knows, with every argument passed" "$out" "    collect: fetch-gate-results abc from h log=$TMP/gate-abc.log round=r-test"
expect_has "page: every line the project printed" "$out" "    collect: record-gate-end abc"
expect_has "page: a kind the project does not know gets the record-the-end command, host left out for a local job" "$out" \
  "    collect: bash $BIN/event.sh remote.end remote.kind=close.plan remote.sha=abc remote.log=$TMP/local-seg.log remote.status=ok"
expect_not "page: a job whose marker is not in the log gets no command" "$out" "remote.kind=sweep"
out=$(run "$BIN/recover.sh")
expect_has "no collect command configured: the record-the-end command, with the host" "$out" \
  "    collect: bash $BIN/event.sh remote.end remote.kind=gate remote.sha=abc remote.log=$TMP/gate-abc.log remote.host=h remote.status=ok"
expect_eq "--json carries the commands" \
  "$(COLLECT_CMD="$TMP/collect.sh" run "$BIN/recover.sh" --json | python3 -c 'import json,sys; r=json.load(sys.stdin)["remotes"]; print(len(r[0]["collect"]), len(r[1]["collect"]), len(r[2]["collect"]))')" "2 1 0"
expect_not "--no-probe: the marker is unknown, no command is offered" "$(COLLECT_CMD="$TMP/collect.sh" run "$BIN/recover.sh" --no-probe)" "    collect:"
# the command printed is the one that closes the record: running it leaves nothing open
run sh -c "$(printf '%s\n' "$out" | sed -n 's/^    collect: //p' | head -1)" >/dev/null
expect_eq "running the offered command records the end" "$(action)" "RESPAWN executor leftover=remote:close.plan@abc(seen);remote:sweep@abc(not-seen)"

# ── a worker registered as running whose transcript stopped (dead?) ───────
# transcripts live in config dirs as <dir>/projects/<project>/<session>/subagents/agent-<id>.jsonl; the worker's
# start event carries no session, so the round's executor's managerSession (sess-A) is where it is looked for
tr_file() {  # tr_file <config dir> <session> <agent id> <seconds ago>
  local f="$1/projects/-x-repo/$2/subagents/agent-$3.jsonl"
  mkdir -p "$(dirname "$f")"; echo '{}' > "$f"
  touch -t "$(date -r "$((NOW - $4))" +%Y%m%d%H%M.%S)" "$f"
}
reset
ev 3500 rotation.end '"trigger":"self"'
ev 600 agent.start "$(agent rotation-1 rotation '"id":"ag-ex"'),\"managerSession\":\"sess-A\""
ev 500 agent.start "$(agent w9 worker '"id":"ag-w9"')"
ev 400 executor.waiting '"waiting":{"workers":["w9"]}'
tr_file "$TMP/cfg-b" sess-A ag-w9 1500
out=$(run "$BIN/recover.sh" --no-probe)
expect_has "dead?: the agent line shows the transcript state and its age" "$out" "transcript=dead? (25 min since written)"
expect_has "dead?: the page says what to do, with the id, the session and the task" "$out" "dead? w9: its transcript $TMP/cfg-b/projects/-x-repo/sess-A/subagents/agent-ag-w9.jsonl"
expect_has "dead?: continue or end and re-dispatch" "$out" "continue it (SendMessage to ag-w9, from session sess-A)"
expect_eq "--json carries the transcript state" \
  "$(run "$BIN/recover.sh" --json --no-probe | python3 -c 'import json,sys; w=json.load(sys.stdin)["workers"]; print(w[0]["name"], w[0]["transcript"]["state"], w[0]["transcript"]["session"])')" "w9 dead? sess-A"
out=$(watch); rc=$?
expect_eq "watchdog: a dead? worker is a WAKE" "$rc" "10"
expect_has "watchdog: WAKE names the worker and its id" "$out" "WAKE dead? worker(s) w9(ag-w9,"
# a manager.resume recorded before the worker went dead? relays nothing: still a WAKE
ev 400 manager.resume '"managerSession":"sess-A","manager":{"agent":{"id":"ag-ex"},"reason":"wake"}'
watch >/dev/null; expect_eq "dead?: a manager.resume from before it went dead? is no relay, still a WAKE" "$?" "10"
# the manager relays it (manager.resume after the WAKE): the page still says dead?, the watchdog stays quiet
ev 100 manager.resume '"managerSession":"sess-A","manager":{"agent":{"id":"ag-ex"},"reason":"wake"}'
watch >/dev/null; expect_eq "dead?: relayed by a manager.resume, no WAKE" "$?" "0"
out=$(run "$BIN/recover.sh" --no-probe)
expect_has "relayed: the page still shows dead?" "$out" "dead? w9: its transcript"
expect_has "relayed: the page says when it was relayed" "$out" "relayed $(date -u -r "$((NOW - 100))" +%Y-%m-%dT%H:%M:%SZ) (manager.resume"
# another worker that went dead? after that resume was never relayed: a WAKE naming it alone
ev 90 agent.start "$(agent w10 worker '"id":"ag-w10"')"
tr_file "$TMP/cfg-b" sess-A ag-w10 1250
out=$(watch); rc=$?
expect_eq "relayed w9 + unrelayed dead? w10: a WAKE" "$rc" "10"
expect_has "the WAKE names w10" "$out" "w10(ag-w10,"
expect_not "the WAKE leaves out the relayed w9" "$out" "w9(ag-w9,"
ev 80 agent.end "$(agent w10 worker '"id":"ag-w10"')"
# written again after the resume, then silent for the threshold once more: a WAKE again
reset
ev 3500 rotation.end '"trigger":"self"'
ev 3400 agent.start "$(agent rotation-1 rotation '"id":"ag-ex"'),\"managerSession\":\"sess-A\""
ev 3350 agent.start "$(agent w9 worker '"id":"ag-w9"')"
ev 2000 manager.resume '"managerSession":"sess-A","manager":{"agent":{"id":"ag-ex"},"reason":"wake"}'
tr_file "$TMP/cfg-b" sess-A ag-w9 3300
watch >/dev/null; expect_eq "relayed at 2000 s ago, not written since: no WAKE" "$?" "0"
tr_file "$TMP/cfg-b" sess-A ag-w9 1300
out=$(watch); rc=$?
expect_eq "written after the resume, silent ≥ the threshold again: a WAKE" "$rc" "10"
expect_has "the renewed WAKE names w9" "$out" "w9(ag-w9,"
expect_not "the renewed dead? is not marked relayed" "$(run "$BIN/recover.sh" --no-probe)" "relayed "
tr_file "$TMP/cfg-b" sess-A ag-w9 60
out=$(run "$BIN/recover.sh" --no-probe)
expect_has "a transcript written a minute ago is alive" "$out" "transcript=alive (1 min since written)"
expect_not "alive: no dead? line" "$out" "dead? w9"
watch >/dev/null; expect_eq "watchdog: an alive worker is no WAKE" "$?" "0"
# the threshold is the conf's
tr_file "$TMP/cfg-b" sess-A ag-w9 1500
printf 'ROTATION_CONF_KERNEL=1\nROTATION_WORKER_STALE=2000\n' > "$TMP/stale.conf"
CONF="$TMP/stale.conf" watch >/dev/null; expect_eq "ROTATION_WORKER_STALE=2000 in the conf: 1500 s is not dead" "$?" "0"
ROTATION_WORKER_STALE=60 watch >/dev/null 2>&1; expect_eq "ROTATION_WORKER_STALE from the environment is ignored (conf-only): 1500 s ≥ 1200 default is a WAKE" "$?" "10"
# no transcript anywhere: unknown, never a WAKE
rm -rf "$TMP/cfg-b"
out=$(run "$BIN/recover.sh" --no-probe)
expect_has "no transcript found: unknown" "$out" "transcript=unknown (no transcript found)"
watch >/dev/null; expect_eq "watchdog: an unknown transcript is no WAKE" "$?" "0"
# the worker's own session on its start event wins over the executor's
reset
ev 3500 rotation.end '"trigger":"self"'
ev 600 agent.start "$(agent rotation-1 rotation '"id":"ag-ex"'),\"managerSession\":\"sess-A\""
ev 500 agent.start "$(agent w8 worker '"id":"ag-w8"'),\"managerSession\":\"sess-Z\""
tr_file "$TMP/cfg-a" sess-Z ag-w8 1500
tr_file "$TMP/cfg-a" sess-A ag-w8 10
out=$(watch); rc=$?
expect_eq "the worker's own managerSession is where its transcript is read (sess-Z: dead?)" "$rc" "10"
# no session anywhere on record: unknown
reset
ev 3500 rotation.end '"trigger":"self"'
ev 600 agent.start "$(agent rotation-1 rotation '"id":"ag-ex"')"
ev 500 agent.start "$(agent w7 worker '"id":"ag-w7"')"
out=$(run "$BIN/recover.sh" --no-probe)
expect_has "no managerSession on record: unknown" "$out" "transcript=unknown (no session on record)"
# an ended worker is not judged
ev 100 agent.end "$(agent w7 worker '"id":"ag-w7"')"
expect_not "an ended worker has no transcript state" "$(run "$BIN/recover.sh" --no-probe)" "transcript="
rm -rf "$TMP/cfg-a"

echo
echo "recover_self_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
