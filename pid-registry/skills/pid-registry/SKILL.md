---
name: pid-registry
description: MANDATORY when starting any long-running process (dev-server, daemon, watcher, tunnel, REPL, debug-attached child — anything that will outlast the current turn) in a Claude Code session. Record a pid handle at `<project>/.claude/pid-registry/<name>.pid` so the same or future sessions can find and safely kill it. Verify before kill — pid reuse is real. The PreToolUse hook auto-fires when Bash is invoked with `run_in_background:true`.
---

# pid-registry — Protocol

Per-project, file-per-handle ledger for long-running processes — anything that doesn't naturally exit when the current turn ends (dev-servers, daemons, watchers, tunnels, REPLs, debug-attached children, …). Each handle is a small KV markdown record at `<project>/.claude/pid-registry/<name>.pid`.

- **Project root** = the absolute path on the `Primary working directory:` line of the environment block (NOT shell cwd, which may have drifted)
- **Applies**: every time you start, find, or are about to kill a long-running process

## Why a registry

Long-running processes don't naturally surface their pids to future sessions. Without a record:

- You can't find what you started yesterday → `ps | grep` archaeology
- Cross-project same-name processes (multiple `vite` / `cargo run` / `bun dev` on different projects) get killed by accident
- Pid reuse silently makes `kill <stale-pid>` hit an innocent process

A 6-line markdown file per process kills all three failure modes.

## File path

`<project-root>/.claude/pid-registry/<name>.pid`

- `<name>` is **semantic and short**: `vite-dev` / `cargo-watch` / `next-dev` / `postgres-local`. Never `dev` / `server` (too generic) and never a transient identifier like a pid number.
- One file per process. A project running backend + frontend gets two files.
- If the directory doesn't exist, `mkdir -p <project-root>/.claude/pid-registry` (absolute path; do not rely on shell cwd).

## File format (KV, one key per line)

```
pid: <integer>
command: <command line as `ps` shows it>
cwd: <process working dir from `lsof -a -p <pid> -d cwd`>
port: <listening port if any, else "none">
started_approx: <YYYY-MM-DD, derived from `ps etime`>
recorded: <YYYY-MM-DD, when this record was written>
verify_before_kill: <one ps command that confirms pid still points to this process>
kill: <one cleanup command; `pkill -f "<pattern>"` as a fallback>
```

Plain KV. Easy to `grep`, easy for humans to read. No JSON, no nesting.

## Register (write a new handle)

Triggered automatically when you launch a long-running process. Specifically:

- **Hook trigger**: PreToolUse fires when Bash is invoked with `run_in_background: true`. After launching, do the register flow.
- **Manual**: any other tool you know spawns a long-running thing (e.g. an MCP tool that starts a server).

Steps:

1. Decide `<name>` — semantic short slug, per "File path" rules.
2. Run the process. Capture its pid (the harness usually returns it; otherwise `bash -c 'cmd & echo $!'`).
3. Gather fields:
   - `lsof -a -p <pid> -d cwd` → cwd
   - `lsof -nP -iTCP -sTCP:LISTEN -p <pid>` → port (or `none`)
   - `ps -o etime= -p <pid>` → started_approx
4. Compose `verify_before_kill`: e.g. `ps -p <pid> -o command=` plus a grep for a unique substring of the original command. This is the pid-reuse defense.
5. Compose `kill`: prefer `kill <pid>` (or `kill -9 <pid>` for stubborn); a pattern fallback like `pkill -f "<pattern>"` is useful when the pid is stale.
6. `mkdir -p <project-root>/.claude/pid-registry` if missing.
7. Write the file with the KV format above. Single-shot write — never partial.

## Verify before kill

**Before any kill, run the file's `verify_before_kill` command.** If it doesn't show the expected process (pid reuse, system restart, crash-restart with a new pid), the record is stale — update or delete it, do NOT kill the pid blind.

Non-negotiable. Pid reuse is real: a long-running process can die, the OS recycles its pid for an unrelated new process, and now your `.pid` file points at an innocent victim.

## Restart (same name, new pid)

When you intentionally restart a registered process:

1. Run new process, get new pid.
2. Re-gather fields (pid, cwd if changed, port if changed, started_approx, recorded).
3. **Overwrite the same `<name>.pid` file in place.** Same logical service = same file name; only the contents update.

## Discovery on session start

When a fresh session begins in a project, if `<project-root>/.claude/pid-registry/*.pid` has entries, treat those as **known background processes** — do not flag them as anomalies during `ps` / `lsof` / port-conflict diagnosis.

## Cross-project same-name guard

`bun dev` / `vite` / `cargo run` are common across many projects. Before assuming a process belongs to **this** project:

- Run `lsof -a -p <pid> -d cwd` and confirm the cwd matches the **current project root**.
- If the cwd doesn't match, the process belongs to another project — leave it alone.

## State boundary

- All state lives in `<project-root>/.claude/pid-registry/` — per-project, scoped, naturally garbage-collected when the project is deleted.
- **`.claude/pid-registry/` should be gitignored.** Pid is ephemeral; committing it is meaningless. Add `.claude/pid-registry/` to project `.gitignore` if not already there.
- **Plugin uninstall does NOT remove `.pid` files.** They live in the project, not the plugin directory.

## Why not memory

Pid is ephemeral — system restart, process death, crash-restart all invalidate it. Memory is for enduring facts. Pids belong in a per-project transient store on disk, which is exactly what `.claude/pid-registry/` is.

The **rule** (write a handle when starting a long-running process) lives in memory / this skill. The **specific pids** live on disk.
