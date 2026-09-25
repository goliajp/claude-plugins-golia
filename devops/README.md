# devops

Reach the goliajp devops control plane (`devops.golia.jp`) safely from **any**
project session.

## What it does

- **Skill** (`devops`) — the judgment layer. Teaches when to reach for the
  control plane, the `devops` CLI as the blessed interface, how to discover the
  live capability surface (`GET /api/meta/capabilities`), and the **red lines**
  you must honor even though you're not in the `devops` repo (DNS delete
  confirmation, `caddy deploy --force` review, never hand-craft an API mutation).
- **PreToolUse hook** — the correction layer. Watches Bash and injects a
  steering reminder when a command is a hand-crafted API mutation against
  `devops.golia.jp/api/...` (raw `curl -X DELETE/PUT/POST`) or a
  `caddy deploy --force`, pointing back to the safe CLI primitive. Soft inject
  only — it never blocks.

## Why

devops capabilities are already reachable from any operator-machine session (the
`devops` CLI is on PATH, the API key is machine-global), but the red lines lived
only in the `devops` repo's own rules. A session elsewhere could bypass a
guardrail it never read — hand-crafting an API `DELETE` instead of using
`devops dns rm`. This plugin makes the guardrails travel with the capability.

## Requires

The `devops` CLI on PATH (operator machines install it via `cargo install`) and
`~/.config/devops/api-key`. Run `devops doctor` first in any session.

## Debug

Set `DEVOPS_HOOK_LOG=/tmp/devops-hook.log` to log every hook invocation.
