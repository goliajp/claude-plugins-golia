# Data contract

Every file the kernel reads or writes, with the fields the gates and the recovery tools depend on. Two rules hold for all of them:

- **Append-only.** `rotations.jsonl`, `events.jsonl` and `stamps.jsonl` grow by whole lines; nothing rewrites or deletes a line. A correction is a new line.
- **Schema only grows.** A field is never removed or given a new meaning; new fields are appended and may be absent in older lines. Every reader tolerates a missing field (unknown is `null`, never `0`).

## rotations.jsonl

One line per accepted trigger (`trigger.sh self|manual`), compact JSON.

| Field | Meaning |
|---|---|
| `rotationId` | `r-<unix-ts>-<4 hex>`; unique (INV-5) |
| `at`, `ts` | trigger time, RFC-3339 UTC and epoch seconds |
| `project` | `ROTATION_PROJECT_NAME`, else the checkout's directory name |
| `trigger` | `self` (gated) / `manual` (operator, terminal only) / `hook` / `daemon` (reserved) |
| `prevHead` | HEAD at trigger time: the commit the *next* round starts from and the start of the range the next verdict judges |
| `handoffSha`, `handoffAgeSec` | sha256 of the handoff and its age at trigger time (INV-1 wants < 90 s) |
| `conformanceBefore` | the `gate: N/F/S` triple from the trigger section, or `null`; INV-3 compares the first number against the previous row |
| `commitsInSession` | first-parent commits in `<previous self prevHead>..HEAD` without an `Agent-Origin:` trailer — the same count TRIG-1 judged; `null` on a cold start (no previous self row) |
| `axis` | the `axis:` line, normalised; TRIG-5 reads the streak from it |
| `triggerReason` | a legacy letter, recorded when present, never required |
| `kernelVersion` | `ROTATION_KERNEL_VERSION` that wrote the row |
| `confSha256`, `thresholds{…}` | sha256 of `rotation.conf` and every effective threshold and mode key; a changed threshold is visible in the rows that follow |
| `activeWallSec` | trigger `ts` − the round's latest `rotation.start` (else its first `agent.start` with `agent.role=rotation`); `null` when neither exists. Differs from the trigger-to-trigger wall by the idle gap between the handover and the executor starting |
| `managerCommits` | commits in the round's range on the first-parent line, without the trailer, whose committer time falls inside no executor's running interval (`agent.start role=rotation` → the same agent's `agent.end`, or now). Should be 0 |

A *self row* is a row with `trigger=self`; "the previous self row" anchors every per-round range and wall.

## events.jsonl

One line per event: `{"at","ts","kind","rotationId","head", …}` plus the kind's own fields. `event.sh <kind> key=value…` is the general writer (dotted keys nest: `remote.log=x` → `{"remote":{"log":"x"}}`; value prefixes `int:`, `list:a,b`, `raw:<json>`). The kinds the kernel reads, and what each must carry (a missing required field is refused, exit 2):

| kind | required | written by |
|---|---|---|
| `agent.start` / `agent.end` | `agent{name,role,model}`; `id`, `worktree`, `scratch`, `gateLog` when the caller set `ROTATION_AGENT_*`; `end` adds `status` ok/fail/abandoned. A `start … rotation` needs `ROTATION_AGENT_ID` and also carries `managerSession` | `agent_log.sh` |
| `rotation.start` | `mode=subagent`, `rotationAgent`, `agent{name,id}`, `managerSession` — the round's active start | `agent_log.sh start … rotation` |
| `agent.stop` | `agent{id,…}` — the executor finished a reply | `subagent_stop_hook.sh` |
| `rotation.end` | `trigger`, `next` (the new id) — written just before the new row | `trigger.sh` |
| `trigger.result` | `trig{result,failed[],observed[],conf{…}}` | `trigger.sh self` |
| `preflight.end` | `preflight{result,quick,parent,sha,files,reasons}`; `parent` = HEAD when it ran, `sha` = the commit checked or `null` | the project's pre-flight command |
| `remote.start` | `remote{kind,log}`; `sha`, `marker` (regexp of the terminal line), `host` optional — **no host means the job ran locally and `log` is a local file** | adapter commands, or `event.sh` for any other job |
| `remote.end` | `remote.log` (or `kind`+`sha`); `status` ok/fail/abandoned, `rc` | adapter commands; `recover.sh` prints the command for a job whose end was never recorded |
| `gate.end` | `gate{sha,pass,fail,skip,log}`; `host` optional. A `gate.end` for a log also closes that log's `remote.start` | the project's gate command — **the only writer** |
| `executor.waiting` | `remote{log,marker}` or `workers: [names]` | the executor, before ending a turn to wait |
| `quota.hit` | `quota.resets` (epoch / ISO / local `HH:MM`); `quota.agent` | whoever received the 429 |
| `manager.start` / `spawn` / `resume` / `verify` / `stop` | all carry `managerSession`; `spawn`/`resume` need `manager.agent{id}`; `resume` needs `manager.reason` quota/restart/wake; `verify` needs `manager.checks{"n":"pass"/"fail"}` and `manager.result` | `manager_log.sh` (never `event.sh` directly) |
| `close.plan`, `close.result` | `plan{rules,rulesSha256,…}` | `close_plan.sh`, `close_verdict_fill.sh` |
| `stamp.carried`, `report.saved`, `doctor.result` | as named | `carry_stamp.sh`, `report_save.sh`, `doctor.sh` |

"This round's events" are those with `ts` ≥ the last self row's `ts`.

## manager.active

One line, present while a round is being managed: `rotation=<rid> executor=<name> id=<agentId> since=<iso> session=<managerSession>` (`rotation=` is empty before the first row exists). Written by `agent_log.sh start … rotation`, left in place by a plain `agent_log.sh end` and by the trigger (the manager is still managing between rounds), removed only by `ROTATION_MANAGER_IDLE=1 agent_log.sh end … rotation` when the manager stops on purpose. While it exists: `FOREIGN-COMMIT` is checked, and a resumed session gets the recovery page printed into its context.

An executor counts as running from its `agent.start` until an `agent.end` of the same name (`agent.stop` from the hook does not end it); the executor records `agent_log.sh end <name> rotation <model>` as its last step before `trigger.sh self`. A registration that is never ended still drops out of "this round" once the trigger has written the next row, which is why `recover.sh` says `IDLE` after a close even when the end was forgotten — but the watchdog and the doctor count it until then.

## Stamps

`ROTATION_STAMP_DIR/<name>-latest.json`, one per check, written by the project's check (the kernel only reads them). Five fixed keys, then whatever readings the check has:

| key | |
|---|---|
| `tool` | the check's name (the `stamp` column's tool in the rules table) |
| `ranAt` | RFC-3339 |
| `headSha` | the **full** sha of the commit measured; a `-dirty` suffix means the tree was not any commit |
| `headShaSource` | how the sha was obtained (`arg`, `git`, …), so a remote run that was told the sha is distinguishable from one that guessed |
| `verdict` | `ok` or the failure word; a stamp **without** this key is red (unknown is not green) |

A carried stamp (see [close.md](close.md)) gains `carriedTo` (the HEAD it is held valid for), `carriedReason`, `carriedAt`; `headSha` is never changed. Readers compare shas by prefix, so older short-sha stamps still read.

`ROTATION_STAMP_HISTORY` (default `<stamp dir>/stamps.jsonl`) gets one line per stamp written or carried (`carried: true`); the verdict's deltas are computed against the last history row of the same tool that measured a *different* commit.

## The sweep line and the axis reading

Two read-only commands the project writes (`project.sh`); both receive the stamp path in `ROTATION_SWEEP_JSON` / `ROTATION_AXIS_JSON`:

- `ROTATION_SWEEP_LINE_CMD` prints one line `sweep: head=<sha> …` from the sweep stamp; **exit 2 when there is no stamp**. TRIG-7 requires every whitespace-separated token of this line to appear in the handoff.
- `ROTATION_AXIS_READING_CMD` (optional) prints one line carrying `ran=` from the axis stamp (a bench, say); TRIG-5 requires its tokens in the `axes-review:` block. `ROTATION_AXIS_READING_FRESH_CMD` (optional) exits 0 when the reading's comparator is current, 1 stale, 2 unknown.

## The handoff's trigger section

```markdown
## rotate-trigger

axis: A
closed: 8ffa78b99 what this closed; be4efafee what that closed; a359e2d71 a third thing
gate: 3773/0/4
sweep: head=… pass=… passTotal=… …        ← pasted from ROTATION_SWEEP_LINE_CMD, never typed
```

- heading: `## ` followed by text matching `ROTATION_TRIGGER_SECTION` (default `rotate-trigger`, an extended regex); the section runs to the next `## `
- `axis:` one or more of `ROTATION_AXES`, comma-separated
- `closed:` the block from this key to the next `key:` line; at least `ROTATION_TRIG1_MIN_CLOSED` shas inside `<previous self prevHead>..HEAD`, each with a sentence
- `gate:` `N/F/S`, F must be 0
- `axes-review:` required only when TRIG-5 fires; must include the axis reading's tokens
- `sweep:` anywhere in the handoff, every round

## The rules table (`close_rules.tsv`)

Tab-separated, `#` lines ignored, ten columns; `-` means none. The template's header comment is the normative description; in short:

| column | |
|---|---|
| `name` | the check; also the key in the verdict |
| `paths` | trigger globs, `;`-separated, `!glob` excludes; `**` crosses `/`, `*` does not; `-` = no own trigger (a prerequisite row) |
| `artifact` | a label the project chooses for what the check reads |
| `stamp` | `<x>[:<tool>]`: `<x>-latest.json` and the `tool` name in the history; `-` = no stamp |
| `minutes` | typical duration |
| `mode` | `sync` (the next round waits) / `async` (runs alongside) / `-` (takes its dependants' mode) |
| `sync_paths` | globs whose hit turns an async check sync for this close |
| `needs` | a prerequisite row (stamp `-`) |
| `show` | stamp keys the verdict lists, `,`-separated, dotted for nested |
| `regress` | `<key>:down|up|nonzero` red when the reading moved that way against the previous stamp; `~` prefix makes it amber |

An empty table is a configuration error (exit 2). `ROTATION_CLOSE_CHECKS_OFF` drops named rows before planning; a name the table lacks is exit 2.

## The verdict

`ROTATION_VERDICT_DIR/<rid>.verdict.md` and `.json`, written by `close_plan.sh`, section 3 filled by `close_verdict_fill.sh`:

1. **What this rotation changed** — the range, files by area, and the gate events of the round: `N gate.end` (with whether the last commit has one) or **missing** when substrate files changed and no `gate.end` belongs to the round
2. **Decision** — per check: run (the paths it hit) or carry (from which sha), sync or async
3. **Results** — per check: ran at HEAD / carried to HEAD / not at HEAD; the `show` readings with deltas; `RED` / `amber` markers
4. **Release** — one of four forms: `next` (everything carried: straight into the next round) / `sync-then-next` / `next-async` / `sync-then-next-async`

The `rid` of a verdict is the round the range *belongs to* (the row whose `prevHead` opened the range), which is the id the round's events carry — not the id the close trigger has just written. `report_save.sh <rid> <file>` files the executor's report as `<rid>.md` beside it, once.

Next: [gates.md](gates.md).
