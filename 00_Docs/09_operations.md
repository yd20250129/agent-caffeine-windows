# Agent Caffeine — Operations

日常運用と再セットアップの最短手順。
履歴や意思決定の経緯ではなく、**今この環境でどう扱うか**だけをまとめる。

## 現在の仕様

- Claude: ターン中だけ holder を持つ
- Codex: ターン中だけ holder を持つ
- janitor: エージェント全滅時のリーク掃除
- clamshell: **AC 時のみ best-effort**
- バッテリー時 clamshell: 対象外

## 初回セットアップ

```bash
cd /Users/yudai/local_development/02_Personal_Projects/agent-caffeine
./install.sh

cp launchd/com.yudai.agent-caffeine.plist ~/Library/LaunchAgents/
cp launchd/com.yudai.agent-caffeine-codex.plist ~/Library/LaunchAgents/

launchctl unload ~/Library/LaunchAgents/com.yudai.agent-caffeine.plist 2>/dev/null || true
launchctl unload ~/Library/LaunchAgents/com.yudai.agent-caffeine-codex.plist 2>/dev/null || true

launchctl load ~/Library/LaunchAgents/com.yudai.agent-caffeine.plist
launchctl load ~/Library/LaunchAgents/com.yudai.agent-caffeine-codex.plist
```

補足:

- Claude フックの relevant 設定は `00_Docs/07_local_setup_snapshot.md` 参照
- Codex は `~/.codex/logs_2.sqlite` を監視するので `notify` 変更は不要

## 状態確認

```bash
agent-caffeine status
launchctl list | rg 'agent-caffeine'
tail -n 50 /tmp/agent-caffeine.err.log
tail -n 50 /tmp/agent-caffeine-codex.err.log
```

期待:

- Claude / Codex の turn 中だけ holder が出る
- idle 時は holder が 0
- janitor は `/tmp/agent-caffeine.err.log`
- Codex watch は `/tmp/agent-caffeine-codex.err.log`

## 再デプロイ

スクリプトや plist を更新したあと:

```bash
cd /Users/yudai/local_development/02_Personal_Projects/agent-caffeine

cp launchd/com.yudai.agent-caffeine.plist ~/Library/LaunchAgents/
cp launchd/com.yudai.agent-caffeine-codex.plist ~/Library/LaunchAgents/

launchctl unload ~/Library/LaunchAgents/com.yudai.agent-caffeine.plist 2>/dev/null || true
launchctl unload ~/Library/LaunchAgents/com.yudai.agent-caffeine-codex.plist 2>/dev/null || true

launchctl load ~/Library/LaunchAgents/com.yudai.agent-caffeine.plist
launchctl load ~/Library/LaunchAgents/com.yudai.agent-caffeine-codex.plist
```

理由:

- `launchd` は plist だけでなく、常駐中の bash プロセスも再起動しないと新ロジックに切り替わらない

## 動作確認

### Claude

1. Claude で短い依頼を送る
2. 別ターミナルで `agent-caffeine status`
3. Claude の `session_id` holder が出て、完了後に消えることを確認

### Codex

1. 監視開始
   ```bash
   tail -f /tmp/agent-caffeine-codex.err.log
   ```
2. 別ターミナルで状態確認
   ```bash
   while true; do clear; agent-caffeine status; sleep 2; done
   ```
3. Codex で短い依頼を送る
4. 次を確認
   - `turn started` で `codex` holder が付く
   - `turn completed` で `codex` holder が消える

## テスト

```bash
bash tests/janitor_test.sh
bash tests/codex_log_watch_test.sh
```

## よくある確認ポイント

- `holders: 1` なのに想定外:
  - `agent-caffeine status`
  - `tail -n 50 /tmp/agent-caffeine*.err.log`
- Codex が反応しない:
  - `sqlite3 ~/.codex/logs_2.sqlite "select id, feedback_log_body from logs where feedback_log_body like 'app-server event:%' order by id desc limit 20;"`
- Claude が反応しない:
  - `~/.claude/settings.json` の hook を確認
- janitor が効かない / 効きすぎる:
  - Claude 側の `pgrep` パターン `native-binary/claude` を確認

## 拡張更新後チェック

VSCode 拡張を更新したら最低限これを見る。

```bash
pgrep -af 'native-binary/claude'
sqlite3 ~/.codex/logs_2.sqlite "select id, feedback_log_body from logs where feedback_log_body like 'app-server event:%' order by id desc limit 20;"
```

確認したいこと:

- Claude の実体パスが `pgrep` に当たる
- Codex の logs DB に `item/agentMessage/delta` / `item/completed` / `turn/completed` が出る
