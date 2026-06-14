#!/usr/bin/env bash
# install.sh — agent-caffeine をデプロイする
#
# このプロジェクトを「正本」とし、実行バイナリを ~/.local/bin に symlink する。
# フック / launchd への配線（A 案 or B 案）は破壊的なので自動編集しない。
# どこに何を足すかのスニペットを表示するだけにして、手動適用を促す。

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$PROJECT_DIR/src/agent-caffeine"
BIN_DIR="${HOME}/.local/bin"
LINK="$BIN_DIR/agent-caffeine"

chmod +x "$SRC"
mkdir -p "$BIN_DIR"
ln -sf "$SRC" "$LINK"
echo "linked: $LINK -> $SRC"
echo

if ! printf '%s' ":$PATH:" | grep -q ":$BIN_DIR:"; then
  echo "⚠️  $BIN_DIR が PATH に入っていません。shell rc に以下を追記してください:"
  echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
  echo
fi

cat <<'EOF'
--- 次のステップ -----------------------------------------------------------

[B 案: フック駆動 / 推奨] Claude Code
  ~/.claude/settings.json の hooks に手動で追記（既存フックは消さないこと）:

    UserPromptSubmit -> agent-caffeine acquire <session_id>
    Stop             -> agent-caffeine release <session_id>

  ※ 現在の実装は「ターン中 = 稼働中」。session_id は hook JSON から取る。

[C 案] Codex
  現在の実装は ~/.codex/logs_2.sqlite 監視 + launchd。
    cp launchd/com.yudai.agent-caffeine-codex.plist ~/Library/LaunchAgents/
    launchctl load ~/Library/LaunchAgents/com.yudai.agent-caffeine-codex.plist

  notify は触らない。logs DB の app-server event を見て turn 精度で追従する。

[janitor]
  cp launchd/com.yudai.agent-caffeine.plist ~/Library/LaunchAgents/
  launchctl load ~/Library/LaunchAgents/com.yudai.agent-caffeine.plist

運用手順:
  00_Docs/09_operations.md を参照

----------------------------------------------------------------------------
動作確認:
  agent-caffeine acquire test1 && agent-caffeine status && agent-caffeine release test1
EOF
