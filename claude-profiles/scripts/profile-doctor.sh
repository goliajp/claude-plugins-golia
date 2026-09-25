#!/usr/bin/env bash
# Audit every ~/.claude-profile-* against the invariants that, when violated,
# fail silently rather than loudly.
#
# Portable to the bash 3.2 that ships with macOS: no mapfile, no `xargs -r`,
# no associative arrays. The machines this runs on are exactly the ones with
# the old bash, so a bash-4 idiom here would only ever fail in the field.
#
# exit 0 = all clear, 1 = at least one FAIL
set -uo pipefail

fail=0
note() { printf '    %-5s %s\n' "$1" "$2"; [ "$1" = "FAIL" ] && fail=1; return 0; }

PROFILES=""
while IFS= read -r d; do PROFILES="$PROFILES$d
"; done <<EOF
$(find "$HOME" -maxdepth 1 -type d -name '.claude-profile-*' | sort -V)
EOF
PROFILES=$(printf '%s' "$PROFILES" | sed '/^$/d')
count=$(printf '%s\n' "$PROFILES" | sed '/^$/d' | wc -l | tr -d ' ')
if [ "$count" -eq 0 ]; then
  echo "no ~/.claude-profile-* directories found"
  exit 1
fi

# The shared root the symlinks point into, derived from what the profiles
# actually use rather than assumed — a profile set that shares nothing is a
# legitimate setup, not a fault.
SHARED=$(printf '%s\n' "$PROFILES" | while IFS= read -r p; do
  [ -n "$p" ] && find "$p" -maxdepth 1 -type l -exec readlink {} \; 2>/dev/null
done | sed 's#/[^/]*$##' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
echo "profiles: $count    shared root: ${SHARED:-<none>}"
echo

# union of every symlink name any profile has; a name present in the others but
# missing here is the drift worth reporting
ALL_LINKS=$(printf '%s\n' "$PROFILES" | while IFS= read -r p; do
  [ -n "$p" ] && find "$p" -maxdepth 1 -type l 2>/dev/null | while IFS= read -r l; do basename "$l"; done
done | sort -u)
link_total=$(printf '%s\n' "$ALL_LINKS" | sed '/^$/d' | wc -l | tr -d ' ')

while IFS= read -r p; do
  [ -n "$p" ] || continue
  n=$(basename "$p"); echo "  $n"

  # 1. history.jsonl must be a real per-profile file. It is the only thing that
  #    maps a session id back to an account; symlinking it into the shared root
  #    silently collapses every account into one.
  if [ -L "$p/history.jsonl" ]; then
    note FAIL "history.jsonl is a symlink — session attribution is destroyed"
  elif [ -f "$p/history.jsonl" ]; then
    note ok "history.jsonl is a per-profile file ($(wc -l < "$p/history.jsonl" | tr -d ' ') entries)"
  else
    note "-" "history.jsonl absent (never used yet)"
  fi

  # 2. symlink set matches the other profiles
  missing=""
  while IFS= read -r l; do
    if [ -n "$l" ] && [ ! -L "$p/$l" ]; then missing="$missing$l "; fi
  done <<LINK_LIST
$ALL_LINKS
LINK_LIST
  if [ -z "$missing" ]; then
    note ok "all $link_total shared symlinks present"
  else
    note FAIL "missing symlinks: $missing"
  fi

  # 3. no dangling symlink — a broken one reads as "the feature is off"
  dangling=""
  for l in "$p"/*; do
    if [ -L "$l" ] && [ ! -e "$l" ]; then dangling="$dangling$(basename "$l") "; fi
  done
  if [ -z "$dangling" ]; then note ok "no dangling symlinks"; else note FAIL "dangling: $dangling"; fi

  # 4. keychain entry — the service name is derived from the absolute path,
  #    never configured, so this also catches a profile moved after login
  if command -v shasum >/dev/null 2>&1 && command -v security >/dev/null 2>&1; then
    svc="Claude Code-credentials-$(printf '%s' "$p" | shasum -a 256 | cut -c1-8)"
    if security find-generic-password -s "$svc" >/dev/null 2>&1; then
      note ok "logged in ($svc)"
    else
      note "-" "not logged in yet ($svc)"
    fi
  fi

  # 5. a `claudeN` command an interactive shell can actually resolve.
  #    Asked of the shell rather than grepped out of a dotfile: an rc that
  #    derives its aliases in a loop contains no per-profile literal to grep
  #    for, and a literal that is present can still be shadowed or unreachable.
  num=$(printf '%s' "$n" | sed 's/.*-//')
  resolved=""
  for sh in zsh bash; do
    command -v "$sh" >/dev/null 2>&1 || continue
    if "$sh" -ic "type claude$num" >/dev/null 2>&1; then resolved="$sh"; break; fi
  done
  if [ -n "$resolved" ]; then
    note ok "claude$num resolves in $resolved"
  else
    note FAIL "no claude$num command — an unreachable profile is one nobody uses"
  fi
done <<PROFILE_LIST
$PROFILES
PROFILE_LIST

echo
[ "$fail" -eq 0 ] && echo "all clear" || echo "problems found — see FAIL above"
exit "$fail"
