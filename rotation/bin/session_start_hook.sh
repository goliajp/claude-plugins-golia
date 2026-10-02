#!/usr/bin/env bash
# SessionStart hook (matchers: startup and resume). Every start records
# where the kernel is: the plugin root goes into the project's
# .claude/rotation/kernel.path, which the shims read, so a plugin update
# (a new versioned install path) is picked up by the next session without
# anyone editing a file. A session resumed while a rotation is being
# managed also gets the recovery page; every other start prints nothing.
# The marker is written when a rotation executor is started and removed
# when the manager goes idle on purpose.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"
input=$(cat)
# only a project that adopted the kernel (init.sh ran) gets a kernel.path
if [ -d "$PROJECT_ROTATION_DIR" ]; then
  printf '%s\n' "${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}" > "$PROJECT_ROTATION_DIR/kernel.path"
fi
source=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1] or "{}").get("source") or "")' "$input" 2>/dev/null)
[ "$source" = resume ] || exit 0
[ -f "$MANAGER_ACTIVE_FILE" ] || exit 0
echo "== rotation manager was active when this session was last running ($(cat "$MANAGER_ACTIVE_FILE")) =="
bash "$SCRIPT_DIR/recover.sh" 2>&1
echo "== act on the last line above; re-arm watchdog.sh (run_in_background) once the executor is running =="
exit 0
