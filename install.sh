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

OS="$(uname -s)"

if [ "$OS" = "Linux" ]; then
  SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
  mkdir -p "$SYSTEMD_USER_DIR"
  cp "$PROJECT_DIR/systemd/"*.service "$PROJECT_DIR/systemd/"*.timer "$SYSTEMD_USER_DIR/"
  systemctl --user daemon-reload
  systemctl --user enable --now agent-caffeine-janitor.timer
  echo "enabled: agent-caffeine-janitor.timer"
  echo
  echo "Codex log watcher は以下で手動起動（~/.codex/logs_2.sqlite が必要）:"
  echo "  systemctl --user enable --now agent-caffeine-watch-codex.service"
  echo
fi

cat <<'EOF'
--- 次のステップ -----------------------------------------------------------

[B 案: フック駆動 / 推奨] Claude Code
  ~/.claude/settings.json の hooks に手動で追記（既存フックは消さないこと）:

    UserPromptSubmit -> agent-caffeine acquire <session_id>
    Stop             -> agent-caffeine release <session_id>

  ※ 現在の実装は「ターン中 = 稼働中」。session_id は hook JSON から取る。

[C 案] Codex (Linux)
  systemctl --user enable --now agent-caffeine-watch-codex.service

[C 案] Codex (macOS)
  cp launchd/com.yudai.agent-caffeine-codex.plist ~/Library/LaunchAgents/
  launchctl load ~/Library/LaunchAgents/com.yudai.agent-caffeine-codex.plist

[janitor] macOS のみ手動インストールが必要（Linux は install.sh が自動設定）:
  cp launchd/com.yudai.agent-caffeine.plist ~/Library/LaunchAgents/
  launchctl load ~/Library/LaunchAgents/com.yudai.agent-caffeine.plist

運用手順:
  00_Docs/09_operations.md を参照

----------------------------------------------------------------------------
動作確認:
  agent-caffeine acquire test1 && agent-caffeine status && agent-caffeine release test1
EOF
