#!/usr/bin/env bash
#
# Append one event to events.jsonl. The general entry for the kinds that
# have no script of their own; recover.sh and watchdog.sh read them back.
#
# usage: event.sh <kind> [key=value ...]
#   a dotted key nests:   remote.log=/tmp/x.log  →  {"remote": {"log": "/tmp/x.log"}}
#   value prefixes:       int:<n> · list:a,b,c · raw:<json>   (anything else is a string)
#
# The kinds the recovery tools read, and what each must carry:
#   remote.start      remote.kind= remote.log=  [remote.sha= remote.marker=<regexp of the terminal line> remote.host=]
#                     [remote.pid=int: remote.pidStart= remote.launcher=int:]  — remote_run.sh adds these three
#   remote.end        remote.log= (or remote.kind= + remote.sha=)  [remote.status=ok|fail|abandoned]
#   executor.waiting  remote.log= remote.marker= [remote.host=]   or   workers=list:<name>,<name>
#   quota.hit         quota.resets=<epoch | ISO time | HH:MM local>  [quota.agent=<name or id>]
#   process.start     process.pid=int:<pid> [process.what=<label>]  — a shell this round started
#                     (`process.pid=int:$$` at the top of a background command); the trigger's
#                     reaper ends every registered pid still alive, and nothing it was not told about
#   process.end       process.pid=int:<pid>  — that shell finished on its own
#   manager.start / manager.spawn / manager.resume / manager.verify / manager.stop
#                     every one carries managerSession= (the session id, or raw:null when unknown);
#                     spawn and resume need manager.agent=raw:{"id":…[,"name":…]}; resume needs
#                     manager.reason=quota|restart|wake; verify needs manager.checks=raw:{"1":"pass",…}
#                     and manager.result=pass|fail. manager_log.sh builds these; call it, not this.
#
# exit: 0 recorded · 2 usage or a required key missing

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

[ "$#" -ge 1 ] || { echo "usage: event.sh <kind> [key=value ...]" >&2; exit 2; }
KIND=$1
shift

pairs=$(python3 - "$KIND" "$@" <<'PY'
import json, re, sys
kind, args = sys.argv[1], sys.argv[2:]
def fail(msg):
    print(f"event.sh: {msg}", file=sys.stderr)
    raise SystemExit(2)
if not re.fullmatch(r'[a-z]+(\.[a-z]+)+', kind):
    fail(f"kind must look like word.word, got '{kind}'")
doc = {}
for arg in args:
    if '=' not in arg:
        fail(f"expected key=value, got '{arg}'")
    key, v = arg.split('=', 1)
    if v.startswith('int:'):
        try:
            v = int(v[4:])
        except ValueError:
            fail(f"{key}: not an integer")
    elif v.startswith('list:'):
        v = [x for x in v[5:].split(',') if x]
    elif v.startswith('raw:'):
        try:
            v = json.loads(v[4:])
        except ValueError:
            fail(f"{key}: not valid JSON")
    node = doc
    parts = key.split('.')
    if parts[0] in ('at', 'ts', 'kind', 'rotationId', 'head') or not all(parts):
        fail(f"key '{key}' is reserved or empty")
    for p in parts[:-1]:
        node = node.setdefault(p, {})
        if not isinstance(node, dict):
            fail(f"key '{key}' nests under a value")
    node[parts[-1]] = v
remote = doc.get('remote') if isinstance(doc.get('remote'), dict) else {}
if kind == 'remote.start' and not (remote.get('kind') and remote.get('log')):
    fail('remote.start needs remote.kind= and remote.log=')
if kind == 'remote.end' and not (remote.get('log') or (remote.get('kind') and remote.get('sha'))):
    fail('remote.end needs remote.log= (or remote.kind= and remote.sha=)')
if kind == 'executor.waiting' and not ((remote.get('log') and remote.get('marker')) or doc.get('workers')):
    fail('executor.waiting needs remote.log= and remote.marker=, or workers=list:<names>')
if kind == 'quota.hit' and (not isinstance(doc.get('quota'), dict) or doc['quota'].get('resets') in (None, '')):
    fail('quota.hit needs quota.resets=')
if kind in ('process.start', 'process.end'):
    proc = doc.get('process') if isinstance(doc.get('process'), dict) else {}
    if not isinstance(proc.get('pid'), int) or isinstance(proc.get('pid'), bool) or proc['pid'] <= 0:
        fail(f'{kind} needs process.pid=int:<pid>')
if kind.startswith('manager.'):
    if kind not in ('manager.start', 'manager.spawn', 'manager.resume', 'manager.verify', 'manager.stop'):
        fail(f"unknown manager kind '{kind}'")
    if 'managerSession' not in doc:
        fail(f'{kind} needs managerSession= (the session id, or raw:null)')
    m = doc.get('manager') if isinstance(doc.get('manager'), dict) else {}
    agent = m.get('agent') if isinstance(m.get('agent'), dict) else {}
    if kind in ('manager.spawn', 'manager.resume') and not agent.get('id'):
        fail(f'{kind} needs manager.agent=raw:{{"id":…}}')
    if kind == 'manager.resume' and m.get('reason') not in ('quota', 'restart', 'wake'):
        fail('manager.resume needs manager.reason=quota|restart|wake')
    if kind == 'manager.verify' and (not isinstance(m.get('checks'), dict) or not m['checks'] or m.get('result') not in ('pass', 'fail')):
        fail('manager.verify needs manager.checks=raw:{"<n>":"pass|fail",…} and manager.result=pass|fail')
for k, v in doc.items():
    print(f"{k}=raw:{json.dumps(v, ensure_ascii=False)}")
PY
) || exit 2

args=()
while IFS= read -r line; do
  [ -n "$line" ] && args+=("$line")
done <<EOF
$pairs
EOF
autorun_record_event "$KIND" ${args[@]+"${args[@]}"}
echo "event: $KIND → $EVENTS_LOG"
