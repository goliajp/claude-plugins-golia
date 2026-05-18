# claude-plugins-golia

Marketplace of Claude Code plugins published by GOLIA K.K.

> 日本語: [README-ja.md](./README-ja.md) · 简体中文: [README-zh_cn.md](./README-zh_cn.md)

## Plugins

| Plugin | What it does |
|--------|--------------|
| [port-registry](./port-registry) | DHCP-style port allocator for local dev services. Same project → same port across sessions; a PreToolUse hook auto-reminds Claude before server-starting commands. |
| [plugin-author](./plugin-author) | End-to-end playbook for creating new Claude Code plugins — marketplace bootstrap, scaffolding, hook/skill design, validate, install, release. |

## Install

Register the marketplace once, then install the plugins you want:

```
claude plugin marketplace add https://github.com/goliajp/claude-plugins-golia
claude plugin install port-registry@golia
claude plugin install plugin-author@golia
```

To pick up newer versions later:

```
claude plugin marketplace update golia
claude plugin update <plugin>
```

## Development install (local checkout)

To hack on these plugins or test changes locally, register the marketplace from a local clone instead of the GitHub URL:

```
git clone https://github.com/goliajp/claude-plugins-golia.git
claude plugin marketplace add ./claude-plugins-golia
claude plugin install <plugin>@golia
```

Local-path installs hot-reload — edit `SKILL.md` or hooks and the new content is picked up on the next session, no `update` needed. Git/URL installs are version-locked and require `claude plugin update` to advance.

## License

MIT — see [LICENSE](./LICENSE).
