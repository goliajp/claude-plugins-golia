# manager mode (read when the operator says "manager mode, continue the autorun" to a fresh session)

Placeholders in `{{…}}` are the project's; replace every one before use.

The manager session does four things: verify → compose the prompt → start one rotation executor → wait for its report; then verify again and start the next round. **No commits, no builds, no diff review, no workers of its own, no `trigger.sh self`** (`trigger.sh manual` only when the operator says so, verbatim). While a rotation runs the manager starts no Bash of its own.

## After a restart (process restart, account switch, quota restored — the first step)

`bash .claude/rotation/manager_log.sh start` (records `manager.start` with this session's `CLAUDE_CODE_SESSION_ID`), then `bash .claude/rotation/doctor.sh` (the wiring check; last line `DOCTOR PASS kernel=… conf=…`; on `DOCTOR FAIL` do not start a round — print the FAIL lines to the operator verbatim, read the WARN lines), then `bash .claude/rotation/recover.sh` and act on its last line, never on memory:
- `RESUME <agentId>`: only when the executor belongs to this session (it, or its `--resume`): `SendMessage <agentId>` "Session restarted; run `bash .claude/rotation/recover.sh`, continue your round, report as before", then `bash .claude/rotation/manager_log.sh resume <agentId> restart <name>`
- `CLEAN main tree first`: the uncommitted files in the main tree go into the next executor's `leftover:` — the manager never commits them
- `RESPAWN executor leftover=…`: start a new executor with the page's leftovers in `leftover:`; an executor registered by another session cannot be continued (`mismatch` / `no-session`) — always a new one
- `IDLE`: proceed to the start

Then re-arm the watchdog: `bash .claude/rotation/watchdog.sh` with `run_in_background: true` (its exit is the notification: WAKE 10 / STALE 11 / QUOTA 12 / DIRTY 13 / FOREIGN-COMMIT 14 / MULTI-EXECUTOR 15).

## Start

1. `git -C <project> status --porcelain` must be empty; the last row of `rotations.jsonl` (`bash .claude/rotation/log.sh --tail 1`) gives `prev:`
2. The verification block: {{VERIFY_COMMANDS}} — paste the output verbatim into `verified:`
3. Fill `templates/rotation-agent-prompt.md` (the project's filled copy: {{EXECUTOR_PROMPT_PATH}}): `prev` / `verified` / `next` (the handoff's "{{HANDOFF_NEXT_HEADING}}" section) / `inbox` / `leftover`
4. `Agent` (`subagent_type: general-purpose`, the project's model, no isolation) with that prompt; the moment it returns an id: `ROTATION_AGENT_ID=<id> bash .claude/rotation/agent_log.sh start <name> rotation <model> "<one line>"` (records `agent.start` + `rotation.start`, writes `manager.active`) and `bash .claude/rotation/manager_log.sh spawn <id> <name>`
5. Wait for the notification. Nothing else runs meanwhile.

## On the report

Verify, in this order, each with a command (never from the report alone):
1. the first line is `ROTATION-CLOSED rid=… head=… trigger_exit=0`, and `rotations.jsonl` has a new row (`log.sh --tail 2`)
2. `git status --porcelain` empty; HEAD equals the report's `head`
3. the gate: an event `gate.end` for this round's HEAD (`grep '"kind":"gate.end"' .claude/rotation-state/events.jsonl | tail -1`), not the report's number
4. the stamps the conf names are at HEAD (`trig_gate.sh` TRIG-6 line in the trigger output)
5. the runner is clean: {{RUNNER_CHECK}}
6. no worktree left: `git worktree list` shows the main tree only
7. no registered agent still running: `recover.sh` says `IDLE`
8. the verdict: `bash .claude/rotation/close_plan.sh <prev> <HEAD>` (read back when the round already produced it) → `bash .claude/rotation/close_verdict_fill.sh <rid>` → read `<ROTATION_VERDICT_DIR>/<rid>.verdict.md`: §1 gate events must not be **missing**; every §3 status is "ran" or "carried from …" ("not at HEAD" = the round did not finish its plan: `SendMessage` the executor to complete it); a **red** in §3 means no next round until it is in the next `leftover:`; §4 gives the release form
9. the executor's report filed: `bash .claude/rotation/report_save.sh <rid> <report file>` (rid = the round that just closed, i.e. the verdict's rid, not the id the trigger just opened; an existing file means the rid is wrong)

Record the nine results: `bash .claude/rotation/manager_log.sh verify 1=pass 2=pass … 9=fail` (record a fail too; record again after it is fixed). The segments the manager runs itself (verdict, fill) are logged with `agent_log.sh start|end <name> manager <model>`.

Then report three lines to the operator (`ROTATION-CLOSED` line · gate / sweep / bench · `verdict: <form> run=[…] carry=[…] red=N`) and go back to **Start**.

## Red lines

The manager never does substrate work: no commits, no source changes, no builds, no gate / sweep / bench / close segment run by hand. When the executor is unavailable (429 / 529 / process restart): back off 3 / 10 / 20 min (then every 20 min) and start a **new** executor, the scene in its `leftover:`; repeated failure is reported, never taken over. "Handover cost" is not a reason.

## Interruptions

- The executor hit 429 (the notification carries `resets <time>`): `bash .claude/rotation/event.sh quota.hit quota.resets=<HH:MM | ISO | epoch> quota.agent=<id>`; the watchdog's `QUOTA` exit says when → `SendMessage <id>` "Quota restored; continue" → `bash .claude/rotation/manager_log.sh resume <id> quota <name>`
- The manager itself stops (operator says stop, or the session is being replaced): `bash .claude/rotation/manager_log.sh stop <reason>`; a new session cannot continue the old executor and follows `recover.sh`'s RESPAWN
- The report's first line is `ROTATION-OPEN`: print it to the operator verbatim; `reason=runner-down` is not restarted automatically; otherwise start a new round from `leftover:`
- A failed notification that is not 429, or a first line that is not `ROTATION-*`: `SendMessage` "report status"; no answer → steps 1 / 6 / 7 above → new round, `leftover:` filled in
- Operator interjections: about the current work → `SendMessage` the text to the executor verbatim; about later → append to `.claude/autorun-inbox.md`; "stop" → forward it and wait for `ROTATION-OPEN reason=operator-stop`
