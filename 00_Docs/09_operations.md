# Agent Caffeine — Operations

日常運用と再セットアップの最短手順。

## 現在の仕様

- Claude: ターン中だけ holder を持つ（`UserPromptSubmit`→acquire / `Stop`→release）
- janitor: Claude プロセス全滅時のリーク掃除（タスクスケジューラ、60秒ごと）
- スリープ抑止: SetThreadExecutionState + F15キー送信 + マウス微動（240秒間隔）
  → 組織 GPO の「5分操作なしスリープ」対策済み

## 初回セットアップ

```bash
cd /c/Users/N196893/agent-caffeine-windows
./install.sh
```

`install.sh` が行うこと:
- `~/.local/bin/agent-caffeine` に symlink（または copy）
- `agent-caffeine-janitor` をタスクスケジューラに登録

Claude フックの設定は `00_Docs/07_local_setup_snapshot.md` 参照。

## 状態確認

```bash
agent-caffeine status
schtasks /Query /TN "agent-caffeine-janitor" /FO LIST
tail -n 50 ~/agent-caffeine-janitor.log
```

期待:
- Claude のターン中だけ holder が出る
- idle 時は holders: 0
- janitor ログ: `~/agent-caffeine-janitor.log`

## 再デプロイ

スクリプトを更新したあと install.sh を再実行するだけでよい（symlink 先が更新される）。
タスクスケジューラの XML を変えた場合は install.sh を再実行してタスクを上書き登録する。

## 動作確認

### Claude

1. Claude で短い依頼を送る
2. 別ターミナルで `agent-caffeine status`
3. Claude の `session_id` holder が出て、完了後に消えることを確認

## テスト

```bash
bash tests/janitor_test.sh
```

## よくある確認ポイント

- `holders: 1` なのに想定外:
  - `agent-caffeine status`
  - `tail -n 50 ~/agent-caffeine-janitor.log`
- Claude が反応しない:
  - `~/.claude/settings.json` の hook を確認
- janitor が効かない / 効きすぎる:
  - Claude 側の検出パターン `win32-x64/claude` を確認
  - `powershell.exe -NoProfile -Command "Get-Process | Where-Object { \$_.Path -match 'win32-x64/claude' }"`

## 拡張更新後チェック

VSCode 拡張を更新したら:

```bash
powershell.exe -NoProfile -Command "Get-Process | Where-Object { \$_.Path -match 'win32-x64/claude' } | Select-Object Path"
```

確認したいこと: Claude の実体パスが `win32-x64/claude` にマッチする
