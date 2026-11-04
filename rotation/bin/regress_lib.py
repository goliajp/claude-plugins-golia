"""rotation kernel — the `regress` column of the rules table: which ops exist, what parameters each takes, and
the per-entry judgement of `each-up`. `downSameSet` is judged in caseset_lib.py."""
import math
import statistics

import caseset_lib


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


REGRESS_OPS = ("down", "up", "nonzero", "each-up", "notice", "downSameSet")


def regress_spec_error(spec):
    """why a `regress` cell entry cannot be judged (None when it can): an unknown op judges nothing, silently"""
    key, _, op = spec.lstrip("~").partition(":")
    name, *params = op.split(":")
    if not key or name not in REGRESS_OPS:
        return f"want <key>:{'|'.join(REGRESS_OPS)}"
    if name == "notice":
        return "notice takes at most one label" if len(params) > 1 or spec.startswith("~") else None
    if name == "downSameSet":
        return caseset_lib.spec_error(params)
    if name != "each-up":
        return "takes no parameters" if params else None
    if not 1 <= len(params) <= 3 or any(num(x) is None or num(x) < 0 for x in params):
        return "each-up takes <rel>[:<k>[:<ceiling>]], non-negative numbers"
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
