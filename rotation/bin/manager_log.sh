#!/usr/bin/env bash
#
# The manager session's own events in events.jsonl: when it started managing,
# which executor it spawned or continued, how the report verification went,
# and when it stopped. Every event carries managerSession = the caller's
# CLAUDE_CODE_SESSION_ID (null when unset): a subagent can be continued by
# SendMessage only from the session that spawned it, and recover.sh compares
# this id with the one the executor was registered under before offering RESUME.
# The watchdog takes `resume` as the executor having been dealt with (QUOTA /
# WAKE no longer fire for the event the resume answered).
#
# usage:
#   manager_log.sh start                                    manager.start
#   manager_log.sh spawn  <agentId> [<name>]                manager.spawn   manager.agent={id,name}
#   manager_log.sh resume <agentId> <quota|restart|wake> [<name>]
#                                                           manager.resume  manager.agent={id,name} manager.reason
#   manager_log.sh verify <n>=pass|fail ...                 manager.verify  manager.checks={"<n>":…} manager.result
#   manager_log.sh stop   [<reason>]                        manager.stop    manager.reason
#
# exit: 0 recorded · 2 usage

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
  echo "usage: manager_log.sh start | spawn <agentId> [<name>] | resume <agentId> <quota|restart|wake> [<name>] | verify <n>=pass|fail ... | stop [<reason>]" >&2
  exit 2
}
[ "$#" -ge 1 ] || usage
VERB=$1
shift

session="managerSession=raw:$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1] or None))' "${CLAUDE_CODE_SESSION_ID:-}")"
agent_json() {
  python3 -c 'import json,sys; d={"id": sys.argv[1]}; sys.argv[2] and d.update(name=sys.argv[2]); print(json.dumps(d))' "$1" "${2:-}"
}

case "$VERB" in
  start)
    [ "$#" -eq 0 ] || usage
    exec bash "$SCRIPT_DIR/event.sh" manager.start "$session" ;;
  spawn)
    [ "$#" -ge 1 ] && [ "$#" -le 2 ] && [ -n "$1" ] || usage
    exec bash "$SCRIPT_DIR/event.sh" manager.spawn "$session" "manager.agent=raw:$(agent_json "$1" "${2:-}")" ;;
  resume)
    [ "$#" -ge 2 ] && [ "$#" -le 3 ] && [ -n "$1" ] || usage
    case "$2" in quota|restart|wake) ;; *) usage ;; esac
    exec bash "$SCRIPT_DIR/event.sh" manager.resume "$session" "manager.agent=raw:$(agent_json "$1" "${3:-}")" "manager.reason=$2" ;;
  verify)
    [ "$#" -ge 1 ] || usage
    checks=$(python3 - "$@" <<'PY'
import json, re, sys
checks = {}
for arg in sys.argv[1:]:
    m = re.fullmatch(r'([A-Za-z0-9_-]+)=(pass|fail)', arg)
    if not m:
        print(f"manager_log.sh: verify takes <n>=pass|fail, got '{arg}'", file=sys.stderr)
        raise SystemExit(2)
    checks[m.group(1)] = m.group(2)
failed = [k for k, v in checks.items() if v == 'fail']
print(json.dumps(checks))
print('fail' if failed else 'pass')
print(json.dumps(failed))
PY
    ) || exit 2
    exec bash "$SCRIPT_DIR/event.sh" manager.verify "$session" \
      "manager.checks=raw:$(printf '%s\n' "$checks" | sed -n 1p)" \
      "manager.result=$(printf '%s\n' "$checks" | sed -n 2p)" \
      "manager.failed=raw:$(printf '%s\n' "$checks" | sed -n 3p)" ;;
  stop)
    [ "$#" -le 1 ] || usage
    if [ -n "${1:-}" ]; then
      exec bash "$SCRIPT_DIR/event.sh" manager.stop "$session" "manager.reason=$1"
    fi
    exec bash "$SCRIPT_DIR/event.sh" manager.stop "$session" ;;
  *) usage ;;
esac
