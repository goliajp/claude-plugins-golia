# Lanes: two executors in one project

A lane is a second instance of the protocol inside the same project: its own executor, its own branch, its own handoff, trigger gate, close rules and state, with the same kernel. The project's first instance is the **main lane**; it does not know lanes exist, and nothing of its layout moves when a lane is added or removed.

## When

Two streams of work that should not share one gate or one commit count — for example substrate work measured on a benchmark machine beside platform or library work that only needs a build machine. One executor per lane, each with its own worker quota. A lane is not a way to run two executors on the same branch: both commit counts and both gates would read the same history.

## Layout

| Path | Lane | Main lane (unchanged) |
|---|---|---|
| shims (`event.sh`, `trigger.sh`, `doctor.sh`, …) | `.claude/rotation-lanes/<lane>/` — each exports `ROTATION_LANE=<lane>`, reads the main lane's `kernel.path` | `.claude/rotation/` |
| `rotation.conf`, `project.sh`, `close_rules.tsv` | `.claude/rotation-lanes/<lane>/` (copied from the main lane's by `init.sh --lane`, then the lane's to edit) | `.claude/rotation/` |
| handoff | `.claude/rotation-lanes/<lane>/handoff.md` | `.claude/handoff.md` |
| intent | `.claude/rotation-lanes/<lane>/autorun-intent` | `.claude/autorun-intent` |
| state (`rotations.jsonl`, `events.jsonl`, `manager.active`, `handoff/`) | `.claude/rotation-state/lanes/<lane>/` | `.claude/rotation-state/` |

Every kernel script derives these from `ROTATION_LANE` in `lib.sh`; the lane's shims set it, so `bash .claude/rotation-lanes/<lane>/<script>` is the lane's call and `bash .claude/rotation/<script>` the main lane's. A lane's events carry `"lane":"<lane>"`; the main lane's rows are byte-for-byte what they were.

## Wiring a lane

```
bash <kernel>/bin/init.sh --lane <name>          # in the main tree; the main lane must be wired already
```

Then edit the lane's `rotation.conf` (its own thresholds — a new lane usually starts TRIG-1a and TRIG-2 in `observe`; its own stamp list, sweep stamp and rules table) and `project.sh` (its own adapter commands, stamp and verdict directories: the lane must not write the main lane's stamps), and run `bash .claude/rotation-lanes/<name>/doctor.sh` to `DOCTOR PASS`.

## The lane's worktree

A lane's executor never works on the main tree (the main lane's executor does). It works in a git worktree of the project on the lane's branch. `.claude/` and whatever else the protocol needs are not in git, so inside that worktree, once:

```
bash "$(cat <main tree>/.claude/rotation/kernel.path)/bin/lane_enter.sh" <lane>
```

makes `.claude/` a real directory whose entries link to the main tree's, except `worktrees/` (the lane's own, so its workers' worktrees never mix with the main lane's) and `handoff.md` (a link to the lane's handoff, so "read the handoff" at the usual path reads the lane's). The directories named in the lane's `ROTATION_LANE_SHARED_DIRS` (`rotation.conf`) or given with `--share` are linked at the top level the same way. A shim called through these links resolves the project root to the worktree, so the lane's HEAD, commit counts and dirty check are the worktree's while conf, rules and state are the shared files.

The main lane's close must leave the lane's worktree alone: it is not one of the main lane's workers. Record its path where the main lane's executor reads leftovers, or keep it outside `.claude/worktrees/`.

## Managing

The manager runs the lane's shims for the lane: `manager_log.sh start`, `doctor.sh`, `recover.sh`, `watchdog.sh`, `report_save.sh` under `.claude/rotation-lanes/<lane>/`, one watchdog per lane. An executor that lives in a worktree is never continued by `SendMessage` (the worktree guard would move the sender's working directory); after a restart or a stall it is replaced from its branch, exactly like a worker.

## How the lanes meet

The kernel does not merge branches. The project writes the hand-over into both handoffs: typically the lane tags its closed HEAD, the main lane's executor merges that tag as a batch of its own, runs its gate on it, and a regression found by the main lane's close is reverted there and handed back through the lane's inbox. What the main lane measures (its stamps, its red lines) applies to the merged result; the lane's own close proves the lane's own checks.

## Removing a lane

Stop its executor, merge or drop its branch, leave `.claude/rotation-lanes/<lane>/` and `.claude/rotation-state/lanes/<lane>/` in place as history (or delete them). The main lane never referenced them: with the lane gone the project is exactly the single-lane project it was. A lane can be re-opened later with the same name; its state continues where it stopped.
