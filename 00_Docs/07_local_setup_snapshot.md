# Agent Caffeine — Local Setup Snapshot

> 2026-06-14 時点のローカル環境スナップショット。
> 引き継ぎ時に「repo 外にある設定」を最短で復元・確認するためのメモ。
> 機密情報を置く場所ではないため、relevant な断片だけを記録する。

## 目的

- repo 外にある `~/.claude/settings.json` と `~/.codex/config.toml` の relevant 設定を残す
- 実機で確認した `pgrep` パターンの当たり方を残す
- 将来 VSCode 拡張更新で検出が外れたときの比較基準にする

## ~/.claude/settings.json の relevant 部分

Claude 側は **B 案 / ターン中のみ** で配線済み。

- `UserPromptSubmit`
  - 既存 `create-project-autostart.mjs` は維持
  - 追加で `jq -r '.session_id // empty' | ... agent-caffeine acquire "${sid:-unknown}"` を実行
- `PreToolUse`
  - 監査ログと `create-project-autostart.mjs` を維持
  - agent-caffeine は未接続
- `Stop`
  - 既存 `afplay` は維持
  - 追加で `jq -r '.session_id // empty' | ... agent-caffeine release "${sid:-unknown}"` を実行

実体パス:

```text
/Users/yudai/local_development/02_Personal_Projects/agent-caffeine/src/agent-caffeine
```

補足:

- フック内は `PATH` 非依存にするため絶対パス直叩き
- `SessionStart` / `SessionEnd` は使っていない
- 現在の定義は「セッション中」ではなく **ターン中**

## ~/.codex/config.toml の relevant 部分

Codex 側は `notify` 未配線のまま。agent-caffeine は **C 案 / launchd + logs DB 監視** で扱う。
現状の重要点は以下。

- `notify` は既に computer-use 用で使用中

```toml
notify = ["/Users/yudai/.codex/computer-use/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient", "turn-ended"]
```

- このため agent-caffeine を notify に足す場合は、既存通知のラップまたは連鎖が必要
- ただし VSCode 拡張版 Codex が `~/.codex/config.toml` の `notify` を尊重するかは未検証
- そのため現実装では `notify` を使わず、`~/.codex/logs_2.sqlite` を監視する

参考になる現設定:

- `model = "gpt-5.4"`
- `approval_policy = "on-request"`
- `sandbox_mode = "workspace-write"`
- `[desktop] preventSleepWhileRunning = true`

最後の項目は Codex 自身のデスクトップ設定であり、agent-caffeine の代替にはならない前提で扱う。

## clamshell 判断の根拠

ローカル確認:

- `man caffeinate`
  - `-s` は **AC power のときだけ有効**
- `man pmset`
  - 設定変更は **root 必須**
  - `pmset -b sleep 0` 系は battery 時のグローバル設定変更になる

Apple ドキュメント:

- Mac の sleep/wake 設定ガイドでは、laptop 向けの
  `Prevent automatic sleeping on power adapter when the display is off`
  は **power adapter 側のみ**案内される
- closed-display mode は MacBook の外部ディスプレイ接続条件に依存する

採用した判断:

- AC 時のみ best-effort
- battery 時 clamshell は対象外
- root を要する `pmset` 自動変更は実装しない

## 実機で確認したプロセス検出例

2026-06-14 時点で次が実際に存在した。

### Claude

検出コマンド:

```bash
pgrep -af 'native-binary/claude'
```

観測例:

```text
24028 /Users/yudai/.vscode/extensions/anthropic.claude-code-2.1.159-darwin-arm64/resources/native-binary/claude ...
42853 /Users/yudai/.vscode/extensions/anthropic.claude-code-2.1.177-darwin-arm64/resources/native-binary/claude ...
```

### Codex

観測対象:

- `~/.codex/logs_2.sqlite`

観測例:

```text
app-server event: item/agentMessage/delta targeted_connections=1
app-server event: item/completed targeted_connections=1
app-server event: turn/completed targeted_connections=1
```

重要:

- Codex は `app-server` が VSCode を開いている間かなり常駐する
- そのため `pgrep` は release 判定に不向き
- `logs_2.sqlite` には turn 中の app-server event が残るため、現実装はこれを使う
- 開始側は `item/started` が常に出るとは限らないため、`item/agentMessage/delta` も開始シグナルに使う

## デプロイ済みのローカル配線

- symlink:
  - `~/.local/bin/agent-caffeine -> /Users/yudai/local_development/02_Personal_Projects/agent-caffeine/src/agent-caffeine`
- launchd:
  - `~/Library/LaunchAgents/com.yudai.agent-caffeine.plist`
  - `launchctl list | rg agent-caffeine` で `com.yudai.agent-caffeine` を確認済み
  - Codex watch は `~/Library/LaunchAgents/com.yudai.agent-caffeine-codex.plist` を使用
  - `launchctl list | rg agent-caffeine` で `com.yudai.agent-caffeine-codex` を確認済み

## janitor ログの見え方

現時点の `/tmp/agent-caffeine.err.log` では次のような出力を確認。

```text
[agent-caffeine] janitor: agents alive, holders=1 (no-op)
[agent-caffeine] janitor: agents alive, holders=2 (no-op)
```

確認コマンド:

```bash
tail -n 50 /tmp/agent-caffeine.err.log
```

観測メモ（2026-06-14）:

- 1 回目の release 実機確認では `agent-caffeine status` が `stopped / holders: 0` になった
- ただし Codex watch ログに `Codex gone` は残らず、janitor ログに
  `no agents alive, purged 2 leaked holder(s), caffeinate stopped` が出た
- よって「最終停止」は確認済みだが、「watch-codex の release 経路」は次回再確認が必要
- 2 回目の確認では `pgrep -af 'openai.chatgpt.*codex'` が **2 件**ヒットし続けた
- どちらも `codex app-server --analytics-default-enabled` で、親は `Code Helper (Plugin)`
- このため **Codex 会話を継続中の同一環境では `watch-codex` の release 実証が難しい**
  ことが分かった。C 案は「Codex パネル」ではなく「VSCode 拡張ホスト配下の app-server」
  を見ている点に注意
- その後、`logs_2.sqlite` に `item/started` / `turn/completed` が残ることを確認し、
  `pgrep` 監視から logs DB 監視へ設計変更した

観測メモ（2026-06-15）:

- 実機で `tail -f /tmp/agent-caffeine-codex.err.log` を監視した結果、次を確認:
  - `watch-codex-logs-once: turn started, token=codex log_id=...`
  - `acquire token=codex holders=1`
  - `watch-codex-logs-once: turn completed, token=codex log_id=...`
  - `release token=codex holders=0`
  - `started caffeinate ...` / `stopped caffeinate ...`
- つまり **Codex turn 中だけ holder が付き、完了後に外れる**ことを実機で確認済み
- logs DB 版 C 案で、release 経路の未実証は解消

## 引き継ぎ時の確認手順

1. `pgrep -af 'native-binary/claude'`
2. `pgrep -af 'openai.chatgpt.*codex'`
3. `agent-caffeine status`
4. `launchctl list | rg agent-caffeine`
5. `tail -n 50 /tmp/agent-caffeine.err.log`
6. `tail -n 50 /tmp/agent-caffeine-codex.err.log`

## 次の実装判断に必要な一文

現状は **起動中 = 稼働中で割り切る** を採用済み。
ターン精度が必要になったら、将来の変更として notify 連鎖を再検討する。
