# Configuration: rotation.conf, project.sh, the adapter command contract

Two files the project owns, written once by `init.sh` from the templates and never overwritten. `rotation.conf` holds **values** (thresholds, modes, names); `project.sh` holds **actions** (directories, commands) and is sourced. The kernel's defaults and the full comment for each key are in `templates/rotation.conf.example` and `templates/project.sh.example`.

## rotation.conf

`key=value`, one per line, `#` comments, only `ROTATION_*` keys. These keys are read **from this file only**: the kernel clears them from the environment first. `trigger.sh` writes every effective value and the file's sha256 into each `rotations.jsonl` row; `doctor.sh` validates the file.

| Key | Required | Default | Meaning |
|---|---|---|---|
| `ROTATION_CONF_KERNEL` | yes | — | the conf format this file is written in: `1`. A conf in another format is exit 2 everywhere (see below) |
| `ROTATION_TRIG1_MIN_COMMITS` | yes | — | TRIG-1a: commit floor N. No kernel default on purpose: it is the project's measurement |
| `ROTATION_TRIG1_MIN_CLOSED` | yes | — | TRIG-1b: shas on `closed:` from this round (template: 3) |
| `ROTATION_TRIG2_MIN_WALL_SEC` / `_MAX_WALL_SEC` | yes | — | TRIG-2 floor and cap in seconds; past the cap TRIG-1a is waived |
| `ROTATION_TRIG2_MEASURE` | no | `trigger` | `trigger` (since the previous self row, idle gap included) or `active` (since this round's `rotation.start`; unknown = FAIL) |
| `ROTATION_TRIG1A_MODE`, `ROTATION_TRIG2_MODE` | no | `enforce` | `observe` computes, prints and records without blocking |
| `ROTATION_BOOTSTRAP_ROUNDS` | no | 20 | self rows `stats.sh --suggest` wants before proposing N and the cap |
| `ROTATION_TRIG5_SAME_AXIS_MAX` | yes | — | consecutive same-axis rounds before `axes-review:` is required (template: 8) |
| `ROTATION_TRIG5_BENCH_MAX_AGE_DAYS` | yes | — | how old the axis reading may be (template: 14) |
| `ROTATION_TRIG8_GATE_COVERAGE` | no | `off` | `on` judges gate coverage; `off` prints no line. Switch on in a gap between rounds and note it in that round's handoff |
| `ROTATION_TRIG9_VERDICT_RED` | no | `off` | `on`: the trigger FAILs while the round's filled close verdict has red, or has no filled verdict; `off` prints no line. Switch on in a gap |
| `ROTATION_COLD_START_WINDOW` | no | 25 | commits TRIG-3 looks back on a cold start |
| `ROTATION_AXES` | yes | — | the axis names, comma-separated |
| `ROTATION_TRIGGER_SECTION` | no | `rotate-trigger` | extended regex matched against the text after `## ` |
| `ROTATION_BLACKLIST_EXTRA` | no | — | TRIG-4 additions, `;`-separated extended regexes |
| `ROTATION_STAMPS` | yes | — | the stamps TRIG-6 requires fresh, space-separated; empty = FAIL |
| `ROTATION_SWEEP_STAMP` | yes | — | the stamp TRIG-7 re-derives the sweep line from |
| `ROTATION_AXIS_STAMP` | no | — | the stamp the axis reading is rendered from (TRIG-5) |
| `ROTATION_CLOSE_RULES` | yes | — | the rules table path (relative to the project root allowed); empty table = exit 2 |
| `ROTATION_CLOSE_CHECKS_OFF` | no | — | rows dropped before planning, comma-separated; an unknown name = exit 2 |
| `ROTATION_WORKER_STALE` | no | 1200 | seconds a worker still registered as running may go without its transcript being written before it is `dead?` (recover page) and a WAKE (watchdog) |
| `ROTATION_MESSAGES` | no | — | a `key=value` file overriding the verdict's human-read strings |
| `ROTATION_LANE_SHARED_DIRS` | no | — | lanes only: top-level directories of the main tree that `lane_enter.sh` links into the lane's worktree, space-separated (e.g. `.dev`); [lanes.md](lanes.md) |
| `ROTATION_LANE_NAME` | no | — | the name of the lane that has no directory (the project's first lane, `.claude/rotation/`): its events then carry `lane` like every other lane's. Unset, its rows are exactly what they were before lanes existed; [lanes.md](lanes.md) |
| `ROTATION_PLAN_FILE` | no | `.claude/plan-state.md` | the plan `onboard_check.sh` (steps 2–5) and `doctor.sh` (`plan.queue`, `plan.l4`) read: L1 roadmap, L2 version scope, the queue table, L3a / L3b, L4 trigger predicates |
| `ROTATION_VISION_FILE` | no | `.claude/vision.md` | the one-page direction file (step 1): a positioning section and a non-goals section |
| `ROTATION_QUEUE_HEADER` | no | `通道\|id\|状态\|一句话\|出处\|登记\|验收\|blocked_by\|done` | the queue table's header, `\|`-separated: the same nine columns in the same order (lane, id, state, summary, source, registered, acceptance, blocked_by, done) under the project's own names. The English `lane\|id\|status\|summary\|source\|registered\|acceptance\|blocked_by\|done` is always accepted too |
| `ROTATION_QUEUE_STATES` | no | `在做,排队,已完成,等决定,撤回` and `active,queued,done,decision,withdrawn` | the states a queue row may be in, comma-separated; setting it replaces both default lists |
| `ROTATION_QUEUE_FINAL_STATES` | no | `已完成,撤回,done,withdrawn` | the final states: a row in one of them may leave acceptance empty (it is history), comma-separated |
| `ROTATION_LANES_DOC` | no | the plan file | where each lane's description lives (step 8): a section headed by the lane's name naming its work line, independence, verification machine and merge protocol |
| `ROTATION_MERGE_FROM` | no | `develop` | lanes: the branch `lane_close.sh` merges into the lane before its trigger |
| `ROTATION_INBOX_FILE` | no | `.claude/autorun-inbox.md` | the inbox `lane_close.sh` and `lane_merge.sh --returned` write their rows into (created when missing) |
| `ROTATION_INBOX_INSERT_LINE` | no | 65 | the line those rows land on (past the end of the file: appended) |
| `ROTATION_TRACE_PATTERN` | no | `Co-Authored-By\|Generated with\|generated with\|🤖\|[Cc]laude` | lanes: an extended regexp `lane_close.sh` (step 0) refuses in any line of a commit message of the round's range, alongside `ROTATION_AGENT_ORIGIN_PATTERN` (default `^Agent-Origin:`) |
| `ROTATION_HANDOFF_SECTIONS` | no | — (not checked) | lanes: titles the handoff must carry before `lane_close.sh` merges, `\|`-separated; a title is present when a line is `#`..`######`, a space and text containing it, or starts with `**` and it (literal text) |

`ROTATION_CONF_KERNEL` names the conf format, not a kernel version. From 2.0.0 it is independent of the product version (`hardev self version` prints both: `hardev 2.0.0 (conf format 1)`); the kernel declares the format it reads as `ROTATION_CONF_FORMAT` in `bin/lib.sh`. The format is still `1`: no key has changed meaning, and a key added with a default does not change the format. It rises only when an existing key's meaning changes incompatibly, and then the release notes say what to rewrite. A value written before 2.0.0 with a dot (`1.1`) is still read; only the part before the dot is compared.

## project.sh

Sourced by the kernel with `PROJECT_DIR` set to the git top level; every value is `export`ed. `doctor.sh` fails without the seven required ones.

| Variable | Required | What |
|---|---|---|
| `ROTATION_STAMP_DIR` | yes | where `<name>-latest.json` stamps live |
| `ROTATION_STAMP_HISTORY` | no | `stamps.jsonl` (default `<stamp dir>/stamps.jsonl`) |
| `ROTATION_VERDICT_DIR` | yes | verdicts `<rid>.verdict.{md,json}` and filed reports `<rid>.md` |
| `ROTATION_SWEEP_LINE_CMD` | yes | read-only: renders the sweep stamp as one `sweep: head=<sha> …` line; exit 2 without a stamp |
| `ROTATION_AXIS_READING_CMD` | no | read-only: renders the axis stamp as one line carrying `ran=` |
| `ROTATION_AXIS_READING_FRESH_CMD` | no | exit 0 comparator current · 1 stale · 2 unknown |
| `ROTATION_GATE_CMD` | yes | the gate (contract below) |
| `ROTATION_PREFLIGHT_CMD` | yes | the pre-flight |
| `ROTATION_CLOSE_SEGMENT_CMD` | yes | the close segment |
| `ROTATION_BENCH_CMD` | yes | the bench (or any axis-reading producer) |
| `ROTATION_AFTER_WRITE_CMD` | no | run after every row or event the kernel appends and at every turn end (a dashboard repack); must exit 0 |
| `ROTATION_REAP_REMOTE_CMD` | no | no longer run since kernel 1.1.5 (it was a pattern kill on a shared runner); the reaper prints `IGNORED` when it is set and ends runner jobs only by their registered `remote.pid` |
| `ROTATION_REMOTE_PROBE_CMD` | no | output shown verbatim on the recovery page (what runs on the runner) |
| `ROTATION_REMOTE_GREP_CMD` | no | `<cmd> <log> <marker> [host]`: exit 0 marker seen in the remote log · 1 not · other unknown. Not called for jobs recorded without a host |
| `ROTATION_REMOTE_COLLECT_CMD` | no | `<cmd> <kind> <sha> <log> <host> <rid>`: prints the commands that collect a finished job's results, one per line |
| `ROTATION_CASESET_CMD` | no | `<cmd> <tool> <sha>`: prints the cases the stamp of `<tool>` at `<sha>` ran, in the `caseFile` line format, exit 0; read by `downSameSet` for a stamp that names no case list (stamps written before the check recorded one). The verdict names it as the list's source |
| `ROTATION_BASE_BRANCH` | no | the branch worktrees are measured against (default: the main tree's current branch) |
| `ROTATION_PROJECT_NAME` | no | the `project` field of each row (default: the checkout's directory name) |
| `ROTATION_LANE_CLOSE_HOOK` | no | lanes: a command `lane_close.sh` runs (`sh -c`, in the lane's worktree) after merging `ROTATION_MERGE_FROM` and before the trigger — what the project regenerates after that merge. May be set in `rotation.conf` instead; non-zero exit stops the close |

A project with no remote runner leaves the three `ROTATION_REMOTE_*` variables unset: its jobs record no `remote.host`, and the recovery tools read the local log files.

Every `*_CMD` must name an executable file (a bare word is looked up on `PATH`); `doctor.sh` checks each.

## The adapter command contract

The kernel does not know how a gate, a pre-flight, a close segment or a bench is run. `project.sh` registers one command for each; the kernel calls them **only** through `adapter_run.sh`, and everything else in the kernel reads the events they write. A command that exits 0 has claimed success, and the claim must be on record: `adapter_run.sh` checks the terminal line and the events appended during the run, and exits **64** when either is missing. Any non-zero exit is passed through untouched (only success is verified).

| Command | Arguments | Exit | Terminal line on stdout (extended regex) | Events it must append |
|---|---|---|---|---|
| gate | `<sha> [project options]` | 0 ran and F = 0 · 1 F > 0 · 2 usage · ≥ 3 did not finish | `[0-9]+ pass / [0-9]+ fail / [0-9]+ skip` | `remote.start` (`remote.kind=gate`, `remote.sha`, `remote.log`, `remote.marker`; `remote.host` optional) before; `gate.end` (`gate{sha,pass,fail,skip,log}`, `host` optional) and `remote.end` (same `remote.log`, `remote.status=ok\|fail`) after. On exit ≥ 3 the end may be missing: the job may still be running, and recovery judges by the marker |
| pre-flight | `[-q] [project options]` | 0 pass · 1 fail · 2 usage | `^PREFLIGHT PASS` (or `^PREFLIGHT FAIL: …` with exit 1) | `preflight.end` (`preflight{result=pass\|fail, quick, parent=HEAD when run, sha=the commit checked or null, files, reasons}`) |
| close segment | `<head> <segment\|plan> [verdict.json]` | the segment's own (0 done) · 2 usage · 3 could not start | none required; recommended `^DONE segment=<s> head=<head> ` registered as the marker | `remote.start` (`remote.kind=close.<segment>`, `remote.sha=<head>`, `remote.log`, `remote.marker`) and `remote.end` (`remote.status`, `remote.rc`) |
| bench | `<sha> [segment …]` | 0 all segments ran and the stamp is written · 1 a segment failed · 2 usage or comparator not current · 3 runner lost | none required | one `remote.start` / `remote.end` pair per segment (`remote.kind=bench.<segment>`); the axis stamp (`ROTATION_AXIS_STAMP`) written at the end |

Common to all four:

- called with the single argument `--doctor-probe`, each must **exit 2 without doing anything**. `doctor.sh` calls them that way; it never runs the real thing. A usage check on the first argument (a sha must be hex, a segment name must be known, `-q` must be the only option) satisfies this naturally
- `remote.host` absent or `null` means the job ran on this machine and `remote.log` is a local file
- a job on a runner is started with `.claude/rotation/remote_run.sh <host> <command> <remote.start fields…>` (the shim): it holds the ssh, has the runner's shell print its own pid first, and records `remote.start` with the fields given plus `remote.host`, `remote.pid` (that shell; everything the job starts is under it), `remote.pidStart` (its `ps -o lstart`) and `remote.launcher` (the local pid holding the ssh). Those pids are the only way the kernel ever ends a runner job: the recovery page prints the command for an `orphan?` job, the trigger's reaper runs it. A runner is shared with other sessions, so nothing — kernel, adapter or person — selects a process there by a command-line pattern (`pkill -f`, a `pgrep -f` fed to a kill)
- events are written with `.claude/rotation/event.sh` (the shim); nested fields as `gate=raw:{"sha":"…","pass":12,"fail":0,"skip":1,"log":"…","host":null}` or as dotted keys `remote.kind=gate remote.sha=…`
- the close segment reads the verdict's `.json`: `checks[]` with `name`, `decision` (`run` / `carry` / `current`), `mode`, `stampFile`, `tool`; it runs the `run` ones, writes each stamp (`<stampFile>` under `ROTATION_STAMP_DIR`, five fixed keys plus the readings, full `headSha`) and appends the same line to `stamps.jsonl`

### What the kernel reads back

| event | read by |
|---|---|
| `gate.end` | the verdict's §1 and TRIG-8 (coverage); the plan (a fail turns a check sync); the manager's report check 3 |
| `preflight.end` | the recovery page's activity; reserved for a per-commit coverage gate |
| `remote.start` / `remote.end` | `recover.sh` (open jobs, `terminal=`, `orphan?` and the command ending the job by `remote.pid`), `watchdog.sh` (WAKE after a `remote.end`), the trigger's reaper (open jobs of the round with a `remote.pid`, session mode) |
| the stamps | TRIG-6, TRIG-7, the plan, the fill, `stats.sh --effect` |

## Overrides for tests

`ROTATION_PROJECT_DIR`, `ROTATION_CONF`, `ROTATION_PROJECT_SH`, `ROTATION_STATE_DIR`, `ROTATION_ROTATIONS_LOG`, `ROTATION_EVENTS_LOG`, `ROTATION_HANDOFF_FILE` point the kernel at a fixture. `ROTATION_LANE` is not one of them: it selects a lane the project wired (`init.sh --lane`), and the lane's shims export it; see [lanes.md](lanes.md). They are for self-tests and for reading a real project's state **without writing to it** (set `ROTATION_EVENTS_LOG` to a throwaway copy before running anything against a live project from a side session). Unset in every real invocation.

Next: [adoption.md](adoption.md).
