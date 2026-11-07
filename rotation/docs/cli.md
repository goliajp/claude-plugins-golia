# CLI: `hardev`

```
hardev <noun> [<verb>] [args] [--lane NAME] [--project DIR] [--json]
```

`bin/hardev` is one entry point for every kernel command. Each noun + verb is a row of `bin/commands.tsv`; hardev `exec`s the kernel script the row names, with the row's fixed arguments first and the caller's after them, so the script's output and exit code are the command's. `hardev help` and `hardev <noun> help` print the table; this page and `init.sh --shims hardev` read the same file.

In 2.x both spellings work: `hardev event add …` and `bash .claude/rotation/event.sh …`. The shims go away in 3.0.

## Global options

Accepted anywhere before a `--`; after `--` every argument goes to the script untouched.

| Option | Effect |
|---|---|
| `--lane NAME` | the lane: exports `ROTATION_LANE=NAME`. For `init` and `onboard check` it is passed on as their own `--lane NAME` argument instead (init wires that lane; onboard check then requires step 8). `NAME` must match `[a-z0-9-]+` (exit 2 otherwise) |
| `--project DIR` | the project root: exports `ROTATION_PROJECT_DIR` (made absolute). For the commands that find their own root from the working directory (`init`, `lane enter`, `hook …`, `self …`) hardev changes into `DIR` instead |
| `--json` | appended to the script's arguments for the rows marked `--json` below; every other command refuses it: `hardev: <noun> <verb> has no --json yet`, exit 2 |

`stats.sh` has an option of its own named `--project` (the project name in the readings); pass it after `--`: `hardev stats -- --project NAME`.

`HARDEV_DRY_RUN=1` prints the line `hardev-dry-run: cwd=<dir> ROTATION_PROJECT_DIR=<dir|-> ROTATION_LANE=<name|-> exec <script> <args>` instead of running it, and exits 0. The self-test is written against it.

## Where the project root comes from

For every command marked `conf` below, in this order:

1. `--project DIR`
2. an exported `ROTATION_PROJECT_DIR` (a shim's, or the caller's)
3. the nearest directory at or above the working directory that holds `.claude/rotation/rotation.conf` — a worker's worktree under `<project>/.claude/worktrees/` finds the project, and a lane's worktree after `hardev lane enter` finds itself (its `.claude/rotation` links to the main tree's), which is what the lane's commands need: its commits, HEAD and branch are the worktree's
4. inside a git worktree: the first worktree of `git worktree list --porcelain` (the main tree), when it holds `.claude/rotation/rotation.conf`
5. nothing: no root is exported and the script uses its own default (the git top level of the working directory), as when it is called directly

## Commands

`root`: `conf` = the lookup above; `cwd` = the script finds its own root from the working directory. Exit codes are the script's; hardev's own errors are exit 2.

| Command | Arguments | Script | `--json` | root | Exit |
|---|---|---|---|---|---|
| `init` | `[--force] [--shims hardev\|legacy\|none] [--lane NAME [--from LANE]]` | `init.sh` | — | cwd | 0 · 1 not a git work tree / main lane not wired / no lane `--from` · 2 usage |
| `onboard check` | `[--lane NAME]` | `onboard_check.sh` | — | conf | 0 · 1 a step failed · 2 usage |
| `doctor` | `[--all]` | `doctor.sh` | — | conf | 0 · 1 a check failed · 2 usage |
| `status` | | `lanes.sh` | yes | conf | 0 · 2 usage |
| `lane list` | | `lanes.sh` | yes | conf | 0 · 2 usage |
| `lane enter` | `NAME [--share DIR]...` | `lane_enter.sh` | — | cwd | 0 · 1 not a worktree of a project with that lane · 2 usage |
| `lane close` | (with `--lane`) | `lane_close.sh` | — | conf | 0 · 1 a step failed · 2 usage · 3 merge conflict |
| `lane merge` | `TAG` \| `--returned TAG REASON [REVERT]` | `lane_merge.sh` | — | conf | 0 · 1 · 2 usage · 3 merge conflict |
| `lane return` | `TAG REASON [REVERT]` | `lane_merge.sh --returned` | — | conf | as `lane merge` |
| `window open` · `extend` | `NAME --until ISO\|+SECONDS\|EPOCH [--host H] [--reason R]` | `window.sh open` / `extend` | — | conf | 0 · 1 (extend) no such window open · 2 usage |
| `window close` | `NAME [--reason R]` | `window.sh close` | — | conf | 0 · 1 no such window open · 2 usage |
| `window status` | `[NAME]` | `window.sh status` | yes | conf | 0 a window open · 1 closed · 2 usage |
| `event add` | `KIND [key=value]...` | `event.sh` | — | conf | 0 · 2 usage or a required key missing |
| `agent start` / `agent end` | `NAME ROLE MODEL [TASK] [REPORT]` | `agent_log.sh start` / `end` | — | conf | 0 · 2 usage |
| `manager start` · `spawn` · `resume` · `verify` · `stop` | as `manager_log.sh` | `manager_log.sh <verb>` | — | conf | 0 · 2 usage |
| `remote run` | `HOST COMMAND FIELD...` | `remote_run.sh` | — | conf | ssh's (255 link died) · 2 usage · 65 no pid line |
| `run preflight` · `gate` · `close-segment` · `bench` | as the adapter contract | `adapter_run.sh <verb>` | — | conf | the command's · 2 not registered · 64 exit 0 without the record |
| `close plan` | `[PREV [HEAD]] [--rid RID] [--explain] [--force]` | `close_plan.sh` | — | conf | 0 · 2 cannot plan |
| `close fill` | `RID` | `close_verdict_fill.sh` | — | conf | 0 · 2 no verdict |
| `close carry` | `X HEAD REASON` | `carry_stamp.sh` | — | conf | 0 · 1 refused · 2 usage |
| `close report` | `RID FILE` | `report_save.sh` | — | conf | 0 · 1 exists · 2 usage |
| `trigger` / `trigger manual` | | `trigger.sh [manual]` | — | conf | 0 · 1 blocked · 2 usage or configuration · 3 no terminal |
| `trigger self` | | `trigger.sh self` | — | conf | as above |
| `trigger gate` | | `trig_gate.sh` | — | conf | 0 · 1 FAIL · 2 configuration |
| `trigger check` | `[RID]` | `check.sh` | — | conf | 0 · 1 · 2 |
| `reap` | | `kill_stray_shells.sh` | — | conf | 0 · 1 no Claude Code ancestor found |
| `watch` | `[--all] [--interval S] [--stale S] [--wake S] [--dirty S] [--once]` | `watchdog.sh` | — | conf | 10–16 the reason · 0 only with `--once` · 1 · 2 usage |
| `recover` | `[--all] [--no-probe]` | `recover.sh` | yes | conf | 0 · 2 usage |
| `log` | `[--tail N]` | `log.sh` | yes | conf | 0 · 2 usage |
| `stats` | `[--tail N] [-- --project NAME]` | `stats.sh` | — | conf | 0 · 2 |
| `stats effect` | `[--tail N]` | `stats.sh --effect` | yes | conf | 0 · 2 |
| `stats suggest` | | `stats.sh --suggest` | — | conf | 0 · 2 |
| `hook stop` · `subagent-stop` · `session-start` | (hook input on stdin) | `stop_hook.sh` · `subagent_stop_hook.sh` · `session_start_hook.sh` | — | cwd | 0 |
| `self version` | | built in: `hardev <version> (conf format <n>)`, both from `bin/lib.sh` | — | — | 0 · 2 |
| `self path` | | built in: the plugin root | — | — | 0 · 2 |
| `self install` | `[--force]` | built in | — | — | 0 · 1 a different file is there · 2 |
| `self uninstall` | | built in | — | — | 0 · 1 not this hardev's link · 2 |
| `help` | `[NOUN]` | built in | — | — | 0 |

`onboard check` reports steps, not yet the project's level (L0–L5: applicability, direction, plan, measurement, cadence, lanes); the level is planned for a later version, together with `onboard guide`.

Errors of hardev itself, all exit 2 with a line on stderr: an unknown noun (the table follows), an unknown verb of a noun (the noun's rows follow), a bare word before `--` that is not a verb of a noun that has verbs, a noun without the verb it needs, `--json` where the script has none, a bad `--lane` name, a `--project` that is not a directory.

## The old spelling

`init.sh --shims MODE` decides what `.claude/rotation/<script>` (and each lane's `.claude/rotation-lanes/<lane>/<script>`) is:

| MODE | Shim |
|---|---|
| `legacy` (default in 2.x) | `exec "$(cat kernel.path)/bin/<script>" "$@"` with the root set from where the shim lives |
| `hardev` | `exec hardev --project <root> <noun> [<verb>] -- "$@"`: the noun and verb are those of the `commands.tsv` row whose legacy column names the script; a lane's shim exports `ROTATION_LANE` first. The `hardev` is the one in `kernel.path`, else the one on the PATH. A script whose first argument is its verb (`trigger.sh self`, `agent_log.sh start`, `manager_log.sh spawn`, `adapter_run.sh gate`) maps to the noun alone, and that argument becomes the verb |
| `none` | no shims and no `lib.sh` source shim |

The root is computed from the shim's location in every mode (an exported `ROTATION_PROJECT_DIR` wins), so a shim reached through a lane worktree's `.claude` link resolves to that worktree. The `lib.sh` shim — sourced by adapter scripts, not run — is the same in `legacy` and `hardev`.

## Install

```
<plugin dir>/bin/hardev self install
```

`hardev self install` links `bin/hardev` to `~/.local/bin/hardev` (no sudo). A link that is already there and points elsewhere, or a file, is left alone (exit 1) unless `--force`. When `~/.local/bin` is not on the `PATH` it prints one line saying so; it never edits a shell rc file. `hardev self uninstall` removes the link when it is this hardev's.

The plugin's install directory carries its version; after `claude plugin update rotation` run `self install --force` from the new directory (`hardev self path` names the one the link points to).

From 2.0.0 the plugin version and the kernel version are one number: `hardev self version`, `plugin.json` and `DOCTOR PASS kernel=…` print the same. `hardev self version` prints `hardev <version> (conf format <n>)`; the conf format is the separate number a `rotation.conf` states as `ROTATION_CONF_KERNEL` ([configuration.md](configuration.md)).
