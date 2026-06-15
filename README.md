# Agent Caffeine (Linux版)

Claude Code がターン中の間だけスリープを抑止するツール。
参照カウント方式により、複数セッションを並行稼働させても最後の1つが終わるまでスリープしない。

## セットアップ

```bash
./install.sh
```

- `~/.local/bin/agent-caffeine` へのシンボリックリンク作成
- janitor（クラッシュ時のリーク掃除）を60秒ごとに実行するsystemd timerを自動登録

`~/.local/bin` が PATH に入っていない場合は `.bashrc` 等に追記:

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
| `janitor` | クラッシュリーク掃除（systemd timerが自動実行） |
