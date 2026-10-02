#!/usr/bin/env bash
# Run every self-test in this directory; exit 0 only when all of them do.
# Each test builds its own throwaway repository and state; none reads the
# project the plugin may be installed in.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
failed=0
for t in "$SCRIPT_DIR"/*_self_test.sh; do
  name=$(basename "$t" _self_test.sh)
  out=$(bash "$t" 2>&1); rc=$?
  printf '%-10s exit=%d  %s\n' "$name" "$rc" "$(printf '%s\n' "$out" | tail -1)"
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" | grep -E '^FAIL' | sed 's/^/           /'
    failed=$((failed + 1))
  fi
done
[ "$failed" -eq 0 ] && echo "all self-tests passed" || echo "$failed self-test(s) failed"
[ "$failed" -eq 0 ]
