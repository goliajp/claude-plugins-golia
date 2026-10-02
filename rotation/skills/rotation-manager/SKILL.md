---
name: rotation-manager
description: MANDATORY when a session is asked to manage rotation rounds ("manager mode", "continue the autorun", "start the next round") in a project wired with the rotation kernel, and whenever such a session resumes or restarts. The manager verifies, starts one executor per round, waits, verifies the report and starts the next; it never commits, builds or runs the project's checks itself, and a lost executor is replaced, never continued from another session.
---

# rotation-manager — the manager's protocol

Four things in a loop: **verify → compose the executor prompt → start one executor → wait for its report**; then verify the report and start the next round. Full text: `docs/roles.md` and `docs/recovery.md` in the plugin directory (`cat .claude/rotation/kernel.path`); the project's filled playbook is its copy of `templates/manager-start.md`.

## Red lines

- No commits, no source changes, no builds, no gate / sweep / bench / close segment by hand, no diff review, no workers of your own, no `trigger.sh self`. `trigger.sh manual` only when the operator says so, and only the operator's terminal can run it.
- An unavailable executor (rate limit, process restart, no answer) is **replaced**: back off 3 / 10 / 20 min, then every 20, and start a new one with the scene in `leftover:`. Never take the work over; repeated failure is reported. "Handover cost" is not a reason.
- `FOREIGN-COMMIT` (watchdog exit 14: the base branch moved while no executor was running) means **do not start the next round**: print the line to the operator and wait for the decision.

## After a restart (first thing)

1. `bash .claude/rotation/manager_log.sh start`
2. `bash .claude/rotation/doctor.sh` — `DOCTOR PASS` or no round; FAIL lines verbatim to the operator
3. `bash .claude/rotation/recover.sh` — act on the **last line**, never on memory:
   - `RESUME <id>` — only when *this* session (or its `--resume`) spawned the executor: `SendMessage <id>` "Session restarted; run recover.sh, continue your round, report as before" → `manager_log.sh resume <id> restart <name>`. No answer → `ROTATION_AGENT_STATUS=abandoned agent_log.sh end <name> rotation <model>`, run `recover.sh` again
   - `CLEAN main tree first` — the dirty files go into the next executor's `leftover:`; you do not touch them
   - `RESPAWN executor leftover=…` — a new executor with the page's leftovers; first `agent_log.sh end … abandoned` any executor it lists (else `MULTI-EXECUTOR`); run every `collect:` line the page offers before starting
   - `IDLE` — start
4. Re-arm the watchdog

**A subagent can be continued only by the session that spawned it, or that session after `--resume`.** From any other session `SendMessage <id>` returns `No transcript found`; `recover.sh` compares the registered `managerSession` with your `CLAUDE_CODE_SESSION_ID` and offers RESUME only on a match. Changing sessions means RESPAWN, always. Stopping on purpose: `manager_log.sh stop <reason>`.

## Start (each round)

1. `git status --porcelain` empty; `bash .claude/rotation/log.sh --tail 1` → `prev:`
2. The project's verification block, pasted verbatim into `verified:`
3. Fill the executor prompt (`prev` / `verified` / `next` = the handoff's next-item section verbatim / `inbox` / `leftover`)
4. `Agent` (`subagent_type: general-purpose`, the project's model, **no isolation**). On its id, at once: `ROTATION_AGENT_ID=<id> bash .claude/rotation/agent_log.sh start <name> rotation <model> "<one line>"`, then `bash .claude/rotation/manager_log.sh spawn <id> <name>`
5. `bash .claude/rotation/watchdog.sh` with `run_in_background: true` (long timeout). Then wait; nothing else runs

## Watchdog first word → action (then re-arm)

| word | exit | action |
|---|---|---|
| `MULTI-EXECUTOR` | 15 | `ROTATION_AGENT_STATUS=abandoned agent_log.sh end <stale name> rotation <model>`; start nothing |
| `WAKE` | 10 | `SendMessage <id>` "What you were waiting for is done: <detail>. Continue." → `manager_log.sh resume <id> wake <name>` |
| `STALE` | 11 | `recover.sh`, act on its last line |
| `QUOTA` | 12 | `SendMessage <id>` "Quota is restored; continue." → `manager_log.sh resume <id> quota <name>` |
| `DIRTY` | 13 | `SendMessage` the executor with the file list; it cleans, you do not |
| `FOREIGN-COMMIT` | 14 | stop; operator decides |
| no output | — | the task's lifetime ended: re-arm |

Without the `manager_log.sh resume`, the re-armed watchdog reports the same WAKE / QUOTA again. `SendMessage` is asynchronous: your turn ends when it is sent; the answer arrives as a new turn. After a `SendMessage` to a worktree-isolated subagent, check once that your cwd is still the main tree.

## On the report — nine checks, each by a command

1 `ROTATION-CLOSED rid=… head=… trigger_exit=0`, new row in `rotations.jsonl`, commit count and no `Agent-Origin:` in the range · 2 tree clean, HEAD = `head` · 3 a `gate.end` for this HEAD in `events.jsonl`; sweep / axis lines equal the commands' output now · 4 row id = `rid`, `prevHead` = HEAD, `confSha256` = `shasum -a 256 .claude/rotation/rotation.conf` · 5 stamps at HEAD (TRIG-6 line) · 6 runner clean (project probe) · 7 `git worktree list` main tree only, `recover.sh` says `IDLE` · 8 handoff has the trigger section, `gate:` F = 0 · 9 `close_plan.sh <prev> <HEAD>` → `close_verdict_fill.sh <rid>` → read the verdict: §1 gate events not **missing**, every §3 status "ran" or "carried from", no **red**, §4 the release form.

Record: `bash .claude/rotation/manager_log.sh verify 1=pass … 9=fail`. File: `bash .claude/rotation/report_save.sh <rid> <report file>` — `rid` is the round that **closed** (the verdict's), not the id the trigger just opened. Report three lines to the operator (`ROTATION-CLOSED` · readings · `verdict: <form> run=[…] carry=[…] red=N`); back to Start.

## Interruptions

- Rate limit on the executor (`resets <time>` in the notification): `bash .claude/rotation/event.sh quota.hit quota.resets=<time> quota.agent=<id>`; the watchdog's QUOTA says when
- `ROTATION-OPEN reason=…`: verbatim to the operator; `runner-down` is not restarted automatically; otherwise a new round from `leftover:`
- A failed notification or a first line that is not `ROTATION-*`: `SendMessage` "report status"; no answer → checks 1 / 6 / 7 → new round
- Operator interjections: about the current work → forward verbatim by `SendMessage`; about later → append to `.claude/autorun-inbox.md`; "stop" → forward, wait for `ROTATION-OPEN reason=operator-stop`
