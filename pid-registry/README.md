# pid-registry

Per-project handle ledger for long-running processes — anything that doesn't naturally exit when the current Claude Code turn ends (dev-servers, daemons, watchers, tunnels, REPLs, debug-attached children).

## Why

Long-running processes don't surface their pids to future sessions. Without a record:

- You can't find what you started yesterday → `ps | grep` archaeology
- Same-name processes from other projects (multiple `vite` / `cargo run` / `bun dev` running concurrently) get killed by accident
- Pid reuse silently makes `kill <stale-pid>` hit an innocent process

A 6-line markdown file per process kills all three failure modes.

## What it does

- **Skill** `pid-registry` — full protocol: register flow (pid / command / cwd / port / verify_before_kill / kill), verify-before-kill defense, restart updates, cross-project same-name guard.
- **Hook** PreToolUse — auto-fires when Bash is invoked with `run_in_background: true` (the signal that the command will outlast the current turn) and reminds Claude to consult the protocol.
- **State** — `<project>/.claude/pid-registry/<name>.pid`, one file per process, plain KV format. State stays inside the project — `claude plugin update` cannot wipe it.

## Install

```
claude plugin marketplace add https://github.com/goliajp/claude-plugins-golia
claude plugin install pid-registry@golia
```

### Development install (local checkout)

To hack on this plugin or test changes locally — local-path installs hot-reload, so `SKILL.md` / hook edits land on the next session without `claude plugin update`:

```
git clone https://github.com/goliajp/claude-plugins-golia.git
claude plugin marketplace add ./claude-plugins-golia
claude plugin install pid-registry@golia
```

## Update

```
claude plugin marketplace update golia
claude plugin update pid-registry
```

## Uninstall

```
claude plugin uninstall pid-registry
```

The state directory (`<project>/.claude/pid-registry/`) is intentionally **not** removed — pids are ephemeral but the records may still be useful right after uninstall. Remove by hand if you want a clean slate.

## Debugging the hook

Set `PID_REGISTRY_HOOK_LOG=/tmp/pid-hook.log` in your shell before starting Claude to log every hook invocation (matched and not):

```
PID_REGISTRY_HOOK_LOG=/tmp/pid-hook.log claude
# in another shell:
tail -f /tmp/pid-hook.log
```

Log format: `<ISO timestamp> invoked: MATCH|no-match|non-Bash|malformed cmd=<first 80 chars>`.

## Relationship to port-registry

`port-registry` allocates a port number (a host-wide resource); `pid-registry` records a process handle (a per-project resource). The two are complementary: when you start a local server, port-registry tells you *which port to bind*, and pid-registry remembers *what you actually started*.

## Notes

- Hook trigger is narrow on purpose: only `run_in_background: true`. Shell-`&` / `nohup` / `disown` backgrounding are intentionally NOT detected at v0.1 — they're rare in Claude Code sessions, and the narrow trigger keeps false positives near zero.
- `.claude/pid-registry/` should be added to project `.gitignore` — pids are ephemeral, no value in committing them.

## Changelog

- **0.1.0** — initial release. Migrated from a global `@import` rule into a structured plugin: explicit protocol, hook trigger on `run_in_background`, project-local state directory.
