#!/usr/bin/env bash
#
# rotation kernel — wire this plugin into the project of the current
# working directory (the `/rotation:init` command runs this).
#
# Writes, under the project's git top level:
#   .claude/rotation/kernel.path      the plugin root (where bin/ is); the shims read it, and the
#                                     SessionStart hook rewrites it at every session start
#   .claude/rotation/<script>         two-line shims for every kernel entry point, so documents,
#                                     adapter scripts and people can keep calling
#                                     `.claude/rotation/<script>` whatever version of the plugin is
#                                     installed; `lib.sh` is a one-line source shim for adapter
#                                     scripts that source the kernel's helpers
#   .claude/rotation/project.sh       from templates/project.sh.example   — only when absent
#   .claude/rotation/rotation.conf    from templates/rotation.conf.example — only when absent
#   .claude/rotation/close_rules.tsv  from templates/close_rules.tsv.example — only when absent
#   .claude/rotation-state/           the state directory (rotations.jsonl, events.jsonl, …)
#
# The three copied files are the project's to edit; an existing one is never
# touched (--force replaces the shims and kernel.path only, never those three).
# Everything written sits under .claude/, which the project keeps out of git.
#
# usage: init.sh [--force]
# exit: 0 written · 1 not inside a git work tree · 2 usage

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

FORCE=0
case "${1:-}" in
  '') ;;
  --force) FORCE=1 ;;
  *) echo "usage: init.sh [--force]" >&2; exit 2 ;;
esac

PROJECT_DIR=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "init: not inside a git work tree (run from the project)" >&2
  exit 1
}
DEST="$PROJECT_DIR/.claude/rotation"
STATE="$PROJECT_DIR/.claude/rotation-state"
mkdir -p "$DEST" "$STATE"

# the entry points a project calls by name; hooks and this script need no shim
SHIMS="trigger.sh trig_gate.sh check.sh close_plan.sh close_verdict_fill.sh carry_stamp.sh recover.sh watchdog.sh
event.sh agent_log.sh manager_log.sh report_save.sh adapter_run.sh doctor.sh stats.sh log.sh kill_stray_shells.sh"

printf '%s\n' "$PLUGIN_ROOT" > "$DEST/kernel.path"
echo "init: kernel.path → $PLUGIN_ROOT"

written=0
for s in $SHIMS; do
  if [ -e "$DEST/$s" ] && [ "$FORCE" -eq 0 ] && ! grep -q 'kernel.path' "$DEST/$s" 2>/dev/null; then
    echo "init: $DEST/$s exists and is not a shim; left alone (--force replaces it)"
    continue
  fi
  printf '#!/usr/bin/env bash\nexec "$(cat "$(dirname "$0")/kernel.path")/bin/%s" "$@"\n' "$s" > "$DEST/$s"
  chmod +x "$DEST/$s"
  written=$((written + 1))
done
# lib.sh is sourced, not executed: the shim sources the kernel's copy
if [ -e "$DEST/lib.sh" ] && [ "$FORCE" -eq 0 ] && ! grep -q 'kernel.path' "$DEST/lib.sh" 2>/dev/null; then
  echo "init: $DEST/lib.sh exists and is not a shim; left alone (--force replaces it)"
else
  printf '. "$(cat "$(dirname "${BASH_SOURCE[0]}")/kernel.path")/bin/lib.sh"\n' > "$DEST/lib.sh"
  written=$((written + 1))
fi
echo "init: $written shims in $DEST"

for t in project.sh rotation.conf close_rules.tsv; do
  if [ -e "$DEST/$t" ]; then
    echo "init: $DEST/$t kept (the project's)"
  else
    cp "$PLUGIN_ROOT/templates/$t.example" "$DEST/$t"
    echo "init: $DEST/$t written from the template — edit it"
  fi
done
echo "init: state directory $STATE"
echo
echo "next: edit $DEST/project.sh and $DEST/rotation.conf, write the adapter commands they name,"
echo "      then run: bash .claude/rotation/doctor.sh   (last line must be DOCTOR PASS)"
exit 0
