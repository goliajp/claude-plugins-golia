# rotation

Machine-governed session rotation for long autonomous Claude Code runs. A round of work ends with a handover only when a gate of measured facts (commits, wall time, fresh check stamps, a gate that actually ran) says so; the next session starts from an archived handoff; the close is planned from a rules table and written up as a verdict; an interrupted round is recovered from append-only event logs rather than from memory. First run for several hundred rounds on a compiler project before it was packaged as a plugin.

The kernel knows no project. A project plugs in through three files it owns (`project.sh`, `rotation.conf`, `close_rules.tsv`) and four adapter commands (gate, pre-flight, close segment, bench) that it writes.

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
| `.claude/rotation/<script>` | two-line shims for every kernel entry point (`trigger.sh`, `doctor.sh`, `recover.sh`, `watchdog.sh`, `agent_log.sh`, `event.sh`, `close_plan.sh`, …): `exec "$(cat kernel.path)/bin/<script>" "$@"`. Documents and adapter scripts keep calling `.claude/rotation/<script>`; `lib.sh` is a one-line source shim for scripts that source the kernel's helpers |
| `.claude/rotation/project.sh` | from `templates/project.sh.example`, written once, never overwritten: directories and the adapter commands |
| `.claude/rotation/rotation.conf` | from `templates/rotation.conf.example`, written once: thresholds, axes, stamp list, switches |
| `.claude/rotation/close_rules.tsv` | from `templates/close_rules.tsv.example`, written once: the close planner's rules table |
| `.claude/rotation-state/` | `rotations.jsonl`, `events.jsonl`, `manager.active`, `handoff/<rid>.md` — append-only state, never inside the plugin directory |

Without Claude: `CLAUDE_PLUGIN_ROOT=<plugin dir> bash <plugin dir>/bin/init.sh` from inside the repository does the same. `--force` rewrites the shims and `kernel.path`; it never touches the three project files.

Then edit `project.sh` and `rotation.conf`, write the adapter commands they name, and run the doctor.

## Doctor

```
bash .claude/rotation/doctor.sh
```

One line per check, `PASS|FAIL|WARN <item> <detail>`; last line `DOCTOR PASS kernel=<x.y.z> conf=<sha256 prefix>` or `DOCTOR FAIL n=<count>`. It checks that `rotation.conf` parses and is written for this kernel's major (a differing minor is a WARN), the thresholds are integers and the mode keys legal, the axes / stamps / sweep stamp are named, `project.sh` sources and sets the seven required variables, every `ROTATION_*_CMD` is executable, the four heavy commands reject `--doctor-probe` with exit 2 without doing anything, the sweep line and axis reading have the right shape, the state / stamp / verdict directories are writable, the rules table parses and is not empty, at most one rotation executor is registered as running, and the repository and base branch exist. Run it after adopting and after every plugin update; a `DOCTOR FAIL` means do not start a round.

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

## Contract in brief

- **Code / configuration / state are three things.** Code is the plugin. Configuration is the project's `project.sh` (commands and directories, sourced) and `rotation.conf` (plain `key=value`, read from the file only — the environment is cleared for its keys first). State is `.claude/rotation-state/`, append-only jsonl; replacing the kernel never touches it.
- **Every rotations.jsonl row carries the kernel version, the conf's sha256 and the effective thresholds**; changing a threshold is changing the file, visible in the rows that follow. `ROTATION_CONF_KERNEL` names the kernel major the conf was written for; a mismatch is a configuration error (exit 2), not a gate result.
- **Empty things do not pass**: an empty stamp list fails TRIG-6, a missing sweep stamp fails TRIG-7, an unconfigured axis reading fails TRIG-5 on a long same-axis streak, an empty rules table is exit 2, a substrate range with no `gate.end` is red.
- **Adapter commands put their claim on record.** gate prints `N pass / F fail / S skip` and records `remote.start`, `gate.end`, `remote.end`; pre-flight prints `PREFLIGHT PASS` and records `preflight.end`; close segment and bench record `remote.start` / `remote.end`. `remote.host` may be empty: the job ran locally and its log is a local file, so a project with no remote runner configures no probe commands at all. Each command must exit 2 on `--doctor-probe` without doing anything.
- **One executor per round.** `agent_log.sh start <name> rotation` needs `ROTATION_AGENT_ID`; a second running executor is `MULTI-EXECUTOR` (exit 15). An executor can be continued by `SendMessage` only from the session that spawned it (or its `--resume`), so `recover.sh` offers `RESUME` only when the recorded manager session equals the current `CLAUDE_CODE_SESSION_ID`; otherwise `RESPAWN`.
- **Calibrate before enforcing.** A new project sets `ROTATION_TRIG1A_MODE` / `ROTATION_TRIG2_MODE=observe`, runs `ROTATION_BOOTSTRAP_ROUNDS` rounds, reads `stats.sh --suggest`, writes the suggested commit floor and wall cap into the conf, and switches to `enforce`.
- **Exit codes**: `trig_gate.sh` 0 / 1 FAIL / 2 configuration; `trigger.sh` 0 / 1 blocked / 2 usage or configuration / 3 `manual` without a terminal; `close_plan.sh` 0 / 2; `adapter_run.sh` the command's own / 2 not registered / 64 claim without record; `doctor.sh` 0 / 1 / 2; `watchdog.sh` 10–15 as above.

The full specification of each gate, the event kinds and their required fields, and the verdict format are in the header comments of the scripts in `bin/`; `templates/` holds the executor prompt and the manager playbook with the project's values as `{{…}}` placeholders.

## Tests

```
bash <plugin dir>/tests/run_all.sh
```

Seven self-tests (trigger gate, turn-end gate, close planner, recovery and watchdog, doctor, hooks, and one whole round end to end) against throwaway repositories and state; none reads any installed project. The marketplace's `.claude-plugin/test.sh rotation` runs them before a release.

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

- **0.1.0** — initial release: kernel 1.1.1 (trigger gate TRIG-1..8, turn-end gate INV-1..5, close planner and verdict, adapter command contract, recovery page, watchdog, manager events, doctor, stats), three hooks, `/rotation:init`, templates, seven self-tests.
