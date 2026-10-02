# The rotation protocol

A long autonomous run is split into *rounds*. A round is one session's worth of work on the main tree; it ends with a handover (a handoff file the next session starts from) and a trigger that writes one row to `rotations.jsonl`. The protocol decides, from measured facts, when a round may end, whether the handover is fit to act on, what has to be re-checked at the close, and how an interrupted round is picked up again. No step asks the model whether it feels done.

## 0 Scope and non-goals

In scope:

- **When a round may close** — the trigger gate TRIG-1..8 (`trigger.sh self`): enough work, a plausible duration, a handoff with content, no procrastination wording, an axes review when one axis has run too long, fresh stamps from this round's source, a sweep line that matches its stamp, a gate that actually ran. [gates.md](gates.md)
- **Whether a triggered round may proceed** — the turn-end gate INV-1..5 (the `Stop` hook): handoff fresh and real, tree clean, gate reading not regressed, rotation id unique. [gates.md](gates.md)
- **What the close re-runs** — the close planner: a rules table, a diff per check from its stamp's commit to HEAD, a verdict with a release form. [close.md](close.md)
- **Who does what** — one manager session, one executor per round, the executor's own workers. [roles.md](roles.md)
- **Interruption** — events on disk, a recovery page, a watchdog whose exit code is the notification. [recovery.md](recovery.md)
- **Adoption and calibration** — thresholds are the project's own measurements, taken in observe mode before they enforce anything. [adoption.md](adoption.md)

Out of scope, on purpose:

- **One executor at a time.** Parallel executors on the same main tree are not supported; a second running executor is a fault (`MULTI-EXECUTOR`). Parallelism belongs inside the executor, as workers in their own worktrees.
- **What a pre-flight, a gate, a sweep or a bench actually does.** The kernel calls the project's commands and reads what they record; their content is the project's.
- **Automatic `/clear` and session restart.** Earlier versions drove a terminal multiplexer from a daemon; that route is retired (see [history.md](history.md), appendix C). The handover is written and gated by the kernel; starting the next session is the manager's or the operator's action.
- **Reviewing the work.** The kernel checks that checks ran, not that the code is good.

## 1 Terms and the three roles

| Term | Meaning |
|---|---|
| round, rotation | the work between two trigger rows; `rotationId` is `r-<unix-ts>-<4 hex>` |
| handoff | `.claude/handoff.md`, overwritten at every close; the next session's only input; archived under `ROTATION_STATE_DIR/handoff/<rid>.md` when the trigger accepts |
| trigger section | the handoff heading the gates read (`## rotate-trigger` by default); carries `axis:`, `closed:`, `gate:` and, when required, `axes-review:` |
| axis | one of the project's named directions of work (`ROTATION_AXES`); each round names the axis it served |
| stamp | `<name>-latest.json` a check writes with the sha it measured and a verdict; the only evidence the gates accept |
| gate (the project's) | the project's conformance run; prints `N pass / F fail / S skip`, records `gate.end` |
| sweep | the project's main instrument (a test-suite sweep, say); its stamp is what TRIG-7 re-derives the `sweep:` line from |
| intent | `.claude/autorun-intent`, written by an accepted trigger, consumed by the Stop hook once INV-1..5 are green |
| base branch | the branch worktrees are measured against (`ROTATION_BASE_BRANCH`, else the main tree's current branch) |

Three layers of agents, each with a different reach:

| Role | Where it runs | What it may do |
|---|---|---|
| **manager** | the interactive session | verify, compose the executor's prompt, start one executor, wait for its report, verify the report, start the next round. Never commits, builds, reviews diffs or runs the project's heavy commands. |
| **executor** (the round's rotation agent) | a subagent the manager spawns, on the main tree | the whole round: ship, pre-flight every commit, gate every batch, close by the plan, write the handoff, `trigger.sh self`, report. The only agent that writes to the main tree. |
| **worker** | a subagent the executor spawns, in its own worktree | one task; commits in its worktree carry an `Agent-Origin:` trailer; the executor cherry-picks, reviews and lands them as its own commits. Research and reviewer agents are workers without a worktree and are told, in their prompt, to be read-only. |

A project may also run the protocol *without* a manager: the interactive session is then the executor itself (the "session mode" the first adopter used for several hundred rounds). Everything in [gates.md](gates.md) and [close.md](close.md) applies unchanged; [roles.md](roles.md) describes the manager mode.

## 2 The five properties, and what holds each one up

The protocol exists for five properties. Each is held up by a mechanical clause, not by instructions to the model; where a clause was missing when the kernel was generalised, it was added before this release.

| Property | Held up by |
|---|---|
| ① the handover moment is decided by a script | TRIG-1..8 before any state is written; thresholds read from `rotation.conf` only (the environment is cleared for those keys); `trigger.sh manual` refuses without a terminal on stdin (exit 3), so a model's shell cannot take the operator's override |
| ② every commit pre-flighted, every batch gated, readings not transcribed by hand | stamps carry the sha they measured (TRIG-6); the sweep line is re-derived and compared token by token (TRIG-7); `gate.end` events are the only evidence a gate ran (TRIG-8 and the verdict's §1); an empty stamp list, a missing sweep stamp, an empty rules table all fail or refuse rather than pass |
| ③ the executor runs in a subagent, the manager does no substrate work | `FOREIGN-COMMIT` (watchdog exit 14) when the base branch moved while no executor was running; `managerCommits` in every row (should be 0) |
| ④ the close is planned from a rules table | the table is the only judge; the verdict records the table's sha256 and row count; a check whose trigger paths were touched runs, one whose stamp is missing, dirty or red runs |
| ⑤ an interrupted round is recovered from disk | every agent, remote job, wait and quota hit is an event; the adapter commands record their own events (a success claim without the record is exit 64); `recover.sh` and `watchdog.sh` read only events and git |

## 3 Where things live

| | Path | Owner |
|---|---|---|
| kernel code | the plugin directory (`bin/`) | the plugin; replaced on update, never edited in place |
| project configuration | `.claude/rotation/project.sh`, `rotation.conf`, `close_rules.tsv` | the project; written once by `init.sh`, never overwritten |
| shims | `.claude/rotation/<script>` → `$(cat kernel.path)/bin/<script>` | written by `init.sh`, refreshed by `--force`; `kernel.path` rewritten at every session start |
| state | `.claude/rotation-state/`: `rotations.jsonl`, `events.jsonl`, `manager.active`, `handoff/<rid>.md` | append-only; the kernel never rewrites a row |
| stamps and verdicts | `ROTATION_STAMP_DIR`, `ROTATION_VERDICT_DIR` (project.sh; the template proposes `.dev/rotation/…`) | written by the project's checks and the close planner |
| the handoff and the intent | `.claude/handoff.md`, `.claude/autorun-intent` | the executor writes the handoff; the trigger writes the intent, the Stop hook consumes it |

Everything under `.claude/` is expected to be outside version control; the kernel reads nothing from git except the repository itself.

Next: [data.md](data.md) for the exact shape of every file above.
