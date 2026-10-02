#!/usr/bin/env bash
# init.sh: the generated shims pin the project root to where they live, so a call
# from a nested git repository (a worker's worktree) or a subdirectory still writes
# the project's state, not the caller's git top level.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1: got [$2] want [$3]"; fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
git -C "$T" init -q && git -C "$T" commit -q --allow-empty -m init
(cd "$T" && CLAUDE_PLUGIN_ROOT="$ROOT" bash "$ROOT/bin/init.sh" >/dev/null 2>&1)
ok "init writes kernel.path" "$(cat "$T/.claude/rotation/kernel.path")" "$ROOT"
mkdir -p "$T/.claude/worktrees/w"; git -C "$T/.claude/worktrees/w" init -q; git -C "$T/.claude/worktrees/w" commit -q --allow-empty -m w
(cd "$T/.claude/worktrees/w" && bash "$T/.claude/rotation/event.sh" harness.note note.kind=nested >/dev/null 2>&1)
ok "event from a nested repo lands in the project's state" "$(grep -c '"nested"' "$T/.claude/rotation-state/events.jsonl" 2>/dev/null)" "1"
ok "nothing is created under the nested repo" "$(ls -A "$T/.claude/worktrees/w" | tr '\n' ' ')" ".git "
mkdir -p "$T/sub"; (cd "$T/sub" && bash "$T/.claude/rotation/event.sh" harness.note note.kind=subdir >/dev/null 2>&1)
ok "event from a subdirectory lands in the project's state" "$(grep -c '"subdir"' "$T/.claude/rotation-state/events.jsonl")" "1"
(cd "$T/.claude/worktrees/w" && ROTATION_PROJECT_DIR="$T/elsewhere" bash -c '. "$1/.claude/rotation/lib.sh"; echo "$PROJECT_DIR"' _ "$T" > "$T/pd.txt" 2>/dev/null)
ok "an explicit ROTATION_PROJECT_DIR is kept by the lib.sh shim" "$(cat "$T/pd.txt")" "$T/elsewhere"
echo "init_self_test: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
