"""rotation kernel — the onboarding checks (onboard_check.sh) and the plan.* rows of doctor.sh.

Read-only: reads the project's vision, plan, handoff, lanes description, stamps and rules table, and
prints one `PASS|WARN|FAIL <item> <detail>` line per check. Everything arrives through the environment
onboard_check.sh exports (the paths already resolved by lib.sh for the lane in question).

usage: onboard_lib.py onboard [--lane-required] | doctor
"""
import os
import re
import sys

E = os.environ
ZH_HEADER = ["通道", "id", "状态", "一句话", "出处", "登记", "验收", "blocked_by", "done"]
EN_HEADER = ["lane", "id", "status", "summary", "source", "registered", "acceptance", "blocked_by", "done"]
ZH_STATES = ["在做", "排队", "已完成", "等决定", "撤回"]
EN_STATES = ["active", "queued", "done", "decision", "withdrawn"]
EMPTY_CELL = {"", "-", "—", "–"}
ID_RE = re.compile(r"[A-Za-z][A-Za-z0-9]*-[A-Za-z0-9][A-Za-z0-9._-]*")
PERCENT_RE = re.compile(r"[0-9]+%")


def lead(alts):
    # a heading that is about the layer: the name opens the title, after any numbering or punctuation
    # (`## L4 trigger predicates`, `### 3. L3a hot queue`), not one that mentions it in passing
    return re.compile(r"^[\W\d_]*(?:" + alts + r")(?![A-Za-z0-9])", re.I)


L1_RE = lead("L1|roadmap|路线图")
L2_RE = lead(r"L2|version scope|版本\s*(?:scope|边界|范围)")
L3A_RE = lead("L3a|hot queue|热队列")
L3B_RE = lead("L3b|cold queue|冷队列")
L4_RE = lead("L4|trigger predicates?|触发谓词")
POSITION_RE = re.compile("定位|positioning", re.I)
NONGOAL_RE = re.compile("非目标|non-goals?", re.I)
LANE_ITEMS = [("work line", re.compile("工作线|work line", re.I)),
              ("independence", re.compile("独立|independen", re.I)),
              ("verification machine", re.compile("验证|verif", re.I)),
              ("merge protocol", re.compile("汇合|合入|merge", re.I))]

out = []


def emit(level, item, detail):
    out.append((level, item, detail))


def read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except (FileNotFoundError, IsADirectoryError):
        return None


def rel(path):
    root = E.get("PROJECT_DIR", "")
    return path[len(root) + 1:] if root and path.startswith(root + "/") else path


def headings(text):
    """[(line index, level, title)] of the markdown headings outside code fences."""
    res, fence = [], False
    for i, line in enumerate(text.split("\n")):
        if line.lstrip().startswith("```"):
            fence = not fence
            continue
        m = None if fence else re.match(r"^(#{1,6})\s+(.*)$", line)
        if m:
            res.append((i, len(m.group(1)), m.group(2).strip()))
    return res


def sections(text, pattern):
    """[(title, body)] of every heading below the document title (level 2 and deeper) matching pattern; a
    body runs to the next heading of the same or a higher level. The title (`# …`) names the whole file
    (`# plan — L1-L4`) and is never a section of its own."""
    lines = text.split("\n")
    hs = headings(text)
    res = []
    for k, (i, level, title) in enumerate(hs):
        if level > 1 and pattern.search(title):
            end = next((j for j, lv, _ in hs[k + 1:] if lv <= level), len(lines))
            res.append((title, "\n".join(lines[i + 1:end])))
    return res


def section(text, pattern):
    found = sections(text, pattern)
    return found[0] if found else None


def section_titles(text):
    return [t for _, level, t in headings(text) if level > 1]


def cells(line):
    parts = [c.strip() for c in re.split(r"(?<!\\)\|", line.strip())]
    if parts and parts[0] == "":
        parts = parts[1:]
    if parts and parts[-1] == "":
        parts = parts[:-1]
    return parts


def conf_list(key, default, sep=","):
    v = E.get(key, "").strip()
    return [x.strip() for x in v.split(sep) if x.strip()] if v else default


# ── ① vision ────────────────────────────────────────────────────────────
def step_vision():
    path = E["ONBOARD_VISION_FILE"]
    text = read(path)
    if text is None:
        return emit("FAIL", "step.1", f"vision: no file at {rel(path)} (ROTATION_VISION_FILE)")
    titles = [t for _, _, t in headings(text)]
    missing = [name for name, rx in (("定位 / Positioning", POSITION_RE), ("非目标 / Non-goals", NONGOAL_RE))
               if not any(rx.search(t) for t in titles)]
    if missing:
        return emit("FAIL", "step.1", f"vision: {rel(path)} has no section {' and no section '.join(missing)}")
    emit("PASS", "step.1", f"vision: {rel(path)} has a positioning and a non-goals section")


# ── ② roadmap L1 and version boundary L2 ────────────────────────────────
def step_roadmap(text, path):
    if text is None:
        return emit("FAIL", "step.2", f"roadmap: no plan file at {rel(path)} (ROTATION_PLAN_FILE)")
    titles = section_titles(text)
    missing = [name for name, rx in (("L1 roadmap", L1_RE), ("L2 version scope", L2_RE))
               if not any(rx.search(t) for t in titles)]
    if missing:
        return emit("FAIL", "step.2", f"roadmap: {rel(path)} has no heading for {', '.join(missing)}")
    emit("PASS", "step.2", f"roadmap: {rel(path)} has the L1 roadmap and the L2 version scope sections")


# ── ③ the lane queue table ──────────────────────────────────────────────
def queue_check(text, path):
    """(level, detail) for the queue table; level None when the plan file is missing."""
    if text is None:
        return None, f"no plan file at {rel(path)} (ROTATION_PLAN_FILE)"
    header = conf_list("ROTATION_QUEUE_HEADER", ZH_HEADER, "|")
    accepted = [header, EN_HEADER]
    if len(header) != 9:
        return "FAIL", f"ROTATION_QUEUE_HEADER names {len(header)} columns, want 9 (lane, id, state, summary, source, registered, acceptance, blocked_by, done)"
    states = conf_list("ROTATION_QUEUE_STATES", ZH_STATES + EN_STATES)
    lines = text.split("\n")
    start = next((i for i, l in enumerate(lines) if l.lstrip().startswith("|") and cells(l) in accepted), None)
    if start is None:
        return "FAIL", f"{rel(path)} has no queue table with the header | {' | '.join(header)} | (or | {' | '.join(EN_HEADER)} |)"
    rows, bad = 0, []
    for n, line in enumerate(lines[start + 1:], start + 2):
        if not line.lstrip().startswith("|"):
            break
        c = cells(line)
        if c and all(re.fullmatch(r":?-+:?", x) for x in c):
            continue
        rows += 1
        if len(c) != 9:
            bad.append(f"line {n}: {len(c)} columns")
            continue
        rid = c[1].strip("`[]")
        if not ID_RE.fullmatch(rid):
            bad.append(f"line {n}: id '{c[1]}' is not <prefix>-<name>")
        if c[2] not in states:
            bad.append(f"line {n} {rid}: state '{c[2]}' not one of {'/'.join(states)}")
        if c[6] in EMPTY_CELL:
            bad.append(f"line {n} {rid}: acceptance empty")
    if rows == 0:
        return "FAIL", f"{rel(path)}:{start + 1}: the queue table has no rows"
    if bad:
        more = f" (+{len(bad) - 5} more)" if len(bad) > 5 else ""
        return "FAIL", f"{rel(path)}:{start + 1}: {len(bad)} bad row(s) of {rows}: {'; '.join(bad[:5])}{more}"
    return "PASS", f"{rel(path)}:{start + 1}: {rows} rows, ids <prefix>-<name>, states legal, acceptance filled"


# ── ④ L3a / L3b ─────────────────────────────────────────────────────────
def step_queues(text, path):
    if text is None:
        return emit("FAIL", "step.4", f"queues: no plan file at {rel(path)}")
    titles = section_titles(text)
    missing = [name for name, rx in (("L3a hot queue", L3A_RE), ("L3b cold queue", L3B_RE))
               if not any(rx.search(t) for t in titles)]
    if missing:
        return emit("FAIL", "step.4", f"queues: {rel(path)} has no heading for {', '.join(missing)}")
    emit("PASS", "step.4", f"queues: {rel(path)} has the L3a hot and the L3b cold queue sections")


# ── ⑤ L4 trigger predicates ─────────────────────────────────────────────
def l4_check(text, path):
    if text is None:
        return None, f"no plan file at {rel(path)}"
    sec = section(text, L4_RE)
    if sec is None:
        return "FAIL", f"{rel(path)} has no L4 trigger predicate section (a heading with L4 / 触发谓词 / trigger predicate)"
    title, body = sec
    if not body.strip():
        return "FAIL", f"{rel(path)} § {title}: empty"
    hits = [l.strip() for l in body.split("\n") if PERCENT_RE.search(l)]
    if hits:
        return "FAIL", f"{rel(path)} § {title}: {len(hits)} line(s) with a percentage threshold — a trigger is a hard fact, not a %: {hits[0][:80]}"
    return "PASS", f"{rel(path)} § {title}: hand-written predicates, no percentage"


# ── ⑥ stamps and the rules table ────────────────────────────────────────
def step_stamps():
    stamps = E.get("ROTATION_STAMPS", "").split()
    if not stamps:
        return emit("FAIL", "step.6", "stamps: ROTATION_STAMPS is empty")
    stamp_dir = E.get("ROTATION_STAMP_DIR", "")
    known = set(stamps) | ({E["ROTATION_AXIS_STAMP"]} if E.get("ROTATION_AXIS_STAMP") else set())
    rules_path = E.get("ROTATION_CLOSE_RULES", "")
    rules = read(rules_path) if rules_path else None
    if rules is None:
        return emit("FAIL", "step.6", f"stamps: no close rules table at {rules_path or '(ROTATION_CLOSE_RULES unset)'}")
    unknown = []
    for n, line in enumerate(rules.split("\n"), 1):
        if not line.strip() or line.startswith("#"):
            continue
        c = line.split("\t")
        if len(c) < 4:
            unknown.append(f"line {n}: {len(c)} columns")
            continue
        name = c[3].strip().partition(":")[0]
        if name not in ("-", "") and name not in known:
            unknown.append(f"line {n} {c[0]}: stamp '{name}'")
    if unknown:
        return emit("FAIL", "step.6", f"stamps: rules rows whose stamp is not in ROTATION_STAMPS ({' '.join(stamps)}): {'; '.join(unknown[:5])}")
    absent = [s for s in stamps if not (stamp_dir and os.path.isfile(os.path.join(stamp_dir, f"{s}-latest.json")))]
    if absent:
        return emit("WARN", "step.6", f"stamps: no {', '.join(s + '-latest.json' for s in absent)} in {stamp_dir or '(ROTATION_STAMP_DIR unset)'} yet (expected before the first round); rules rows name only listed stamps")
    emit("PASS", "step.6", f"stamps: {' '.join(stamps)} present in {stamp_dir}; rules rows name only listed stamps")


# ── ⑦ the handoff's trigger section ─────────────────────────────────────
def handoff_check():
    path = E["ONBOARD_HANDOFF_FILE"]
    text = read(path)
    if text is None or not text.strip():
        return None, f"{rel(path)} {'missing' if text is None else 'empty'}"
    sec = E.get("ONBOARD_TRIGGER_SECTION_TEXT", "")
    heading = E.get("ONBOARD_TRIGGER_SECTION_RE", "rotate-trigger")
    if not sec.strip() and not re.search(r"^## .*(" + heading + ")", text, re.M):
        return "FAIL", f"{rel(path)} has no `## ` heading matching /{heading}/ (ROTATION_TRIGGER_SECTION)"
    missing = [k for k in ("axis:", "closed:", "gate:") if not re.search(r"^\s*" + k, sec, re.M)]
    if missing:
        return "FAIL", f"{rel(path)} trigger section lacks {' '.join(missing)}"
    return "PASS", f"{rel(path)} has the trigger section (/{heading}/) with axis: closed: gate:"


# ── ⑧ the lanes ─────────────────────────────────────────────────────────
def step_lanes(required):
    lanes = [x for x in E.get("ONBOARD_LANES", "").split() if x]
    if not lanes:
        if required:
            return emit("FAIL", "step.8", "lanes: --lane given but no lane is wired")
        return emit("PASS", "step.8", "lanes: no .claude/rotation-lanes/ — single lane, nothing to describe")
    path = E["ONBOARD_LANES_DOC"]
    text = read(path)
    if text is None:
        return emit("FAIL", "step.8", f"lanes: no lanes description at {rel(path)} (ROTATION_LANES_DOC)")
    bad = []
    for lane in lanes:
        found = sections(text, re.compile(r"(?<![A-Za-z0-9-])" + re.escape(lane) + r"(?![A-Za-z0-9-])", re.I))
        if not found:
            bad.append(f"{lane}: no section")
            continue
        # any heading naming the lane may be its description; the first one that covers the four items counts
        gaps = [(title, [name for name, rx in LANE_ITEMS if not rx.search(body)]) for title, body in found]
        if all(missing for _, missing in gaps):
            title, missing = gaps[0]
            bad.append(f"{lane}: § {title} lacks {', '.join(missing)}")
    if bad:
        return emit("FAIL", "step.8", f"lanes: {rel(path)}: {'; '.join(bad)}")
    emit("PASS", "step.8", f"lanes: {rel(path)} describes {', '.join(lanes)} (work line, independence, verification machine, merge protocol)")


def main(argv):
    mode = argv[0] if argv else ""
    plan_path = E["ONBOARD_PLAN_FILE"]
    plan = read(plan_path)
    if mode == "onboard":
        step_vision()
        step_roadmap(plan, plan_path)
        level, detail = queue_check(plan, plan_path)
        emit(level or "FAIL", "step.3", "queue: " + detail)
        step_queues(plan, plan_path)
        level, detail = l4_check(plan, plan_path)
        emit(level or "FAIL", "step.5", "L4: " + detail)
        step_stamps()
        level, detail = handoff_check()
        emit(level or "FAIL", "step.7", "handoff: " + detail)
        step_lanes("--lane-required" in argv)
    elif mode == "doctor":
        # a project wired before the onboarding existed may have no plan file or handoff yet: WARN, not FAIL;
        # one that has them must keep them in shape
        for item, (level, detail) in (("plan.queue", queue_check(plan, plan_path)), ("plan.l4", l4_check(plan, plan_path)),
                                      ("plan.handoff", handoff_check())):
            emit(level or "WARN", item, detail + (" (onboard_check.sh)" if level is None else ""))
    else:
        print("usage: onboard_lib.py onboard [--lane-required] | doctor", file=sys.stderr)
        return 2
    for level, item, detail in out:
        print(f"{level} {item} {detail}")
    return 1 if any(level == "FAIL" for level, _, _ in out) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
