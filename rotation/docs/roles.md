# Roles: manager, executor, worker

The manager mode: an interactive session that manages, a subagent per round that executes, the executor's own subagents that work. The protocol's reason for the split is the record of what happens without it — a session that both manages and executes drifts, and when it commits "just this one thing" between rounds, nothing in the history says who did it. `FOREIGN-COMMIT` and `managerCommits` make that visible; the role rules below keep it from happening.

The plugin ships the two prompts as templates with `{{…}}` placeholders for the project's values: `templates/manager-start.md` (the manager's playbook) and `templates/rotation-agent-prompt.md` (the executor's prompt, filled once per round). A project copies them, fills the placeholders once, and keeps the copies beside its other instructions.

## The manager

Four things, in a loop: **verify → compose the prompt → start one executor → wait for the report**. Then verify the report and start the next round.

### Red lines

- No commits, no source changes, no builds, no gate / sweep / bench / close segment run by hand, no diff review, no workers of its own. "The executor is unavailable and the handover cost is high" is not a reason: back off (3 / 10 / 20 min, then every 20) and start a **new** executor with the scene in `leftover:`; repeated failure is reported, never taken over.
- Never `trigger.sh self` (that is the executor's close). `trigger.sh manual` only when the operator says so, verbatim, and only the operator's terminal can run it.
- While a round runs, the manager starts no Bash of its own except the watchdog and the commands below.

### After a restart (first thing after a process restart, an account switch, quota restored)

1. `bash .claude/rotation/manager_log.sh start` — records `manager.start` with this session's `CLAUDE_CODE_SESSION_ID`
2. `bash .claude/rotation/doctor.sh` — last line `DOCTOR PASS …` or do not start a round; print FAIL lines to the operator verbatim
3. `bash .claude/rotation/recover.sh` — act on its **last line**, never on memory. See [recovery.md](recovery.md) for the four actions; in short: `RESUME <id>` only when this session (or its `--resume`) spawned the executor; `CLEAN main tree first` → the dirty files go into the next executor's `leftover:`, the manager does not touch them; `RESPAWN executor leftover=…` → a new executor with the page's leftovers; `IDLE` → start
4. Re-arm the watchdog (background tasks did not survive the restart)

### Start (every round)

1. `git status --porcelain` empty; `bash .claude/rotation/log.sh --tail 1` gives `prev:`
2. The project's verification block (its own read-only commands); paste the output verbatim into `verified:`
3. Fill the executor prompt: `prev` / `verified` / `next` (the handoff's next-item section, verbatim) / `inbox` (the operator's queued interjections, or "none") / `leftover` (what the previous round left, or "none")
4. `Agent` (`subagent_type: general-purpose`, the project's model, **no isolation** — the executor works on the main tree). The moment the call returns an id: `ROTATION_AGENT_ID=<id> bash .claude/rotation/agent_log.sh start <name> rotation <model> "<one line>"` (records `agent.start` + `rotation.start`, writes `manager.active`; refused without the id), then `bash .claude/rotation/manager_log.sh spawn <id> <name>`
5. `bash .claude/rotation/watchdog.sh` with `run_in_background: true` (a long timeout). Its exit is the notification. Then wait; nothing else runs

### The watchdog's first word (exit code) and what to do

| first word | exit | do |
|---|---|---|
| `MULTI-EXECUTOR` | 15 | two executors registered as running — end the stale one: `ROTATION_AGENT_STATUS=abandoned bash .claude/rotation/agent_log.sh end <name> rotation <model>`; do not start another |
| `WAKE` | 10 | what the executor waited for has happened (a worker ended, a remote job ended) and it has not moved → `SendMessage <id>` "What you were waiting for is done: <the line's detail>. Continue." → `bash .claude/rotation/manager_log.sh resume <id> wake <name>` (without the resume the next watchdog reports the same WAKE) |
| `STALE` | 11 | no event and no commit for `--stale` seconds → `recover.sh`, act on its last line |
| `QUOTA` | 12 | the recorded reset time passed and nothing followed → `SendMessage <id>` "Quota is restored; continue." → `manager_log.sh resume <id> quota <name>` |
| `DIRTY` | 13 | an uncommitted file appeared in the main tree while the executor was silent → `SendMessage` the executor with the file list; it cleans (commits or reverts) — the manager does not |
| `FOREIGN-COMMIT` | 14 | the base branch moved while no executor was running — the red-line incident shape. **Do not start the next round**; print the line to the operator; wait for the operator's decision about the commit; only then follow `recover.sh` |
| (no output) | — | the background task's timeout was reached: re-arm |

After handling any of them, re-arm the watchdog.

### On the report (every round) — verify each with a command, never from the report alone

1. first line `ROTATION-CLOSED rid=… head=… trigger_exit=0`; `rotations.jsonl` has a new row (`log.sh --tail 2`); `git log --oneline <prev>..HEAD | wc -l` equals the report's `commits:`; `git log -E --grep='^Agent-Origin:' <prev>..HEAD` is empty
2. `git status --porcelain` empty; HEAD equals the report's `head`
3. a `gate.end` event for this round's HEAD in `events.jsonl` (`grep '"kind":"gate.end"' … | tail -1`), not the report's number; the sweep line and the axis reading in the report equal the commands' output now
4. the new row's `rotationId` equals the report's `rid=`, its `prevHead` is this HEAD, its `confSha256` equals `shasum -a 256 .claude/rotation/rotation.conf` (a changed threshold shows here)
5. every stamp the conf names is at HEAD (the TRIG-6 line of the trigger output); `-dirty` = fail
6. the runner is clean (the project's own probe, when it has one)
7. no worktree left: `git worktree list` shows the main tree only; `recover.sh` says `IDLE`
8. the handoff has the trigger section and `gate:` with F = 0
9. the verdict: `bash .claude/rotation/close_plan.sh <prev> <HEAD>` (reads back the one the round produced) → `bash .claude/rotation/close_verdict_fill.sh <rid>` → read `<ROTATION_VERDICT_DIR>/<rid>.verdict.md`: §1 gate events must not be **missing**; every §3 status is "ran" or "carried from …" ("not at HEAD" means the round did not finish its plan: `SendMessage` the executor to complete it); a **red** in §3 means no next round until it heads the next `leftover:`; §4 is the release form

Record the results: `bash .claude/rotation/manager_log.sh verify 1=pass 2=pass … 9=fail` (record a fail too; record again when fixed). File the report: `bash .claude/rotation/report_save.sh <rid> <report file>` — `rid` is the round that just **closed** (the verdict's rid, the id the round's events carry), never the id the trigger just opened; an existing file means the rid is wrong. Segments the manager runs itself (plan, fill) are logged with `agent_log.sh start|end <name> manager <model>`.

Then report to the operator — the `ROTATION-CLOSED` line, the gate / sweep / axis readings, `verdict: <form> run=[…] carry=[…] red=N` — and go back to **Start**.

### Interruptions

- The executor hit a rate limit (the notification carries `resets <time>`): `bash .claude/rotation/event.sh quota.hit quota.resets=<HH:MM | ISO | epoch> quota.agent=<id>`; the watchdog's `QUOTA` says when
- The manager itself stops (the operator says stop, the session is being replaced): `bash .claude/rotation/manager_log.sh stop <reason>`; the next session cannot continue this executor and will `RESPAWN`
- The report's first line is `ROTATION-OPEN reason=…`: print it verbatim; `runner-down` is not restarted automatically; otherwise a new round from `leftover:`
- A failed notification that is not a rate limit, or a first line that is not `ROTATION-*`: `SendMessage` "report status"; no answer → steps 1, 6, 7 above → new round, `leftover:` filled in
- Operator interjections: about the current work → `SendMessage` the text to the executor verbatim; about later → append to `.claude/autorun-inbox.md`; "stop" → forward it and wait for `ROTATION-OPEN reason=operator-stop`
- `SendMessage` is **asynchronous**: the manager's turn ends when the message is sent, and the executor's answer arrives as a new turn. Do not wait for it inside the same turn.

## The executor

The round's rotation agent, on the main tree, branch `ROTATION_BASE_BRANCH`. It does exactly what a careful interactive session would: read the handoff in full → ship the items under the next-item heading in order → pre-flight every commit, gate at the end of every batch → close by the plan ([close.md](close.md)) → write the handoff → `bash .claude/rotation/trigger.sh self` → the final report. Every project rule applies to it; where a rule says "the main session", it means the executor.

### Bookkeeping that is not optional

The manager's `recover.sh` and `watchdog.sh` read **only** events; what is not recorded did not happen.

- Register every agent you spawn, with its id, the moment the `Agent` call returns it: `ROTATION_AGENT_ID=<id> ROTATION_AGENT_WORKTREE=<path> bash .claude/rotation/agent_log.sh start <name> worker <model> "<task>"`; `end` when it finishes (`ROTATION_AGENT_STATUS=abandoned` when given up). An agent registered without an id cannot be resumed after a restart
- Heavy jobs go through the adapter commands, never a hand-written remote invocation: `adapter_run.sh gate <HEAD>` (wrap in `run_in_background`; exit 0 = no failures; **`gate.end` is written only on this path**), `adapter_run.sh preflight [-q]`, `adapter_run.sh close-segment <HEAD> <segment>|plan <verdict.json>`, `adapter_run.sh bench <HEAD> [segment…]`. Any other long job: `event.sh remote.start remote.kind=… remote.sha=… remote.log=… 'remote.marker=<regexp>' [remote.host=…]` before, `event.sh remote.end remote.log=<same> remote.status=ok|fail` after
- Before ending a turn to wait: `event.sh executor.waiting remote.log=<log> 'remote.marker=<regexp>'` or `event.sh executor.waiting workers=list:<name>,<name>`. The manager wakes you when it has happened and you have not moved
- Every background shell you start begins with `bash .claude/rotation/event.sh process.start process.pid=int:$$ process.what=<label>` (the adapter commands do not register themselves — the shell that wraps them does); `event.sh process.end process.pid=int:<pid>` when it finished on its own. The trigger's reaper ends registered pids still alive and nothing else; an unregistered watcher outlives the round
- A worker hit a rate limit and you stop to wait: `event.sh quota.hit quota.resets=<time> quota.agent=<worker id>`

### Workers

- Implementation workers get `isolation: worktree`; their first step is `git merge --ff-only <base branch>`; their commits carry an `Agent-Origin: <name>` trailer and stay in the worktree. You `cherry-pick --no-commit`, review (a reviewer agent's conclusion, not your own read of a thousand-line diff) and land them as your own commits; the trailer never reaches the base branch, and TRIG-1 counts only commits without it
- A worker uses only its own scratch directory; after landing: `git worktree remove --force` + `git branch -D` + remove the scratch
- Research and reviewer agents run without isolation and are told in their prompt: read-only, results in the final message. **No subagent writes to the main tree**; an uncommitted file there that you did not write is yours to clean
- Every worker has ended before you close; then `bash .claude/rotation/agent_log.sh end <your name> rotation <model>` (your own registration), only then `trigger.sh self`. Nothing of yours may still be running: the trigger's reaper ends the shells you registered with `process.start` and nothing else, so a shell you never registered is yours to end by PID
- Never ask "continue?" or "may I clear?"; a TRIG FAIL means keep shipping; `trigger.sh manual` is never yours

### After a restart (the manager sends "Session restarted")

Background tasks and worker processes are gone. `recover.sh` first; workers registered with an id are continued by `SendMessage` to that id (context kept) and re-spawned from the commits in their worktree only when that fails; a remote job with `remote.start` and no `remote.end` is collected or waited for according to the page's `terminal=` column, never restarted while it may still be running.

### The report (≤ 60 lines, the last message; first line fixed)

```
ROTATION-CLOSED rid=<r-…> head=<sha> trigger_exit=0      ← or ROTATION-OPEN reason=<runner-down|operator-stop|…> leftover=<…>
commits: N (types …); closed: the shas named on closed:
gate: N/F/S ; sweep: <the sweep line verbatim> ; axis: <the axis reading verbatim>
stamps: <name>=<sha> …
workers: n=… landed=… resumes=… worktrees_removed=yes/no scratch_removed=yes/no
runner: <the leftover-process check>
unverified / open: …
inbox_ack: what was done about the operator's interjections
```

`rid` is the round that is closing (the verdict's rid), not the id the trigger just opened.

Next: [recovery.md](recovery.md).
