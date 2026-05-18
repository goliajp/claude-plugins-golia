---
name: plugin-author
description: 'MANDATORY when the user wants to create a new Claude Code plugin, scaffold a new marketplace, or release a plugin version. Triggers on phrases like "create a plugin", "make a marketplace", "init plugin", "new plugin", "scaffold plugin", "做一个 plugin", "建一个 marketplace", or any plugin-authoring lifecycle question. Walks the full flow professionally — marketplace bootstrap (gh repo + git-flow with master as default branch), plugin scaffolding (plugin.json + skill + optional hook), state file portability, validate, install across profiles, smoke-test, and release (bump version, tag, ff master, push). Never let the user write boilerplate by hand if you can run the steps for them.'
---

# plugin-author — Protocol

A step-by-step playbook for creating a Claude Code plugin end-to-end. Each step is actionable; together they cover the full lifecycle from "no marketplace exists" to "v0.1.0 is published on GitHub".

## Pre-flight (confirm BEFORE any destructive action)

1. `gh auth status` — gh CLI installed and authed (required for new GitHub repo)
2. `git config user.email` — non-empty
3. Confirm with the user:
   - Marketplace source location (typically `~/workspace/<marketplace-repo>/`)
   - GitHub `<owner>/<repo>` namespace (org needs `admin:org` token scope)
   - **Marketplace internal `name` field** — kebab-case, **MUST NOT start with `claude-plugins-`** (Anthropic reserved; validator rejects with "Marketplace name impersonates an official Anthropic/Claude marketplace"). Use an org-prefixed namespace like `<owner>-plugins` or just `<owner>`.
   - Plugin name (kebab-case)
   - Whether the plugin has state (data file) — affects Step 6
   - Whether the plugin needs implicit triggering — affects Step 5

## Step 1: Does the marketplace already exist?

Check for `<marketplace-root>/.claude-plugin/marketplace.json`.

- **Yes** → skip to Step 3 (just add a new plugin entry to existing marketplace).
- **No** → Step 2 (bootstrap the marketplace from scratch).

## Step 2: Bootstrap marketplace (only if missing)

Create the skeleton:

```bash
mkdir -p <marketplace-root>/.claude-plugin
cd <marketplace-root>
```

Write `.claude-plugin/marketplace.json`:

```json
{
  "name": "<short-namespace>",
  "description": "...",
  "owner": {
    "name": "<owner>",
    "url": "https://github.com/<owner>"
  },
  "plugins": []
}
```

Git init on `develop` (git-flow convention), initial commit, create GitHub repo, push, set up `master`, set default branch:

```bash
git init -b develop
git add .claude-plugin
git commit -m "marketplace: initial scaffold"

gh repo create <owner>/<repo> --public --description "..."
git remote add origin git@github.com:<owner>/<repo>.git
git push -u origin develop

git checkout -b master
git push -u origin master
git checkout develop

gh repo edit <owner>/<repo> --default-branch master
```

**Why default branch is `master`, not `develop`** — and why it matters: marketplace.json uses relative source paths (`./<plugin>`) which **don't lock a git ref/sha**. `claude plugin install/update` pulls the default branch HEAD. If default is `develop`, consumers get whatever WIP commits are on develop — breaking release discipline. With default = `master`, master is ff-merged to the tagged commit after each release, so `master HEAD = release snapshot = what consumers pull`.

## Step 3: Scaffold the plugin directory

Flat layout (plugin sits directly under marketplace root, no `plugins/` middle dir):

```
<marketplace-root>/<plugin-name>/
├── .claude-plugin/plugin.json
├── README.md
├── skills/<plugin-name>/SKILL.md       # protocol (on-invoke loaded)
└── hooks/                               # only if implicit triggering is needed
    ├── hooks.json
    └── <event>.py
```

`<plugin-name>/.claude-plugin/plugin.json`:

```json
{
  "name": "<plugin-name>",
  "version": "0.1.0",
  "description": "...",
  "author": { "name": "<owner>" }
}
```

## Step 4: Write the SKILL (description craft)

`skills/<plugin-name>/SKILL.md` frontmatter:

```yaml
---
name: <plugin-name>
description: <one-paragraph trigger description, lead with MANDATORY/NEVER/ALWAYS, ~100 tokens max>
---
```

**Description craft rules**:

- Lead with **MANDATORY** / **NEVER** / **ALWAYS** — raises LLM trigger priority dramatically.
- One paragraph saying "when this skill applies", not a feature dump.
- **Do NOT enumerate trigger commands in the description** — that's the hook's job. Description bloat balloons always-on token cost.
- After install, verify with `claude plugin details <plugin-name>`. Aim for always-on ~50–150 tok. Trim the description if it's higher.

Body of SKILL.md = the actual protocol (whatever the plugin's domain needs — lookup flow, allocation rules, conflict resolution, etc.).

## Step 5: Hook design (only if implicit triggering needed)

If the plugin must auto-fire on tool calls (e.g. PreToolUse to catch Bash commands that imply the plugin's domain), add `hooks/`.

`hooks/hooks.json`:

```json
{
  "description": "<one-liner>",
  "hooks": {
    "PreToolUse": [{
      "hooks": [{
        "type": "command",
        "command": "python3 ${CLAUDE_PLUGIN_ROOT}/hooks/<event>.py",
        "timeout": 5
      }]
    }]
  }
}
```

`hooks/<event>.py` skeleton:

```python
#!/usr/bin/env python3
"""<one-line purpose>. Errors swallowed silently (exit 0, empty stdout)
so the hook never breaks Claude's flow."""
import sys, json, re, os
from datetime import datetime

_LOG = os.environ.get('<PLUGIN>_HOOK_LOG')

def _log(msg):
    if not _LOG: return
    try:
        with open(_LOG, 'a') as f:
            f.write(f'{datetime.now().isoformat()} {msg}\n')
    except Exception:
        pass

PATTERNS = [
    # wide-net regexes for the trigger
]
_COMPILED = [re.compile(p, re.IGNORECASE) for p in PATTERNS]

REMINDER = "..."

def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        _log('malformed stdin'); sys.exit(0)
    if payload.get('tool_name') != 'Bash':
        sys.exit(0)
    cmd = payload.get('tool_input', {}).get('command', '')
    if not cmd or not any(p.search(cmd) for p in _COMPILED):
        _log(f'no-match {cmd[:120]!r}'); sys.exit(0)
    _log(f'MATCH {cmd[:120]!r}')
    sys.stdout.write(json.dumps({"systemMessage": REMINDER}))

if __name__ == '__main__':
    main()
```

`chmod +x hooks/<event>.py` so it's executable.

**Hook robustness rules (non-negotiable)**:

- Any exception → **silent exit 0**. Hook MUST NEVER break Claude's flow.
- stdin = JSON payload; stdout = JSON output (or empty).
- Pattern matching **wide > strict**: false positives cost ~70 tokens of reminder; false negatives are the original bug.
- Always add `<PLUGIN>_HOOK_LOG` env-gated logging — invaluable for debugging "did the hook actually fire".

**Hook output JSON schema** (cross-confirmed):

- `{"systemMessage": "..."}` — inject text into Claude's reasoning (most common case).
- `{"decision": "block", "reason": "..."}` — hard-block the tool call (rare, for safety).
- `{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny"}}` — PreToolUse permission denial.

## Step 6: State file portability (only if plugin has state)

State **MUST NOT** live inside the plugin directory — `claude plugin update` overwrites the plugin dir and would wipe user state.

Two-layer resolve in the SKILL protocol:

```
1. $<PLUGIN>_DATA env var if set and non-empty.
2. Otherwise ~/.claude/<plugin>-data.md (single-profile users get it free).
3. If file doesn't exist → Bootstrap (inline template below) before first read.
```

Include a Bootstrap section in SKILL.md with the exact markdown template to create on first run. Mention to user: `"Created <plugin> data file at <path>"`.

Multi-profile / shared setups (like ours): user exports `<PLUGIN>_DATA=~/.claude-shared/<plugin>-data.md` in shell rc to point all profiles at one shared file. Skill protocol stays portable; environment opts into sharing.

## Step 7: Register plugin in marketplace.json

Append to `plugins[]` array in `<marketplace-root>/.claude-plugin/marketplace.json`:

```json
{
  "name": "<plugin-name>",
  "description": "...",
  "source": "./<plugin-name>",
  "version": "0.1.0",
  "category": "developer-tools",
  "tags": ["...", "..."]
}
```

`source` is a relative path from `marketplace.json`'s directory.

## Step 8: Validate

```bash
claude plugin validate <marketplace-root>
claude plugin validate <marketplace-root>/<plugin-name>
```

Both must pass before installing. Common failures:

- `Marketplace name impersonates an official Anthropic/Claude marketplace` → fix the `name` field (don't use `claude-plugins-*` prefix).
- `plugin.json version` mismatch with marketplace entry → align both to the same semver.

## Step 9: Install + smoke-test

For our multi-profile setup:

```bash
for p in 1 2 3; do
  CLAUDE_CONFIG_DIR=~/.claude-profile-$p claude plugin marketplace add <marketplace-root>
  CLAUDE_CONFIG_DIR=~/.claude-profile-$p claude plugin install <plugin>@<marketplace-name>
done
```

Smoke-test checklist:

1. **Plugin loaded** — `claude plugin details <plugin>` shows component inventory + token cost. Verify always-on is in the expected range (~50–150 tok for skill description).
2. **Hook unit test** (if hook exists) — `echo '{"tool_name":"Bash","tool_input":{"command":"<trigger>"}}' | python3 <plugin>/hooks/<event>.py` should output systemMessage JSON; negative inputs should output nothing.
3. **Hook fires in fresh session** (if hook exists) — `<PLUGIN>_HOOK_LOG=/tmp/h.log claude -p '<prompt that triggers>'` should write a `MATCH` line to `/tmp/h.log`. (Note: `claude -p` mode triggers hooks but may not inject systemMessage into LLM reasoning; interactive sessions do.)
4. **Skill description visible in fresh session** — `claude -p 'Quote the first 10 words of the <plugin> skill description.'` should quote frontmatter back.

## Step 10: Release

When ready to publish:

```bash
# (changes already committed on develop)

# 1. dry-run verify version sync between plugin.json and marketplace.json entry
claude plugin tag ./<plugin-name> --dry-run

# 2. real tag (creates <plugin>--v<version> annotated tag at HEAD)
claude plugin tag ./<plugin-name>

# 3. git-flow: ff master to develop (master = release line = default branch)
git checkout master
git merge develop --ff-only
git push origin master
git checkout develop

# 4. push develop + all tags
git push origin develop --tags
```

For releases after v0.1.0: bump version in **both** `<plugin>/.claude-plugin/plugin.json` and the marketplace.json entry (they must match, `claude plugin tag` checks). Commit. Then repeat the flow.

## Step 11: README

`<plugin>/README.md` (for end users):

```markdown
# <plugin-name>

<one-line tagline>

## Install

\`\`\`
claude plugin marketplace add https://github.com/<owner>/<repo>
claude plugin install <plugin>@<marketplace-name>
\`\`\`

## Update

\`\`\`
claude plugin marketplace update <marketplace-name>
claude plugin update <plugin>
\`\`\`

## Uninstall

\`\`\`
claude plugin uninstall <plugin>
\`\`\`

## Changelog

- **0.1.0** — initial release
```

## Common pitfalls

- ❌ Marketplace `name` starts with `claude-plugins-` → validator rejects.
- ❌ State file inside plugin directory → `claude plugin update` wipes it.
- ❌ Description listing all trigger commands → balloons always-on token cost; let the hook detect commands.
- ❌ `plugin.json` version ≠ marketplace.json entry version → `claude plugin tag` refuses (correctly).
- ❌ Default branch = `develop` → consumers pull unreleased work. Set to `master`.
- ❌ Hook lacks try/except → exception crashes Claude's tool call flow. Always silent exit 0 on error.
- ❌ Using `--force` on first `claude plugin tag` → bypasses safety checks. Almost never the right move.
- ❌ Putting marketplace under `~/.claude-shared/` → that's Claude Code runtime state. Use `~/workspace/<repo>/` instead.

## Reference

Conceptual rationale, design trade-offs, and history of these conventions: the sth library doc at `~/workspace/labs/lab5-sth/claude-code/plugin-authoring.md`.
