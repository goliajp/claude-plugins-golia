# Configuration: rotation.conf, project.sh, the adapter command contract

Two files the project owns, written once by `init.sh` from the templates and never overwritten. `rotation.conf` holds **values** (thresholds, modes, names); `project.sh` holds **actions** (directories, commands) and is sourced. The kernel's defaults and the full comment for each key are in `templates/rotation.conf.example` and `templates/project.sh.example`.

## rotation.conf

`key=value`, one per line, `#` comments, only `ROTATION_*` keys. These keys are read **from this file only**: the kernel clears them from the environment first. `trigger.sh` writes every effective value and the file's sha256 into each `rotations.jsonl` row; `doctor.sh` validates the file.

| Key | Required | Default | Meaning |
|---|---|---|---|
| `ROTATION_CONF_KERNEL` | yes | — | the kernel major this file was written for (`1`, or `1.1` to record the minor); a major mismatch is exit 2 everywhere, a minor difference a doctor WARN |
| `ROTATION_TRIG1_MIN_COMMITS` | yes | — | TRIG-1a: commit floor N. No kernel default on purpose: it is the project's measurement |
| `ROTATION_TRIG1_MIN_CLOSED` | yes | — | TRIG-1b: shas on `closed:` from this round (template: 3) |
| `ROTATION_TRIG2_MIN_WALL_SEC` / `_MAX_WALL_SEC` | yes | — | TRIG-2 floor and cap in seconds; past the cap TRIG-1a is waived |
| `ROTATION_TRIG2_MEASURE` | no | `trigger` | `trigger` (since the previous self row, idle gap included) or `active` (since this round's `rotation.start`; unknown = FAIL) |
| `ROTATION_TRIG1A_MODE`, `ROTATION_TRIG2_MODE` | no | `enforce` | `observe` computes, prints and records without blocking |
| `ROTATION_BOOTSTRAP_ROUNDS` | no | 20 | self rows `stats.sh --suggest` wants before proposing N and the cap |
| `ROTATION_TRIG5_SAME_AXIS_MAX` | yes | — | consecutive same-axis rounds before `axes-review:` is required (template: 8) |
| `ROTATION_TRIG5_BENCH_MAX_AGE_DAYS` | yes | — | how old the axis reading may be (template: 14) |
| `ROTATION_TRIG8_GATE_COVERAGE` | no | `off` | `on` judges gate coverage; `off` prints no line. Switch on in a gap between rounds and note it in that round's handoff |
| `ROTATION_COLD_START_WINDOW` | no | 25 | commits TRIG-3 looks back on a cold start |
| `ROTATION_AXES` | yes | — | the axis names, comma-separated |
| `ROTATION_TRIGGER_SECTION` | no | `rotate-trigger` | extended regex matched against the text after `## ` |
| `ROTATION_BLACKLIST_EXTRA` | no | — | TRIG-4 additions, `;`-separated extended regexes |
| `ROTATION_STAMPS` | yes | — | the stamps TRIG-6 requires fresh, space-separated; empty = FAIL |
| `ROTATION_SWEEP_STAMP` | yes | — | the stamp TRIG-7 re-derives the sweep line from |
| `ROTATION_AXIS_STAMP` | no | — | the stamp the axis reading is rendered from (TRIG-5) |
| `ROTATION_CLOSE_RULES` | yes | — | the rules table path (relative to the project root allowed); empty table = exit 2 |
| `ROTATION_CLOSE_CHECKS_OFF` | no | — | rows dropped before planning, comma-separated; an unknown name = exit 2 |
| `ROTATION_WAKE_AFTER` | no | 300 | seconds of executor silence after a `remote.end` before the watchdog's WAKE |
| `ROTATION_MESSAGES` | no | — | a `key=value` file overriding the verdict's human-read strings |

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
| `ROTATION_REAP_REMOTE_CMD` | no | best-effort cleanup on a runner when a round closes |
| `ROTATION_REMOTE_PROBE_CMD` | no | output shown verbatim on the recovery page (what runs on the runner) |
| `ROTATION_REMOTE_GREP_CMD` | no | `<cmd> <log> <marker> [host]`: exit 0 marker seen in the remote log · 1 not · other unknown. Not called for jobs recorded without a host |
| `ROTATION_REMOTE_COLLECT_CMD` | no | `<cmd> <kind> <sha> <log> <host> <rid>`: prints the commands that collect a finished job's results, one per line |
| `ROTATION_BASE_BRANCH` | no | the branch worktrees are measured against (default: the main tree's current branch) |
| `ROTATION_PROJECT_NAME` | no | the `project` field of each row (default: the checkout's directory name) |

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
- events are written with `.claude/rotation/event.sh` (the shim); nested fields as `gate=raw:{"sha":"…","pass":12,"fail":0,"skip":1,"log":"…","host":null}` or as dotted keys `remote.kind=gate remote.sha=…`
- the close segment reads the verdict's `.json`: `checks[]` with `name`, `decision` (`run` / `carry` / `current`), `mode`, `stampFile`, `tool`; it runs the `run` ones, writes each stamp (`<stampFile>` under `ROTATION_STAMP_DIR`, five fixed keys plus the readings, full `headSha`) and appends the same line to `stamps.jsonl`

### What the kernel reads back

| event | read by |
|---|---|
| `gate.end` | the verdict's §1 and TRIG-8 (coverage); the plan (a fail turns a check sync); the manager's report check 3 |
| `preflight.end` | the recovery page's activity; reserved for a per-commit coverage gate |
| `remote.start` / `remote.end` | `recover.sh` (open jobs, `terminal=`), `watchdog.sh` (WAKE after a `remote.end`) |
| the stamps | TRIG-6, TRIG-7, the plan, the fill, `stats.sh --effect` |

## Overrides for tests

`ROTATION_PROJECT_DIR`, `ROTATION_CONF`, `ROTATION_PROJECT_SH`, `ROTATION_STATE_DIR`, `ROTATION_ROTATIONS_LOG`, `ROTATION_EVENTS_LOG`, `ROTATION_HANDOFF_FILE` point the kernel at a fixture. They are for self-tests and for reading a real project's state **without writing to it** (set `ROTATION_EVENTS_LOG` to a throwaway copy before running anything against a live project from a side session). Unset in every real invocation.

Next: [adoption.md](adoption.md).
