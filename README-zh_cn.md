# claude-plugins-golia

GOLIA K.K. 发布的 Claude Code 插件市场。

> English: [README.md](./README.md) · 日本語: [README-ja.md](./README-ja.md)

## 插件

| 插件 | 用途 |
|------|------|
| [port-registry](./port-registry) | 本地开发服务的端口分配器（DHCP 风格）。同一项目恒定使用同一端口；PreToolUse hook 在 Claude 启动服务前自动提醒。 |
| [plugin-author](./plugin-author) | Claude Code 插件从零到发布的完整 playbook —— marketplace 初始化、scaffolding、hook/skill 设计、validate、install、release。 |

## 安装

注册 marketplace 一次，然后安装需要的插件:

```
claude plugin marketplace add https://github.com/goliajp/claude-plugins-golia
claude plugin install port-registry@golia
claude plugin install plugin-author@golia
```

之后拿新版本:

```
claude plugin marketplace update golia
claude plugin update <plugin>
```

## 开发模式安装（本地 checkout）

如果你要改这些插件、或者本地测试改动，把本地 clone 注册成 marketplace（替代 GitHub URL）:

```
git clone https://github.com/goliajp/claude-plugins-golia.git
claude plugin marketplace add ./claude-plugins-golia
claude plugin install <plugin>@golia
```

本地路径安装是热重载 —— 改 `SKILL.md` 或 hook 后下一次会话自动生效（不需要 `update`）。git/URL 安装是版本锁定，必须 `claude plugin update` 才能拿新版。

## 许可证

MIT —— 见 [LICENSE](./LICENSE)。
