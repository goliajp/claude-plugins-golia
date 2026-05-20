#!/usr/bin/env bash
# Consumer hook for plugin-author Step 10b §9 (after tag pushed).
# plugin-author calls: .claude-plugin/post-release.sh <plugin> <version>
#
# goliajp's implementation: refresh installs on all 3 dev profiles so the
# new release is immediately usable across our local Claude profiles.
# Only the marketplace maintainer runs this; consumers don't.
set -euo pipefail

PLUGIN="${1:?usage: $0 <plugin> [<version>]}"
VERSION="${2:-}"

REPO_ROOT="$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel)"

echo "=== post-release: 3-profile reinstall of $PLUGIN${VERSION:+ @v$VERSION} ==="
"$REPO_ROOT/.dev/helpers/dev-cycle.sh" "$PLUGIN"

echo
echo "=== consumer-visible version check ==="
CLAUDE_CONFIG_DIR="$HOME/.claude-profile-1" claude plugin details "$PLUGIN" 2>&1 | head -10
