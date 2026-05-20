---
name: plugin-author
description: MANDATORY when the user wants to create, scaffold, or release a Claude Code plugin or marketplace. Walks the full lifecycle — marketplace bootstrap (gh repo + git-flow with master as default branch), plugin scaffolding (plugin.json + skill + optional hook), state file portability, validate, multi-profile install, smoke-test, and release (version bump, tag, ff master, push). Never let the user write boilerplate by hand if the protocol can run the steps.
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

## Step 10a: First release (v0.1.0)

Used right after Step 9 succeeds — the plugin scaffolded in this session is at v0.1.0 and ready to publish for the first time.

```bash
# (scaffold changes already committed on develop)

# 1. dry-run verify version sync between plugin.json and marketplace.json entry
claude plugin tag ./<plugin-name> --dry-run

# 2. real tag (creates <plugin>--v<version> annotated tag at HEAD)
claude plugin tag ./<plugin-name>

# 3. git-flow: ff master to develop's HEAD (master = release line = default branch)
git checkout master
git merge develop --ff-only
git push origin master
git checkout develop

# 4. push develop + all tags
git push origin develop --tags
```

For releases after v0.1.0, follow **Step 10b** below — not this section.

## Step 10b: Subsequent release (vX.Y.Z, X+Y+Z > 1)

Use this when bumping an **already-released** plugin to a new version. The protocol below is what the model walks through end-to-end; if any step's check fails, **stop and surface the failure to the user**, do not silently proceed.

### 1. Diff: what changed since the last tag

```bash
LATEST=$(git tag --list "<plugin-name>--v*" --sort=-v:refname | head -1)
git log "$LATEST..HEAD" --oneline -- "<plugin-name>/"
```

Group commits into buckets — `feat:` / `fix:` / `refactor:` / `docs:` / `chore:` / **breaking**. Show the user a 3-5 line summary.

### 2. Propose semver bump

- **breaking** change present → **major**
- any `feat:` commit, no breaking → **minor**
- only `fix:` / `refactor:` / `docs:` / `chore:` → **patch**

Suggest, let user confirm or override. Compute `NEXT_VERSION`.

### 3. Pre-flight

- `git rev-parse --abbrev-ref HEAD` must be `develop`
- `git diff --quiet && git diff --cached --quiet` (clean tree — no WIP)

### 4. Run tests via consumer-provided hook (optional)

```bash
if [ -x "<marketplace-root>/.claude-plugin/test.sh" ]; then
  "<marketplace-root>/.claude-plugin/test.sh" "<plugin-name>"
else
  echo "no .claude-plugin/test.sh hook — skipping automated tests"
fi
```

This is **plugin-author defining a convention**: any marketplace that wants automated test integration creates `.claude-plugin/test.sh <plugin>` themselves. plugin-author **does not** dictate how tests are run — the consumer marketplace owns that. If the hook is missing, warn and continue (do not block).

If the hook fails (non-zero exit), **stop**. Surface the output to the user.

### 5. Bump both version fields atomically

Edit two files to the **same** new version:

- `<plugin-name>/.claude-plugin/plugin.json` → `"version": "<NEXT_VERSION>"`
- `.claude-plugin/marketplace.json` → the matching plugin entry's `"version"` field

Then immediately verify:

```bash
jq -r .version "<plugin-name>/.claude-plugin/plugin.json"
jq -r '.plugins[] | select(.name=="<plugin-name>") | .version' .claude-plugin/marketplace.json
```

Both must print `<NEXT_VERSION>`. If they don't match, fix and re-verify before continuing — this is the single most common release-day footgun.

### 6. Append to README Changelog

`<plugin-name>/README.md` should have a `## Changelog` section (per Step 11 template). Append one line:

```
- **<NEXT_VERSION>** — <one-line summary derived from the diff buckets in step 1>
```

If the README lacks a `## Changelog` section, add it before continuing (don't silently skip — the convention exists for a reason).

### 7. Commit the bump

```bash
git add "<plugin-name>/.claude-plugin/plugin.json" .claude-plugin/marketplace.json "<plugin-name>/README.md"
git commit -m "chore(<plugin-name>): release v<NEXT_VERSION>"
```

### 8. Tag and push (inlined release ceremony)

Same as Step 10a, but for the new version:

```bash
# dry-run first — catches version mismatch before any tag is made
claude plugin tag "./<plugin-name>" --dry-run

# real tag
claude plugin tag "./<plugin-name>"

# git-flow: ff master to develop
git checkout master
git merge develop --ff-only
git push origin master
git checkout develop

# push tags + develop
git push origin develop --tags
```

### 9. Run post-release hook via consumer (optional)

```bash
if [ -x "<marketplace-root>/.claude-plugin/post-release.sh" ]; then
  "<marketplace-root>/.claude-plugin/post-release.sh" "<plugin-name>" "<NEXT_VERSION>"
fi
```

Same convention as the test hook: plugin-author defines the path; consumer marketplace decides what to put in it (e.g. multi-profile reinstall, smoke test, notification). If absent, skip silently — post-release is the consumer's domain.

### 10. Report

Tell the user, in one line:

```
✔ <plugin-name>@v<NEXT_VERSION> released. Tag: <plugin-name>--v<NEXT_VERSION>.
  Master now at <short-sha>. Default branch ready for `claude plugin update`.
```

## Step 10 — Consumer hook conventions (reference)

plugin-author exposes exactly **two** optional hook paths that a marketplace consumer (the marketplace owner — not the end user of an installed plugin) may provide:

| Path | When invoked | Args | Required to exist? |
|------|-------------|------|--------------------|
| `<marketplace-root>/.claude-plugin/test.sh` | Step 10b §4 (before bump) | `<plugin-name>` | No — skip with warning if missing |
| `<marketplace-root>/.claude-plugin/post-release.sh` | Step 10b §9 (after tag pushed) | `<plugin-name> <version>` | No — skip silently if missing |

Both hooks are **invoked as standalone executables** — plugin-author does not source them, exec them, or inspect their internals. The consumer marketplace owns their content. plugin-author does **not** depend on, look inside, or assume anything about gitignored private paths like `.dev/`; the consumer can implement these hooks however they like (thin shell wrapper to private helpers, embedded logic, etc.).

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

Conceptual rationale, design trade-offs, and history of these conventions live in the marketplace repo's gitignored `.dev/plugin-authoring.md` — only accessible to maintainers. For end users of this skill, the protocol above is self-contained.
