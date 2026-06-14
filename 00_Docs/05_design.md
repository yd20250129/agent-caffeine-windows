# Agent Caffeine — 設計 / ADR

## 全体像

トリガ（いつ ON/OFF するか）と、コア（実際に caffeinate を上げ下げする）を分離する。
コアは A/B どちらでも共通で使える参照カウント式ラッパー（`src/agent-caffeine`）。
**決めるべきはトリガの配線方法**。

```
[トリガ] ──acquire/release──> [コア: agent-caffeine] ──> caffeinate -i
 A: launchd + pgrep                参照カウント
 B: Claude フック / Codex notify   holder が 1 つでもあれば ON
```

## 方式比較

### A 案: プロセス監視デーモン型（エージェント非依存）

launchd で常駐し `pgrep` で対象プロセスを定期検出 → いれば acquire、消えたら release。

検出対象（2026-06-14 実機確認・VSCode 拡張）:
- Claude: `pgrep -f 'native-binary/claude'`
- Codex: `pgrep -f 'openai.chatgpt.*bin/.*codex'`（`/Applications/Codex.app` ではない）

- ✅ エージェント側の設定に依存しない。Codex の「開始」検知の弱点が無い
- ✅ シンプル・堅牢
- ❌ 「開いてるだけ／実際に作業中」の区別ができない（要件 1 の定義次第で過剰抑止）
- ❌ 常時ポーリング（数秒間隔）が必要

### B 案: フック駆動型（環境特化 / 元 TODO の推奨）

- Claude: SessionStart で `acquire`、Stop/SessionEnd で `release`
- Codex: session 開始フックが無いため `notify`(turn-ended) かラッパー起動で補う
- ✅ ライフサイクルに正確追従・常時ポーリング不要
- ✅ 「ツール実行中のみ」等の細かい定義に寄せやすい（Claude は PreToolUse/PostToolUse も持つ）
- ❌ **Codex 側の「開始」検知が弱点**（notify は turn 終了通知が主）

### C 案: ハイブリッド（採用）

- Claude は B 案（フックで正確に追従）
- Codex は `~/.codex/logs_2.sqlite` を軽くポーリングし、
  `app-server event: item/started` / `turn/completed` で acquire/release
- ✅ `notify` を触らずに **ターン精度** に寄せられる
- ✅ `pgrep` のように app-server 常駐へ誤反応しない
- ❌ 実装が 2 系統になり複雑
- ❌ `~/.codex/logs_2.sqlite` の内部イベント名に依存する

> **推奨更新（2026-06-14）**: Codex の `notify` は computer-use が既に使用中で、VSCode 拡張版で
> 尊重されるかも未検証。一方 `~/.codex/logs_2.sqlite` には `item/started` / `item/completed` /
> `turn/completed` が記録されるため、**Codex は logs DB 監視で扱う C 案**を採用する。

#### C 案の実装（2026-06-14）

- `src/agent-caffeine watch-codex-logs`
  - `~/.codex/logs_2.sqlite` を既定 2 秒間隔で監視
  - `app-server event: item/started` または `item/agentMessage/delta` で `acquire codex`
  - `app-server event: item/completed` または `turn/completed` で `release codex`
- `launchd/com.yudai.agent-caffeine-codex.plist`
  - `KeepAlive` で watch を常駐
  - ログは `/tmp/agent-caffeine-codex.{out,err}.log`
- `watch-codex-logs-once`
  - 1 回だけ logs 判定を行うテスト用・手動確認用サブコマンド

この実装は notify 不要で、**Codex も「ターン中」**として扱える。
最大のリスクは `logs_2.sqlite` のイベント名や出力形式が将来変わること。

## コア実装（確定済み・方式非依存）

`src/agent-caffeine` は参照カウントで以下を提供:

- `acquire <token>`: holder 登録 → caffeinate 起動（冪等）
- `release <token>`: holder 解除 → 0 になれば停止
- `status`: 稼働状態と holder 一覧
- `reap`: PID 消滅した holder を掃除（FR-4 = 異常終了対策）
- `janitor`: claude/codex が**両方とも皆無**なら残存 holder を全消去して停止（③ crash-leak 対策・2026-06-14 追加）

状態: `~/.local/state/agent-caffeine/`（`caffeinate.pid` と `holders/<token>`）。
token が数値（PID）なら `reap` で生存検証して自動掃除。Claude の session_id 等
非数値 token はフックの release に依存するため、保険で薄いポーリング reap を推奨。

#### janitor（crash-leak の安全網）

ターン中（`UserPromptSubmit`→acquire）に Claude/Codex が異常終了すると、`Stop`→release が
発火せず holder が残る。session_id のような**非数値トークンは `reap` では消えない**ため、
caffeinate が無制限に動き続ける。`janitor` はこれを受けるための安全網:

- `pgrep -f "$CLAUDE_PATTERN"`（既定 `native-binary/claude`）でエージェント生存を確認
- **Codex 検出は既定で無効（`CODEX_PATTERN` は空）**。codex の `app-server` は VSCode を
  開いている間ずっと常駐するため、検出すると `agents_alive` がほぼ永久に true になり janitor が
  Claude のリークを掃除できなくなる（2026-06-14 デプロイ検証で実害確認）。現状 Codex は holder を
  作らない（acquire 未配線）ので検出不要。② で turn 精度の信号を用意できたら有効化する。
  空パターンは「無効」扱い（空のまま `pgrep -f ""` は全プロセスにマッチするため非空チェック必須）。
- **生きている claude が 1 つでもあれば何もしない**（他人の holder を巻き込まない＝過剰停止の防止）
- **両方皆無のときだけ**残存 holder を消去し caffeinate を停止
- **安全弁（grace）**: 全滅判定でも、作成から `JANITOR_GRACE` 秒（既定 60）未満の holder は消さない。
  検出パターンの誤判定や acquire 直後の取りこぼしで誤って「全滅」と見えても、起動直後の現役
  セッションを巻き込まない。新鮮な holder が残る間は caffeinate も止めない（mtime は `stat -f %m`）。
- 検出パターンは `AGENT_CAFFEINE_CLAUDE_PATTERN` / `AGENT_CAFFEINE_CODEX_PATTERN`、猶予は
  `AGENT_CAFFEINE_JANITOR_GRACE` で上書き可
- 常駐は `launchd/com.yudai.agent-caffeine.plist`（`StartInterval` で 60 秒ごとに実行）
- テスト: `tests/janitor_test.sh`（実 caffeinate を起動しないスタブ方式・5 ケース）

> 最大の故障モード = 検出パターンが将来の拡張更新で外れ、稼働中なのに「全滅」と誤判定すること。
> grace はこの誤判定からターン開始直後を守る保険。恒久対策は「拡張更新後に `pgrep -f` の生存確認」。
>
> 限界: claude が生きている（=別 VSCode ウィンドウのセッションが稼働中）状態で、過去にクラッシュ
> した別 claude セッションの holder が残っていても janitor は purge しない。session_id を生存
> プロセスに紐付けられない以上、「全員いなくなったら（grace 超過分を）全消し」が非数値トークンに
> 取れる最善。
>
> 複数ウィンドウの実例（2026-06-14）: 別プロジェクト（investment-dashboard）の Claude ウィンドウが
> ターン中に終了し holder `6d4f198e…` がリーク。現セッションが生存中のため janitor は保持し、
> 全 Claude ウィンドウを閉じた後に grace 経過で自動回収される。これは設計どおりの挙動。

## 未解決の設計論点（ADR 候補）

- **ADR-001 「稼働中」の定義**
  - Claude: ✅ **ターン中**（`UserPromptSubmit`→acquire / `Stop`→release）
  - Codex: ✅ **ターン中**（`watch-codex-logs` が `item/started` / `turn/completed` を監視）
  - 両者とも待機中は寝かせる省電力方針
- **ADR-002 バッテリー時の clamshell 維持** → ✅ 決定:
  - **AC 時のみ best-effort で支援**
  - **バッテリー時 clamshell は対象外**
  - 理由:
    - `caffeinate -s` は AC 時のみ有効（`man caffeinate`）
    - `pmset` による sleep 設定変更は root 権限が必要で、グローバル設定変更になる（`man pmset`）
    - Apple の設定 UI でも laptop 向けの「Prevent automatic sleeping ...」は power adapter 側のみ案内される
  - 実装方針:
    - 既定 `AGENT_CAFFEINE_FLAGS` を `-i -s` にする
    - battery 時に `pmset -b ...` を自動変更しない
    - closed-display mode の成立条件（外部電源、外部ディスプレイ/入力機器要件）は macOS の責務として扱う
- **ADR-003 配布形態** → ✅ 暫定決定: **C ハイブリッド**
  - Claude = フック駆動
  - Codex = launchd + pgrep watch
  - janitor = 60 秒ごとの safety net
