# The two gates

Two independent, mechanical gates with no model judgement in either. **TRIG-1..9** governs whether a self-initiated rotation may be *triggered* at all (`trigger.sh self` → `trig_gate.sh`, before any state is written). **INV-1..5** governs whether a triggered rotation may *proceed* (the `Stop` hook → `check.sh`, at every turn end while the intent is pending).

Both print one stable line per check — `TRIG-N STATE detail` / `INV-N STATE detail` — with STATE in PASS / FAIL / SKIP / WAIVED / OBSERVE, and summarise failures on stderr (`TRIG-FAILED: TRIG-x …` / `FAILED: INV-x …`). Exit 0 all pass, 1 a FAIL, 2 configuration (a missing conf, a non-integer threshold, an unknown mode value — never reported as a gate result).

## TRIG-1..9 — may this round close?

Every threshold is a `rotation.conf` key; the environment is cleared for those keys before the file is read, so a value cannot be slipped in from a shell. The effective values are written into the row the trigger appends.

| | Question | Rule | Keys |
|---|---|---|---|
| **TRIG-1** | enough work? | **1a** first-parent commits in `<previous self prevHead>..HEAD` without an `Agent-Origin:` trailer ≥ N; **1b** shas on `closed:` that belong to that range ≥ M. The whole gate (1a and 1b) is WAIVED when TRIG-2 is at or past its cap. In observe mode 1a is computed and printed, not enforced; 1b still is | `ROTATION_TRIG1_MIN_COMMITS` (N), `ROTATION_TRIG1_MIN_CLOSED` (M, default 3), `ROTATION_TRIG1A_MODE` |
| **TRIG-2** | plausible duration? | wall ∈ [floor, cap]; **≥ cap waives TRIG-1** (the only mechanical exit for a long hard round). Which wall: `trigger` = since the previous self row (idle gap included), `active` = since the round's `rotation.start` (unknown → FAIL, not pass). Observe mode prints, does not block | `ROTATION_TRIG2_MIN_WALL_SEC`, `ROTATION_TRIG2_MAX_WALL_SEC`, `ROTATION_TRIG2_MEASURE`, `ROTATION_TRIG2_MODE` |
| **TRIG-3** | content? | the trigger section has `axis:` (from `ROTATION_AXES`), `closed:` with at least one sha inside this round's range, and `gate: N/F/S` with F = 0 | `ROTATION_AXES`, `ROTATION_TRIGGER_SECTION` |
| **TRIG-4** | wording? | the section contains none of the blacklisted phrases (case-insensitive extended regex). Kernel list: `prep work done`, `audit (complete\|already)`, `audit-only`, `substantial work`, `complexity`, `ROI`, `sub-milestone` | `ROTATION_BLACKLIST_EXTRA` (`;`-separated additions) |
| **TRIG-5** | allocation? | when the previous K rows all name this round's axis, the section must carry `axes-review:` **and** the axis reading: the reading command configured, its stamp present and ≤ D days old, its comparator current when a freshness command exists, and every token of the reading line in the review. No reading configured on a long streak = FAIL. Rows without an axis break the streak | `ROTATION_TRIG5_SAME_AXIS_MAX` (K), `ROTATION_TRIG5_BENCH_MAX_AGE_DAYS` (D), `ROTATION_AXIS_STAMP`; `ROTATION_AXIS_READING_CMD`, `ROTATION_AXIS_READING_FRESH_CMD` (project.sh) |
| **TRIG-6** | evidence? | every stamp named in `ROTATION_STAMPS`: `headSha` is a commit of this round, not `-dirty`, `verdict=ok` — or `carriedTo` equals exactly this HEAD (the planner's carry). A stamp without a verdict is red; an empty stamp list FAILs | `ROTATION_STAMPS`; `ROTATION_STAMP_DIR` (project.sh) |
| **TRIG-7** | transcription? | the `sweep:` line in the handoff contains every token of the line `ROTATION_SWEEP_LINE_CMD` re-derives from the sweep stamp now. No command, no stamp, or a sweep whose own conservation is broken = FAIL, never SKIP | `ROTATION_SWEEP_STAMP`; `ROTATION_SWEEP_LINE_CMD` |
| **TRIG-8** | coverage? | when files in the range hit any stamped check's trigger paths, the round must have a `gate.end` event (by `rotationId`, or by `gate.sha` inside the range). Same facts as the verdict's §1. `off` prints no line; `on` judges | `ROTATION_TRIG8_GATE_COVERAGE`, `ROTATION_CLOSE_RULES` |
| **TRIG-9** | verdict? | the round's close verdict (`<ROTATION_VERDICT_DIR>/<rid>.verdict.json`, `<rid>` the round being closed) is filled and its `results.red` is empty; every red line is named in the FAIL. No verdict, or one never filled, FAILs (never SKIP). `off` prints no line; `on` judges | `ROTATION_TRIG9_VERDICT_RED`; `ROTATION_VERDICT_DIR` (project.sh) |

Cold start (no previous self row): TRIG-1 and TRIG-2 SKIP, TRIG-3 and TRIG-6 look back `ROTATION_COLD_START_WINDOW` commits (default 25) as `HEAD~<window>..HEAD`. **The repository must have more commits than the window**, or that range is empty and TRIG-3 fails with "returned nothing"; a new repository sets the window to fewer than its commit count for the first round.

What each gate owns, so that none duplicates another: 1 the floor (two measures because one of them is dilutable — a commit count can be met by splitting commits; a `closed:` entry has to name a sha and say what it closed), 2 both edges and the only exit, 3 the content, 4 the wording, 5 the allocation across axes, 6 the evidence on *this* source, 7 the transcript, 8 whether the gate ran at all, 9 whether the close verdict it was handed is clean. 6, 7, 8 and 9 exist because 1–5 read only what the handoff *says*; each of "not run", "run on the previous HEAD" and "last round's number carried forward" had been invisible to every other gate.

`trigger.sh manual` is the operator's override: it skips TRIG-1..9 and refuses without an interactive terminal on stdin (exit 3). `hook` and `daemon` are reserved sources and are not gated either; a model's shell has exactly one path, `self`.

## INV-1..5 — may this triggered round proceed?

Run by the `Stop` hook while `.claude/autorun-intent` exists (the trigger wrote it). Green consumes the intent; red keeps it so the next turn end retries after the executor fixed the invariant, without re-running the trigger.

| | Invariant | Failure it stops |
|---|---|---|
| **INV-1** | the handoff's mtime age < 90 s | a handover written before the last commits: the next session starts from a stale description |
| **INV-2** | `git status --porcelain` empty | uncommitted work becomes invisible to the next session |
| **INV-3** | the `gate:` triple's first number ≥ the previous row's `conformanceBefore` | a regression introduced in this round, unnoticed |
| **INV-4** | the handoff is non-empty, has the trigger section and names at least one commit sha | a phantom handoff (zero bytes, half written, a stray `touch`) that satisfies INV-1 |
| **INV-5** | the new `rotationId` is not already in `rotations.jsonl` | an id collision corrupting every later join. Checked only when a rid is passed (`check.sh <rid>`): the Stop hook passes none, because the trigger has already appended the row, and would otherwise fail forever |

Exit codes as above. `check.sh` can be run by hand at any time as a pre-flight for the handover.

## Observe mode and calibration

TRIG-1a and TRIG-2 are the two gates whose thresholds are a project's own rhythm. A new project runs them in `observe` (computed, printed as `TRIG-n OBSERVE …`, recorded under `trig.observed` in the `trigger.result` event, not enforced) until it has `ROTATION_BOOTSTRAP_ROUNDS` self rows; `stats.sh --suggest` then proposes N and the cap. TRIG-1b and TRIG-3..8 do not depend on rhythm and always enforce. See [adoption.md](adoption.md).

Next: [close.md](close.md).
