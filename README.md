# Agent Caffeine (Windows Git Bash版)

Claude Code がターン中の間だけ Windows のスリープを抑止するツール。
参照カウント方式により、複数セッションを並行稼働させても最後の1つが終わるまでスリープしない。

## 必要なもの

- [Git for Windows](https://gitforwindows.org/)（Git Bash を使用）
- [jq](https://jqlang.github.io/jq/) — Claude Code フック用（`winget install jqlang.jq`）
- [sqlite3](https://www.sqlite.org/download.html) — Codex 監視機能を使う場合（`winget install SQLite.SQLite`）

## セットアップ

Git Bash で実行:

```bash
./install.sh
```

- `~/.local/bin/agent-caffeine` へのリンク作成
- janitor（クラッシュ時のリーク掃除）をタスクスケジューラに1分ごとで登録

`~/.local/bin` が PATH に入っていない場合は `~/.bashrc` に追記:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## Claude Code との配線

`~/.claude/settings.json` の `hooks` に以下を追加:

```json
"hooks": {
  "UserPromptSubmit": [
    {"hooks": [{"type": "command", "command": "bash -c 'agent-caffeine acquire \"$(jq -r .session_id)\"'"}]}
  ],
  "Stop": [
    {"hooks": [{"type": "command", "command": "bash -c 'agent-caffeine release \"$(jq -r .session_id)\"'"}]}
  ]
}
```

## 動作確認

```bash
agent-caffeine acquire test1   # スリープ抑止開始
agent-caffeine status          # 状態確認
agent-caffeine release test1   # スリープ抑止解除
```

## 主なコマンド

| コマンド | 説明 |
|---|---|
| `acquire [token]` | holder を登録してスリープ抑止開始 |
| `release [token]` | holder を解除（0になれば抑止解除） |
| `status` | 現在の状態とholder一覧を表示 |
| `janitor` | クラッシュリーク掃除（タスクスケジューラが自動実行） |

## 補足

- スリープ抑止には Win32 API `SetThreadExecutionState` を PowerShell 経由で呼び出す
- シンボリックリンクには Windows Developer Mode が必要。無効な場合は自動的にコピーにフォールバックする
- タスクスケジューラのログは `%USERPROFILE%\agent-caffeine-janitor.log` に記録される
