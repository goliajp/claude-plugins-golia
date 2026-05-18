---
name: port-registry
description: MANDATORY before binding any TCP port for a local service. Allocates a stable port per project (DHCP-style — same project → same port), renews TTL on use, reassigns on EADDRINUSE, prunes stale/zombie rows. Invoke whenever you plan to bind a port, or when the plugin's PreToolUse hook injects a reminder. Never guess a port number.
---

# Port Registry — Protocol

Soft, globally shared port table. Defaults stay stable; hand-editable; TTL keeps it from rotting; no daemon, no cron — just a markdown file.

- **Data file path** — resolve in this order:
  1. `$PORT_REGISTRY_DATA` if the env var is set and non-empty.
  2. Otherwise `~/.claude/port-registry-data.md` (Claude Code's standard user dir; works out of the box for single-profile users).
  3. If the resolved file doesn't exist, **bootstrap it** (see the Bootstrap section near the bottom of this skill) before any Lookup.
- **Why two layers**: single-profile users get a working default; multi-profile / shared setups override with the env var to point all profiles at one shared file (e.g. `~/.claude-shared/port-registry-data.md`) — keeping the DHCP view globally unique.
- **Applies**: before starting any local service that binds a port.

## Lookup

1. Project root `P` = absolute path from the environment block's `Primary working directory:` line (**not** shell cwd — it may have drifted).
2. Open the data file. Find rows where `path == P`.
3. **0 rows** → Allocate.
4. **1 row, port `N`** → run `lsof -nP -iTCP:N -sTCP:LISTEN`:
   - Free → use `N`. If `last_used` ≠ today, set it to today (renewal — this is what keeps TTL from drifting on active projects).
   - Bound → stop, report the squatter, ask: kill or reassign. Do **not** silently switch.
5. **2+ rows** → list every row's `port / name / purpose`. Ask the user which service to start, or whether to allocate a new one. **Never silently pick one** — multiple services in a project is an explicit choice; the user must point.

## Allocate

1. `lsof -nP -iTCP -sTCP:LISTEN` → set `S` of currently bound ports.
2. Candidate, in order:
   1. A stale row (`last_used` > 30 days ago) or zombie row (`test -d <path>` fails) — overwrite it in place.
   2. Next port in the free pool `6000-49151`, then `49152-60000` (extended; overlaps macOS ephemeral range, use only when default is full).
3. Skip candidates in `S` or already assigned to another row.
4. Write the row: `path / port / name / purpose / last_used / notes`.
5. While the data file is open, count stale + zombie rows.
6. Report: "Allocated `N` (new / reclaimed from `<old path>`)". If stale+zombie > 5, append: "Data has `M` stale/zombie rows — say 'prune port registry'."

## Conflict at service start

The registry is *preference*, not reservation. A port `lsof` showed free at allocation can be grabbed before your service binds — startup fails with EADDRINUSE.

1. `lsof -nP -iTCP:N -sTCP:LISTEN` → identify the squatter.
2. Report squatter info; offer:
   - **Kill** → confirm, kill, retry. Row unchanged.
   - **Reassign** → re-run Allocate, **overwrite the same row** (same `path`, new `port`), retry.
3. **Never leave a half-dead row.** The next lookup must read a live or reassigned binding — a row known to be broken poisons future allocations.

## Prune

Triggers:

- **User**: "prune port registry" / "clean up ports" / "scan for zombies".
- **Auto-prompt only**: at allocation when stale+zombie > 5. Prompt — never auto-delete.

List both categories and **wait for user confirmation before deleting**:

- Stale: `last_used` > 30 days ago.
- Zombie: `path` no longer exists.

## Reserved ports

No static reserved list. `lsof` is the live defense. To permanently claim a port (e.g. a known local service that always runs), add a normal row with `purpose: reserved` and `name: <service>` — no separate blacklist mechanism.

## Invariants

- Each `(path, name)` pair is unique; each `port` value is unique across the table. Most projects have one row per path — projects running multiple services (e.g. backend + frontend, dev + long-running daemon) get one row per service, distinguished by `name`.
- This skill file is read-only. All state lives in the data file.
- Edits to the data file are written in one shot (Write/Edit the whole table), never partial appends — half-written tables are worse than no table.

## Bootstrap (first-time data file creation)

If the resolved data file path doesn't exist (typical on a fresh install), create it with the following exact content before the first Lookup, then proceed. Mention to the user: `"Created port-registry data file at <path>"`.

````markdown
# Port Registry — Data

Live data backing the `port-registry` plugin's SKILL.md protocol. Hand-editing is fine — the table is soft.

## Fields

- `path` — project root absolute path (**primary key**; matching is by this)
- `port` — assigned port
- `name` — display alias (short, for humans; does not affect matching)
- `purpose` — one-line description (e.g. `next.js dev`, `fastapi`, `vite preview`, `reserved: postgres`)
- `last_used` — ISO date `YYYY-MM-DD`; basis for TTL; renewed once per day on start
- `notes` — optional

## Table

| path | port | name | purpose | last_used | notes |
|------|------|------|---------|-----------|-------|
| _(empty — first allocation by Claude populates this)_ | | | | | |
````
