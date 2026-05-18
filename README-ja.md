# claude-plugins-golia

GOLIA K.K. が公開している Claude Code プラグインのマーケットプレイス。

> English: [README.md](./README.md) · 简体中文: [README-zh_cn.md](./README-zh_cn.md)

## プラグイン

| プラグイン | 概要 |
|------------|------|
| [port-registry](./port-registry) | ローカル開発サービス向けのポート割当て（DHCP 風）。同じプロジェクトは常に同じポートを使い続ける。PreToolUse フックがサーバ起動コマンドを検知して通知する。 |
| [plugin-author](./plugin-author) | Claude Code プラグインを一から作るためのプレイブック — マーケットプレイス雛形、scaffolding、フック/スキル設計、validate、install、release まで。 |

## インストール

マーケットプレイスを一度登録すれば、各プラグインを入れられる:

```
claude plugin marketplace add https://github.com/goliajp/claude-plugins-golia
claude plugin install port-registry@golia
claude plugin install plugin-author@golia
```

新しいバージョンを取り込む:

```
claude plugin marketplace update golia
claude plugin update <plugin>
```

## 開発用インストール（ローカルチェックアウト）

プラグインを改造したり変更を試したい場合は、GitHub URL の代わりにローカルのクローンを登録する:

```
git clone https://github.com/goliajp/claude-plugins-golia.git
claude plugin marketplace add ./claude-plugins-golia
claude plugin install <plugin>@golia
```

ローカルパス経由のインストールはホットリロード — `SKILL.md` やフックを編集すると次セッションで反映される（`update` 不要）。git/URL 経由はバージョン固定なので `claude plugin update` でしか進まない。

## ライセンス

MIT — [LICENSE](./LICENSE) を参照。
