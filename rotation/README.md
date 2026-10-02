# rotation

Machine-governed session rotation for long autonomous Claude Code runs. A round of work ends with a handover only when a gate of measured facts says so — enough commits, a plausible duration, fresh check stamps from this round's source, a gate that actually ran; the next session starts from an archived handoff; the close is planned from a rules table and written up as a verdict; an interrupted round is recovered from append-only event logs rather than from memory. Run for several hundred rounds on a compiler project before it was packaged as a plugin.

The kernel knows no project. A project plugs in through three files it owns (`project.sh`, `rotation.conf`, `close_rules.tsv`) and four adapter commands (gate, pre-flight, close segment, bench) that it writes to a fixed contract.

## Documentation

| Read | For |
|---|---|
| [docs/protocol.md](docs/protocol.md) | scope and non-goals, the three roles, the five properties and what holds each up, where files live |
| [docs/data.md](docs/data.md) | the data contract: `rotations.jsonl`, `events.jsonl`, stamps, the handoff's trigger section, the rules table, the verdict |
| [docs/gates.md](docs/gates.md) | the trigger gate TRIG-1..8 (every threshold as its `rotation.conf` key) and the turn-end gate INV-1..5 |
| [docs/close.md](docs/close.md) | the close: plan, run, carry, fill, release forms |
| [docs/roles.md](docs/roles.md) | the manager's loop, red lines, watchdog table and report checks; the executor's duties and report; workers |
| [docs/recovery.md](docs/recovery.md) | `recover.sh`, `watchdog.sh`, the hooks, the reaper, and the cross-session facts the protocol is written around |
| [docs/configuration.md](docs/configuration.md) | every `rotation.conf` key and `project.sh` variable; the adapter command contract |
| [docs/adoption.md](docs/adoption.md) | install → init → configure → doctor → observe mode → `stats.sh --suggest` → enforce; measuring with `stats.sh --effect` |
| [docs/history.md](docs/history.md) | appendix: how the first adopter's thresholds were arrived at, the incidents behind each gate, retired routes |

Two skills load the protocol into a session: `rotation` (for the session or subagent that executes a round) and `rotation-manager` (for the session that manages rounds). Both point back at `docs/`.

## Install

```
claude plugin marketplace add https://github.com/goliajp/claude-plugins-golia
claude plugin install rotation@golia
```

Development install (local checkout, hot-reloads on the next session):

```
git clone https://github.com/goliajp/claude-plugins-golia.git
claude plugin marketplace add ./claude-plugins-golia
claude plugin install rotation@golia
```

## Wire a project: `/rotation:init`

In a session whose working directory is inside the project's git repository, run `/rotation:init`. It runs `bin/init.sh`, which writes under the repository's `.claude/`:

| Path | What |
|---|---|
| `.claude/rotation/kernel.path` | the plugin's install root; rewritten by the SessionStart hook at every session start, so a plugin update is picked up without editing anything |
| `.claude/rotation/<script>` | two-line shims for every kernel entry point (`trigger.sh`, `doctor.sh`, `recover.sh`, `watchdog.sh`, `agent_log.sh`, `event.sh`, `close_plan.sh`, …): `exec "$(cat kernel.path)/bin/<script>" "$@"`. Documents and adapter scripts keep calling `.claude/rotation/<script>`; `lib.sh` is a one-line source shim |
| `.claude/rotation/project.sh` | from `templates/project.sh.example`, written once, never overwritten: directories and the adapter commands |
| `.claude/rotation/rotation.conf` | from `templates/rotation.conf.example`, written once: thresholds, axes, stamp list, switches |
| `.claude/rotation/close_rules.tsv` | from `templates/close_rules.tsv.example`, written once: the close planner's rules table |
| `.claude/rotation-state/` | `rotations.jsonl`, `events.jsonl`, `manager.active`, `handoff/<rid>.md` — append-only state, never inside the plugin directory |

Without Claude: `CLAUDE_PLUGIN_ROOT=<plugin dir> bash <plugin dir>/bin/init.sh` from inside the repository does the same. `--force` rewrites the shims and `kernel.path`; it never touches the three project files.

Then edit `project.sh` and `rotation.conf`, write the adapter commands they name ([docs/configuration.md](docs/configuration.md); a complete minimal adapter is in [docs/adoption.md](docs/adoption.md)), and run the doctor:

```
bash .claude/rotation/doctor.sh
```

Last line `DOCTOR PASS kernel=<x.y.z> conf=<sha256 prefix>` means the project can start a round; every `FAIL` line names what to fix.

## What runs when

| Piece | Entry | Runs |
|---|---|---|
| Trigger gate TRIG-1..8 | `trigger.sh self` → `trig_gate.sh` | at the end of a round, by the executor; exit 0 writes the `rotations.jsonl` row, archives the handoff and sets the intent; FAIL = keep working |
| Turn-end gate INV-1..5 | `Stop` hook → `stop_hook.sh` → `check.sh` | at every turn end while an intent is pending; green consumes the intent, red keeps it for the next turn end |
| Close planner | `close_plan.sh [<prev> [<head>]]`, `close_verdict_fill.sh <rid>`, `carry_stamp.sh` | at close: per check, diff from its stamp's sha to HEAD against its trigger paths → run or carry; the verdict `<rid>.verdict.md/.json` in `ROTATION_VERDICT_DIR` |
| Adapter commands | `adapter_run.sh gate\|preflight\|close-segment\|bench …` | the kernel's only call site for the project's heavy commands; exit 0 without the contract's terminal line and events is refused (exit 64) |
| Recovery | `recover.sh [--json] [--no-probe]` | after any interruption: one page of the scene, last line `RESUME <id>` / `CLEAN main tree first` / `RESPAWN executor leftover=…` / `IDLE` |
| Watchdog | `watchdog.sh [--interval] [--stale] [--wake] [--dirty] [--once]` | beside a running round; exits with the reason: WAKE 10 / STALE 11 / QUOTA 12 / DIRTY 13 / FOREIGN-COMMIT 14 / MULTI-EXECUTOR 15 |
| Events | `event.sh <kind> k=v…`, `agent_log.sh start\|end …`, `manager_log.sh …`, `report_save.sh` | whenever an agent, a remote job, a wait, a quota hit or a manager action happens |
| Readings | `log.sh`, `stats.sh --effect\|--suggest` | any time; `--suggest` proposes thresholds once `ROTATION_BOOTSTRAP_ROUNDS` self rows exist |

## Hooks

`hooks/hooks.json` registers three hooks; all run in the session's working directory and find the project root with `git rev-parse --show-toplevel`.

- `Stop` → `bin/stop_hook.sh`: runs the project's after-write hook, then the INV-1..5 gate while an intent is pending. Always exits 0.
- `SessionStart` (`startup` and `resume`) → `bin/session_start_hook.sh`: writes `kernel.path`; on `resume`, while `manager.active` exists, prints the recovery page into the session.
- `SubagentStop` → `bin/subagent_stop_hook.sh`: when the stopping subagent's id is one the session registered through `agent_log.sh`, records `agent.stop` for the round's executor or one `agent.end` for a worker — the mechanical event the watchdog's WAKE reads. Unknown ids write nothing.

A project that has not run `/rotation:init` is untouched by all three: no `.claude/rotation/`, no intent, no registered agents, nothing written.

## Exit codes

Scripts print their usage on a wrong argument count or an unknown option (exit 2); none takes `--help`. `trig_gate.sh` 0 / 1 FAIL / 2 configuration · `trigger.sh` 0 / 1 blocked / 2 usage or configuration / 3 `manual` without a terminal · `check.sh` 0 / 1 / 2 · `close_plan.sh` 0 / 2 · `adapter_run.sh` the command's own / 2 not registered / 64 claim without record · `doctor.sh` 0 / 1 / 2 · `watchdog.sh` 10–15 as above, 0 only with `--once` · `recover.sh` 0 / 2 · `agent_log.sh`, `manager_log.sh`, `event.sh` 0 / 2.

## Tests

```
bash <plugin dir>/tests/run_all.sh
```

Seven self-tests (trigger gate, turn-end gate, close planner, recovery and watchdog, doctor, hooks, and one whole round end to end — including the Stop hook consuming the intent and a round interrupted in every way the recovery page and the watchdog know) against throwaway repositories and state; none reads any installed project.

## Update

```
claude plugin marketplace update golia
claude plugin update rotation
```

Then `bash .claude/rotation/doctor.sh`: a changed major means the conf needs a change; a changed minor is a WARN naming the keys added since.

## Uninstall

```
claude plugin uninstall rotation
```

`.claude/rotation/` and `.claude/rotation-state/` stay in the project; remove them by hand if the project is leaving the protocol.

## Changelog

- **0.1.3** — kernel 1.1.4. A `dead?` worker no longer wakes the watchdog again once a `manager.resume` of the round is recorded after it went `dead?` (the manager relayed it to the executor); the recover page still shows it `dead?`, marked with when it was relayed, and it wakes the watchdog again only after its transcript is written after that resume and stops for `ROTATION_WORKER_STALE` seconds once more. Self-tests +11.
- **0.1.2** — kernel 1.1.3. TRIG-9 (`ROTATION_TRIG9_VERDICT_RED`, default off): `trigger.sh self` fails while the round's filled close verdict has red, naming each red line, and fails when the round has no verdict or one never filled. Recovery: a worker still registered as running whose transcript (`<config>/projects/<project>/<session>/subagents/agent-<id>.jsonl`, looked up by the registering session across every config directory) has not been written for `ROTATION_WORKER_STALE` seconds (default 1200) is `dead?` on the recover page, with how to continue it or end and re-dispatch it, and a WAKE for the watchdog. Close planner: a new `regress` op, `<key>:each-up:<rel>[:<k>[:<ceiling>]]`, judges a map of repeated readings per entry (only entries both stamps carry; the move must clear the repeats' own noise); an unknown op is refused when the table is read instead of judging nothing; a stamp row withdrawn by a later `stamp.void` row is never a baseline. Self-tests +31.
- **0.1.1** — kernel 1.1.2. The trigger's reaper ends only the pids the round registered (`event.sh process.start process.pid=int:$$ …` / `process.end`), with a STALE guard for a pid no longer under the session; it no longer walks the Claude Code process tree, so the manager's watchdog and other agents' shells are never touched; in manager mode the remote reap is skipped, registered pids are reaped all the same. `close_verdict_fill.sh` judges a reading against the last stamp at or before the round's start (the verdict's `prevSha`) — never a mid-round stamp — and the results header names the baseline sha. Self-tests +14.
- **0.1.0** — initial release: kernel 1.1.1 (trigger gate TRIG-1..8, turn-end gate INV-1..5, close planner and verdict, adapter command contract, recovery page, watchdog, manager events, doctor, stats), three hooks, `/rotation:init`, templates, the protocol documentation under `docs/`, the `rotation` and `rotation-manager` skills, seven self-tests.
