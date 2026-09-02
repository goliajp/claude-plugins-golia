---
name: claude-profiles
description: Use when adding, removing, or auditing a Claude Code account profile on a machine that runs several accounts side by side (CLAUDE_CONFIG_DIR / ~/.claude-profile-N). Covers creating the profile with the correct symlink set, the derived keychain service name, the shell alias, logging in, and the invariants a broken profile violates silently. Also covers what to do when a separate repo keeps its own copy of the account roster.
---

# claude-profiles

Several Claude Code accounts on one machine, each with its own
`CLAUDE_CONFIG_DIR`, sharing a workspace through symlinks.

```
~/.claude-profile-1   ← account A     projects/  ─┐
~/.claude-profile-2   ← account B     sessions/  ─┼─→ ~/.claude-shared/
~/.claude-profile-3   ← account C     skills/    ─┘
                                      history.jsonl  ← NOT shared, one per profile
```

## Add a profile

```bash
scripts/new-profile.sh 5          # mirrors the symlink set from the newest profile
```

Then, in order:

1. **Alias** — append next to the existing ones so they stay together:
   `alias claude5='CLAUDE_CONFIG_DIR=~/.claude-profile-5 claude'`
   Aliases are read at shell start; the current shell needs `source ~/.zshrc`.
2. **Log in** — `claude5`, then `/login`. This is interactive and cannot be
   scripted.
3. **Verify** — `scripts/profile-doctor.sh` must end in `all clear`.

## Remove a profile

1. Log out from inside that profile, or delete its keychain entry:
   `security delete-generic-password -s "Claude Code-credentials-<hash>"`
   (get the hash from the doctor's output — see below).
2. Remove the alias line.
3. `rm -rf ~/.claude-profile-N` — safe *only* because every shared thing in it
   is a symlink. Confirm with `find ~/.claude-profile-N -maxdepth 1 ! -type l`
   first: whatever that lists is real per-profile data that is about to go,
   `history.jsonl` included, which is the account's session history.

## The four things that fail silently

**`history.jsonl` must stay a per-profile regular file.** It is what maps a
session id back to an account. Symlinking it into the shared root — easy to do
when mirroring symlinks by hand — collapses every account into one and the only
symptom is attribution quietly going wrong. `new-profile.sh` mirrors *only*
symlinks for this reason, and the doctor checks it first.

**The keychain service name is derived, not configured.** It is
`Claude Code-credentials-<first 4 bytes of sha256(absolute profile path)>`
(`~/.claude` itself is the unsuffixed `Claude Code-credentials`). Two
consequences: you can predict the name before logging in, and *moving or
renaming a profile directory orphans its credentials* — the login is still in
the keychain, just under a name nothing looks up any more.

```bash
printf '%s' "$HOME/.claude-profile-5" | shasum -a 256 | cut -c1-8
```

**A dangling symlink reads as "the feature is off".** A profile whose `skills`
or `plugins` link points at a moved shared root simply behaves as if those do
not exist. Nothing errors.

**A profile with no alias is a profile nobody uses.** It keeps working, keeps
holding a login, and stays invisible. The doctor reports it.

## When another repo keeps its own copy of the roster

Telemetry, dashboards and session hooks tend to each hardcode the account list.
Every copy is a place to forget. The rule that holds:

> One manifest is the source of truth. Consumers either read it at runtime, or
> carry a typed mirror **with a test that fails when the two diverge**.

A count assertion (`assert len == 5`) is not that test — it goes stale in the
same edit. Compare against the manifest itself.

**Whatever you add, prove it can report a problem.** Break it on purpose once —
add a sixth entry to the manifest, or point a symlink at nothing — and confirm
the check goes red *and* exits non-zero. A checker whose loop runs inside a
pipeline updates its flag in a subshell and reports "all clear" while printing
failures directly above; this doctor had exactly that bug before it was tested
in the failing direction.

In this org the manifest is `goliajp/devops/claude-accounts.json`: the web
dashboard imports it, the session hook reads it with `jq`, and the Rust CLI
keeps a typed mirror guarded by a test that diffs the two.
