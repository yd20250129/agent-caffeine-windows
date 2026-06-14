# TASK_NOTES — agent-caffeine

> **次セッションへの引き継ぎ（2026-06-15 更新）**
> このファイルが作業の正本。再開はここだけ読めば OK。
> **最初にやること** → 運用は `00_Docs/09_operations.md`、ローカル設定は `00_Docs/07_local_setup_snapshot.md` を参照。
> プロジェクト: `02_Personal_Projects/agent-caffeine/` / 正本スクリプト: `src/agent-caffeine`
> ユーザーは「Claude(B案) → 再起動して確認 → Codex(C案)」の順で進める方針。
> repo 外のローカル設定スナップショットは `00_Docs/07_local_setup_snapshot.md` 参照。

## 現状（完了分）

- 🟢 軽量 Project 化（scaffold）
- 🟢 コア `src/agent-caffeine`（参照カウント式・方式非依存）。smoke test 済み（並行 acquire/release・dead holder の reap）
- 🟢 `install.sh` 実行済み → `~/.local/bin/agent-caffeine` に symlink 済み
- 🟢 **B 案(Claude) 配線完了 / 「稼働中」= ターン中**
  - `~/.claude/settings.json`: `UserPromptSubmit`→`agent-caffeine acquire <session_id>` / `Stop`→`release <session_id>`
  - 既存フック（create-project / PreToolUse 監査ログ / afplay）は保持
  - フック内は**絶対パス直叩き**（PATH 非依存）。caffeinate は `nohup + disown` で detach 済み
  - ✅ **実証済み（2026-06-14）**: 実セッションで `UserPromptSubmit` 発火 → holder 登録 →
    `status` が `RUNNING` + 当該 session_id を表示。ADR-001（ターン中）の acquire 側は実環境で確認済み。
- 🟢 **③ janitor（crash-leak 安全網）実装＋デプロイ完了**（2026-06-14）
  - `src/agent-caffeine janitor`: 生きてる claude が皆無なら残存 holder を消去して停止
  - **Codex 検出は既定で無効**（`CODEX_PATTERN` 空）。app-server が常駐し誤検出→janitor 無効化する
    実害をデプロイ検証で発見し修正。現状 Codex は holder 未作成なので Claude のみ見れば十分。
  - **安全弁**: 全滅判定でも作成 `JANITOR_GRACE` 秒（既定60）未満の新鮮 holder は消さない＝
    検出パターン誤判定でも起動直後の現役セッションを巻き込まない（`stat -f %m` で mtime 判定）
  - `launchd/com.yudai.agent-caffeine.plist`: `StartInterval` 60 秒で janitor を定期実行
    → **`~/Library/LaunchAgents/` に配置＆`launchctl load` 済み**。`launchctl list | grep agent-caffeine` で確認可
  - `tests/janitor_test.sh`: 実 caffeinate を起動しないスタブ方式。✅ **6 ケース全 PASS**
    （grace=0で全消去 / 生存時 no-op / reap数値 / 新鮮holder保護 / 古いholder消去 / 空パターン無効）
  - 解除したい時: `launchctl unload ~/Library/LaunchAgents/com.yudai.agent-caffeine.plist`
- 🟢 **② Codex(C 案) 実装＋デプロイ完了**（2026-06-14）
  - 初版: `watch-codex` = `pgrep -f 'openai.chatgpt.*codex'` 監視
  - 問題: `codex app-server` が常駐し、release を正しく判定できなかった
  - 更新版: `watch-codex-logs` = `~/.codex/logs_2.sqlite` の
    `app-server event: item/started` または `item/agentMessage/delta` /
    `item/completed` または `turn/completed` を監視
  - `launchd/com.yudai.agent-caffeine-codex.plist`: logs 版に更新
  - `tests/codex_log_watch_test.sh`: ✅ **6 ケース全 PASS**
  - 意味論: **Codex も「ターン中 = 稼働中」**
  - ✅ **release 実証済み（2026-06-15）**:
    - `/tmp/agent-caffeine-codex.err.log` に
      `watch-codex-logs-once: turn started, token=codex ...`
      `watch-codex-logs-once: turn completed, token=codex ...`
      が連続して出力
    - あわせて `acquire token=codex` / `release token=codex holders=0`、
      `started caffeinate ...` / `stopped caffeinate ...` を確認
    - つまり **Codex turn 中だけ holder が付き、完了後に外れる**ことを実機で確認済み

## 📒 複数ウィンドウ運用の実例（2026-06-14・要記憶）

- holder は token=session_id 単位。**VSCode の別ウィンドウで開いた Claude は別セッション**＝別 holder。
  - `3422e7ae…` = このウィンドウ（local_development）/ `6d4f198e…` = 別ウィンドウ（investment-dashboard）
- 当初 `6d4f198e…` を「リーク」と判断し `release` したが、実は**当時稼働中の別ウィンドウ**で、
  次ターンで再 acquire され自己修復した（＝参照カウントが多重セッションで正しく機能している実証）。
- その後その別ウィンドウがターン中に終了 → `6d4f198e…` が真のリークとして残存。
  janitor は「生きてる claude が皆無」のときだけ掃除するため、**このセッション生存中は保持**。
  全 Claude ウィンドウを閉じれば grace 経過で自動回収される（設計どおり・限界の実例）。
- 教訓: holder を手で消す前に `find ~/.claude/projects -name '<token>*.jsonl'` で
  どのウィンドウのセッションか確認すること（別ウィンドウの稼働中セッションを誤って消さない）。

## 次のアクション（この順で）

### ① janitor のデプロイ ← まずこれ（リーク掃除とテストは完了済み）
- ```
  cp launchd/com.yudai.agent-caffeine.plist ~/Library/LaunchAgents/
  launchctl load ~/Library/LaunchAgents/com.yudai.agent-caffeine.plist
  ```
- 60 秒後にエージェント全滅 → caffeinate 自動停止することを `status` とログ（`/tmp/agent-caffeine.*.log`）で確認。

### ② Codex(C 案) の実装 ← 完了（2026-06-14）
- `src/agent-caffeine`
  - 旧: `watch-codex-once` / `watch-codex` = `pgrep -f 'openai.chatgpt.*codex'` 監視
  - 現行: `watch-codex-logs-once` / `watch-codex-logs` = `~/.codex/logs_2.sqlite` 監視
- `launchd/com.yudai.agent-caffeine-codex.plist`
  - `KeepAlive` 常駐。Codex ターン中だけ holder=`codex` を保持
- `launchd/com.yudai.agent-caffeine.plist`
  - janitor は pgrep ではなく logs DB から Codex turn 中を判定
- テスト:
  - `tests/codex_log_watch_test.sh`: ✅ watch acquire/release の 6 ケース PASS
- 採用した方針:
  - **Codex も「ターン中 = 稼働中」**
  - `notify` 連鎖は未実装。必要になったら将来の改善候補

### ③ logs 版 release 実機確認 ← 完了（2026-06-15）
- 実機ログで次を確認済み:
  - `watch-codex-logs-once: turn started, token=codex ...`
  - `acquire token=codex holders=1`
  - `watch-codex-logs-once: turn completed, token=codex ...`
  - `release token=codex holders=0`
  - `started caffeinate ...` / `stopped caffeinate ...`
- 結論:
  - **Codex turn 中だけ holder が付き、完了後に外れる**
  - `pgrep` 版で未解決だった release 問題は、logs DB 版で解消

#### release 実機確認手順（履歴）

```bash
# 1. 監視を開始
tail -f /tmp/agent-caffeine-codex.err.log

# 2. 別ターミナルで状態確認を繰り返す
while true; do clear; agent-caffeine status; sleep 2; done

# 3. Codex 側で短い依頼を1回送る
#    → turn開始で codex holder が付くはず

# 4. 応答完了まで待つ
#    → turn/completed で codex holder が外れるはず

# 5. 単発確認
agent-caffeine status

# 6. ログ確認
tail -n 50 /tmp/agent-caffeine-codex.err.log
```

期待結果:

- turn 中は `codex` holder が出る
- turn 完了後は `codex` holder が消える
- ログに `watch-codex-logs-once: turn started, token=codex ...` が出る
- ログに `watch-codex-logs-once: turn completed, token=codex ...` が出る

#### logs 版 watch-codex release 経路の切り分けテスト手順（履歴）

目的:

- `janitor` ではなく **`watch-codex-logs` 自身が `codex` holder を付け外しする**ことを確認する

手順:

1. 監視用ターミナルを 2 つ開く
   - 1つ目:
     ```bash
     tail -f /tmp/agent-caffeine-codex.err.log
     ```
   - 2つ目:
     ```bash
     while true; do clear; agent-caffeine status; sleep 2; done
     ```
2. Codex 側で短い依頼を 1 回送る
3. 次の 2 点を確認する
   - `agent-caffeine status` に `codex` holder が出る
   - `/tmp/agent-caffeine-codex.err.log` に
     `watch-codex-logs-once: turn started, token=codex`
     が出る
4. 応答完了後、次の 2 点を確認する
   - `agent-caffeine status` から `codex` holder が消える
   - `/tmp/agent-caffeine-codex.err.log` に
     `watch-codex-logs-once: turn completed, token=codex`
     が出る
5. 判定する
   - turn 中だけ `codex` holder がある
   - 完了後は `codex` holder が消える
   - この 2 点が揃えば logs 版の release 経路は OK

## 判断ステータス（ADR / 詳細は 00_Docs/05_design.md）
- ✅ **ADR-001**
  - Claude = 「稼働中」= ターン中
  - Codex = 「稼働中」= ターン中（logs DB 監視）
- ✅ **ADR-002**
  - AC 時のみ best-effort
  - battery 時 clamshell は対象外
  - 既定 flags は `-i -s`
  - `pmset` の自動変更は root / グローバル設定変更になるため不採用
- ✅ ADR-003 配布形態: **C ハイブリッド**（Claude=フック / Codex=watch / janitor=launchd）

## クイックリファレンス
- 手動操作: `agent-caffeine {acquire|release|status|reap|janitor|watch-codex-once|watch-codex|watch-codex-logs-once|watch-codex-logs} [token]`
- 状態ディレクトリ: `~/.local/state/agent-caffeine/`（`caffeinate.pid` / `holders/<token>`）
- env: `AGENT_CAFFEINE_STATE`（テスト時は一時 dir 推奨で実環境を汚さない）/ `AGENT_CAFFEINE_FLAGS`（default `-i`）
  ※ 現在の default は `-i -s`
  / `AGENT_CAFFEINE_{CLAUDE,CODEX}_PATTERN`（janitor 検出）/ `AGENT_CAFFEINE_JANITOR_GRACE`（default 60秒）
  / `AGENT_CAFFEINE_CODEX_WATCH_{PATTERN,TOKEN,INTERVAL}`（旧 pgrep watch）
  / `AGENT_CAFFEINE_CODEX_LOG_{DB,INTERVAL}`（logs DB watch）
- ⚠️ 運用ルール:
  - Claude 拡張更新後は `pgrep -f 'native-binary/claude'` が当たるか確認
  - Codex 拡張更新後は `~/.codex/logs_2.sqlite` に `item/started` / `turn/completed` が出るか確認
- 環境: Claude/Codex とも **VSCode 拡張**（memory: user-dev-env-vscode-extensions 参照）
