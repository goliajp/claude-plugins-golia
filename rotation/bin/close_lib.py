#!/usr/bin/env python3
"""rotation kernel — the close planner and its verdict.

Driven by close_plan.sh (`plan`), close_verdict_fill.sh (`fill`) and
trig_gate.sh (`coverage`: the gate-coverage facts of a range, one line);
never run by hand. Everything project-specific comes in through the environment
the wrappers export from lib.sh / project.sh:

  ROTATION_REPO           the git repository the shas live in
  ROTATION_CLOSE_RULES    the rules table (tsv; see its header for columns)
  ROTATION_STAMP_DIR      where <x>-latest.json stamps live
  ROTATION_STAMP_HISTORY  stamps.jsonl (one row per stamp written or carried)
  ROTATION_VERDICT_DIR    where <rid>.verdict.{md,json} go
  ROTATION_ROTATIONS_LOG  rotations.jsonl
  ROTATION_EVENTS_LOG     events.jsonl
  ROTATION_MESSAGES       a project's message table (optional; see MESSAGES)
  ROTATION_CLOSE_CHECKS_OFF
                          check names (comma / space separated) switched off in
                          rotation.conf: their rows are dropped before planning, so
                          they appear in no verdict and judge nothing. A name the
                          table does not have is a configuration error.

The decision rule is the one the table states: a check runs when the diff
from its own stamp's sha to HEAD touches one of its trigger paths, and is
carried from that sha otherwise. There are no thresholds and no notion of
"small enough to skip" — the table is the only judge, and changing it is a
change to the table.
"""
import datetime
import json
import math
import os
import re
import statistics
import subprocess
import sys

REPO = os.environ.get("ROTATION_REPO") or os.getcwd()
RULES = os.environ.get("ROTATION_CLOSE_RULES") or ""
STAMP_DIR = os.environ.get("ROTATION_STAMP_DIR") or ""
STAMP_HISTORY = os.environ.get("ROTATION_STAMP_HISTORY") or os.path.join(STAMP_DIR, "stamps.jsonl")
VERDICT_DIR = os.environ.get("ROTATION_VERDICT_DIR") or ""
ROTATIONS_LOG = os.environ.get("ROTATION_ROTATIONS_LOG") or ""
EVENTS_LOG = os.environ.get("ROTATION_EVENTS_LOG") or ""
MESSAGES_FILE = os.environ.get("ROTATION_MESSAGES") or ""
CHECKS_OFF = {x for x in re.split(r"[,\s]+", os.environ.get("ROTATION_CLOSE_CHECKS_OFF") or "") if x}

COLUMNS = ["name", "paths", "artifact", "stamp", "minutes", "mode", "sync_paths", "needs", "show", "regress"]
RESULTS_BEGIN = "<!-- results:begin -->"
RESULTS_END = "<!-- results:end -->"

# Every string a person reads in the verdict, the plan summary and the fill
# output, keyed. The kernel speaks English; a project that wants the verdict
# in its own language points ROTATION_MESSAGES (rotation.conf) at a file of
# `key=value` lines overriding any of these keys — the value is taken
# verbatim after the first `=` (leading / trailing spaces included), `{name}`
# fields are str.format placeholders, `#` lines and blank lines are skipped,
# and a key not listed here is a configuration error. Keys the file leaves
# out keep the English text. Machine-read strings (`plan:` / `release:` /
# `gate:` summary lines, `RED` / `amber` markers, JSON keys) are not in here
# and never change.
MESSAGES = {
    # release forms (release.word, and the `release:` summary line)
    "form_next": "straight into the next rotation",
    "form_sync_then_next": "finish, then open",
    "form_next_async": "open now, run alongside",
    "form_sync_then_next_async": "finish the sync checks, then open; async continue",
    # per-check decision and mode words
    "decision_run": "run",
    "decision_carry": "carry",
    "decision_current": "at HEAD",
    "mode_sync": "sync",
    "mode_async": "async",
    "mode_none": "—",
    # why a check runs / carries (checks[].reason)
    "reason_no_stamp": "no stamp",
    "reason_no_head_sha": "stamp has no headSha",
    "reason_dirty": "stamp measured a dirty tree",
    "reason_sha_unknown": "stamp sha is not in the repository",
    "reason_no_verdict": "stamp has no verdict",
    "reason_red_last": "last reading was red (verdict={verdict})",
    "reason_current": "at HEAD",
    "reason_carried_to_head": "carried to HEAD ({reason})",
    "reason_carried_to_head_bare": "carried to HEAD",
    "reason_paths_hit": "{n} change(s) on trigger paths since {base}",
    "reason_paths_clear": "no change on trigger paths since {base} ({n} files changed in the range)",
    "prereq_reason_for": "runs for {users}",
    "prereq_reason_unused": "no running check needs it",
    # why a check takes its mode (checks[].modeReason)
    "mode_why_table": "rules table",
    "mode_why_sync_paths": "sync path hit: {files}",
    "mode_why_gate_fails": "a gate failed mid-round ({shas})",
    "mode_why_red_last": "last round's reading unresolved",
    "prereq_mode_why": "follows the checks that need it",
    # separators for lists of names and of sentences
    "list_sep": ", ",
    "sentence_sep": "; ",
    "none": "none",
    # fill: the red line for a range with substrate changes and no gate.end
    "red_gate_missing": "gate: {n} substrate file(s) changed in the range and no gate.end event "
                        "(the gate did not run, or ran outside ROTATION_GATE_CMD)",
    # fill: a check the plan decided to run whose stamp never reached HEAD (not at HEAD / no stamp) — at least amber
    "amber_not_at_head": "{name}: planned to run, stamp {status} (sha {sha})",
    # the verdict document
    "title": "# Verdict {rid} · {prev}..{head}",
    "subtitle": "Generated {at} · rules table `{rules}` · written by close_plan.sh, facts only; a hand-written verdict does not count.",
    "h_changes": "## 1 What this rotation changed",
    "types_none": "none",
    "changes_range": "- range `{prev}..{head}`: {commits} commit(s) ({types})",
    "changes_agent_suffix": ", {n} of them landed by agents",
    "changes_files": "- {files} file(s) changed, by directory / crate:",
    "areas_table_head": "| directory / crate | files |",
    "gate_missing": "- gate events this round: **missing** — {n} substrate file(s) changed in the range and events hold no gate.end "
                    "(\"no fail\" cannot be concluded; red on fill)",
    "gate_ends": "- gate events this round: {n} gate.end",
    "gate_at_head": ", the last commit has a gate",
    "gate_substrate": "; substrate files {n}",
    "gate_no_substrate": "; no substrate change",
    "gate_fails": "- gate fails mid-round: {items}",
    "gate_fail_item": "{sha} ({n} fail)",
    "gate_fails_unknown": "no gate.end event, unknown",
    "sync_hits": "- sync trigger paths hit: {items}",
    "sync_hit_item": "{name} ({files}{more})",
    "more_ellipsis": "…",
    "static_shape_note": "- runtime static data shape / link layout changed? the rules table cannot judge it mechanically; "
                         "the rotation's handoff states it",
    "h_decision": "## 2 Decision",
    "decision_table_head": "| check | stamp sha | hits | decision | mode | estimate |",
    "hits_n": "{n} hit(s): ",
    "hits_more": " … +{n}",
    "carry_from": "carried from {sha}",
    "paren": " ({x})",
    "total_all_carry": "Overall: **everything carried, straight into the next rotation**",
    "total_run": "Overall: the close runs {n} check(s), about {sync} min sync · {async} min async",
    "h_results": "## 3 Results",
    "results_pending": "(to be filled: `close_verdict_fill.sh {rid}`)",
    "results_filled": "Filled {at}. Readings come from the stamps; \"previous\" = the last row in stamps.jsonl "
                      "of the same check that measured the round's start `{prev}` or an earlier commit "
                      "(baseline sha {prev}; a stamp taken mid-round is never the baseline).",
    "results_table_head": "| check | status | stamp sha | readings (delta vs previous) | elapsed | verdict |",
    "status_ran": "ran",
    "status_carried": "carried from {sha}",
    "status_pending": "not at HEAD",
    "status_missing": "no stamp",
    "flag_red": "**red**",
    "flag_amber": "amber",
    "judge_ok": "ok",
    "results_red": "**Regressions (red)**: {items}",
    "results_red_action": "Owner: the round now running handles it first — bisect inside the range, fix or revert; "
                          "the next rotation does not close until it is handled.",
    "results_amber": "To attribute (amber): {items}",
    "results_none": "No regressions.",
    "h_release": "## 4 Release",
    "release_form": "Form: **{word}** (`{form}`)",
    "release_sync": "- sync (blocking, the next rotation opens after): {items}",
    "release_async": "- async (alongside, the next rotation opens now; report only on trouble): {items}",
    "release_carry": "- carried: {items}",
}


def die(msg, code=2):
    print(f"close_plan: {msg}", file=sys.stderr)
    sys.exit(code)


def load_messages():
    if not MESSAGES_FILE:
        return
    if not os.path.isfile(MESSAGES_FILE):
        die(f"message table missing: {MESSAGES_FILE} (ROTATION_MESSAGES)")
    with open(MESSAGES_FILE, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            key, eq, val = line.partition("=")
            key = key.strip()
            if not eq or key not in MESSAGES:
                die(f"{MESSAGES_FILE}:{n}: not a message key: {line}")
            MESSAGES[key] = val


def msg(key, **kw):
    try:
        return MESSAGES[key].format(**kw)
    except (KeyError, IndexError, ValueError) as e:
        die(f"message table: template {key!r} cannot be filled ({e}); file {MESSAGES_FILE or '(kernel default)'}")


def join_names(names):
    return MESSAGES["list_sep"].join(names)


def join_sentences(items):
    return MESSAGES["sentence_sep"].join(items)


FORM_KEY = {"next": "form_next", "sync-then-next": "form_sync_then_next",
            "next-async": "form_next_async", "sync-then-next-async": "form_sync_then_next_async"}
DECISION_KEY = {"run": "decision_run", "carry": "decision_carry", "current": "decision_current"}
MODE_KEY = {"sync": "mode_sync", "async": "mode_async", "-": "mode_none"}


def decision_word(d):
    return msg(DECISION_KEY[d]) if d in DECISION_KEY else d


def mode_word(m):
    return msg(MODE_KEY[m]) if m in MODE_KEY else msg("mode_none")


def git(*args, default=None):
    r = subprocess.run(["git", "-C", REPO, *args], capture_output=True, text=True)
    return r.stdout.rstrip("\n") if r.returncode == 0 else default


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def read_jsonl(path):
    out = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
    except OSError:
        pass
    return out


def same_sha(a, b):
    return bool(a and b) and (a.startswith(b) or b.startswith(a))


# ── rules ──────────────────────────────────────────────────────────────
def glob_re(pat):
    """a path glob as a regex: `**` crosses `/`, `*` and `?` do not"""
    out = ""
    i = 0
    while i < len(pat):
        c = pat[i]
        if pat.startswith("**", i):
            out += ".*"
            i += 2
            continue
        if c == "*":
            out += "[^/]*"
        elif c == "?":
            out += "[^/]"
        else:
            out += re.escape(c)
        i += 1
    return re.compile("^" + out + "$")


def parse_globs(field):
    inc, exc = [], []
    if field in ("", "-"):
        return inc, exc
    for g in field.split(";"):
        g = g.strip()
        if not g:
            continue
        if g.startswith("!"):
            exc.append((g[1:], glob_re(g[1:])))
        else:
            inc.append((g, glob_re(g)))
    return inc, exc


def match_paths(files, inc, exc):
    """the files a glob set hits, and which glob hit each"""
    hits = []
    for f in files:
        if any(r.match(f) for _, r in exc):
            continue
        for g, r in inc:
            if r.match(f):
                hits.append((f, g))
                break
    return hits


REGRESS_OPS = ("down", "up", "nonzero", "each-up")


def regress_spec_error(spec):
    """why a `regress` cell entry cannot be judged (None when it can): an unknown op judges nothing, silently"""
    key, _, op = spec.lstrip("~").partition(":")
    name, *params = op.split(":")
    if not key or name not in REGRESS_OPS:
        return f"want <key>:{'|'.join(REGRESS_OPS)}"
    if name != "each-up":
        return "takes no parameters" if params else None
    if not 1 <= len(params) <= 3 or any(num(x) is None or num(x) < 0 for x in params):
        return "each-up takes <rel>[:<k>[:<ceiling>]], non-negative numbers"
    return None


def load_rules():
    if not RULES or not os.path.isfile(RULES):
        die(f"rules table missing: {RULES or '(ROTATION_CLOSE_RULES unset)'}")
    rules = []
    with open(RULES, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            cells = line.split("\t")
            if len(cells) != len(COLUMNS):
                die(f"{RULES}:{n}: {len(cells)} columns, want {len(COLUMNS)}")
            r = dict(zip(COLUMNS, [c.strip() for c in cells]))
            stamp, _, tool = r["stamp"].partition(":")
            r["stamp"] = stamp if stamp != "-" else None
            r["tool"] = tool or r["stamp"]
            r["minutes"] = float(r["minutes"]) if r["minutes"] not in ("", "-") else 0.0
            r["needs"] = r["needs"] if r["needs"] != "-" else None
            r["show"] = [k for k in r["show"].split(",") if k and k != "-"]
            r["regress"] = [k for k in r["regress"].split(";") if k and k != "-"]
            for spec in r["regress"]:
                bad = regress_spec_error(spec)
                if bad:
                    die(f"{RULES}:{n}: regress `{spec}`: {bad}")
            r["_inc"], r["_exc"] = parse_globs(r["paths"])
            r["_sinc"], r["_sexc"] = parse_globs(r["sync_paths"])
            rules.append(r)
    if not rules:
        die(f"{RULES}: no rules — an empty table would carry every check forever")
    # rows switched off in rotation.conf leave the table here: no verdict row, no judgement, no coverage paths
    unknown = CHECKS_OFF - {r["name"] for r in rules}
    if unknown:
        die(f"ROTATION_CLOSE_CHECKS_OFF names a check the table does not have: {', '.join(sorted(unknown))}")
    rules = [r for r in rules if r["name"] not in CHECKS_OFF]
    if not rules:
        die(f"{RULES}: every rule is switched off (ROTATION_CLOSE_CHECKS_OFF)")
    names = [r["name"] for r in rules]
    for r in rules:
        if r["needs"] and r["needs"] not in names:
            die(f"rule {r['name']} needs unknown check {r['needs']}")
        if r["mode"] not in ("sync", "async", "-"):
            die(f"rule {r['name']}: mode must be sync | async | -, got {r['mode']}")
        if r["stamp"] is None and r["mode"] != "-":
            die(f"rule {r['name']}: a check without a stamp is a prerequisite and takes mode `-`")
    return rules


# ── the rotation and its range ─────────────────────────────────────────
def rotation_rows():
    return [r for r in read_jsonl(ROTATIONS_LOG) if r.get("rotationId")]


def resolve_range(prev, head, rid):
    """the rid a range belongs to is the row whose prevHead opened it: the id the rotation ran under, which is
    the rotationId its events carry. with no shas given the range is the open rotation's: last row's prevHead..HEAD"""
    rows = rotation_rows()
    head = git("rev-parse", head or "HEAD")
    if not head:
        die("cannot resolve HEAD")
    if not prev:
        if not rows:
            die("no rotations.jsonl row and no <prev-sha> given")
        last = rows[-1]
        if same_sha(last["prevHead"], head) and len(rows) > 1:
            # the close trigger has already written the next row at this head: the closed rotation is the one before
            prev = rows[-2]["prevHead"]
            rid = rid or rows[-2]["rotationId"]
        else:
            prev = last["prevHead"]
            rid = rid or last["rotationId"]
    prev_full = git("rev-parse", prev + "^{commit}")
    if not prev_full:
        die(f"prev sha {prev} is not a commit in {REPO}")
    if not rid:
        row = next((r for r in reversed(rows) if same_sha(r["prevHead"], prev_full)), None)
        rid = row["rotationId"] if row else None
    if not rid:
        die("cannot determine the rotation id: pass --rid")
    return prev_full, head, rid


def commits_in(prev, head):
    log = git("log", "--format=%H%x1f%h%x1f%s%x1f%B%x1e", f"{prev}..{head}", default="")
    out = []
    for chunk in log.split("\x1e"):
        parts = chunk.strip("\n").split("\x1f")
        if len(parts) < 4:
            continue
        m = re.match(r"^([a-z]+)(\([^)]*\))?!?:", parts[2])
        out.append({"sha": parts[0], "short": parts[1], "subject": parts[2],
                    "type": m.group(1) if m else None,
                    "agentOrigin": bool(re.search(r"^Agent-Origin:", parts[3], re.M))})
    return out


def area_of(path):
    parts = path.split("/")
    if len(parts) >= 3 and parts[0] in ("crates", "packages"):
        return parts[0] + "/" + parts[1]
    return parts[0] if len(parts) > 1 else "(root)"


def gate_fails(rid, shas):
    """gate.end events of this rotation (by id, or by the sha they ran on) that carry a fail"""
    out = []
    for e in read_jsonl(EVENTS_LOG):
        if e.get("kind") != "gate.end":
            continue
        g = e.get("gate") or {}
        if (g.get("fail") or 0) <= 0:
            continue
        if e.get("rotationId") == rid or any(same_sha(g.get("sha"), s) for s in shas):
            out.append({"sha": g.get("sha"), "fail": g.get("fail"), "at": e.get("at")})
    return out


def gate_coverage(rid, shas, files, rules):
    """whether the range had substrate changes (files on any check's trigger paths) and whether a gate.end
    event of this rotation (by id or by sha) exists at all. a substrate range with no gate.end is a hole in the
    evidence, not an absence of failures: section 1 says so and fill() turns it red"""
    inc, exc = [], []
    for r in rules:
        if r["stamp"] is not None:
            inc += r["_inc"]
            exc += r["_exc"]
    substrate = [f for f, _ in match_paths(files, inc, exc)]
    ends = []
    for e in read_jsonl(EVENTS_LOG):
        if e.get("kind") != "gate.end":
            continue
        g = e.get("gate") or {}
        if e.get("rotationId") == rid or any(same_sha(g.get("sha"), s) for s in shas):
            ends.append({"sha": g.get("sha"), "pass": g.get("pass"), "fail": g.get("fail"), "at": e.get("at")})
    return {"substrateFiles": len(substrate), "gateEnds": len(ends),
            "missing": bool(substrate) and not ends,
            "atHead": any(same_sha(x["sha"], shas[0]) for x in ends) if shas and ends else False}


# ── plan ───────────────────────────────────────────────────────────────
def stamp_state(rule, head):
    """where this check's stamp stands: (base sha, decision-or-None, reason code, reason text, doc)"""
    path = os.path.join(STAMP_DIR, f"{rule['stamp']}-latest.json")
    doc = read_json(path)
    if doc is None:
        return None, "run", "no-stamp", msg("reason_no_stamp"), None
    sha = doc.get("headSha") or ""
    if not sha:
        return None, "run", "no-head-sha", msg("reason_no_head_sha"), doc
    if sha.endswith("-dirty"):
        return sha, "run", "dirty", msg("reason_dirty"), doc
    full = git("rev-parse", sha + "^{commit}")
    if not full:
        return sha, "run", "sha-unknown", msg("reason_sha_unknown"), doc
    verdict = doc.get("verdict")
    if not verdict:
        return full, "run", "no-verdict", msg("reason_no_verdict"), doc
    if verdict != "ok":
        return full, "run", "red-last", msg("reason_red_last", verdict=verdict), doc
    if full == head:
        return full, "current", "current", msg("reason_current"), doc
    carried = doc.get("carriedTo")
    if carried and same_sha(carried, head):
        why = doc.get("carriedReason") or ""
        text = msg("reason_carried_to_head", reason=why) if why else msg("reason_carried_to_head_bare")
        return full, "current", "carried", text, doc
    return full, None, None, "", doc


def plan(prev, head, rid, explain, force):
    rules = load_rules()
    os.makedirs(VERDICT_DIR, exist_ok=True)
    json_path = os.path.join(VERDICT_DIR, f"{rid}.verdict.json")
    md_path = os.path.join(VERDICT_DIR, f"{rid}.verdict.md")
    existing = read_json(json_path)
    if existing and not force and existing.get("prevSha") == prev and existing.get("headSha") == head:
        print(f"verdict exists: {md_path} (use --force to re-plan)")
        print_summary(existing, explain)
        return existing

    commits = commits_in(prev, head)
    shas = [c["sha"] for c in commits]
    files = [f for f in (git("diff", "--name-only", prev, head, default="") or "").split("\n") if f]
    types = {}
    for c in commits:
        types[c["type"] or "?"] = types.get(c["type"] or "?", 0) + 1
    areas = {}
    for f in files:
        areas[area_of(f)] = areas.get(area_of(f), 0) + 1
    fails = gate_fails(rid, shas)
    coverage = gate_coverage(rid, shas, files, rules)

    checks = []
    for r in rules:
        if r["stamp"] is None:
            checks.append({"name": r["name"], "prerequisite": True, "artifact": r["artifact"], "minutes": r["minutes"],
                           "decision": None, "mode": None, "modeReason": None, "stampSha": None, "base": None,
                           "hits": [], "reason": None, "needs": None, "tool": None, "stampFile": None})
            continue
        base, decision, code, reason, doc = stamp_state(r, head)
        diff_files = []
        hits = []
        if decision is None:
            diff_files = [f for f in (git("diff", "--name-only", base, head, default="") or "").split("\n") if f]
            hits = match_paths(diff_files, r["_inc"], r["_exc"])
            if hits:
                decision = "run"
                reason = msg("reason_paths_hit", base=base[:9], n=len(hits))
            else:
                decision = "carry"
                reason = msg("reason_paths_clear", base=base[:9], n=len(diff_files))
        sync_hits = match_paths(diff_files or files, r["_sinc"], r["_sexc"]) if decision == "run" else []
        mode, why = None, None
        if decision == "run":
            mode, why = r["mode"], msg("mode_why_table")
            if r["mode"] == "async":
                if sync_hits:
                    mode, why = "sync", msg("mode_why_sync_paths", files=", ".join(f for f, _ in sync_hits[:3]))
                elif fails:
                    mode, why = "sync", msg("mode_why_gate_fails", shas=", ".join((x["sha"] or "?")[:9] for x in fails))
                elif code == "red-last":
                    mode, why = "sync", msg("mode_why_red_last")
        checks.append({"name": r["name"], "prerequisite": False, "artifact": r["artifact"], "minutes": r["minutes"],
                       "decision": decision, "mode": mode, "modeReason": why,
                       "stampSha": (doc or {}).get("headSha"), "base": base, "stampFile": f"{r['stamp']}-latest.json",
                       "tool": r["tool"], "needs": r["needs"], "hits": [{"file": f, "glob": g} for f, g in hits],
                       "syncHits": [f for f, _ in sync_hits], "reason": reason, "result": None})
    # a prerequisite runs for its dependants and takes the stricter of their modes
    by_name = {c["name"]: c for c in checks}
    for c in checks:
        if not c["prerequisite"]:
            continue
        users = [u for u in checks if u.get("needs") == c["name"] and u["decision"] == "run"]
        if users:
            c["decision"] = "run"
            c["mode"] = "sync" if any(u["mode"] == "sync" for u in users) else "async"
            c["reason"] = msg("prereq_reason_for", users=join_names(u["name"] for u in users))
            c["modeReason"] = msg("prereq_mode_why")
        else:
            c["decision"] = "carry"
            c["reason"] = msg("prereq_reason_unused")
    running = [c for c in checks if c["decision"] == "run"]
    sync = [c["name"] for c in running if c["mode"] == "sync"]
    asyn = [c["name"] for c in running if c["mode"] == "async"]
    if not running:
        form = "next"
    elif sync and asyn:
        form = "sync-then-next-async"
    elif sync:
        form = "sync-then-next"
    else:
        form = "next-async"
    verdict = {
        "rotationId": rid, "prevSha": prev, "headSha": head, "generatedAt": now_iso(),
        "rules": RULES, "repo": REPO,
        "changes": {"commits": len(commits), "agentCommits": sum(1 for c in commits if c["agentOrigin"]),
                    "types": dict(sorted(types.items(), key=lambda kv: -kv[1])), "files": len(files),
                    "areas": dict(sorted(areas.items(), key=lambda kv: -kv[1])),
                    "gateFails": fails, "gateCoverage": coverage,
                    "syncHits": {c["name"]: c["syncHits"] for c in checks if c.get("syncHits")}},
        "checks": checks,
        "release": {"form": form, "word": msg(FORM_KEY[form]), "sync": sync, "async": asyn,
                    "minutesSync": round(sum(by_name[n]["minutes"] for n in sync), 1),
                    "minutesAsync": round(sum(by_name[n]["minutes"] for n in asyn), 1)},
        "results": {"filledAt": None, "red": [], "amber": []},
    }
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(verdict, f, ensure_ascii=False, indent=1)
        f.write("\n")
    with open(md_path, "w", encoding="utf-8") as f:
        f.write(render_md(verdict))
    print(f"verdict: {md_path}")
    print_summary(verdict, explain)
    return verdict


def print_summary(v, explain):
    rel = v["release"]
    run = [c["name"] for c in v["checks"] if c["decision"] == "run"]
    carry = [c["name"] for c in v["checks"] if c["decision"] in ("carry", "current")]
    print(f"plan: {v['prevSha'][:9]}..{v['headSha'][:9]} commits={v['changes']['commits']} files={v['changes']['files']}"
          f" run=[{' '.join(run)}] carry=[{' '.join(carry)}]")
    print(f"release: {rel['form']} · {rel['word']} · sync={rel['minutesSync']}min [{' '.join(rel['sync'])}]"
          f" · async={rel['minutesAsync']}min [{' '.join(rel['async'])}]")
    cov = (v.get("changes") or {}).get("gateCoverage")
    if cov:
        print(f"gate: substrateFiles={cov['substrateFiles']} gateEnds={cov['gateEnds']} "
              + ("MISSING (substrate changed, no gate.end event)" if cov["missing"] else "ok"))
    if not explain:
        return
    for c in v["checks"]:
        head = f"  {c['name']:<14} {decision_word(c['decision'])}"
        if c["decision"] == "run" and c["mode"]:
            head += f" ({mode_word(c['mode'])}: {c['modeReason']})"
        print(f"{head} — {c['reason']}")
        for h in c["hits"]:
            print(f"      {h['file']}  ← {h['glob']}")


# ── fill ───────────────────────────────────────────────────────────────
def dig(doc, key):
    cur = doc
    for part in key.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur


def num(v):
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return v
    if isinstance(v, str):
        try:
            return float(v) if "." in v else int(v)
        except ValueError:
            return None
    return None


def is_ancestor(sha, base):
    r = subprocess.run(["git", "-C", REPO, "merge-base", "--is-ancestor", sha, base], capture_output=True, text=True)
    return r.returncode == 0


def voided(history):
    """(tool, ranAt) of every row a later void row withdrew. stamps.jsonl is append-only, so a reading found wrong
    after the fact (a meter that measured less than it claimed) is withdrawn by appending
    {"tool": "stamp.void", "void": [{"tool": …, "ranAt": …, "headSha": …}, …], "reason": …}"""
    return {(v.get("tool"), v.get("ranAt")) for s in history if isinstance(s.get("void"), list)
            for v in s["void"] if isinstance(v, dict)}


def previous_row(history, tool, cur, base):
    """the baseline a reading is judged against: the last non-carried, non-voided row of this tool that measured
    the round's start `base` or a commit before it, and not the current stamp's own commit. a stamp taken
    mid-round is never the baseline — one measured under lighter load made the round's own end read as a
    regression while the readings at the round's start and end were the same"""
    cur_sha = cur.get("headSha") or ""
    void = voided(history)
    for s in reversed(history):
        if s.get("tool") != tool or s.get("carried") or (tool, s.get("ranAt")) in void:
            continue
        sha = s.get("headSha") or ""
        if not sha or sha.endswith("-dirty") or same_sha(sha, cur_sha):
            continue
        if is_ancestor(sha, base):
            return s
    return None


def readings(v):
    """one positive reading, or a list of repeated ones, as a list; None when it is neither"""
    xs = [num(x) for x in v] if isinstance(v, list) else [num(v)]
    return xs if xs and all(x is not None and x > 0 for x in xs) else None


def each_up(cur, prev, params):
    """`each-up:<rel>[:<k>[:<ceiling>]]` over a map of lower-is-better readings: every entry both maps carry is
    judged, an entry only one of them has is not. an entry is one reading, or a list of repeats; two lists of at
    least three are judged on their medians, and the move must also clear the noise the repeats show: every new
    reading above every old one, and (for the `rel` bar) the log move above k times the larger log-spread
    (max/min) of the two lists. a shorter list is judged on nothing. hit: the median rose by more than `rel`, or
    it crossed `ceiling` from below. returns [(entry, previous median, current median)]"""
    rel, k, ceiling = (num(params[i]) if len(params) > i else d for i, d in enumerate((0, 0, None)))
    hits = []
    if not isinstance(cur, dict) or not isinstance(prev, dict):
        return hits
    for name in sorted(set(cur) & set(prev)):
        a, b = readings(prev[name]), readings(cur[name])
        if a is None or b is None:
            continue
        repeats = isinstance(prev[name], list) and isinstance(cur[name], list)
        if repeats and (len(a) < 3 or len(b) < 3):
            continue
        ma, mb = statistics.median(a), statistics.median(b)
        apart = min(b) > max(a) if repeats else True
        spread = max(math.log(max(a) / min(a)), math.log(max(b) / min(b))) if repeats else 0.0
        up = math.log(mb / ma) > max(math.log1p(rel), k * spread)
        crossed = ceiling is not None and ma < ceiling <= mb
        if apart and (up or crossed):
            hits.append((name, round(ma, 4), round(mb, 4)))
    return hits


def fill(rid):
    rules = {r["name"]: r for r in load_rules()}
    json_path = os.path.join(VERDICT_DIR, f"{rid}.verdict.json")
    md_path = os.path.join(VERDICT_DIR, f"{rid}.verdict.md")
    v = read_json(json_path)
    if not v:
        die(f"no verdict for {rid} at {json_path}")
    history = read_jsonl(STAMP_HISTORY)
    head = v["headSha"]
    red, amber = [], []
    cov = (v.get("changes") or {}).get("gateCoverage") or {}
    if cov.get("missing"):
        red.append(msg("red_gate_missing", n=cov["substrateFiles"]))
    for c in v["checks"]:
        if c["prerequisite"]:
            continue
        r = rules.get(c["name"])
        doc = read_json(os.path.join(STAMP_DIR, c["stampFile"]))
        if doc is None or not r:
            c["result"] = {"status": "missing", "flags": []}
            if c["decision"] == "run":
                # the plan said run and nothing was ever written: the close did not finish, which is never ok
                c["result"]["flags"].append({"level": "amber", "key": "status", "value": "missing", "previous": None, "op": "at-head"})
                amber.append(msg("amber_not_at_head", name=c["name"], status=msg("status_missing"), sha="—"))
            continue
        sha = doc.get("headSha") or ""
        if same_sha(sha, head):
            status = "ran"
        elif same_sha(doc.get("carriedTo"), head):
            status = "carried"
        else:
            status = "pending"
        prev = previous_row(history, r["tool"], doc, v["prevSha"])
        readings = []
        for key in r["show"]:
            cur_v = dig(doc, key)
            prev_v = dig(prev, key) if prev else None
            cn, pn = num(cur_v), num(prev_v)
            delta = round(cn - pn, 4) if cn is not None and pn is not None else None
            readings.append({"key": key, "value": cur_v, "previous": prev_v, "delta": delta})
        flags = []
        for spec in r["regress"]:
            level = "amber" if spec.startswith("~") else "red"
            key, _, op = spec.lstrip("~").partition(":")
            if op.startswith("each-up"):
                for name, pv, cv in (each_up(dig(doc, key), dig(prev, key), op.split(":")[1:]) if prev else []):
                    flags.append({"level": level, "key": f"{key}.{name}", "value": cv, "previous": pv, "op": "each-up"})
                    (red if level == "red" else amber).append(f"{c['name']}: {key}.{name} {pv} → {cv}")
                continue
            cn, pn = num(dig(doc, key)), num(dig(prev, key)) if prev else None
            hit = False
            if op == "nonzero":
                hit = cn is not None and cn != 0
            elif op == "down":
                hit = cn is not None and pn is not None and cn < pn
            elif op == "up":
                hit = cn is not None and pn is not None and cn > pn
            if hit:
                flags.append({"level": level, "key": key, "value": cn, "previous": pn, "op": op})
                (red if level == "red" else amber).append(f"{c['name']}: {key} {pn} → {cn}" if op != "nonzero" else f"{c['name']}: {key}={cn}")
        verdict = doc.get("verdict") or "missing"
        if verdict != "ok":
            flags.append({"level": "red", "key": "verdict", "value": verdict, "previous": None, "op": "ok"})
            red.append(f"{c['name']}: verdict={verdict}")
        if status == "pending" and c["decision"] == "run":
            # the plan said run and the stamp still names an older commit: the close did not reach HEAD.
            # a reading of the wrong commit judges nothing, so this is at least amber, never ok
            flags.append({"level": "amber", "key": "status", "value": "pending", "previous": None, "op": "at-head"})
            amber.append(msg("amber_not_at_head", name=c["name"], status=msg("status_pending"), sha=sha[:9]))
        c["result"] = {"status": status, "stampSha": sha, "ranAt": doc.get("ranAt"), "carriedTo": doc.get("carriedTo"),
                       "carriedReason": doc.get("carriedReason"), "elapsedSec": doc.get("elapsedSec"), "verdict": verdict,
                       "previousSha": prev.get("headSha") if prev else None, "readings": readings, "flags": flags}
    v["results"] = {"filledAt": now_iso(), "red": red, "amber": amber}
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(v, f, ensure_ascii=False, indent=1)
        f.write("\n")
    md = open(md_path, encoding="utf-8").read() if os.path.isfile(md_path) else render_md(v)
    a, b = md.find(RESULTS_BEGIN), md.find(RESULTS_END)
    section = render_results(v)
    if a >= 0 and b > a:
        md = md[:a] + section + md[b + len(RESULTS_END):]
    else:
        md = render_md(v)
    with open(md_path, "w", encoding="utf-8") as f:
        f.write(md)
    print(f"filled: {md_path} red={len(red)} amber={len(amber)}")
    for x in red:
        print(f"  RED   {x}")
    for x in amber:
        print(f"  amber {x}")
    return v


# ── markdown ───────────────────────────────────────────────────────────
def fmt_v(v):
    if v is None:
        return "—"
    if isinstance(v, float):
        return f"{v:.4f}".rstrip("0").rstrip(".")
    return str(v)


def render_results(v):
    out = [RESULTS_BEGIN, msg("h_results"), ""]
    res = v.get("results") or {}
    if not res.get("filledAt"):
        out += [msg("results_pending", rid=v["rotationId"]), "", RESULTS_END]
        return "\n".join(out)
    out += [msg("results_filled", at=res["filledAt"], prev=v["prevSha"][:9]), ""]
    out += [msg("results_table_head"), "|---|---|---|---|---|---|"]
    for c in v["checks"]:
        if c["prerequisite"]:
            continue
        r = c.get("result") or {}
        st = r.get("status")
        word = {"ran": msg("status_ran"), "carried": msg("status_carried", sha=(r.get("stampSha") or "")[:9]),
                "pending": msg("status_pending"), "missing": msg("status_missing")}.get(st, st)
        parts = []
        for x in r.get("readings") or []:
            s = f"{x['key']}={fmt_v(x['value'])}"
            if x.get("delta") is not None:
                s += f"({x['delta']:+g})"
            parts.append(s)
        flags = r.get("flags") or []
        judge = join_names((msg("flag_red") if f["level"] == "red" else msg("flag_amber")) + f" {f['key']}" for f in flags) or msg("judge_ok")
        el = f"{r['elapsedSec']:.0f}s" if isinstance(r.get("elapsedSec"), (int, float)) else "—"
        out.append(f"| {c['name']} | {word} | {(r.get('stampSha') or '')[:9] or '—'} | {' '.join(parts) or '—'} | {el} | {judge} |")
    out.append("")
    if res.get("red"):
        out += [msg("results_red", items=join_sentences(res["red"])), "", msg("results_red_action"), ""]
    if res.get("amber"):
        out += [msg("results_amber", items=join_sentences(res["amber"])), ""]
    if not res.get("red") and not res.get("amber"):
        out += [msg("results_none"), ""]
    out.append(RESULTS_END)
    return "\n".join(out)


def render_md(v):
    ch = v["changes"]
    rel = v["release"]
    out = [msg("title", rid=v["rotationId"], prev=v["prevSha"][:9], head=v["headSha"][:9]), "",
           msg("subtitle", at=v["generatedAt"], rules=os.path.relpath(v["rules"], v["repo"])), "",
           msg("h_changes"), ""]
    types = " · ".join(f"{k} {n}" for k, n in ch["types"].items()) or msg("types_none")
    out.append(msg("changes_range", prev=v["prevSha"][:9], head=v["headSha"][:9], commits=ch["commits"], types=types)
               + (msg("changes_agent_suffix", n=ch["agentCommits"]) if ch["agentCommits"] else ""))
    out.append(msg("changes_files", files=ch["files"]))
    out += ["", msg("areas_table_head"), "|---|---|"]
    out += [f"| `{k}` | {n} |" for k, n in ch["areas"].items()]
    out.append("")
    fails = ch.get("gateFails") or []
    cov = ch.get("gateCoverage") or {}
    if cov.get("missing"):
        out.append(msg("gate_missing", n=cov["substrateFiles"]))
    elif cov:
        out.append(msg("gate_ends", n=cov["gateEnds"]) + (msg("gate_at_head") if cov.get("atHead") else "")
                   + (msg("gate_substrate", n=cov["substrateFiles"]) if cov.get("substrateFiles") else msg("gate_no_substrate")))
    if fails:
        fails_s = join_names(msg("gate_fail_item", sha=(x["sha"] or "?")[:9], n=x["fail"]) for x in fails)
    elif cov.get("gateEnds") or not cov.get("substrateFiles"):
        fails_s = msg("none")
    else:
        fails_s = msg("gate_fails_unknown")
    out.append(msg("gate_fails", items=fails_s))
    sh = ch.get("syncHits") or {}
    hits_s = join_sentences(msg("sync_hit_item", name=k, files=", ".join(fs[:3]), more=msg("more_ellipsis") if len(fs) > 3 else "")
                            for k, fs in sh.items()) if sh else msg("none")
    out.append(msg("sync_hits", items=hits_s))
    out.append(msg("static_shape_note"))
    out += ["", msg("h_decision"), "", msg("decision_table_head"), "|---|---|---|---|---|---|"]
    for c in v["checks"]:
        hits = c["hits"]
        hit_s = "—"
        if hits:
            hit_s = msg("hits_n", n=len(hits)) + ", ".join(f"`{h['file']}`" for h in hits[:3]) + (msg("hits_more", n=len(hits) - 3) if len(hits) > 3 else "")
        elif c["prerequisite"]:
            hit_s = c["reason"] or "—"
        dec = decision_word(c["decision"])
        if c["decision"] == "carry" and c["base"]:
            dec = msg("carry_from", sha=c["base"][:9])
        if c["decision"] == "run" and not hits and not c["prerequisite"]:
            dec += msg("paren", x=c["reason"])
        if c["decision"] == "run":
            mode = mode_word(c["mode"]) + (msg("paren", x=c["modeReason"]) if c["modeReason"] and c["modeReason"] != msg("mode_why_table") else "")
        else:
            mode = msg("mode_none")
        mins = f"{c['minutes']:g} min" if c["decision"] == "run" else "—"
        out.append(f"| {c['name']} | {(c['stampSha'] or '—')[:9]} | {hit_s} | {dec} | {mode} | {mins} |")
    out.append("")
    n_run = len(rel["sync"]) + len(rel["async"])
    if n_run == 0:
        out.append(msg("total_all_carry"))
    else:
        out.append(msg("total_run", n=n_run, sync=f"{rel['minutesSync']:g}", **{"async": f"{rel['minutesAsync']:g}"}))
    out += ["", render_results(v), "", msg("h_release"), "", msg("release_form", word=rel["word"], form=rel["form"]), ""]
    out.append(msg("release_sync", items=join_names(rel["sync"]) if rel["sync"] else msg("none")))
    out.append(msg("release_async", items=join_names(rel["async"]) if rel["async"] else msg("none")))
    carried = [c["name"] for c in v["checks"] if c["decision"] in ("carry", "current")]
    out.append(msg("release_carry", items=join_names(carried) or msg("none")))
    out.append("")
    return "\n".join(out)


def main():
    argv = sys.argv[1:]
    if not argv:
        die("usage: close_lib.py plan|fill ...")
    load_messages()
    cmd, argv = argv[0], argv[1:]
    if cmd == "plan":
        explain = force = False
        rid = None
        pos = []
        i = 0
        while i < len(argv):
            a = argv[i]
            if a == "--explain":
                explain = True
            elif a == "--force":
                force = True
            elif a == "--rid":
                i += 1
                rid = argv[i] if i < len(argv) else die("--rid needs a value")
            elif a.startswith("-"):
                die(f"unknown option {a}")
            else:
                pos.append(a)
            i += 1
        if len(pos) > 2:
            die("usage: close_plan.sh [<prev-sha> [<head-sha>]] [--rid <rid>] [--explain] [--force]")
        prev, head, rid = resolve_range(pos[0] if pos else None, pos[1] if len(pos) > 1 else None, rid)
        plan(prev, head, rid, explain, force)
    elif cmd == "fill":
        if len(argv) != 1:
            die("usage: close_verdict_fill.sh <rid>")
        fill(argv[0])
    elif cmd == "coverage":
        # coverage <prev> <head> <rid>: the same facts section 1 of the verdict states, for TRIG-8
        if len(argv) != 3:
            die("usage: close_lib.py coverage <prev-sha> <head-sha> <rid>")
        prev, head, rid = argv
        rules = load_rules()
        shas = [c["sha"] for c in commits_in(prev, head)]
        files = [f for f in (git("diff", "--name-only", prev, head, default="") or "").split("\n") if f]
        cov = gate_coverage(rid, shas, files, rules)
        print(f"substrateFiles={cov['substrateFiles']} gateEnds={cov['gateEnds']} "
              f"atHead={'yes' if cov['atHead'] else 'no'} missing={'yes' if cov['missing'] else 'no'}")
    else:
        die(f"unknown command {cmd}")


if __name__ == "__main__":
    main()
