#!/usr/bin/env bash
# Make `claudeN` resolve for every profile that exists — now and for every
# profile added later — by installing a derived alias block into the shell rc.
#
# Idempotent: keyed on a sentinel comment, safe to run repeatedly.
# Backs up the rc before touching it. --dry-run shows the plan and changes nothing.
set -euo pipefail

SENTINEL="# >>> claude-profiles: derived aliases >>>"
END="# <<< claude-profiles: derived aliases <<<"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

case "${SHELL##*/}" in
  zsh)  RC="$HOME/.zshrc";  FLAVOUR=zsh ;;
  bash) RC="$HOME/.bashrc"; FLAVOUR=bash ;;
  *)    echo "unsupported login shell ${SHELL##*/}; add the block by hand" >&2; exit 1 ;;
esac

if [ -f "$RC" ] && grep -qF "$SENTINEL" "$RC"; then
  echo "already installed in $RC — profiles added later get their alias with no further edit"
  exit 0
fi

if [ "$FLAVOUR" = zsh ]; then
  # (N) is the null_glob qualifier: without it a machine with no profiles
  # errors on every shell start.
  BLOCK="$SENTINEL
# claudeN is derived from the profiles that exist, so creating
# ~/.claude-profile-N gives you claudeN in the next shell, and removing the
# directory takes its alias with it. Nothing here to edit per profile.
for _cc_dir in \"\$HOME\"/.claude-profile-*(N); do
  alias \"claude\${_cc_dir##*-}=CLAUDE_CONFIG_DIR='\$_cc_dir' claude\"
done
unset _cc_dir
$END"
else
  BLOCK="$SENTINEL
# claudeN is derived from the profiles that exist. The [ -d ] guard is what
# keeps an unmatched glob from creating an alias to a literal '*'.
for _cc_dir in \"\$HOME\"/.claude-profile-*; do
  [ -d \"\$_cc_dir\" ] || continue
  alias \"claude\${_cc_dir##*-}=CLAUDE_CONFIG_DIR='\$_cc_dir' claude\"
done
unset _cc_dir
$END"
fi

# Hand-written per-profile aliases would shadow or duplicate the derived ones.
EXISTING=$(grep -n "^alias claude[0-9]" "$RC" 2>/dev/null || true)
if [ -n "$EXISTING" ]; then
  echo "these hand-written aliases become redundant once the block is in:"
  printf '%s\n' "$EXISTING" | sed 's/^/    /'
  echo "  (they are removed — the derived block covers exactly the same profiles)"
fi

if [ "$DRY" = 1 ]; then
  echo "--- would append to $RC ---"; printf '%s\n' "$BLOCK"; exit 0
fi

BACKUP="$RC.bak.$(date +%Y%m%d%H%M%S)"
cp "$RC" "$BACKUP" 2>/dev/null || touch "$RC"
[ -f "$BACKUP" ] && echo "backup: $BACKUP"

if [ -n "$EXISTING" ]; then
  tmp=$(mktemp); grep -v "^alias claude[0-9]" "$RC" > "$tmp"; mv "$tmp" "$RC"
fi
printf '\n%s\n' "$BLOCK" >> "$RC"
echo "installed into $RC — open a new shell, or: source $RC"
