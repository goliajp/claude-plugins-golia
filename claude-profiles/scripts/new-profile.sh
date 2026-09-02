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
# find prints full paths — readlink takes them as-is. Prefixing $TEMPLATE
# again silently produced zero links until the doctor reported 14 missing.
while IFS= read -r entry; do
  [ -L "$entry" ] || continue
  target=$(readlink "$entry" 2>/dev/null) || continue
  [ -n "$target" ] || continue
  ln -sfn "$target" "$DEST/$(basename "$entry")"
  count=$((count + 1))
done < <(find "$TEMPLATE" -maxdepth 1 -mindepth 1 -type l)

if [ "$count" -eq 0 ]; then
  echo "no symlinks found in $TEMPLATE — refusing to leave a half-built profile" >&2
  rmdir "$DEST" 2>/dev/null || true
  exit 1
fi

echo "created $DEST with $count symlinks mirrored from $(basename "$TEMPLATE")"

# The keychain service name is derived from the absolute path, not configured.
# Printing it lets you confirm a login landed in the right place.
if command -v shasum >/dev/null 2>&1; then
  HASH=$(printf '%s' "$DEST" | shasum -a 256 | cut -c1-8)
  echo "keychain service once logged in: Claude Code-credentials-$HASH"
fi

# The alias is not left as an instruction: with the derived block installed,
# the directory that was just created IS the alias, from the next shell on.
echo
"$(dirname "$0")/ensure-alias-block.sh" || echo "could not install the alias block — add claude$N by hand"

echo
echo "next:"
echo "  1. open a new shell (or: source your rc) so claude$N resolves"
echo "  2. log in:  claude$N   then /login"
echo "  3. verify:  $(dirname "$0")/profile-doctor.sh"
