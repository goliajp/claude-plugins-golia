# rotation kernel — helpers for the commands that span lanes (lanes.sh, the --all modes of doctor.sh,
# recover.sh and watchdog.sh) and for the lane close and merge (lane_close.sh, lane_merge.sh).
#
# Source after lib.sh:
#   . "$SCRIPT_DIR/lib.sh"; . "$SCRIPT_DIR/lane_lib.sh"

# shellcheck shell=bash

# the inbox lane_close.sh and lane_merge.sh write their rows into
INBOX_FILE="${ROTATION_INBOX_FILE:-$CLAUDE_DIR/autorun-inbox.md}"

# Every lane of the project, one per line: `<ROTATION_LANE value>|<name>`. The first lane comes first
# when it is wired (its value is empty; its name is ROTATION_LANE_NAME of its conf, else `main`), then
# each .claude/rotation-lanes/<name>/ that has a rotation.conf, in name order. (`|`, not a tab: read would
# strip a leading tab and shift the first lane's empty value away.)
autorun_lanes() {
  local d n first
  if [ -f "$CLAUDE_DIR/rotation/rotation.conf" ]; then
    first=$(sed -n 's/^[[:space:]]*ROTATION_LANE_NAME[[:space:]]*=[[:space:]]*//p' "$CLAUDE_DIR/rotation/rotation.conf" | tail -1 | tr -d '[:space:]')
    printf '|%s\n' "${first:-main}"
  fi
  for d in "$CLAUDE_DIR"/rotation-lanes/*/; do
    [ -f "$d/rotation.conf" ] || continue
    n=$(basename "$d")
    case "$n" in *[!a-z0-9-]*) continue ;; esac
    printf '%s|%s\n' "$n" "$n"
  done
}

# The lane whose tree the working directory is in, else nothing: a directory under <main tree>/.claude/lanes/<lane>/,
# or a worktree other than the main tree whose branch is the ROTATION_BASE_BRANCH a lane sets (its project.sh, or its
# rotation.conf). A lane's worktree links its .claude/ to the main tree's, so the kernel called there without the
# lane's shim resolves to the first lane's state.
autorun_lane_of_cwd() {
  local common main here top branch d n b
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  main=$(cd "$(dirname "$common")" && pwd -P)
  here=$(pwd -P)
  case "$here/" in
    "$main/.claude/lanes/"?*/*) n=${here#"$main/.claude/lanes/"}; printf '%s\n' "${n%%/*}"; return 0 ;;
  esac
  top=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
  top=$(cd "$top" && pwd -P)
  [ "$top" != "$main" ] || return 0
  branch=$(git -C "$top" symbolic-ref --short -q HEAD) || return 0
  for d in "$main"/.claude/rotation-lanes/*/; do
    [ -f "$d/rotation.conf" ] || continue
    n=$(basename "$d")
    b=$(sed -n 's/^[[:space:]]*ROTATION_BASE_BRANCH[[:space:]]*=[[:space:]]*//p' "$d/rotation.conf" | tail -1 | tr -d '[:space:]')
    [ -n "$b" ] || b=$(unset ROTATION_BASE_BRANCH; [ -f "$d/project.sh" ] && . "$d/project.sh" >/dev/null 2>&1; printf '%s' "${ROTATION_BASE_BRANCH:-}")
    [ -n "$b" ] && [ "$b" = "$branch" ] && { printf '%s\n' "$n"; return 0; }
  done
  return 0
}

# autorun_run_all <script> [args…]: run the script once per lane in that lane's environment, printing
# `== lane <name> ==` before each run's output. Returns the highest exit code of the runs.
# The overrides a single-lane self-test may set are dropped for the children: each lane's own paths apply.
autorun_run_all() {
  local script=$1 worst=0 rc val name
  shift
  while IFS='|' read -r -u 3 val name; do
    echo "== lane $name =="
    env -u ROTATION_STATE_DIR -u ROTATION_CONF -u ROTATION_PROJECT_SH -u ROTATION_EVENTS_LOG -u ROTATION_ROTATIONS_LOG \
      -u HARDEV_EVENTS_LOG -u HARDEV_ROTATIONS_LOG -u ROTATION_HANDOFF_FILE -u HARDEV_HANDOFF_FILE -u ROTATION_MANAGER_ACTIVE -u ROTATION_REPO \
      ROTATION_LANE="$val" ROTATION_PROJECT_DIR="$PROJECT_DIR" bash "$script" "$@"
    rc=$?
    [ "$rc" -le "$worst" ] || worst=$rc
  done 3< <(autorun_lanes)
  return "$worst"
}

# Insert one row into the inbox at ROTATION_INBOX_INSERT_LINE (default 65: the line the row lands on;
# past the end of the file it is appended). The file is created when missing, and written in place, so
# the link a lane's worktree has to the main tree's inbox writes the main tree's file. Prints the line number.
autorun_inbox_insert() {
  python3 - "$INBOX_FILE" "${ROTATION_INBOX_INSERT_LINE:-65}" "$1" <<'PY'
import os, sys
path, at, row = sys.argv[1], int(sys.argv[2]), sys.argv[3]
lines = open(path, encoding="utf-8").read().split("\n") if os.path.exists(path) else []
if lines and lines[-1] == "":
    lines.pop()
i = min(max(at, 1), len(lines) + 1) - 1
lines.insert(i, row)
with open(path, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
print(i + 1)
PY
}
