#!/usr/bin/env bash
#
# One page of the scene after an interruption (session restart, account
# switch, quota, a lost background task), and what to do next. Read-only.
#
# usage: recover.sh [--json] [--no-probe]
#   --json      the same content as one JSON document (the action is its `action` key)
#   --no-probe  skip the remote probe and the remote terminal-marker checks
#
# The page: HEAD and this round's commit count, the main tree's uncommitted
# files, every other worktree with its commits ahead of the base branch, the
# last five events, the registered agents (id, role, status, last event),
# remote jobs that have a remote.start and no remote.end (with whether their
# terminal marker is already in the remote log; `orphan?` when the local
# process that held the job's ssh, remote.launcher, is gone, with the command
# that ends it by its registered remote.pid — or, with no pid registered, the
# note to confirm by hand; never a command-line pattern), commits on the main tree
# that no running executor accounts for, and the raw output of the
# project's remote probe.
#
# Last line, one of:
#   RESUME <agentId>                an executor of this round is registered as running WITH an id, and it was
#                                   registered from this session (managerSession == CLAUDE_CODE_SESSION_ID; an
#                                   event older than the field counts as this session and the page says so)
#   CLEAN main tree first           no resumable executor, and the main tree has uncommitted files
#   RESPAWN executor leftover=…     no resumable executor; worktrees / remote jobs / workers / an executor
#                                   registered without an id (`executor:<name>(no-id)`) or from another session
#                                   (`executor:<name>(<id>,mismatch)`, or `no-session` when either id is null)
#                                   are left over
#   IDLE                            nothing running, nothing left over
# The page also counts the running rotation executors; more than one is flagged (the protocol runs one).
#
# Project side (project.sh): ROTATION_REMOTE_PROBE_CMD, ROTATION_REMOTE_GREP_CMD,
# ROTATION_BASE_BRANCH. Overrides for the self-test: ROTATION_REPO,
# HARDEV_EVENTS_LOG, HARDEV_ROTATIONS_LOG.
#
# exit: 0 page printed · 2 usage

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

for arg in "$@"; do
  case "$arg" in
    --json|--no-probe) ;;
    *) echo "usage: recover.sh [--json] [--no-probe]" >&2; exit 2 ;;
  esac
done

export ROTATION_REPO="${ROTATION_REPO:-$PROJECT_DIR}"
export ROTATION_EVENTS_LOG="$EVENTS_LOG"
export ROTATION_ROTATIONS_LOG="$ROTATIONS_LOG"
export ROTATION_MANAGER_ACTIVE="${ROTATION_MANAGER_ACTIVE:-$MANAGER_ACTIVE_FILE}"
export ROTATION_AGENT_ORIGIN_PATTERN="$AGENT_ORIGIN_PATTERN"
exec python3 "$SCRIPT_DIR/recover_lib.py" recover "$@"
