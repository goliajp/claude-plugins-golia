# The close: plan, run, carry, verdict, release

A close used to run every mechanical check every round, whatever the round had changed. The planner reads the project's rules table and decides per check from the diff; the outcome is a verdict the handoff refers to and the manager verifies.

## Order (fixed)

```
0a end every child process this session started
0p plan: close_plan.sh → the verdict (sections 1, 2, 4)
   run the checks the plan says to run (adapter_run.sh close-segment … plan <verdict.json>)
   carry the rest (carry_stamp.sh, once per carried check)
   close_verdict_fill.sh <rid> → section 3; red = fix first, amber = attribute in the handoff
1  write the handoff (the trigger section, the pasted sweep line, the next item)
   agent_log.sh end <name> rotation <model>   — the executor closes its own registration
2  trigger.sh self
3  one line, then stop
```

The sweep line to paste is `ROTATION_SWEEP_JSON=<stamp dir>/<sweep stamp>-latest.json bash <ROTATION_SWEEP_LINE_CMD>` — the same call TRIG-7 makes.

Every stamp the plan says to *run* must be at HEAD **before** `close_verdict_fill.sh`; a stamp written after the fill leaves §3 saying "not at HEAD" (amber), and the fill has to be run again.

## The plan

`close_plan.sh [<prev> [<head>]] [--rid <rid>] [--explain] [--force]`

- no shas: the open round, `<last row's prevHead>..HEAD` (after the close trigger has written the next row, the row before it)
- **the very first round** has no row to read: pass `<prev>` (the commit the round started from) **and** `--rid <id>` (there is no row whose id the verdict could take; choose one, e.g. `r-0-bootstrap`, and use the same id for `close_verdict_fill.sh` and `report_save.sh`). From the second round on both come from the row
- the scripts print their usage on a wrong argument count or an unknown option (exit 2); there is no `--help`
- per check: `git diff --name-only <its stamp's headSha>..HEAD` against the `paths` globs → **run**; otherwise **carry** from that sha
- a missing stamp, a `-dirty` sha, a sha not in the repository, a stamp without a verdict or with a red one → run (red also turns the check sync)
- a `gate.end` with fails in this round, or a hit on `sync_paths` → the check turns sync for this close
- a prerequisite row (stamp `-`) runs when any dependant runs, with their mode
- the same range re-planned reads the existing verdict back; `--force` recomputes

The plan appends a `close.plan` event with the rules table's path, sha256 and row count. There are no thresholds and no "small enough to skip": the table is the only judge, and changing it is visible.

## Running

`bash .claude/rotation/adapter_run.sh close-segment <HEAD> plan <verdict.json>` hands the plan to the project's close segment command (`ROTATION_CLOSE_SEGMENT_CMD`), which runs the checks the plan lists and writes their stamps at HEAD. The command records `remote.start` / `remote.end` (kind `close.plan`); a segment that exits 0 without them is refused (exit 64). A project may split the work into named segments (`close-segment <HEAD> <segment>`) when one run would exceed a waiting tool's limit; each segment leaves its own log with a terminal line the recovery page can look for.

## Carrying

`carry_stamp.sh <name> <head> <reason>` writes `carriedTo`, `carriedReason`, `carriedAt` into `<name>-latest.json`, appends a history row (`carried: true`, the original `ranAt`) and records `stamp.carried`. It refuses a dirty, red or verdict-less stamp. `headSha` is never touched: a reader can always tell what was measured from what it is held valid for. TRIG-6 accepts `carriedTo == HEAD` exactly; a carry to an earlier commit of the round was decided before later commits could have touched the paths and does not count.

## The fill

`close_verdict_fill.sh <rid>` writes section 3 from the stamps and the history as they are now; re-runnable.

| marker | when |
|---|---|
| **RED** | a `regress` rule hit (`down` / `up` / `nonzero` / `each-up` against the last stamp that measured a different commit); a stamp verdict other than `ok` or no verdict; substrate files in the range and no `gate.end` of this round (`red_gate_missing`, naming `ROTATION_GATE_CMD`) |
| **amber** | a `~`-prefixed `regress` rule hit; a check the plan said to run whose stamp is not at HEAD or missing (`amber_not_at_head`) |

Red means the round does not close until it is dealt with (bisect the range, fix or revert, run the gate through `ROTATION_GATE_CMD` again); amber must be attributed in the handoff. The fill reports regressions in its output and the `close.result` event, not in its exit code (0 filled, 2 no verdict).

## Release forms

Section 4 reads the `mode` columns of the checks that run:

| form | meaning |
|---|---|
| `next` | everything carried: straight into the next round |
| `sync-then-next` | only sync checks run: finish them, then open |
| `next-async` | only async checks run: open now, they run alongside |
| `sync-then-next-async` | both: finish the sync ones, open, async continue |

Until a project has somewhere for async checks to run beside the next round (a second checkout, a queue), **all four forms are "finish, then open"**: the executor runs the async column too, serially, and the verdict's async list is bookkeeping for the manager. The release form is advice to the manager, not a gate; TRIG-6 (fresh or carried stamps) is what actually blocks.

## Messages in another language

Every human-read string in the verdict, the plan summary and the fill output is a key in the kernel's message table (English). `ROTATION_MESSAGES` in `rotation.conf` points at a `key=value` file that overrides any of them (`{name}` placeholders kept; an unknown key is a configuration error). Machine-read lines — `plan:`, `release:`, `gate:` summaries, `RED` / `amber`, JSON keys — never change.

Next: [roles.md](roles.md).
