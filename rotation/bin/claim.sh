#!/usr/bin/env bash
#
# rotation kernel — who is changing what: path claims shared by every lane of the project, so two lanes do not
# fix the same file twice or change one name two ways without the manager hearing of it first.
#
# usage: claim.sh add <glob> [--reason TEXT]
#        claim.sh drop [<glob>] [--rid RID] [--reason TEXT]
#        claim.sh list [<glob>] [--json]
#
# The claims live in one file for all lanes, <.claude>/rotation-state/claims.jsonl (ROTATION_STATE_DIR when set),
# append-only: each line is {"kind":"claim.add"|"claim.drop","lane","rid","glob","reason","ts","at"}. lane is
# ROTATION_LANE, else the first lane's ROTATION_LANE_NAME, else `main`; rid is the lane's round in progress.
# The claims in force are derived: an add of (lane, glob) is in force until a later drop of the same (lane, glob).
#
#   add    records claim.add. When a claim in force of another lane overlaps the glob, every such claim is printed
#          as `CONFLICT lane=… glob=… reason=… since=…` and the exit is 3 — the claim is recorded all the same: the
#          manager orders the two lanes, the tool does not refuse the work
#   drop   with a glob: records claim.drop for this lane's claim of it (exit 1 when none is in force). Without one:
#          drops every claim in force this lane made in round --rid (default the round in progress)
#   list   the claims in force, one line each (`<lane> <glob> rid=… since=… reason=…`), then `claims: <n>`;
#          with a glob only those overlapping it. --json: a list of {lane, rid, glob, reason, ts, at}
#
# Overlap: two globs overlap when they are equal, or when either, read as an fnmatch pattern, matches the other
# read as a literal string (`*` matches across `/`). crates/a/* and crates/a/src/x.rs overlap; crates/a/*.rs and
# crates/*/x.rs do not, although a path could match both — claim a directory, not a pattern of patterns.
#
# exit: 0 · 1 (drop) no such claim in force · 2 usage · 3 (add) recorded, and it overlaps another lane's claim

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

usage() {
  echo "usage: claim.sh add <glob> [--reason TEXT] · drop [<glob>] [--rid RID] [--reason TEXT] · list [<glob>] [--json]" >&2
  exit 2
}
[ "$#" -ge 1 ] || usage
VERB=$1
shift
case "$VERB" in add|drop|list) ;; *) usage ;; esac
GLOB=""; REASON=""; RID=""; JSON=0; HAVE_GLOB=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --reason|--rid)
      [ "$#" -ge 2 ] || usage
      case "$1" in --reason) REASON=$2 ;; --rid) RID=$2 ;; esac
      shift 2 ;;
    --json) JSON=1; shift ;;
    -*) usage ;;
    *) [ "$HAVE_GLOB" -eq 0 ] || usage; GLOB=$1; HAVE_GLOB=1; shift ;;
  esac
done
case "$VERB" in
  add) [ -n "$GLOB" ] && [ -z "$RID" ] && [ "$JSON" -eq 0 ] || usage ;;
  drop) [ "$JSON" -eq 0 ] || usage; [ -z "$RID" ] || [ "$HAVE_GLOB" -eq 0 ] || usage ;;
  list) [ -z "$REASON" ] && [ -z "$RID" ] || usage ;;
esac
case "$GLOB" in *"
"*) echo "claim.sh: a glob is one line" >&2; exit 2 ;; esac
[ "$HAVE_GLOB" -eq 0 ] || [ -n "$GLOB" ] || usage

LANE_NAME="${ROTATION_LANE:-${ROTATION_LANE_NAME:-main}}"
[ "$VERB" = list ] || [ -n "$RID" ] || RID=$(autorun_current_rotation_id)
mkdir -p "$(dirname "$CLAIMS_FILE")"

python3 - "$CLAIMS_FILE" "$VERB" "$LANE_NAME" "$RID" "$GLOB" "$HAVE_GLOB" "$REASON" "$JSON" <<'PY'
import datetime, fnmatch, json, sys, time
path, verb, lane, rid, glob, have_glob, reason, as_json = sys.argv[1:9]
have_glob = have_glob == '1'


def rows():
    try:
        with open(path, encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    yield json.loads(line)
                except json.JSONDecodeError:
                    pass
    except FileNotFoundError:
        return


def in_force():
    live = {}
    for r in rows():
        key = (r.get('lane'), r.get('glob'))
        if r.get('kind') == 'claim.add':
            live[key] = r
        elif r.get('kind') == 'claim.drop':
            live.pop(key, None)
    return sorted(live.values(), key=lambda r: r.get('ts') or 0)


def overlap(a, b):
    return a == b or fnmatch.fnmatchcase(a, b) or fnmatch.fnmatchcase(b, a)


def append(kind, g, why, r):
    now = int(time.time())
    row = {'kind': kind, 'lane': lane, 'rid': r or None, 'glob': g, 'reason': why,
           'ts': now, 'at': datetime.datetime.fromtimestamp(now, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}
    with open(path, 'a', encoding='utf-8') as f:
        f.write(json.dumps(row, ensure_ascii=False, separators=(',', ':')) + '\n')


def line(c):
    return f"{c['lane']} {c['glob']} rid={c.get('rid') or '-'} since={c.get('at') or '-'} reason={c.get('reason') or '-'}"


live = in_force()
if verb == 'list':
    shown = [c for c in live if not have_glob or overlap(c['glob'], glob)]
    if as_json == '1':
        print(json.dumps([{k: c.get(k) for k in ('lane', 'rid', 'glob', 'reason', 'ts', 'at')} for c in shown], ensure_ascii=False))
    else:
        for c in shown:
            print(line(c))
        print(f"claims: {len(shown)}")
    sys.exit(0)

if verb == 'add':
    clash = [c for c in live if c['lane'] != lane and overlap(c['glob'], glob)]
    append('claim.add', glob, reason, rid)
    print(f"claim.sh: {lane} claims {glob} (round {rid or '-'})")
    for c in clash:
        print(f"CONFLICT lane={c['lane']} glob={c['glob']} reason={c.get('reason') or '-'} since={c.get('at') or '-'}")
    if clash:
        print(f"claim.sh: {len(clash)} claim(s) of another lane overlap {glob}: recorded, for the manager to order", file=sys.stderr)
        sys.exit(3)
    sys.exit(0)

mine = [c for c in live if c['lane'] == lane]
targets = [c for c in mine if c['glob'] == glob] if have_glob else [c for c in mine if (c.get('rid') or '') == rid]
if have_glob and not targets:
    print(f"claim.sh: {lane} has no claim of {glob} in force", file=sys.stderr)
    sys.exit(1)
for c in targets:
    append('claim.drop', c['glob'], reason, rid or c.get('rid'))
print(f"claim.sh: {lane} dropped {len(targets)} claim(s)" + ('' if have_glob else f" of round {rid or '-'}"))
PY
