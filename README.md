# Agent Caffeine

Claude Code / Codex が稼働している間だけ Mac をスリープさせない自作ツール。
$9 の [Agent Caffeine](https://caffeinagent.com) 相当を、macOS 標準の `caffeinate` で無料・自前実装する。

## 構成

```
agent-caffeine/
├── README.md            これ
├── install.sh           ~/.local/bin に symlink + 配線スニペット表示
├── src/agent-caffeine   本体（参照カウント式の caffeinate ラッパー）
├── launchd/             janitor / Codex watch 用の plist テンプレート
├── 00_Docs/
│   ├── 01_requirements.md   目的・要件・要決定事項
│   ├── 05_design.md         A/B/ハイブリッド比較 + ADR
│   ├── 07_local_setup_snapshot.md  ~/.claude / ~/.codex の relevant 設定控え
│   └── 09_operations.md     日常運用・再デプロイ手順
└── TASK_NOTES.md        未決事項・人間への質問
```

## クイックスタート

```bash
./install.sh                          # ~/.local/bin/agent-caffeine に symlink
agent-caffeine acquire test1          # caffeinate 起動
agent-caffeine status                 # 状態確認
agent-caffeine release test1          # holder 0 で caffeinate 停止
```

## 設計の肝: 参照カウント

Claude / Codex を worktree で**並行稼働**させるため、単純な ON/OFF だと片方の
セッション終了でもう片方が稼働中なのにスリープしてしまう。holder をトークン単位で
登録し、1 つでも生きている間だけ caffeinate を動かす方式にしている。

詳細は [00_Docs/05_design.md](00_Docs/05_design.md)。

日常運用と再デプロイ手順は [00_Docs/09_operations.md](00_Docs/09_operations.md)。

## ステータス

🟢 コア完成 + **B 案(Claude) 配線済み / 「稼働中」= ターン中**（`~/.claude/settings.json` の UserPromptSubmit→acquire / Stop→release）。
🟢 crash-leak janitor 実装・デプロイ済み（launchd で 60 秒ごとに監視）。
🟢 Codex(C 案) 実装・デプロイ済み（`watch-codex-logs` + launchd。`~/.codex/logs_2.sqlite` 監視で「ターン中 = 稼働中」）。
🟡 clamshell は **AC 時のみ best-effort**。**バッテリー時 clamshell は対象外**。
次のアクションは [TASK_NOTES.md](TASK_NOTES.md) 参照。

## clamshell 方針

- AC 時:
  - 既定フラグは `caffeinate -i -s`
  - `-s` は AC 上でのみ有効なので、agent 実行中の system sleep 抑止を少し強める
  - ただし closed-display mode 自体の成立条件（外部電源、必要な周辺機器や外部ディスプレイ要件）は macOS 側に依存
- バッテリー時:
  - `caffeinate` 単体では clamshell 維持を保証できない
  - `pmset -b sleep 0` 系は root 権限が必要で、グローバル設定を書き換えるため本ツールの標準機能にはしない
- 必要なら `AGENT_CAFFEINE_FLAGS` で上書き可能
