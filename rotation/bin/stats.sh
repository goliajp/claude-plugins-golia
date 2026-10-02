#!/usr/bin/env bash
#
# rotation kernel — the rotation log, read back as numbers.
#
# Three reports, all pure reads (no state is written):
#
#   (default)   the statistical baseline: self→self interval (session wall
#               time), commits per session, a recent-N tail, and how often
#               history would have passed the current TRIG-1 / TRIG-2
#               thresholds. Used by "measure before mechanism".
#
#   --effect    whether rotating is doing anything, per round:
#                 throughput    first-parent commits without an Agent-Origin
#                               trailer in the round's range, per active hour
#                               (activeWallSec of the row that closed the
#                               round); null when the row predates that field
#                 regressions   red items of the round's verdict + the sweep
#                               check's lost passes (−Δpass when negative);
#                               null when the round has no filled verdict
#                 gap           seconds from the trigger that opened the round
#                               to the round's first rotation.start event;
#                               null when the round recorded no start
#                 restarts      executor registrations (agent.start with
#                               agent.role=rotation) in the round minus one —
#                               every registration after the first is a
#                               respawn; manager.resume events of those
#                               executors are listed beside it as `resumes`
#                               (a resume continues, it does not restart);
#                               null when the round registered no executor
#               plus the summary over all rounds. `--json` for the dashboard.
#
#   --suggest   thresholds from this project's own rows, once it has
#               ROTATION_BOOTSTRAP_ROUNDS self rows: p10 / p50 / p90 of
#               commits per round and of the active wall, and the proposal
#               N = ⌊commits p50 × 0.8⌋, cap = active wall p90. Prints only;
#               writing them into rotation.conf is the operator's commit.
#
# Commits are counted the way TRIG-1 counts them (lib.sh
# autorun_main_session_revs: first-parent line, Agent-Origin excluded).
#
# Usage:
#   stats.sh [--tail N] [--project NAME]
#   stats.sh --effect [--tail N] [--json]
#   stats.sh --suggest
#
# Zero deps beyond python3 + git.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

PROJECT="${HARDEV_AUTORUN_PROJECT:-$(autorun_project_name)}"
TAIL_N="10"
MODE=baseline
JSON=0

while [ $# -gt 0 ]; do
  case "$1" in
    --tail) TAIL_N="${2:?--tail needs N}"; shift 2 ;;
    --project) PROJECT="${2:?--project needs name}"; shift 2 ;;
    --effect) MODE=effect; shift ;;
    --suggest) MODE=suggest; shift ;;
    --json) JSON=1; shift ;;
    *) echo "stats.sh: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

if [ ! -f "$ROTATIONS_LOG" ]; then
  echo "stats.sh: $ROTATIONS_LOG not found" >&2
  exit 2
fi

export STATS_LOG="$ROTATIONS_LOG" STATS_EVENTS="$EVENTS_LOG" STATS_REPO="$PROJECT_DIR" STATS_PROJECT="$PROJECT"
export STATS_TAIL="$TAIL_N" STATS_MODE="$MODE" STATS_JSON="$JSON" STATS_ORIGIN="$AGENT_ORIGIN_PATTERN"
export STATS_CONF_N="${ROTATION_TRIG1_MIN_COMMITS:-}" STATS_CONF_M="${ROTATION_TRIG2_MIN_WALL_SEC:-}" STATS_CONF_CAP="${ROTATION_TRIG2_MAX_WALL_SEC:-}"
export STATS_BOOTSTRAP="${ROTATION_BOOTSTRAP_ROUNDS:-20}" STATS_VERDICT_DIR="${ROTATION_VERDICT_DIR:-}" STATS_SWEEP_STAMP="${ROTATION_SWEEP_STAMP:-}"

python3 - <<'PY'
import json, os, subprocess, sys

E = os.environ
log, events_log, repo, project = E["STATS_LOG"], E["STATS_EVENTS"], E["STATS_REPO"], E["STATS_PROJECT"]
tail_n, mode, as_json, origin = int(E["STATS_TAIL"]), E["STATS_MODE"], E["STATS_JSON"] == "1", E["STATS_ORIGIN"]
verdict_dir, sweep_stamp = E["STATS_VERDICT_DIR"], E["STATS_SWEEP_STAMP"]
bootstrap = int(E["STATS_BOOTSTRAP"]) if E["STATS_BOOTSTRAP"].isdigit() else 20


def read_jsonl(path):
    out = []
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        out.append(json.loads(line))
                    except ValueError:
                        pass
    except OSError:
        pass
    return out


rows = [r for r in read_jsonl(log) if r.get("project") == project]
rows.sort(key=lambda r: r["ts"])
self_rows = [r for r in rows if r["trigger"] == "self"]
manual_rows = [r for r in rows if r["trigger"] == "manual"]


def commit_count(prev_head, this_head):
    """commits the way TRIG-1 counts them: first-parent line, Agent-Origin excluded; None when git cannot answer"""
    if not prev_head or not this_head or prev_head == this_head:
        return 0
    r = subprocess.run(["git", "-C", repo, "rev-list", "--first-parent", "--invert-grep", "-E", f"--grep={origin}",
                        f"{prev_head}..{this_head}"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    if r.returncode != 0:
        return None
    return sum(1 for l in r.stdout.split("\n") if l)


def stats(xs):
    if not xs:
        return None
    s = sorted(xs)
    n = len(s)
    pick = lambda q: s[min(int(n * q), n - 1)]
    return {"n": n, "min": s[0], "p10": pick(0.10), "p25": pick(0.25), "p50": pick(0.50),
            "p75": pick(0.75), "p90": pick(0.90), "max": s[-1]}


def fmt_min(s):
    return f"{s / 60:.1f} min"


# ── the rounds: each self row opens one; the next self row closes it ─────
# The closing row carries the round's measures (activeWallSec, commitsInSession);
# the round's events carry its id.
def rounds():
    events = read_jsonl(events_log)
    by_rid = {}
    for e in events:
        by_rid.setdefault(e.get("rotationId"), []).append(e)
    out = []
    for i, row in enumerate(self_rows):
        nxt = self_rows[i + 1] if i + 1 < len(self_rows) else None
        rid = row.get("rotationId")
        ev = sorted(by_rid.get(rid, []), key=lambda e: e.get("ts") or 0)
        starts = [e["ts"] for e in ev if e.get("kind") == "rotation.start" and isinstance(e.get("ts"), int)]
        execs = [e for e in ev if e.get("kind") == "agent.start" and (e.get("agent") or {}).get("role") == "rotation"]
        exec_ids = {(e.get("agent") or {}).get("id") for e in execs} - {None}
        resumes = sum(1 for e in ev if e.get("kind") == "manager.resume"
                      and ((e.get("manager") or {}).get("agent") or {}).get("id") in exec_ids)
        rd = {"rid": rid, "at": row.get("at"), "ts": row["ts"], "prevHead": row.get("prevHead"), "axis": row.get("axis"),
              "open": nxt is None, "commits": None, "activeWallSec": None, "wallSec": None, "throughputPerHour": None,
              "gapSec": (min(starts) - row["ts"]) if starts else None,
              "executorStarts": len(execs), "restarts": (len(execs) - 1) if execs else None, "resumes": resumes,
              "verdict": None, "red": None, "sweepPassLost": None, "regressions": None}
        if nxt is not None:
            rd["commits"] = commit_count(row.get("prevHead"), nxt.get("prevHead"))
            rd["wallSec"] = nxt["ts"] - row["ts"]
            aw = nxt.get("activeWallSec")
            rd["activeWallSec"] = aw if isinstance(aw, int) else None
            if rd["commits"] is not None and isinstance(aw, int) and aw > 0:
                rd["throughputPerHour"] = round(rd["commits"] / (aw / 3600), 2)
        if verdict_dir and rid:
            path = os.path.join(verdict_dir, f"{rid}.verdict.json")
            try:
                with open(path) as f:
                    v = json.load(f)
            except (OSError, ValueError):
                v = None
            if v and (v.get("results") or {}).get("filledAt"):
                rd["verdict"] = path
                rd["red"] = len(v["results"].get("red") or [])
                lost = None
                for c in v.get("checks") or []:
                    if sweep_stamp and (c.get("stampFile") == f"{sweep_stamp}-latest.json" or c.get("name") == sweep_stamp):
                        for x in ((c.get("result") or {}).get("readings") or []):
                            if x.get("key") == "pass":
                                d = x.get("delta")
                                lost = -int(d) if isinstance(d, (int, float)) and d < 0 else 0
                rd["sweepPassLost"] = lost
                rd["regressions"] = rd["red"] + (lost or 0)
        out.append(rd)
    return out


def q(v, suffix=""):
    return "null" if v is None else f"{v}{suffix}"


def effect():
    rs = rounds()
    closed = [r for r in rs if not r["open"]]
    thr = [r["throughputPerHour"] for r in closed if r["throughputPerHour"] is not None]
    gaps = [r["gapSec"] for r in rs if r["gapSec"] is not None]
    reg = [r for r in rs if r["regressions"] is not None]
    rst = [r for r in rs if r["restarts"] is not None]
    summary = {
        "rounds": len(rs), "closed": len(closed),
        "throughput": {"n": len(thr), "p50": stats(thr)["p50"] if thr else None, "p90": stats(thr)["p90"] if thr else None,
                       "noActiveWall": sum(1 for r in closed if r["activeWallSec"] is None)},
        "regressions": {"n": len(reg), "total": sum(r["regressions"] for r in reg),
                        "perRound": round(sum(r["regressions"] for r in reg) / len(reg), 3) if reg else None,
                        "noVerdict": len(rs) - len(reg)},
        "gap": {"n": len(gaps), "p50": stats(gaps)["p50"] if gaps else None, "p90": stats(gaps)["p90"] if gaps else None,
                "noStart": len(rs) - len(gaps)},
        "restarts": {"n": len(rst), "total": sum(r["restarts"] for r in rst), "roundsWithRestart": sum(1 for r in rst if r["restarts"] > 0),
                     "resumes": sum(r["resumes"] for r in rs), "noExecutor": len(rs) - len(rst)},
    }
    if as_json:
        print(json.dumps({"project": project, "summary": summary, "rounds": rs}, ensure_ascii=False, indent=1))
        return
    print(f"# rotation effect · project={project}")
    print()
    print(f"- rounds: {summary['rounds']} (closed {summary['closed']}, open {summary['rounds'] - summary['closed']})")
    t = summary["throughput"]
    print(f"- throughput (commits / active hour): n={t['n']} p50={q(t['p50'])} p90={q(t['p90'])}"
          f" — {t['noActiveWall']} closed round(s) have no activeWallSec (rows before 2026-10-02 did not record it): null")
    g = summary["regressions"]
    print(f"- regressions (verdict red + sweep passes lost) per round: {q(g['perRound'])} over n={g['n']} (total {g['total']})"
          f" — {g['noVerdict']} round(s) without a filled verdict: null")
    p = summary["gap"]
    print(f"- gap (trigger → rotation.start): n={p['n']} p50={q(p['p50'], 's')} p90={q(p['p90'], 's')}"
          f" — {p['noStart']} round(s) without a rotation.start: null")
    r = summary["restarts"]
    print(f"- restarts (executor agent.start role=rotation − 1): total {r['total']} in {r['roundsWithRestart']} of n={r['n']} round(s);"
          f" resumes (manager.resume of those executors) {r['resumes']} — {r['noExecutor']} round(s) without an executor registration: null")
    print()
    print(f"## recent {tail_n} rounds")
    print()
    print("| rid | at | commits | active | commits/h | regressions (red+pass lost) | gap | restarts | resumes |")
    print("|---|---|---|---|---|---|---|---|---|")
    for rd in rs[-tail_n:]:
        active = "null" if rd["activeWallSec"] is None else fmt_min(rd["activeWallSec"])
        regs = "null" if rd["regressions"] is None else f"{rd['regressions']} ({rd['red']}+{q(rd['sweepPassLost'])})"
        print(f"| {rd['rid']}{' (open)' if rd['open'] else ''} | {rd['at']} | {q(rd['commits'])} | {active} | {q(rd['throughputPerHour'])}"
              f" | {regs} | {q(rd['gapSec'], 's')} | {q(rd['restarts'])} | {rd['resumes']} |")


def suggest():
    rs = [r for r in rounds() if not r["open"]]
    commits = [r["commits"] for r in rs if r["commits"] is not None]
    active = [r["activeWallSec"] for r in rs if r["activeWallSec"] is not None]
    n_self = len(self_rows)
    conf_n, conf_cap = E["STATS_CONF_N"], E["STATS_CONF_CAP"]
    print(f"# threshold suggestion · project={project}")
    print()
    print(f"- self rows: {n_self} (bootstrap needs {bootstrap}); closed rounds: {len(rs)}; with activeWallSec: {len(active)}")
    print(f"- current conf: N={conf_n or 'unset'} cap={conf_cap or 'unset'}s" + (f" ({int(conf_cap) // 60} min)" if conf_cap.isdigit() else ""))
    if n_self < bootstrap:
        print(f"- not enough rows yet: {bootstrap - n_self} more self rotation(s) before a suggestion")
        return
    c = stats(commits)
    print()
    print("## commits per round (first-parent, Agent-Origin excluded)")
    if c:
        print(f"- n={c['n']} · p10={c['p10']} · p50={c['p50']} · p90={c['p90']}")
        print(f"- suggested N = ⌊p50 × 0.8⌋ = {int(c['p50'] * 0.8)}")
    else:
        print("- no closed round has a countable range")
    print()
    print("## active wall per round (activeWallSec of the closing row)")
    a = stats(active)
    if a:
        print(f"- n={a['n']} · p10={a['p10']}s ({fmt_min(a['p10'])}) · p50={a['p50']}s ({fmt_min(a['p50'])}) · p90={a['p90']}s ({fmt_min(a['p90'])})")
    if len(active) >= bootstrap:
        print(f"- suggested cap = p90 = {a['p90']}s ({fmt_min(a['p90'])})")
    else:
        print(f"- cap: not yet — {len(active)} of {bootstrap} rounds carry activeWallSec; {bootstrap - len(active)} more needed")
    print()
    print("(printed only; put the values into rotation.conf yourself — the change shows up as a new confSha256 in the rows that follow)")


def baseline():
    intervals = []  # (sec, commits, curr_row)
    for prev, curr in zip(self_rows[:-1], self_rows[1:]):
        sec = curr["ts"] - prev["ts"]
        if sec <= 0:
            continue
        c = commit_count(prev["prevHead"], curr["prevHead"])
        intervals.append((sec, c, curr))
    durations = [d for d, _, _ in intervals]
    commits = [c for _, c, _ in intervals if c is not None]

    print(f"# autorun rotation baseline · project={project}")
    print()
    print(f"- total rotations: {len(rows)} (self={len(self_rows)}, manual={len(manual_rows)})")
    if rows:
        print(f"- range: {rows[0]['at']} → {rows[-1]['at']}")
    print(f"- self→self interval samples: {len(durations)}")
    print()

    print("## self→self session wall time")
    d = stats(durations)
    if d:
        print(f"- n={d['n']}")
        for k in ("min", "p25", "p50", "p75", "p90", "max"):
            print(f"- {k:<4} {d[k]:>6} s ({fmt_min(d[k])})")
    print()

    print("## commits per self→self session (rev-list count)")
    c = stats(commits)
    if c:
        print(f"- n={c['n']}")
        print(f"- min={c['min']} · p25={c['p25']} · p50={c['p50']} · p75={c['p75']} · p90={c['p90']} · max={c['max']}")
    print()

    print(f"## recent {tail_n} self→self sessions (tail)")
    print()
    print("| # | sec | min | commits | prevHead |")
    print("|---|-----|-----|---------|----------|")
    recent = intervals[-tail_n:]
    base_idx = len(intervals) - len(recent)
    for i, (sec, cn, row) in enumerate(recent):
        cn_s = str(cn) if cn is not None else "-"
        print(f"| {base_idx + i + 1} | {sec} | {sec/60:.1f} | {cn_s} | {row['prevHead'][:10]} |")
    print()

    print("## TRIG threshold (from rotation.conf; kernel defaults 12 / 1800 when unset)")
    print()
    conf_n, conf_m = E["STATS_CONF_N"], E["STATS_CONF_M"]
    N = int(conf_n) if conf_n.isdigit() else 12
    M = int(conf_m) if conf_m.isdigit() else 1800
    print(f"- TRIG-1 N (commit count): {N}")
    print(f"- TRIG-2 M (wall seconds): {M} ({M/60:.0f} min)")
    print()

    if commits and durations:
        p_pass_n = sum(1 for x in commits if x >= N) / len(commits) * 100
        p_pass_m = sum(1 for x in durations if x >= M) / len(durations) * 100
        p_pass_both = sum(1 for d, c, _ in intervals if (c is not None and c >= N) and d >= M) / len(intervals) * 100
        print(f"- % historical self rotations passing TRIG-1 (≥{N} commits): {p_pass_n:.1f}%")
        print(f"- % historical self rotations passing TRIG-2 (≥{M}s): {p_pass_m:.1f}%")
        print(f"- % historical self rotations passing BOTH: {p_pass_both:.1f}%")
    print()

    if len(intervals) >= 30:
        recent30 = intervals[-30:]
        rd = [d for d, _, _ in recent30]
        rc = [c for _, c, _ in recent30 if c is not None]
        print("## recent 30 vs all-time (drift surface)")
        print()
        all_d, all_c = stats(durations), stats(commits)
        r_d, r_c = stats(rd), stats(rc)
        print(f"- wall p50 — all={all_d['p50']}s ({fmt_min(all_d['p50'])}) · recent30={r_d['p50']}s ({fmt_min(r_d['p50'])})")
        print(f"- wall p75 — all={all_d['p75']}s ({fmt_min(all_d['p75'])}) · recent30={r_d['p75']}s ({fmt_min(r_d['p75'])})")
        print(f"- commits p50 — all={all_c['p50']} · recent30={r_c['p50']}")
        print(f"- commits p75 — all={all_c['p75']} · recent30={r_c['p75']}")


{"baseline": baseline, "effect": effect, "suggest": suggest}[mode]()
PY
