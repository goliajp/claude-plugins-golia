#!/usr/bin/env bash
# Consumer hook for plugin-author Step 10b §9 (after tag pushed).
# plugin-author calls: .claude-plugin/post-release.sh <plugin> <version>
#
# goliajp's implementation: refresh installs on every local profile (whatever
# .dev/helpers/profiles.sh finds) so the new release is usable everywhere at once.
# Only the marketplace maintainer runs this; consumers don't.
set -euo pipefail

PLUGIN="${1:?usage: $0 <plugin> [<version>]}"
VERSION="${2:-}"

REPO_ROOT="$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel)"

echo "=== post-release: reinstall of $PLUGIN${VERSION:+ @v$VERSION} on every profile ==="
"$REPO_ROOT/.dev/helpers/dev-cycle.sh" "$PLUGIN"

echo
echo "=== consumer-visible version check ==="
CLAUDE_CONFIG_DIR="$("$REPO_ROOT/.dev/helpers/profiles.sh" | head -1)" claude plugin details "$PLUGIN" 2>&1 | head -10
