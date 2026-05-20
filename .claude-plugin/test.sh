#!/usr/bin/env bash
# Consumer hook for plugin-author Step 10b §4 (run tests before release).
# plugin-author calls: .claude-plugin/test.sh <plugin>
#
# goliajp's implementation: delegate to private .dev/ test harness.
# Only the marketplace maintainer runs this; consumers of installed plugins
# never invoke it (it lives at marketplace root, not inside any <plugin>/).
set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel)"
exec "$REPO_ROOT/.dev/helpers/test.sh" "$@" --unit
