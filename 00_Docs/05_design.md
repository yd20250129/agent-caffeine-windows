# Agent Caffeine — 設計 / ADR

## 全体像

トリガ（いつ ON/OFF するか）と、コア（実際に caffeinate を上げ下げする）を分離する。
コアは参照カウント式ラッパー（`src/agent-caffeine`）。

```
[トリガ] ──acquire/release──> [コア: agent-caffeine] ──> PowerShell sleep-inhibit
 Claude フック                 参照カウント
 UserPromptSubmit/Stop         holder が 1 つでもあれば ON
```

## 採用方式: B案（フック駆動型）

- Claude: `UserPromptSubmit` で `acquire`、`Stop` で `release`
- ✅ ライフサイクルに正確追従・常時ポーリング不要
- ✅ ターン中のみ抑止する省電力方針

## コア実装

`src/agent-caffeine` は参照カウントで以下を提供:

- `acquire <token>`: holder 登録 → sleep-inhibit 起動（冪等）
- `release <token>`: holder 解除 → 0 になれば停止
- `status`: 稼働状態と holder 一覧
- `reap`: PID 消滅した holder を掃除（FR-4 = 異常終了対策）
- `janitor`: claude が**皆無**なら残存 holder を全消去して停止（crash-leak 対策）

状態: `~/.local/state/agent-caffeine/`（`caffeinate.pid` と `holders/<token>`）。
token が数値（PID）なら `reap` で生存検証して自動掃除。Claude の session_id 等
非数値 token はフックの release に依存するため、janitor が安全網として機能する。

## スリープ抑止の実装（三重対策）

`start_caffeinate` が起動する PowerShell プロセスは 240 秒（4分）間隔でループし、
以下を組み合わせることで組織 GPO 管理環境の「5分操作なしスリープ」を突破する:

1. **`SetThreadExecutionState(0x80000003)`** — Windows API でシステムスリープを直接ブロック
   （GPO 非管理環境や `ES_SYSTEM_REQUIRED` が効く環境向け）
2. **`SendKeys('{F15}')`** — キーボードアクティビティを偽装
   F15 は画面や入力欄に影響しない仮想キー。GPO が「キーボード操作なし XX 分でスリープ」を
   強制していてもアクティビティとして認識させられる。
3. **マウス 1px 微動** — ポインタアクティビティも偽装（元の位置に即戻す）

間隔を 240 秒にしているのは、5 分（300 秒）制限に対して 1 分の余裕を持たせるため。

## janitor（crash-leak の安全網）

ターン中（`UserPromptSubmit`→acquire）に Claude が異常終了すると、`Stop`→release が
発火せず holder が残る。session_id のような**非数値トークンは `reap` では消えない**ため、
caffeinate が無制限に動き続ける。`janitor` はこれを受けるための安全網:

- `CLAUDE_PATTERN`（既定 `win32-x64/claude`）で Claude プロセスの生存を確認
- **生きている claude が 1 つでもあれば何もしない**（過剰停止の防止）
- **皆無のときだけ**残存 holder を消去して停止
- **安全弁（grace）**: 全滅判定でも、作成から `JANITOR_GRACE` 秒（既定 60）未満の holder は消さない
- 常駐: Windows タスクスケジューラ（60 秒ごとに実行）

## ADR

- **ADR-001 「稼働中」の定義**: **ターン中**（`UserPromptSubmit`→acquire / `Stop`→release）
- **ADR-002 バッテリー時の挙動**: SetThreadExecutionState と入力偽装はバッテリー時も動作する。
  AC/バッテリーの区別は実装しない。
- **ADR-003 配布形態**: B案（Claude フック駆動）＋ janitor（タスクスケジューラ安全網）
