# plugin-author

A Claude Code skill that walks you through creating a new plugin (or a new marketplace) end-to-end. Invoke it whenever you want to scaffold plugin infrastructure professionally without writing boilerplate by hand.

## What it covers

- **Marketplace bootstrap** if you don't have one yet — `gh repo create`, git-flow (`develop` for active dev, `master` as release line + default branch), initial commit, push
- **Plugin scaffolding** — directory layout, `plugin.json`, `SKILL.md` with proper trigger description, optional PreToolUse hook
- **State file portability** — env override + standard default + bootstrap-when-missing, so the plugin works for anyone who installs it
- **Validation + multi-profile install + smoke tests** — manifest validation, install across profiles, hook unit tests, fresh-session description quote
- **Release flow** — `claude plugin tag` verify, ff-merge `master` to `develop` HEAD, push tags
- **Common pitfalls** — marketplace name reserved prefixes, state files inside plugin dir, description token bloat, default-branch traps

## Install

```
claude plugin marketplace add https://github.com/goliajp/claude-plugins-golia
claude plugin install plugin-author@golia
```

## Use

Just say something like:

- "Help me make a new plugin called X"
- "Scaffold a marketplace at Y for plugins by Z"
- "I want to publish a plugin"

The skill auto-triggers from the description; once invoked it walks the lifecycle step by step.

## Update

```
claude plugin marketplace update golia
claude plugin update plugin-author
```

## Uninstall

```
claude plugin uninstall plugin-author
```

## Changelog

- **0.1.0** — initial release. End-to-end plugin authoring protocol from scratch, including marketplace bootstrap, hook/skill design, portability, validate/install/test, and the git-flow release flow.
