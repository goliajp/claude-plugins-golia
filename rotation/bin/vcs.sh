# rotation kernel — which version control the project is kept in.
#
# Source me, don't run me (lib.sh does). The kernel speaks git's command line
# to both backends: every call is `"$ROTATION_VCS_BIN" -C <dir> <git arguments>`,
# and alt takes the same arguments and prints the same output. What differs
# between the two is structure, not syntax, and only that is branched on:
#   - the subcommand that lists the parallel trees (`worktree` / `workspace`)
#   - where a worker's tree lives: a git worktree under .claude/worktrees/,
#     an alt workspace outside the repository (alt refuses one inside it)
#
# ROTATION_VCS_KIND  git | alt (exported, so the python helpers read it)
# ROTATION_VCS_BIN   the command run: `git`, or ROTATION_ALT_BIN (default `alt`)

# shellcheck shell=bash

# rotation_vcs_detect <dir>: `git` or `alt` for the nearest directory, from <dir> up, holding a `.git` or an
# `.alt` (a directory, or the file a worktree or workspace has); git when both are at the same level, and when
# neither is found, so a tree outside any repository fails as it did before alt was known.
rotation_vcs_detect() {
  local d
  d=$(cd "$1" 2>/dev/null && pwd) || { echo git; return 0; }
  while :; do
    [ -e "$d/.git" ] && { echo git; return 0; }
    [ -e "$d/.alt" ] && { echo alt; return 0; }
    [ "$d" = / ] && break
    d=$(dirname "$d")
  done
  echo git
}

# rotation_vcs_select <dir> [git|alt]: set and export ROTATION_VCS_KIND and ROTATION_VCS_BIN, the second
# argument (rotation.conf ROTATION_VCS) overriding what <dir> shows. Returns 2 on an unknown backend.
rotation_vcs_select() {
  local kind="${2:-}"
  case "$kind" in
    '') kind=$(rotation_vcs_detect "$1") ;;
    git|alt) ;;
    *) echo "vcs.sh: ROTATION_VCS must be git or alt, got '$kind'" >&2; return 2 ;;
  esac
  ROTATION_VCS_KIND=$kind
  if [ "$kind" = alt ]; then ROTATION_VCS_BIN="${ROTATION_ALT_BIN:-alt}"; else ROTATION_VCS_BIN=git; fi
  export ROTATION_VCS_KIND ROTATION_VCS_BIN
}

# rotation_vcs_trees [args before the subcommand…]: the parallel trees in `git worktree list --porcelain` form,
# the main tree first.
rotation_vcs_trees() {
  if [ "${ROTATION_VCS_KIND:-git}" = alt ]; then
    "$ROTATION_VCS_BIN" "$@" workspace list --porcelain
  else
    git "$@" worktree list --porcelain
  fi
}
