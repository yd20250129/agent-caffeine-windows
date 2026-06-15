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
if ln -sf "$SRC" "$LINK" 2>/dev/null; then
  echo "linked: $LINK -> $SRC"
else
  cp "$SRC" "$LINK"
  echo "copied: $LINK (symlink unavailable — enable Developer Mode for symlinks)"
fi
echo

if ! printf '%s' ":$PATH:" | grep -q ":$BIN_DIR:"; then
  echo "⚠️  $BIN_DIR が PATH に入っていません。shell rc に以下を追記してください:"
  echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
  echo
fi

OS="$(uname -s)"

case "$OS" in
  MINGW*|MSYS*|CYGWIN*)
    TASK_DIR="$PROJECT_DIR/task-scheduler"
    schtasks.exe /Create /XML "$(cygpath -w "$TASK_DIR/agent-caffeine-janitor.xml")" \
      /TN "agent-caffeine-janitor" /F
    echo "registered: agent-caffeine-janitor (Task Scheduler)"
    echo
    echo "Codex log watcher は以下で手動登録（~/.codex/logs_2.sqlite が必要）:"
    echo "  schtasks /Create /XML task-scheduler/agent-caffeine-watch-codex.xml /TN agent-caffeine-watch-codex /F"
    echo
    ;;
esac

cat <<'EOF'
--- 次のステップ -----------------------------------------------------------

[Claude Code フック設定]
  ~/.claude/settings.json の hooks に手動で追記（既存フックは消さないこと）:

    UserPromptSubmit -> agent-caffeine acquire <session_id>
    Stop             -> agent-caffeine release <session_id>

  ※ jq が必要です。未インストールの場合: winget install jqlang.jq

[Codex 監視]
  タスクスケジューラへ登録（~/.codex/logs_2.sqlite が必要）:
    schtasks /Create /XML task-scheduler\agent-caffeine-watch-codex.xml /TN agent-caffeine-watch-codex /F

  ※ sqlite3 が必要です。未インストールの場合: winget install SQLite.SQLite

----------------------------------------------------------------------------
動作確認:
  agent-caffeine acquire test1 && agent-caffeine status && agent-caffeine release test1
EOF
