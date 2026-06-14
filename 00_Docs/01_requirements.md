# Agent Caffeine — 要件

## 目的

Claude Code（`claude`）/ Codex（`/Applications/Codex.app`, gpt-5.4）が稼働している間だけ
Mac をスリープさせないツールを、自分の環境に特化して自作する。
$9 の [Agent Caffeine](https://caffeinagent.com) と同等を `caffeinate` で無料・自前実装。

## 環境特化のポイント

> **実行形態（2026-06-14 実機確認）**: Claude Code / Codex とも **VSCode 拡張**として常駐する。
> CLI 単体やスタンドアロンアプリではない。
> - Claude Code: `~/.vscode/extensions/anthropic.claude-code-*/resources/native-binary/claude`
> - Codex: `~/.vscode/extensions/openai.chatgpt-*/bin/macos-aarch64/codex`（OpenAI ChatGPT 拡張）
> - `/Applications/Codex.app` も存在するが computer-use 時に拡張が一時 spawn する補助プロセス。
>   **常駐の検出対象は VSCode 拡張側の codex バイナリ**であり Codex.app ではない。
> - 両プロセスとも拡張ホスト配下でパネルを開いている間は常駐 → pgrep では「セッションが開いている」
>   までしか判別できず「作業中」は分からない（→ 要決定事項 1 に直結）。

- 常用エージェントは **Claude Code と Codex の 2 種＋並行稼働**（worktree 運用）。
  検出対象を汎用 40+ ではなく上記 2 バイナリに絞れる。
- Claude Code は**フックを持つ**。**VSCode 拡張でも `~/.claude/settings.json` のフックは効く**。
  現状 `UserPromptSubmit` / `PreToolUse` / `Stop` を設定済み。
  acquire 用の `SessionStart`、release 用の `SessionEnd` は**未設定なので追加が要る**。
- Codex は**フック無し**。`~/.codex/config.toml` の `notify` は **1 枠のみ**で、現状すでに
  computer-use クライアント（SkyComputerUseClient, turn-ended）に占有されている。
  → acquire/release を足すには既存 notify を**ラップ/連鎖**する必要がある。
    そもそも **VSCode 拡張版 Codex が `~/.codex/config.toml` の notify を尊重するかは要検証**。
  → 両者で制御手段が異なる前提で設計する。

## 機能要件

| ID | 要件 |
|----|------|
| FR-1 | 対象エージェント稼働中はアイドルスリープを防止する（`caffeinate -i`） |
| FR-2 | 稼働終了後は確実にスリープ抑止を解除する（電池の無駄食いを防ぐ） |
| FR-3 | **並行稼働に対応**: 複数セッションが同時に稼働しても、最後の 1 つが終わるまで抑止継続 |
| FR-4 | プロセス/セッションが異常終了しても抑止が残り続けない（dead holder の掃除） |
| FR-5 | 現在の状態（抑止中か / 誰が holder か）を確認できる |

## 非機能要件

- 常時ポーリングを避ける（B 案）か、軽量なポーリング（A 案）に留める
- テレメトリ・外部送信なし（元ネタの売りに合わせる）
- 既存の Claude フック・Codex notify 設定を**壊さない**

## 要決定事項（未確定 — TASK_NOTES.md と連動）

1. **「稼働中」の定義**: セッションが開いている間 / ターン実行中のみ / ツール実行中のみ
   （元 Agent Caffeine は「エージェント実行中のみ」）
2. **clamshell（蓋を閉じた状態）**でも維持するか。AC 電源は標準で可だが
   **バッテリー時は `caffeinate` だけでは不可**（→ ADR-002 で「AC のみ best-effort / battery は対象外」に決定）
3. **配布形態**: launchd 常駐（A 案）/ フック駆動スクリプト（B 案）/ ハイブリッド

## 技術メモ

- `caffeinate -i`: アイドルスリープ防止・kill まで継続
- `caffeinate -i -w <PID>`: 指定プロセス終了まで待機（A 案の単発利用に便利）
- `man caffeinate` 参照
- Codex の `notify` は `~/.codex/config.toml` に設定済み（現状は computer-use クライアント）

## 参考

- 元ネタ [Agent Caffeine](https://caffeinagent.com)（$9 買い切り・テレメトリ無しを謳う／第三者検証ではない）
