#!/usr/bin/env bash
# Remove a Claude Code profile: its credentials, its directory, and its alias.
#
# usage: remove-profile.sh <n> [--yes]
#
# Prints exactly what will be destroyed before doing it. Everything shared is a
# symlink and is left alone; what dies is the per-profile state, of which
# history.jsonl is the one that matters — it is that account's session history
# and the only record of which sessions belonged to it.
set -euo pipefail

N="${1:?usage: remove-profile.sh <n> [--yes]}"
YES=0
[ "${2:-}" = "--yes" ] && YES=1
DIR="$HOME/.claude-profile-$N"

[ -d "$DIR" ] || { echo "$DIR does not exist"; exit 1; }

echo "about to remove $DIR"
echo
echo "  symlinks (shared, left untouched elsewhere):"
find "$DIR" -maxdepth 1 -type l -exec basename {} \; 2>/dev/null | sed 's/^/    /'
echo
echo "  real data, destroyed with the directory:"
find "$DIR" -maxdepth 1 -mindepth 1 ! -type l -exec basename {} \; 2>/dev/null | sed 's/^/    /'
if [ -f "$DIR/history.jsonl" ]; then
  echo "    ^ history.jsonl holds $(wc -l < "$DIR/history.jsonl" | tr -d ' ') session entries for this account"
fi

SVC=""
if command -v shasum >/dev/null 2>&1; then
  SVC="Claude Code-credentials-$(printf '%s' "$DIR" | shasum -a 256 | cut -c1-8)"
  echo
  if security find-generic-password -s "$SVC" >/dev/null 2>&1; then
    echo "  keychain entry to delete: $SVC"
  else
    echo "  keychain: no entry under $SVC (already logged out)"
    SVC=""
  fi
fi

if [ "$YES" != 1 ]; then
  printf '\nproceed? [y/N] '
  read -r a
  case "$a" in y|Y|yes) ;; *) echo "aborted"; exit 1 ;; esac
fi

[ -n "$SVC" ] && security delete-generic-password -s "$SVC" >/dev/null 2>&1 && echo "deleted keychain entry"
rm -rf "$DIR"
echo "removed $DIR"

# With the derived alias block installed there is nothing to un-edit: the alias
# was a function of the directory, and the directory is gone.
if grep -qs "claude-profiles: derived aliases" "$HOME/.zshrc" "$HOME/.bashrc" 2>/dev/null; then
  echo "alias claude$N disappears on its own in the next shell (aliases are derived)"
else
  echo "remove the 'alias claude$N=' line from your shell rc by hand,"
  echo "or run ensure-alias-block.sh so aliases stop being hand-maintained"
fi
