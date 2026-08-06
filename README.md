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

## Optional: VSCode auto-hold

VSCode Remote SSH で EC2 側の Claude Code を回している間は、ローカル Windows 側の
hook が発火せず DC 電源で 180 秒でスリープする問題がある。Remote SSH を TCP 22
検知や接続ホスト名で絞り込む案は過剰と判断し、割り切って「VSCode プロセスが
生きている＝この PC で作業したい」と見なして `vscode-alive` という固定名 holder
を daemon 側で自動保持する簡易フォールバックを用意している。

副作用: VSCode を開いたまま放置するとスリープ抑止も続く（実害は電池消費のみ）。
承認プロンプトで席を外した間もカバーできるので、EC2 用途以外にも保険になる。

### 有効化

環境変数 `AGENT_CAFFEINE_WATCH_VSCODE` を `1` または `true` にする。既定は OFF。

永続化するには PowerShell で:

```powershell
[Environment]::SetEnvironmentVariable('AGENT_CAFFEINE_WATCH_VSCODE', '1', 'User')
```

その後、既に起動済みの daemon には反映されないので、daemon を再起動する:

```bash
agent-caffeine repair
```

または再ログインすれば logon-triggered task が新しい環境変数で起動する。

無効化するには `[Environment]::SetEnvironmentVariable('AGENT_CAFFEINE_WATCH_VSCODE', $null, 'User')`
で環境変数を消してから `agent-caffeine repair`。無効化後は次のポーリング (既定 20 秒)
で残っている `vscode-alive` holder が掃除される (他 holder には触らない)。

### 動作確認

```bash
agent-caffeine status
# holders に vscode-alive が現れていれば OK
```

daemon.log の `vscode-watch state=alive` / `state=gone` の行で状態遷移を追える。

## 補足

- スリープ抑止には Win32 API `SetThreadExecutionState` を PowerShell 経由で呼び出す
- シンボリックリンクには Windows Developer Mode が必要。無効な場合は自動的にコピーにフォールバックする
- タスクスケジューラのログは `%USERPROFILE%\agent-caffeine-janitor.log` に記録される
