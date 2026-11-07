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
#   remote.end        remote.log= (or remote.kind= + remote.sha=)  [remote.status=ok|fail|abandoned|timeout remote.rc=int:]
#                     remote.rc 75 or 124 (a wait that ran out, `timeout`'s code) with remote.status=ok is not
#                     recorded as ok: the status is written as timeout and a line on stderr says so
#   executor.waiting  remote.log= remote.marker= [remote.host=]   or   workers=list:<name>,<name>
#                     and/or waiting.window=<name>: held while that window is open (window.sh)
#   window.open / window.extend   window.name= window.until=int:<epoch> window.untilAt=<ISO> [window.host= window.reason=]
#   window.close      window.name= [window.reason=]          — window.sh writes these three; call it, not this
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
# With ROTATION_LANE unset, a call from inside a lane's tree is refused (autorun_lane_of_cwd: under
# .claude/lanes/<lane>/, or a worktree on a lane's branch): there the first lane's log is what the links resolve
# to, and the event would land in the wrong lane's chain. The lane's shim sets ROTATION_LANE.
#
# exit: 0 recorded · 2 usage, a required key missing, or a lane's tree without ROTATION_LANE

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
. "$SCRIPT_DIR/lane_lib.sh"

[ "$#" -ge 1 ] || { echo "usage: event.sh <kind> [key=value ...]" >&2; exit 2; }
if [ -z "$ROTATION_LANE" ]; then
  in_lane=$(autorun_lane_of_cwd)
  if [ -n "$in_lane" ]; then
    echo "event.sh: $PWD is lane $in_lane's tree and ROTATION_LANE is unset — run it through the lane's shim .claude/rotation-lanes/$in_lane/event.sh" >&2
    exit 2
  fi
fi
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
waiting = doc.get('waiting') if isinstance(doc.get('waiting'), dict) else {}
if kind == 'remote.end' and remote.get('status') == 'ok' and str(remote.get('rc')).strip() in ('75', '124'):
    print(f"event.sh: remote.end with remote.rc={remote['rc']} is a timeout, not ok; recorded as remote.status=timeout", file=sys.stderr)
    remote['status'] = 'timeout'
if kind == 'executor.waiting' and not ((remote.get('log') and remote.get('marker')) or doc.get('workers') or waiting.get('window')):
    fail('executor.waiting needs remote.log= and remote.marker=, or workers=list:<names>, or waiting.window=<name>')
if kind.startswith('window.'):
    win = doc.get('window') if isinstance(doc.get('window'), dict) else {}
    if kind not in ('window.open', 'window.extend', 'window.close'):
        fail(f"unknown window kind '{kind}'")
    if not win.get('name'):
        fail(f'{kind} needs window.name=')
    if kind != 'window.close' and (not isinstance(win.get('until'), int) or isinstance(win.get('until'), bool)):
        fail(f'{kind} needs window.until=int:<epoch>')
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
