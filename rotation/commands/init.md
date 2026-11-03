---
description: Wire the rotation kernel into this project and walk it through onboarding — kernel.path and shims, project.sh / rotation.conf / close_rules.tsv from the templates, then vision, roadmap, queue table, hot and cold queues, trigger predicates, stamps, handoff and lanes, each step checked before the next
allowed-tools: Bash(bash:*), Read, Edit, Write
---

# Wiring and onboarding

Two parts. Part 1 wires the kernel (mechanical). Part 2 walks the project through the eight things a round needs to know where it is going; each step has a check in `onboard_check.sh`, and **a step that does not PASS is not left for the next one**. The protocol runs rounds for hours without a human; what a round may work on, in which order and when a line of work is finished must already be written down in a form a script can read.

## Part 1 — wire

Run the kernel's init script from the project root and show its output verbatim:

```
bash "${CLAUDE_PLUGIN_ROOT}/bin/init.sh" $ARGUMENTS
```

If it says it is not inside a git work tree, stop and tell the user: the kernel keeps its project files under the repository's `.claude/`, which the project keeps out of git.

Read `.claude/rotation/project.sh` and `.claude/rotation/rotation.conf` as written; tell the user which files came from the templates and which were kept. Do not fill in the adapter commands or thresholds yourself: they are the project's measurements. Ask for each `ROTATION_*_CMD` the project has (gate, pre-flight, close segment, bench, sweep line), or confirm the paths the template proposes, and edit `project.sh` to match. Keep `rotation.conf` in observe mode unless the user has data for the thresholds.

With `$ARGUMENTS` = `--lane <name> [--from <lane>]` the same applies to that lane's directory (`.claude/rotation-lanes/<name>/`); go to step 8 afterwards.

## Part 2 — onboard

Run the checker after every step and show the step's line:

```
bash .claude/rotation/onboard_check.sh            # a lane: bash .claude/rotation/onboard_check.sh --lane <name>
```

It prints `PASS|WARN|FAIL step.<n> <detail>` for all eight steps and ends with `ONBOARD PASS` or `ONBOARD FAIL`. Work top down: the first step that is not PASS (or, for step 6, WARN) is the one to do now. Write the files **with the user**: ask, propose a draft, let them correct it. Never invent a project's direction, versions or acceptance commands. The examples below are for a made-up project — a firmware controller for an electric kettle — to show the shape only.

The file paths are the defaults; a project that keeps them elsewhere sets `ROTATION_VISION_FILE`, `ROTATION_PLAN_FILE` and `ROTATION_LANES_DOC` in `rotation.conf` (relative to the root allowed).

### Step 1 — vision (`.claude/vision.md`)

- **Do**: one page on where the project is going. Two sections at least: positioning (what it is, for whom, what it is better at than the alternatives) and non-goals (what it will not do, even when asked).
- **Why**: every later choice — what goes in the queue, what a round may refuse — is checked against this page. Non-goals are what stops a long unattended run from drifting into neighbouring work.
- **Check**: the file exists; a heading containing `定位` or `Positioning`, and one containing `非目标` or `Non-goals`.
- **Example**:
  ```
  # kettle — direction
  ## Positioning
  Firmware for the K-1 kettle that holds a set temperature within one degree, on the existing board.
  ## Non-goals
  No phone app, no cloud, no second kettle model before v1.0.
  ```

### Step 2 — roadmap L1 and version boundary L2 (`.claude/plan-state.md`)

- **Do**: in the plan file, an L1 section (the roadmap: the versions in order, one line each) and an L2 section (the scope of the next version: what is in, what is explicitly out).
- **Why**: a round needs to know which version its work serves; "out of this version" is how it declines work without asking.
- **Check**: below the document title, a heading opening with `L1`, `Roadmap` or `路线图`, and one opening with `L2`, `Version scope` or `版本 scope / 边界 / 范围`.
- **Example**: `## L1 roadmap` — "v1 holds temperature; v2 adds schedules" · `## L2 version scope` — "v1.0: heating loop, boil-dry cutoff, button UI. Out: schedules, Wi-Fi."

### Step 3 — the queue table

- **Do**: one machine-readable table of every item of work, one row each, with the header `| 通道 | id | 状态 | 一句话 | 出处 | 登记 | 验收 | blocked_by | done |` (or `| lane | id | status | summary | source | registered | acceptance | blocked_by | done |`, or the project's own nine names in `ROTATION_QUEUE_HEADER`). `id` is `<prefix>-<name>`, the prefix naming the line of work. State is one of `ROTATION_QUEUE_STATES` (default 在做 / 排队 / 已完成 / 等决定 / 撤回, or active / queued / done / decision / withdrawn); "waiting for X" goes into `blocked_by`, not the state. `acceptance` is the command or observable fact that says the item is done. `done` is the commit that finished it.
- **Why**: the executor's prompt, the handoff's next items and the dashboard all name items by id; an item without an acceptance can never be closed by evidence, only by opinion.
- **Check**: the header is found; every row has nine cells (`\|` inside a cell is fine), an id `<prefix>-<name>`, a listed state, a non-empty acceptance (`—` counts as empty).
- **Example**:
  ```
  | lane | id | status | summary | source | registered | acceptance | blocked_by | done |
  |---|---|---|---|---|---|---|---|---|
  | control | CT-pid | active | PID loop on the heater | plan "heating loop" | r1 | `make test-pid` exits 0 | — | — |
  | control | CT-dry | queued | boil-dry cutoff | plan "boil-dry cutoff" | r1 | the dry-run rig trips in under 2 s | CT-pid | — |
  ```

### Step 4 — hot queue L3a and cold queue L3b

- **Do**: an L3a section (what the next rounds do, in order; the queue table usually lives here) and an L3b section (known work not scheduled yet, and things to watch).
- **Why**: a round takes the top of L3a without asking; L3b is where new findings go so they are not lost and do not jump the queue.
- **Check**: headings opening with `L3a` / `Hot queue` / `热队列` and `L3b` / `Cold queue` / `冷队列`.

### Step 5 — L4 trigger predicates

- **Do**: an L4 section listing what moves work between layers: "X moves to L3a when Y is done", "v1.0 is cut when every L2 item is done and <fact>". Hand-written facts that are true or false.
- **Why**: a percentage threshold ("when coverage reaches 80%") invites lowering the threshold or arguing about rounding; a fact does not. The pass rate stays a diagnostic.
- **Check**: the section exists below the title, is not empty, and has no `<digits>%` anywhere in it.
- **Example**: "CT-dry moves to L3a when CT-pid is done" · "v1.0 is cut when the rig log of a full boil shows no overshoot above one degree".

### Step 6 — the checks and their stamps

- **Do**: decide which checks prove a round's work (tests, a sweep, a benchmark) and name their stamps in `ROTATION_STAMPS`; write `close_rules.tsv` with one row per check (the template's header comment explains the columns). The adapter commands write `<stamp>-latest.json` into `ROTATION_STAMP_DIR`.
- **Why**: the trigger gate only releases a round whose stamps are fresh at its HEAD; a rules row naming a stamp the gate does not require is a check nobody enforces.
- **Check**: `ROTATION_STAMPS` not empty; every rules row's stamp is in `ROTATION_STAMPS` (or is `ROTATION_AXIS_STAMP`); a missing `<stamp>-latest.json` is a WARN until the first round has run the checks.

### Step 7 — the handoff template

- **Do**: write `.claude/handoff.md` (a lane: `.claude/rotation-lanes/<lane>/handoff.md`) with the trigger section the gates read: a `## rotate-trigger` heading (or the heading `ROTATION_TRIGGER_SECTION` names, e.g. `rotate 触发`) and the three lines.
- **Why**: TRIG-3 reads `axis:`, `closed:` and `gate:` from exactly this section; a handoff without it blocks every close.
- **Check**: the section is found with `axis:`, `closed:` and `gate:` lines.
- **Example**:
  ```
  ## rotate-trigger

  axis: A
  closed: 1a2b3c4 CT-pid loop; 5d6e7f8 rig test; 9a0b1c2 tuning table
  gate: 41/0/2
  ```

### Step 8 — lanes (only when the project runs more than one)

- **Do**: when `.claude/rotation-lanes/` exists (or for `--lane`), one section per lane — headed by the lane's name — saying its **work line** (what it works on), its **independence** (why its commits do not collide with the other lanes': the directories or crates it owns), its **verification machine** (where its gate runs) and its **merge protocol** (who merges its tags, when, what happens on a regression). The first lane needs a section too once `ROTATION_LANE_NAME` names it. A lane that is like an existing one is wired with `init.sh --lane <name> --from <lane>`; the docs are `docs/lanes.md`.
- **Why**: two executors on one repository are safe only while their work does not overlap and their results meet in one known place.
- **Check**: `ROTATION_LANES_DOC` (default: the plan file) has, for every lane, a heading containing its name whose section mentions 工作线 / work line, 独立 / independence, 验证 / verification and 汇合 / 合入 / merge.
- **Example**:
  ```
  ### Lane control
  Work line: heater loop and safety cutoffs. Independence: commits only under firmware/control/.
  Verification: the bench rig host. Merge: its tags are merged by the ui lane at the start of a batch.
  ```

## Finish

`bash .claude/rotation/onboard_check.sh` ends with `ONBOARD PASS`, then `bash .claude/rotation/doctor.sh` ends with `DOCTOR PASS kernel=… conf=…` (its `plan.*` rows re-check steps 3, 5 and 7 before every round). Show both last lines. Every `FAIL` names what to fix.
