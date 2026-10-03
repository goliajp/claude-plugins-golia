# Adopting the protocol, calibrating it, measuring it

```
install → /rotation:init → edit project.sh + rotation.conf + close_rules.tsv → write the adapter commands
→ doctor.sh PASS → run rounds in observe mode → stats.sh --suggest → write N and the cap → enforce
```

## 1 Install and wire

```
claude plugin marketplace add <the marketplace this plugin is published in>
claude plugin install rotation@<marketplace>
```

In a session whose working directory is inside the project's repository, run `/rotation:init` (or, outside Claude, `CLAUDE_PLUGIN_ROOT=<plugin dir> bash <plugin dir>/bin/init.sh` from inside the repository). It writes under the repository's `.claude/`: `rotation/kernel.path`, a shim per kernel entry point, `rotation/project.sh`, `rotation/rotation.conf` and `rotation/close_rules.tsv` from the templates (only when absent), and the state directory `rotation-state/`. `init.sh --force` rewrites the shims and `kernel.path` and never the three project files. Everything written is under `.claude/`, which the project keeps out of version control.

## 2 Configure

1. **`rotation.conf`** — set `ROTATION_AXES` to the project's directions of work, `ROTATION_STAMPS` / `ROTATION_SWEEP_STAMP` to the checks that exist, `ROTATION_CLOSE_RULES` to the table. Leave `ROTATION_TRIG1A_MODE` / `ROTATION_TRIG2_MODE=observe` and the template's thresholds: they are placeholders until the project has its own rows ([§4](#4-calibrate)).
2. **`close_rules.tsv`** — one row per check the close may run, with the paths that trigger it. Start wide (the whole source tree triggers the sweep) and narrow from stamp history.
3. **`project.sh`** — the stamp and verdict directories, the sweep line command, the four adapter commands, and the optional remote and after-write hooks. The template proposes `.dev/rotation/…` paths; any location the project keeps out of version control works.
4. **Write the commands** to the contract in [configuration.md](configuration.md#the-adapter-command-contract). A project that already has a gate script wraps it: record `remote.start`, run it, print the `N pass / F fail / S skip` line, record `gate.end` and `remote.end`. A job that runs on a runner is started with `.claude/rotation/remote_run.sh <host> <command> <fields…>`, which records the `remote.start` itself, with the pid the job runs under there.

### A minimal local adapter

A complete, runnable adapter for a project with no remote runner — the shape the kernel's own end-to-end test uses. Each script sits where `project.sh` points (`$PROJECT_DIR/.dev/rotation/bin/` in the template), is executable, and uses the shim `.claude/rotation/event.sh` to write events. The kernel passes the commands nothing but their arguments and the exported `ROTATION_*` variables (`ROTATION_STAMP_DIR` among them); each script finds the rest itself:

```bash
R=$(git rev-parse --show-toplevel); EV="$R/.claude/rotation/event.sh"
```

```bash
# sweep_line.sh — the sweep stamp as one line; exit 2 without a stamp
f="${ROTATION_SWEEP_JSON:-}"; [ -f "$f" ] || exit 2
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("sweep: head=%s pass=%s passTotal=%s" % (d["headSha"], d["pass"], d["passTotal"]))' "$f"
```

```bash
# gate.sh <sha> — run the test suite, put the result on record
case "${1:-}" in *[!0-9a-f]*|'') echo "usage: gate.sh <sha>" >&2; exit 2;; esac     # --doctor-probe lands here
sha=$1; log="$R/.tmp/gate-$sha.log"; mkdir -p "$(dirname "$log")"
"$EV" remote.start remote.kind=gate "remote.sha=$sha" "remote.log=$log" 'remote.marker=[0-9]+ pass / [0-9]+ fail / [0-9]+ skip' >/dev/null
<run the suite>; pass=…; fail=…; skip=…                                              # the project's own
echo "$pass pass / $fail fail / $skip skip" | tee "$log"
"$EV" gate.end "gate=raw:{\"sha\":\"$sha\",\"pass\":$pass,\"fail\":$fail,\"skip\":$skip,\"log\":\"$log\",\"host\":null}" >/dev/null
"$EV" remote.end remote.kind=gate "remote.sha=$sha" "remote.log=$log" "remote.status=$([ "$fail" -eq 0 ] && echo ok || echo fail)" >/dev/null
[ "$fail" -eq 0 ]
```

```bash
# preflight.sh [-q] — build and unit-test, put the result on record
quick=false; case "${1:-}" in '') ;; -q) quick=true;; *) echo "usage: preflight.sh [-q]" >&2; exit 2;; esac
head=$(git -C "$R" rev-parse HEAD); sha=null; [ -z "$(git -C "$R" status --porcelain)" ] && sha="\"$head\""
if <build and test>; then result=pass; else result=fail; fi
"$EV" preflight.end "preflight.result=$result" "preflight.quick=raw:$quick" "preflight.parent=$head" "preflight.sha=raw:$sha" 'preflight.files=raw:[]' 'preflight.reasons=raw:[]' >/dev/null
[ "$result" = pass ] && echo "PREFLIGHT PASS" || { echo "PREFLIGHT FAIL: <why>"; exit 1; }
```

```bash
# close_segment.sh <head> <segment|plan> [verdict.json] — run the checks the plan says to run, stamp them at <head>
[ "$#" -ge 2 ] && case "$1" in *[!0-9a-f]*) false;; *) true;; esac || { echo "usage: close_segment.sh <head> <segment|plan> [verdict.json]" >&2; exit 2; }
head=$1; seg=$2; verdict=${3:-}; log="$R/.tmp/rc-seg-$head-$seg.log"; mkdir -p "$(dirname "$log")"
"$EV" remote.start "remote.kind=close.$seg" "remote.sha=$head" "remote.log=$log" "remote.marker=^DONE segment=$seg head=$head " >/dev/null
# prerequisite rows (stamp `-`, e.g. a build) are in the run list too, with stampFile null: run them, stamp nothing
for check in $(python3 -c 'import json,sys; [print(c["name"]) for c in json.load(open(sys.argv[1]))["checks"] if c["decision"]=="run" and c["stampFile"]]' "$verdict"); do
  <run the check>                                                                     # writes $ROTATION_STAMP_DIR/<check>-latest.json:
  # {"tool":"<check>","ranAt":"<iso>","headSha":"<head>","headShaSource":"arg","verdict":"ok", ...readings}
  cat "$ROTATION_STAMP_DIR/$check-latest.json" >> "$ROTATION_STAMP_DIR/stamps.jsonl"
done
echo "DONE segment=$seg head=$head rc=0" | tee "$log"
"$EV" remote.end "remote.kind=close.$seg" "remote.sha=$head" "remote.log=$log" remote.status=ok remote.rc=int:0 >/dev/null
```

```bash
# bench.sh <sha> [segment] — one segment on record, the axis stamp at the end
case "${1:-}" in *[!0-9a-f]*|'') echo "usage: bench.sh <sha> [segment]" >&2; exit 2;; esac
sha=$1; seg=${2:-A}; log="$R/.tmp/bench-$sha-$seg.log"; mkdir -p "$(dirname "$log")"
"$EV" remote.start "remote.kind=bench.$seg" "remote.sha=$sha" "remote.log=$log" 'remote.marker=^BENCH-DONE' >/dev/null
<run the bench; write $ROTATION_STAMP_DIR/bench-latest.json with the five keys and the readings>
echo "BENCH-DONE rc=0" | tee "$log"
"$EV" remote.end "remote.kind=bench.$seg" "remote.sha=$sha" "remote.log=$log" remote.status=ok remote.rc=int:0 >/dev/null
```

A project without a bench still registers `ROTATION_BENCH_CMD` (the variable is required): a script that records its pair of events and writes no stamp is enough, and TRIG-5 then needs no axis reading until an axis runs `ROTATION_TRIG5_SAME_AXIS_MAX` rounds in a row.

### Trying a round by hand

A dry round — register an executor with `ROTATION_AGENT_ID=<any id> agent_log.sh start <name> rotation <model>`, pre-flight, gate, plan, segment, fill, handoff, `agent_log.sh end`, `trigger.sh self` — is the fastest way to see the contract working. Three things catch a first attempt:

- **The trigger's reaper ends only the pids the round registered** (`event.sh process.start process.pid=int:$$ …`, [recovery.md](recovery.md#the-reaper)); a trial `trigger.sh self` in a shared session, with its own throwaway events log (`HARDEV_EVENTS_LOG=<copy>`), therefore touches nothing of the other agents. Still, inside a Claude Code session that is doing other work (a managed session, a session with subagents), prefer to stop the trial **before** `trigger.sh self` — doctor, the adapter commands, the plan and the fill are safe to run anywhere — and let the plugin's own end-to-end test stand in for the trigger step: `bash <plugin dir>/tests/e2e_self_test.sh` runs the whole round, trigger included, against a kernel copy whose reaper is stubbed. In session mode the trigger also ends the round's open runner jobs by their registered `remote.pid`; a trial with its own events log has none.
- The first round has no row: `close_plan.sh <prev> <HEAD> --rid <id>` with an id of your choosing, and `ROTATION_COLD_START_WINDOW` smaller than the repository's commit count ([gates.md](gates.md), cold start).
- Cold start leaves TRIG-1 / TRIG-2 at SKIP and `commitsInSession` at `null`; the second round is the first fully judged one.

## 3 Doctor

```
bash .claude/rotation/doctor.sh
```

One line per check, `PASS|FAIL|WARN <item> <detail>`; last line `DOCTOR PASS kernel=<x.y.z> conf=<sha256 prefix>` or `DOCTOR FAIL n=<count>`. It validates the conf and `project.sh`, checks every `*_CMD` is executable, probes the four heavy commands with `--doctor-probe` (exit 2, nothing done), runs the two read-only commands for shape, checks the state / stamp / verdict directories are writable and the rules table parses and is not empty, that at most one executor is running, and that the repository and base branch exist. Fix every FAIL; read every WARN (a missing sweep stamp is a WARN until the first close writes one). Run it again after every plugin update: a changed major means the conf needs a change, a changed minor lists the keys added since.

## 4 Calibrate

**Do not copy another project's thresholds.** The commit floor and the wall cap measure a project's own rhythm, and a commit means a different amount of work in every repository. The protocol ships with those two gates in observe mode:

1. Run `ROTATION_BOOTSTRAP_ROUNDS` (default 20) rounds with `ROTATION_TRIG1A_MODE=observe` and `ROTATION_TRIG2_MODE=observe`. Every other gate enforces from the first round; TRIG-1a and TRIG-2 print `OBSERVE` lines and are recorded in `trigger.result` events.
2. `bash .claude/rotation/stats.sh --suggest` — once enough self rows exist it prints p10 / p50 / p90 of commits per round and of the active wall, and proposes **N = ⌊commits p50 × 0.8⌋** and **cap = active wall p90**. Until then it says how many rounds are missing. It prints; writing is the operator's edit.
3. Write N into `ROTATION_TRIG1_MIN_COMMITS`, the cap into `ROTATION_TRIG2_MAX_WALL_SEC`, consider `ROTATION_TRIG2_MEASURE=active` (the trigger-to-trigger wall includes the idle gap between a handover and the next executor starting; in manager mode that gap is minutes, in session mode it was found to be a third of the wall), and switch both modes to `enforce`. The change is a new `confSha256` in the rows that follow.
4. Every 30 rounds or so, `--suggest` again; a drift in p50 is a reason to re-read the numbers, not to loosen a gate.

What the two quantities mean: the wall cap is the only mechanical exit from the commit floor, so it has to sit where a round is long enough that drift outweighs amortising the fixed close cost — p90 of what the project actually does, not a round number. The floor exists because every round pays a fixed cost (the close checks, the handoff, rebuilding context on the far side); 0.8 × p50 leaves the floor below most rounds while still refusing a round that closes after a handful of commits. The `closed:` count (TRIG-1b) is the gate that cannot be met by splitting commits, and it does not need calibrating.

## 5 Measure

```
bash .claude/rotation/stats.sh                 # baseline: self→self interval, commits per round, pass rates of the current thresholds
bash .claude/rotation/stats.sh --effect [--json]
```

`--effect` answers whether rotating is doing anything, per round and summarised:

| measure | definition | `null` when |
|---|---|---|
| throughput | first-parent commits without the trailer in the round's range ÷ `activeWallSec` in hours | the closing row has no `activeWallSec` |
| regressions | red items of the round's verdict + the sweep check's lost passes | the round has no filled verdict |
| gap | seconds from the trigger that opened the round to its first `rotation.start` | the round recorded no start |
| restarts | executor registrations in the round − 1 (every registration after the first is a respawn); `manager.resume` counts are listed beside it as resumes | no executor was registered |

A rising gap means the manager is slow to start the next executor; rising restarts mean executors are being lost; regressions per round are the number the gates exist to hold at zero. All four come from the same append-only files the gates read, so they can be recomputed at any time.

## 6 Update, uninstall

```
claude plugin marketplace update <marketplace>
claude plugin update rotation
bash .claude/rotation/doctor.sh
```

`kernel.path` is rewritten by the SessionStart hook, so the shims follow the new install without an edit. `claude plugin uninstall rotation` leaves `.claude/rotation/` and `.claude/rotation-state/` in the project; remove them by hand when the project leaves the protocol.

Appendix: [history.md](history.md) — how the first adopter arrived at its thresholds, and the incidents behind each gate.
