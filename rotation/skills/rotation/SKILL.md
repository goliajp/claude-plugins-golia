---
name: rotation
description: MANDATORY for any session or subagent that executes a rotation round in a project wired with the rotation kernel (a `.claude/rotation/` directory exists) — before shipping, before any gate, pre-flight, bench or close, before writing the handoff, and before `trigger.sh self`. The round closes only when the trigger gate releases it; every heavy job goes through the adapter commands; what is not recorded as an event did not happen.
---

# rotation — the executor's protocol

The round: read `.claude/handoff.md` in full → ship the next items in order → pre-flight every commit, gate every batch → close by the plan → write the handoff → `bash .claude/rotation/trigger.sh self` → report. Full text: `docs/protocol.md`, `docs/gates.md`, `docs/close.md`, `docs/roles.md`, `docs/recovery.md` in the plugin directory (`cat .claude/rotation/kernel.path`).

## What differs from a normal session

- **You do not decide when to stop.** `trigger.sh self` runs TRIG-1..8 and either writes the row or blocks. A FAIL means keep shipping — not "ask whether to continue", not `trigger.sh manual` (operator-only; refuses without a terminal). Observe-mode lines (`TRIG-n OBSERVE`) do not block.
- **Heavy jobs only through `adapter_run.sh`**: `bash .claude/rotation/adapter_run.sh gate <HEAD>` · `preflight [-q]` · `close-segment <HEAD> plan <verdict.json>` · `bench <HEAD> [segment]`. A hand-written remote invocation leaves no `gate.end` / `remote.*` event; the verdict then shows the gate as **missing** and the round cannot close. Exit 64 = the command claimed success without its record.
- **Readings are pasted, never typed.** The handoff's `sweep:` line is the output of `ROTATION_SWEEP_LINE_CMD`; TRIG-7 compares it token by token with the stamp. `gate:` is the triple the gate printed. An axes review carries the axis reading's line verbatim.
- **The trigger section is a contract**, under `## rotate-trigger` (or the project's `ROTATION_TRIGGER_SECTION`): `axis:` (one of `ROTATION_AXES`), `closed:` (≥ `ROTATION_TRIG1_MIN_CLOSED` shas from *this* round, each with what it closed), `gate: N/F/S` with F = 0. No phrase from the TRIG-4 blacklist (`prep work done`, `substantial work`, `complexity`, `ROI`, `sub-milestone`, …).
- **Stamps are the evidence.** Every check in `ROTATION_STAMPS` is at HEAD (`headSha` a commit of this round, not `-dirty`, `verdict=ok`) or carried to exactly HEAD by the plan. Stamp, then `close_verdict_fill.sh`, then handoff — a fill before the last stamp is amber.
- **Red in the verdict = no close.** Bisect, fix or revert, run the gate again through `adapter_run.sh`. Amber = attribute it in the handoff.
- **Close order** (`docs/close.md`): end every child process → `close_plan.sh` → run the plan → carry the rest → fill → handoff → `agent_log.sh end <your name> rotation <model>` → `trigger.sh self` → one line, stop. The trigger's reaper ends the shells you registered with `event.sh process.start` and nothing else (not the manager's watchdog, not other agents' shells); a shell you never registered is yours to end by PID first.

## Bookkeeping the recovery tools depend on

- Register every agent you spawn the moment `Agent` returns its id: `ROTATION_AGENT_ID=<id> ROTATION_AGENT_WORKTREE=<path> bash .claude/rotation/agent_log.sh start <name> worker <model> "<task>"`; `end` when done (`ROTATION_AGENT_STATUS=abandoned` when given up). Without the id it cannot be resumed after a restart.
- Before ending a turn to wait: `bash .claude/rotation/event.sh executor.waiting remote.log=<log> 'remote.marker=<regexp>'` or `… executor.waiting workers=list:<name>,<name>`.
- Every background shell you start begins with `bash .claude/rotation/event.sh process.start process.pid=int:$$ process.what=<label>`; `… process.end process.pid=int:<pid>` when it finished on its own. Only registered pids are reaped at the trigger.
- A rate limit you stop for: `event.sh quota.hit quota.resets=<time> quota.agent=<id>`.
- After "Session restarted": `bash .claude/rotation/recover.sh` first; continue registered workers by `SendMessage <id>`; never restart a remote job whose end is not on record while its log has no terminal marker.

## Workers

Implementation workers: `isolation: worktree`, first step `git merge --ff-only <base branch>`, commits with an `Agent-Origin: <name>` trailer kept in the worktree; you `cherry-pick --no-commit`, take a reviewer agent's conclusion, land as your own commits (the trailer never reaches the base branch — TRIG-1 does not count it). Research / reviewer agents: no isolation, told read-only in their prompt. **No subagent writes to the main tree**; a stray file there is yours to clean. Every worker has ended before you close. After `SendMessage` to a worktree subagent, check once that your cwd is the main tree.

## Report (last message, ≤ 60 lines, first line fixed)

`ROTATION-CLOSED rid=<the round that closed> head=<sha> trigger_exit=0` — or `ROTATION-OPEN reason=<…> leftover=<…>`. Then commits / closed / gate / sweep / axis readings verbatim / stamps / workers / runner / open items / inbox ack.
