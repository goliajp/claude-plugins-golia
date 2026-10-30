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
# A lane (`init.sh --lane <name>`, docs/lanes.md) is a second instance of the
# protocol in the same project, run by its own executor on its own branch:
#   .claude/rotation-lanes/<name>/<script>        shims that export ROTATION_LANE=<name>
#   .claude/rotation-lanes/<name>/project.sh      copied from the main lane's (or the template) — only when absent
#   .claude/rotation-lanes/<name>/rotation.conf   same
#   .claude/rotation-lanes/<name>/close_rules.tsv same
#   .claude/rotation-lanes/<name>/handoff.md      the lane's handoff, empty until its first round
#   .claude/rotation-state/lanes/<name>/          the lane's state
# The main lane must be wired first (its kernel.path is the one the lane's
# shims read); nothing of the main lane is touched.
#
# usage: init.sh [--force] | init.sh --lane <name> [--force]
# exit: 0 written · 1 not inside a git work tree / main lane not wired · 2 usage

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

FORCE=0
LANE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --lane) [ "$#" -ge 2 ] || { echo "usage: init.sh [--force] | init.sh --lane <name> [--force]" >&2; exit 2; }; LANE=$2; shift 2 ;;
    *) echo "usage: init.sh [--force] | init.sh --lane <name> [--force]" >&2; exit 2 ;;
  esac
done
case "$LANE" in ''|[a-z0-9-]*) ;; esac
case "$LANE" in *[!a-z0-9-]*) echo "init: lane must match [a-z0-9-]+, got '$LANE'" >&2; exit 2 ;; esac

PROJECT_DIR=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "init: not inside a git work tree (run from the project)" >&2
  exit 1
}
MAIN_DEST="$PROJECT_DIR/.claude/rotation"
if [ -n "$LANE" ]; then
  [ -f "$MAIN_DEST/kernel.path" ] || { echo "init: wire the main lane first (no $MAIN_DEST/kernel.path)" >&2; exit 1; }
  DEST="$PROJECT_DIR/.claude/rotation-lanes/$LANE"
  STATE="$PROJECT_DIR/.claude/rotation-state/lanes/$LANE"
  # the shims of a lane: root three levels up, kernel.path the main lane's, the lane exported
  ROOT_UP='../../..'
  KPATH='$d/../../rotation/kernel.path'
  LANE_EXPORT="export ROTATION_LANE=$LANE\n"
else
  DEST="$MAIN_DEST"
  STATE="$PROJECT_DIR/.claude/rotation-state"
  ROOT_UP='../..'
  KPATH='$d/kernel.path'
  LANE_EXPORT=""
fi
mkdir -p "$DEST" "$STATE"

# the entry points a project calls by name; hooks and this script need no shim
SHIMS="trigger.sh trig_gate.sh check.sh close_plan.sh close_verdict_fill.sh carry_stamp.sh recover.sh watchdog.sh
event.sh agent_log.sh manager_log.sh report_save.sh adapter_run.sh remote_run.sh doctor.sh stats.sh log.sh kill_stray_shells.sh"

if [ -z "$LANE" ]; then
  printf '%s\n' "$PLUGIN_ROOT" > "$DEST/kernel.path"
  echo "init: kernel.path → $PLUGIN_ROOT"
else
  echo "init: lane $LANE reads the main lane's kernel.path ($(cat "$MAIN_DEST/kernel.path"))"
fi

written=0
for s in $SHIMS; do
  if [ -e "$DEST/$s" ] && [ "$FORCE" -eq 0 ] && ! grep -q 'kernel.path' "$DEST/$s" 2>/dev/null; then
    echo "init: $DEST/$s exists and is not a shim; left alone (--force replaces it)"
    continue
  fi
  printf '#!/usr/bin/env bash\n# the project root is where this shim lives, not the caller'"'"'s git top level\n# (a worker'"'"'s worktree inside the project is a different top level)\nd="$(cd "$(dirname "$0")" && pwd)"\n: "${ROTATION_PROJECT_DIR:=$(cd "$d/%s" && pwd)}"\nexport ROTATION_PROJECT_DIR\n'"$LANE_EXPORT"'exec "$(cat "%s")/bin/%s" "$@"\n' "$ROOT_UP" "$KPATH" "$s" > "$DEST/$s"
  chmod +x "$DEST/$s"
  written=$((written + 1))
done
# lib.sh is sourced, not executed: the shim sources the kernel's copy
if [ -e "$DEST/lib.sh" ] && [ "$FORCE" -eq 0 ] && ! grep -q 'kernel.path' "$DEST/lib.sh" 2>/dev/null; then
  echo "init: $DEST/lib.sh exists and is not a shim; left alone (--force replaces it)"
else
  printf '_rotation_shim_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n: "${ROTATION_PROJECT_DIR:=$(cd "$_rotation_shim_dir/%s" && pwd)}"\nexport ROTATION_PROJECT_DIR\n'"$LANE_EXPORT"'. "$(cat "%s")/bin/lib.sh"\n' "$ROOT_UP" "${KPATH//\$d/\$_rotation_shim_dir}" > "$DEST/lib.sh"
  written=$((written + 1))
fi
echo "init: $written shims in $DEST"

for t in project.sh rotation.conf close_rules.tsv; do
  if [ -e "$DEST/$t" ]; then
    echo "init: $DEST/$t kept (the project's)"
  elif [ -n "$LANE" ] && [ -f "$MAIN_DEST/$t" ]; then
    cp "$MAIN_DEST/$t" "$DEST/$t"
    echo "init: $DEST/$t copied from the main lane's — edit it for the lane"
  else
    cp "$PLUGIN_ROOT/templates/$t.example" "$DEST/$t"
    echo "init: $DEST/$t written from the template — edit it"
  fi
done
if [ -n "$LANE" ] && [ ! -e "$DEST/handoff.md" ]; then
  : > "$DEST/handoff.md"
  echo "init: $DEST/handoff.md created empty (the lane's handoff)"
fi
echo "init: state directory $STATE"
echo
echo "next: edit $DEST/project.sh and $DEST/rotation.conf, write the adapter commands they name,"
echo "      then run: bash $DEST/doctor.sh   (last line must be DOCTOR PASS)"
exit 0
