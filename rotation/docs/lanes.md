# Lanes: two executors in one project

A lane is one instance of the protocol inside a project: its own executor, its own branch, its own handoff, trigger gate, close rules and state, with the same kernel. Lanes are peers; the project gives them different work, not different ranks. The one the project had first lives at `.claude/rotation/` and `.claude/rotation-state/` and has no directory name — call it the **first lane**; it is named by `ROTATION_LANE_NAME` in its `rotation.conf` (an unnamed first lane writes rows exactly as it did before lanes existed), and nothing of its layout moves when another lane is added or removed.

## When

Two streams of work that should not share one gate or one commit count — for example substrate work measured on a benchmark machine beside platform or library work that only needs a build machine. One executor per lane, each with its own worker quota. A lane is not a way to run two executors on the same branch: both commit counts and both gates would read the same history.

## Layout

| Path | Lane | First lane (unchanged) |
|---|---|---|
| shims (`event.sh`, `trigger.sh`, `doctor.sh`, …) | `.claude/rotation-lanes/<lane>/` — each exports `ROTATION_LANE=<lane>`, reads the first lane's `kernel.path` | `.claude/rotation/` |
| `rotation.conf`, `project.sh`, `close_rules.tsv` | `.claude/rotation-lanes/<lane>/` (copied from the first lane's by `init.sh --lane`, then the lane's to edit) | `.claude/rotation/` |
| handoff | `.claude/rotation-lanes/<lane>/handoff.md` | `.claude/handoff.md` |
| intent | `.claude/rotation-lanes/<lane>/autorun-intent` | `.claude/autorun-intent` |
| state (`rotations.jsonl`, `events.jsonl`, `manager.active`, `handoff/`) | `.claude/rotation-state/lanes/<lane>/` | `.claude/rotation-state/` |

Every kernel script derives these from `ROTATION_LANE` in `lib.sh`; the lane's shims set it, so `bash .claude/rotation-lanes/<lane>/<script>` is the lane's call and `bash .claude/rotation/<script>` the first lane's. A lane's events carry `"lane":"<lane>"`; the first lane's rows are byte-for-byte what they were.

## Wiring a lane

```
bash <kernel>/bin/init.sh --lane <name>          # in the main tree; the first lane must be wired already
```

A lane that resembles an existing lane more than the first lane is copied from it instead:

```
bash <kernel>/bin/init.sh --lane <name> --from <lane>
```

copies that lane's `rotation.conf`, `project.sh` and `close_rules.tsv` with the source lane's name replaced wherever it names the lane — `rotation-lanes/<from>`, `lanes/<from>`, `lane-<from>`, `lane/<from>`, ``lane `<from>` ``, `lane <from>` (the name followed by anything but a letter, digit or dash) — and prints each file's replacement count. Read the copies anyway: a name spelled any other way is left as it was. A `--from` lane that does not exist is exit 1; nothing is written.

Then edit the lane's `rotation.conf` (its own thresholds — a new lane usually starts TRIG-1a and TRIG-2 in `observe`; its own stamp list, sweep stamp and rules table) and `project.sh` (its own adapter commands, stamp and verdict directories: the lane must not write the first lane's stamps), and run `bash .claude/rotation-lanes/<name>/doctor.sh` to `DOCTOR PASS`.

## The lane's worktree

A lane's executor never works on the main tree (the first lane's executor does). It works in a git worktree of the project on the lane's branch. `.claude/` and whatever else the protocol needs are not in git, so inside that worktree, once:

```
bash "$(cat <main tree>/.claude/rotation/kernel.path)/bin/lane_enter.sh" <lane>
```

makes `.claude/` a real directory whose entries link to the main tree's, except `worktrees/` (the lane's own, so its workers' worktrees never mix with the first lane's) and `handoff.md` (a link to the lane's handoff, so "read the handoff" at the usual path reads the lane's). The directories named in the lane's `ROTATION_LANE_SHARED_DIRS` (`rotation.conf`) or given with `--share` are linked at the top level the same way. A shim called through these links resolves the project root to the worktree, so the lane's HEAD, commit counts and dirty check are the worktree's while conf, rules and state are the shared files.

The first lane's close must leave the lane's worktree alone: it is not one of the first lane's workers. Record its path where the first lane's executor reads leftovers, or keep it outside `.claude/worktrees/`.

## Managing

The manager runs the lane's shims for the lane: `manager_log.sh start`, `doctor.sh`, `recover.sh`, `watchdog.sh`, `report_save.sh` under `.claude/rotation-lanes/<lane>/`, one watchdog per lane. An executor that lives in a worktree is never continued by `SendMessage` (the worktree guard would move the sender's working directory); after a restart or a stall it is replaced from its branch, exactly like a worker.

Every lane on one page, and one command for all of them:

```
bash .claude/rotation/lanes.sh [--json]          # one line per lane: branch, rid, head, last event, running executors, manager.active;
                                                 # then `windows:` the open windows (not in --json)
bash .claude/rotation/doctor.sh --all            # each lane's doctor under `== lane <name> ==`; exit = the highest
bash .claude/rotation/recover.sh --all [--json] [--no-probe]
bash .claude/rotation/watchdog.sh --all [--interval …] [--stale …] [--wake …] [--dirty …] [--once]
```

`watchdog.sh --all` is one process for every lane: each pass checks every lane in that lane's environment against one start floor, and the first pass with a hit prints `== lane <name> ==` and the line for each lane that hit, then exits with the highest of their codes. The manager reads the header to know which lane's executor to wake. Lanes are listed first lane first (under its `ROTATION_LANE_NAME`, else `main`), then `.claude/rotation-lanes/*` in name order.

## How the lanes meet

A lane closes its round with `lane_close.sh` instead of calling `trigger.sh self` itself, and the lane that merges it (usually the first lane) takes the result with `lane_merge.sh`. What the merging lane measures (its stamps, its red lines) applies to the merged result; the lane's own close proves the lane's own checks.

### Closing a lane's round: `lane_close.sh`

In the lane's worktree, through the lane's shim, after the close checks and the handoff:

```
bash .claude/rotation-lanes/<lane>/lane_close.sh
```

0. Trace check, before anything is merged: every commit of `<merge-base>..HEAD` (the merge base of the base below and HEAD) is read with `git log --format=%B`, and a line matching `ROTATION_AGENT_ORIGIN_PATTERN` (default `^Agent-Origin:`) or `ROTATION_TRACE_PATTERN` (default `Co-Authored-By|Generated with|generated with|🤖|[Cc]laude`) is listed with its sha. The handoff must carry every title of `ROTATION_HANDOFF_SECTIONS` (`|`-separated, default empty = not checked): a line of `#`..`######`, a space and text containing the title, or a line starting with `**` and the title; the missing ones are listed. Either finding exits 1 with nothing merged and no tag: reword the commits (a cherry-pick keeps the trailer) or write the section, and run it again.
1. `git merge <ROTATION_MERGE_FROM>` (default `develop`, message `merge: <base> into <lane branch>`): the round closes on what the merging lane has, so the tag merges back without surprises. A conflict exits 3, prints the conflicted files and leaves the merge in progress; resolve and commit (or `git merge --abort`) and run it again.
2. `ROTATION_LANE_CLOSE_HOOK` (optional; `project.sh` or `rotation.conf`): what the project regenerates after that merge, run with `sh -c` in the worktree. Non-zero stops the close (exit 1).
3. `trigger.sh self`: the lane's trigger gate. Blocked = exit 1, no tag, no inbox row: keep working and run it again.
4. `git tag lane/<lane>/<rid> HEAD`, where `<rid>` is the round that closed (the id its events carry).
5. One row at line `ROTATION_INBOX_INSERT_LINE` (default 65) of `ROTATION_INBOX_FILE` (default `.claude/autorun-inbox.md`; through `lane_enter.sh`'s link this is the main tree's inbox): `| <date> | lane/<lane>/<rid> ready · <N> commit · gate <N>/<F>/<S> | .claude/rotation-lanes/<lane>/handoff.md |`. The commit count is the `commitsInSession` of the row the trigger wrote, the gate triple the round's last `gate.end`; `?` where unknown.
6. Event `lane.ready` in the lane's log. Last line `LANE READY <tag> head=<sha>`.

Exit: 0 · 1 a step failed (not on the lane's branch, the tag exists, the trace check, the hook, the trigger) · 2 usage (not run through a lane's shim) · 3 merge conflict.

### Merging it, or handing it back: `lane_merge.sh`

In the merging lane's tree:

```
bash .claude/rotation/lane_merge.sh lane/<lane>/<rid>                              # merge
bash .claude/rotation/lane_merge.sh --returned lane/<lane>/<rid> "<reason>" [<revert commit>]   # hand back
```

The merge records `lane.merge.start`, runs `git merge --no-ff -m "merge: <tag> into <branch>" <tag>` and records `lane.merge.end`; last line `LANE MERGED <tag> commit=<sha>`. A conflict records `lane.merge.end` with status `conflict`, prints the files, leaves the merge in progress and exits 3; once it is resolved and committed by hand, record the end yourself: `event.sh lane.merge.end tag=<tag> merge.status=ok merge.commit=<sha>`. The merging lane then runs its own batch checks on the merge as usual.

`--returned` is for a merged tag the merging lane's checks reject: revert the merge there (`git revert -m 1 <merge>`), then record it: event `lane.returned` and an inbox row `| <date> | <tag> returned · <reason>[ · revert <sha>] | .claude/rotation-lanes/<lane>/handoff.md |` at the same line, for the lane's next round to pick up.

Exit: 0 · 1 no such tag or revert commit, or the merge failed · 2 usage · 3 merge conflict.

### Events

The three kinds join on `tag` (`lane/<lane>/<rid>`): one chain per closed lane round. `lane.ready` is in the closing lane's `events.jsonl`; `lane.merge.*` and `lane.returned` in the merging lane's. Besides the fields every event has (`at`, `ts`, `kind`, `rotationId` — the round in progress when it was written, so for `lane.ready` already the next round —, `head`, `lane`):

| kind | fields |
|---|---|
| `lane.ready` | `tag`; `ready.rid` (the round that closed), `ready.head` (short sha tagged), `ready.commits` (int or null), `ready.gate` (`{pass, fail, skip}` or null), `ready.mergedFrom` (the base merged in step 1), `ready.inboxLine` (int), `ready.handoff` (path relative to the root) |
| `lane.merge.start` | `tag`; `merge.branch`, `merge.baseHead` (short sha before the merge), `merge.tagHead` (short sha the tag points at) |
| `lane.merge.end` | `tag`; `merge.status` (`ok` / `conflict` / `fail`), `merge.commit` (the merge commit, null unless ok), `merge.branch`, `merge.baseHead` |
| `lane.returned` | `tag`; `returned.reason`, `returned.revert` (short sha or null) |

These fields are append-only like every other event's: never renamed or removed.

## Removing a lane

Stop its executor, merge or drop its branch, leave `.claude/rotation-lanes/<lane>/` and `.claude/rotation-state/lanes/<lane>/` in place as history (or delete them). The first lane never referenced them: with the lane gone the project is exactly the single-lane project it was. A lane can be re-opened later with the same name; its state continues where it stopped.
