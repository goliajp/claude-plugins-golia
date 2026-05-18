# port-registry

Soft, globally shared port allocator (DHCP-style) for local development services.

## What it does

- **Stable defaults**: same project → same port across sessions.
- **Soft**: no locks, no daemon — just a markdown table you can hand-edit.
- **TTL anti-rot**: stale rows (30 days unused) and zombies (project path no longer exists) are reclaimed on next allocation.
- **Implicit trigger**: PreToolUse hook detects server-starting commands (`bun run ios`, `metro`, `vite`, `uvicorn`, `rails server`, ...) and injects a reminder to consult the protocol before running.
- **Explicit invocation**: invoke the `port-registry` skill any time you need a port.

## Components

- **Skill** `port-registry`: full DHCP-style protocol (lookup, allocate, conflict, prune)
- **Hook** PreToolUse: pattern-matches Bash commands for server starts; injects reminder (never blocks)
- **State file**: `$PORT_REGISTRY_DATA` if set, else `~/.claude/port-registry-data.md`. Lives outside the plugin so it survives `claude plugin update`. Multi-profile / shared setups point all profiles at one file via the env var.

## Install

```
claude plugin marketplace add https://github.com/goliajp/claude-plugins-golia
claude plugin install port-registry@golia
```

For multi-profile setups, install state is per-profile so you need to install in each one. The plugin cache is shared, so files only download once. One-liner sync:

```
for p in 1 2 3; do
  CLAUDE_CONFIG_DIR=~/.claude-profile-$p claude plugin marketplace add https://github.com/goliajp/claude-plugins-golia
  CLAUDE_CONFIG_DIR=~/.claude-profile-$p claude plugin install port-registry@golia
done
```

### Development install (local checkout)

To hack on this plugin or test changes locally, point the marketplace at a clone instead of the GitHub URL — local-path installs hot-reload, so edits to `SKILL.md` / hooks are picked up on the next session without `claude plugin update`:

```
git clone https://github.com/goliajp/claude-plugins-golia.git
claude plugin marketplace add ./claude-plugins-golia
claude plugin install port-registry@golia
```

## Update

```
claude plugin marketplace update golia
claude plugin update port-registry
```

Restart sessions to pick up changes.

## Uninstall

```
claude plugin uninstall port-registry
```

The data file (at `$PORT_REGISTRY_DATA` or `~/.claude/port-registry-data.md`) is intentionally **not** removed by uninstall — remove by hand if you want a clean slate.

## Debugging the hook

Set `PORT_REGISTRY_HOOK_LOG=/tmp/pr-hook.log` in your shell before starting Claude to log every hook invocation (matched and not). Useful when you suspect a server-starting command isn't triggering the reminder, or vice versa:

```
PORT_REGISTRY_HOOK_LOG=/tmp/pr-hook.log claude
# in another shell:
tail -f /tmp/pr-hook.log
```

Hook log format: `<ISO timestamp> invoked: MATCH|no-match cmd=<first 120 chars>`.

If `MATCH` is logged but Claude doesn't act on the reminder, the systemMessage may not be reaching the LLM in some session modes (e.g. `claude -p` non-interactive print mode). Interactive sessions inject systemMessages normally.

## Changelog

- **0.1.1** — manifest polish: author normalized to `GOLIA K.K.`, added `homepage` / `repository` / `license` fields. README now leads with the public GitHub install URL.
- **0.1.0** — initial migration from `@import` global rule + standalone data file.
