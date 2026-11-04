"""rotation kernel — `<key>:downSameSet[:<verdict>,...]`: a count judged on the cases both stamps ran.

A suite that loses cases (a fixture deleted, a port withdrawn) loses their passes with them; `down` reads that as a
regression. downSameSet compares only what both readings measured.

Where a stamp's case list comes from, first that applies:
  caseFile   a text file named by the stamp (path relative to the stamp directory, or absolute; gzip when it ends
             in .gz), one case per line: `<case>` or `<case>\t<verdict>[:<detail>]`
  cases      an inline list of case names in the stamp (membership only)
  command    ROTATION_CASESET_CMD, when the project sets one: `<cmd> <tool> <sha>` prints the same line format and
             exits 0. For stamps written before the stamp carried a list; the verdict names this source
A list is used only when it agrees with the stamp it stands for: with verdicts, the cases whose verdict is one of
the counted verdicts (the op's parameter, default the key itself) must number exactly the stamp's <key>; without,
the cases must number the stamp's `caseCount`, else its `total`, when it has either. A list that disagrees, repeats
a name or cannot be read is not used, and the verdict says why.

Rules, against the baseline stamp:
  same-set       both lists carry verdicts: red when fewer of the common cases carry a counted verdict now than
                 before (the same-set delta d < 0); a case that went from counted to not is `lost`
  removed-bound  both lists, verdicts missing on one side: red when the count fell by more than the cases removed
  fallback       no usable list on one side: the plain `down` rule
"""
import gzip
import os
import subprocess


def _parse(lines):
    """{case: verdict or None}, whether every line carries a verdict; None for the map when a name repeats"""
    names, with_v, n = {}, 0, 0
    for line in lines:
        line = line.rstrip("\n")
        if not line.strip():
            continue
        n += 1
        name, tab, rest = line.partition("\t")
        verdict = rest.split(":", 1)[0].strip() if tab else None
        with_v += verdict is not None
        names[name] = verdict
    if len(names) != n:
        return None, False
    return names, n > 0 and with_v == n


def case_list(doc, tool, stamp_dir, repo, cmd):
    """(names, has_verdicts, source) or (None, False, why): source / why are (message key, fields)"""
    f = doc.get("caseFile")
    if isinstance(f, str) and f:
        path = f if os.path.isabs(f) else os.path.join(stamp_dir, f)
        try:
            opener = gzip.open if path.endswith(".gz") else open
            with opener(path, "rt", encoding="utf-8") as fh:
                names, hv = _parse(fh)
        except OSError as e:
            return None, False, ("caseset_why_unreadable", {"err": f"{f}: {e.strerror or e}"})
        src = ("caseset_src_file", {"file": f})
    elif isinstance(doc.get("cases"), list):
        names, _ = _parse(str(x) for x in doc["cases"])
        hv = False
        src = ("caseset_src_inline", {})
    elif cmd:
        r = subprocess.run([cmd, tool, doc.get("headSha") or ""], cwd=repo, capture_output=True, text=True)
        if r.returncode != 0:
            return None, False, ("caseset_why_cmd", {"cmd": cmd, "rc": r.returncode})
        names, hv = _parse(r.stdout.splitlines())
        src = ("caseset_src_cmd", {"cmd": cmd})
    else:
        return None, False, ("caseset_why_none", {})
    if names is None:
        return None, False, ("caseset_why_repeat", {})
    return names, hv, src


def _agrees(names, hv, doc, key, counted, num):
    """None when the list stands for the stamp, else the why (message key, fields)"""
    if hv:
        n, m = sum(1 for v in names.values() if v in counted), num(doc.get(key))
        return None if m is not None and n == m else ("caseset_why_mismatch", {"n": n, "what": key, "m": m})
    t = num(doc.get("caseCount"))
    what = "caseCount"
    if t is None:
        t, what = num(doc.get("total")), "total"
    return None if t is None or len(names) == t else ("caseset_why_mismatch", {"n": len(names), "what": what, "m": t})


def judge(key, params, cur, prev, tool, stamp_dir, repo, cmd, num):
    """the downSameSet reading of one key against the baseline `prev` (not None). returns a dict: hit, mode,
    cn, pn, and per mode removed / added / delta / lost / drop, src (cur, prev) or why (side, (key, fields))"""
    counted = set(params[0].split(",")) if params else {key}
    cn, pn = num(cur.get(key)), num(prev.get(key))
    out = {"cn": cn, "pn": pn}
    sides = {}
    for side, doc in (("cur", cur), ("prev", prev)):
        names, hv, src = case_list(doc, tool, stamp_dir, repo, cmd)
        bad = src if names is None else _agrees(names, hv, doc, key, counted, num)
        if bad:
            out.update(mode="fallback", why=(side, bad), hit=cn is not None and pn is not None and cn < pn)
            return out
        sides[side] = (names, hv, src)
    (b, bv, bsrc), (a, av, asrc) = sides["cur"], sides["prev"]
    removed, added = len(a.keys() - b.keys()), len(b.keys() - a.keys())
    out.update(removed=removed, added=added, src=(bsrc, asrc))
    if av and bv:
        common = a.keys() & b.keys()
        pc = sum(1 for k in common if a[k] in counted)
        cc = sum(1 for k in common if b[k] in counted)
        lost = sum(1 for k in common if a[k] in counted and b[k] not in counted)
        out.update(mode="same-set", delta=cc - pc, lost=lost, hit=cc < pc)
    else:
        drop = (pn - cn) if cn is not None and pn is not None else 0
        out.update(mode="removed-bound", drop=drop, hit=drop > removed)
    return out
