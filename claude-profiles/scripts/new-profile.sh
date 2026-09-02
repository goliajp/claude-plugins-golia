#!/usr/bin/env bash
# Create a new Claude Code profile by mirroring an existing one's symlink set.
#
# usage: new-profile.sh <n> [template-n]
#   n           the new profile number, e.g. 5  -> ~/.claude-profile-5
#   template-n  which existing profile to copy the symlink set from (default:
#               the highest-numbered one that already exists)
#
# Only symlinks are mirrored. Per-profile state (history.jsonl, cache, plugins,
# stats) is deliberately NOT copied — Claude Code creates it, and history.jsonl
# in particular must stay per-profile: it is what maps a session back to an
# account. Sharing it destroys attribution.
set -euo pipefail

N="${1:?usage: new-profile.sh <n> [template-n]}"
DEST="$HOME/.claude-profile-$N"

if [ -e "$DEST" ]; then
  echo "refusing to touch an existing $DEST — remove it first if that is what you mean" >&2
  exit 1
fi

if [ -n "${2:-}" ]; then
  TEMPLATE="$HOME/.claude-profile-$2"
else
  TEMPLATE=$(find "$HOME" -maxdepth 1 -type d -name '.claude-profile-*' 2>/dev/null | sort -V | tail -1)
fi
[ -d "$TEMPLATE" ] || { echo "no template profile found; expected ~/.claude-profile-N" >&2; exit 1; }

echo "template: $TEMPLATE"
mkdir -p "$DEST"
count=0
while IFS= read -r entry; do
  target=$(readlink "$TEMPLATE/$entry" 2>/dev/null) || continue
  [ -n "$target" ] || continue
  ln -sfn "$target" "$DEST/$(basename "$entry")"
  count=$((count + 1))
done < <(find "$TEMPLATE" -maxdepth 1 -mindepth 1 -type l)

echo "created $DEST with $count symlinks mirrored from $(basename "$TEMPLATE")"

# The keychain service name is derived from the absolute path, not configured.
# Printing it lets you confirm a login landed in the right place.
if command -v shasum >/dev/null 2>&1; then
  HASH=$(printf '%s' "$DEST" | shasum -a 256 | cut -c1-8)
  echo "keychain service once logged in: Claude Code-credentials-$HASH"
fi

echo
echo "next:"
echo "  1. add an alias:  alias claude$N='CLAUDE_CONFIG_DIR=~/.claude-profile-$N claude'"
echo "  2. log in:        CLAUDE_CONFIG_DIR=~/.claude-profile-$N claude   then /login"
echo "  3. verify:        profile-doctor.sh"
