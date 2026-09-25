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

## The alias is derived, not maintained

`claudeN` is not written per profile. One block in the shell rc loops over the
profile directories that exist and defines an alias for each:

```zsh
for _cc_dir in "$HOME"/.claude-profile-*(N); do
  alias "claude${_cc_dir##*-}=CLAUDE_CONFIG_DIR='$_cc_dir' claude"
done
```

So **creating the directory is creating the alias** (from the next shell), and
removing the directory removes it. There is no rc edit in either direction and
no way for the two to drift apart.

`scripts/ensure-alias-block.sh` installs it — idempotent, keyed on a sentinel
comment, backs the rc up, and strips any hand-written `alias claudeN=` lines it
replaces. `new-profile.sh` calls it for you. The zsh `(N)` qualifier matters:
without it a machine with no profiles errors on every shell start.

## Add a profile

```bash
scripts/new-profile.sh 5     # symlink set mirrored + alias block ensured
```

Then:

1. **Open a new shell** (or `source` the rc) so `claude5` resolves.
2. **Log in** — `claude5`, then `/login`. Interactive; cannot be scripted.
3. **Verify** — `scripts/profile-doctor.sh` must end in `all clear`.

`new-profile.sh` aborts rather than leaving a half-built profile if it mirrors
zero symlinks — which it once did, silently, by prefixing a path that `find`
had already printed in full. The doctor is what caught it.

## Remove a profile

```bash
scripts/remove-profile.sh 5        # prints what dies, asks, then does it
```

It lists the symlinks (shared, untouched elsewhere) separately from the real
per-profile data that goes with the directory — `history.jsonl` included, which
is that account's session history and the only record of which sessions were
its. It deletes the keychain entry under the derived service name, removes the
directory, and says nothing more about the alias because the alias was a
function of the directory.

If the rc still has hand-written aliases, the script says so and points at
`ensure-alias-block.sh` instead of silently leaving a `claude5` that launches
nothing.

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

**A profile with no reachable `claudeN` is a profile nobody uses.** It keeps
working, keeps holding a login, and stays invisible. The doctor asks a real
interactive shell whether `claudeN` resolves rather than grepping the rc for a
literal — a derived block contains no per-profile literal to find, and a
literal that is present can still be shadowed.

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
