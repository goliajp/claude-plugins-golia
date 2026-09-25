---
name: devops
description: Use when you need to touch goliajp infrastructure from ANY project — deploy a service, add/remove a domain or Caddy site, check fleet/device health, inspect or resolve drift, read a secret, or when you're about to call the devops API by hand. There is a control plane (`devops.golia.jp`) and a `devops` CLI; this skill is how you reach them safely and which actions are red lines you must never bypass. Also triggers when the PreToolUse hook flags a hand-crafted API mutation.
---

# devops — reaching the goliajp control plane safely

There is a devops control plane at `https://devops.golia.jp` (tailscale-internal;
public DNS points here but needs a Bearer key or OIDC). Its capabilities are
already reachable from **any** session on studio/mini: the `devops` CLI is on
PATH and the API key lives at `~/.config/devops/api-key`. You are almost
certainly *not* in the `devops` repo when you need this — that's exactly why the
red lines below travel with this skill instead of living in that repo's rules.

## First, always

```
devops doctor
```

CLI version / API reachability / auth / compatibility, in one call. `verdict=ready`
means go. Do this before anything else — it tells you what the environment can
and can't do without guessing.

## Discover what's available — don't assume

The capability manifest is public (no auth) and is the single source of truth:

```
curl -s https://devops.golia.jp/api/meta/capabilities | jq
```

Each row is `{name, kind: read|mutating, red_line, cli, endpoint, summary}`. The
`cli` field is the **one blessed way** to do that action. Prefer it. `devops
--help` and `devops <cmd> --help` list the same surface interactively.

## The one rule that prevents incidents

**Never hand-craft an API mutation. Use the CLI primitive.**

Every infra change has exactly one safe verb (`devops dns add/rm`, `devops caddy
add/rm`, `devops deploy`, …). Those verbs enforce the red lines — the confirm
prompts, the diff-first review, the audit log. A raw `curl -X DELETE
.../api/dns/...` or `PUT .../api/caddy/sites/...` does the change but skips the
guardrail. If you find yourself assembling a JSON body for a devops endpoint,
stop: there is a `devops` verb for it (`curl /api/meta/capabilities` to find it).

## RED LINES — honor these even though you're not in the devops repo

| Action | Rule |
|---|---|
| **Delete a DNS record** | `devops dns rm <zone> <name>` — it confirms each live record y/N. NEVER `curl -X DELETE .../api/dns/live/...` by hand. Records you didn't create may be someone else's. |
| **`caddy deploy --force`** | Regenerates the ENTIRE live Caddyfile from the store and overwrites it — any live-only site vanishes. Run `devops caddy drift <device>` and review the diff FIRST. `devops caddy rm` and `devops caddy set-block` do this for you (they refuse while other drift exists, print the change, and ask before forcing). |
| **DNS sync with deletes** | `devops dns sync` never auto-deletes; it prompts per record. Don't work around the prompt. |
| **Delete a secret** | irreversible — confirm the exact key first. |
| **SSH to a managed device** | every SSH op must leave an audit entry (the platform does this for you through the API — prefer the API/CLI over raw ssh). |

If unsure whether something is a red line: `curl -s
https://devops.golia.jp/api/meta/capabilities | jq '.capabilities[] |
select(.red_line)'`.

## When to reach for devops

- **Deploy a service** you just changed → `devops deploy <service>` (see the
  deploy recipes; don't reinvent). Never edit a live config on a device by hand
  — the store is the source of truth and a deploy will overwrite you.
- **Add a subdomain / route** → `devops dns add <zone> <name> --type CNAME
  --value t01.golia.jp.` and `devops caddy add <device> <id> --domain d
  --proxy 127.0.0.1:PORT`. One primitive each; both sync/deploy for you.
- **Change an existing site's Caddy config** (a header, a new `handle`) → write the block to a file, `devops caddy set-block <device> <id> --file <path>`. Never edit `/etc/caddy/Caddyfile` by hand.
- **Take a domain/service offline** → `devops caddy rm` + `devops dns rm`
  (both walk you through the red-line confirmation).
- **Check health / find a problem** → `devops health`, `devops status`,
  `devops caddy drift <device>`, `devops dns drift`, `devops iam diff`.
- **Triage errors** → `curl -s "https://devops.golia.jp/api/sync-log?status=error&limit=20"`.

## Never hardcode infra data

Device names, IPs, SSH users, domain expiry — always query, never assume:
`devops status` / `GET /api/infra/state` for devices, `devops domains` for
domains. Hardcoded infra data rots the moment a device changes.

## If the CLI isn't there

`devops doctor` failing to run means the CLI isn't installed on this machine
(operator machines have it via `cargo install`; it's a thin HTTP client of the
API). You can still reach read endpoints with `curl` + the key at
`~/.config/devops/api-key`, but **do not** hand-craft mutations — install the
CLI or hand the change to a session that has it.
