#!/usr/bin/env bash
# janitor サブコマンドのスモークテスト。
# 実 caffeinate を起動しないよう、pid_file には存在しない PID を置いてスタブ化する。
# 一時 state dir を使い実環境（~/.local/state/agent-caffeine）は汚さない。
#
#   bash tests/janitor_test.sh
#
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/src/agent-caffeine"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export AGENT_CAFFEINE_STATE="$T"
mkdir -p "$T/holders"

NOMATCH="zzz-nonexistent-pattern-$$"
pass=0 fail=0
ok() {
  echo "  PASS: $1"
  pass=$((pass + 1))
}
ng() {
  echo "  FAIL: $1"
  fail=$((fail + 1))
}
holders() { find "$T/holders" -type f | wc -l | tr -d ' '; }

echo "=== TEST1: agent 皆無 + grace=0 → 全 holder 消去 & caffeinate 停止 ==="
printf '999999\n' >"$T/caffeinate.pid" # 存在しない PID（kill は静かに失敗→pid_file 削除を検証）
: >"$T/holders/session-aaa"
: >"$T/holders/session-bbb"
AGENT_CAFFEINE_JANITOR_GRACE=0 AGENT_CAFFEINE_CLAUDE_PATTERN="$NOMATCH" AGENT_CAFFEINE_CODEX_PATTERN="$NOMATCH" "$SRC" janitor
{ [ "$(holders)" = "0" ] && [ ! -f "$T/caffeinate.pid" ]; } && ok "holders=0 / pid_file removed" || ng "holders=$(holders) pid_file=$([ -f "$T/caffeinate.pid" ] && echo exists || echo removed)"

echo "=== TEST2: agent 生存 → no-op（他人の holder を巻き込まない） ==="
printf '999999\n' >"$T/caffeinate.pid"
: >"$T/holders/session-ccc"
AGENT_CAFFEINE_CLAUDE_PATTERN="launchd" AGENT_CAFFEINE_CODEX_PATTERN="$NOMATCH" "$SRC" janitor
[ -e "$T/holders/session-ccc" ] && ok "holder 維持" || ng "holder が消えた"
rm -f "$T/holders/"*

echo "=== TEST3: reap = 死んだ数値 PID は消す / 非数値は残す ==="
: >"$T/holders/4000000000" # 範囲外で確実に存在しない PID → 消えるべき
: >"$T/holders/session-ddd" # 非数値 → 残るべき
AGENT_CAFFEINE_CLAUDE_PATTERN="launchd" "$SRC" janitor >/dev/null
{ [ -e "$T/holders/session-ddd" ] && [ ! -e "$T/holders/4000000000" ]; } && ok "数値死PIDのみ掃除" || ng "remaining: $(ls "$T/holders" | tr '\n' ' ')"
rm -f "$T/holders/"*

echo "=== TEST4: 安全弁 — agent 皆無でも grace 内の新鮮な holder は消さない & 停止しない ==="
printf '999999\n' >"$T/caffeinate.pid"
: >"$T/holders/session-fresh" # 作りたて（age≒0 < 60）
AGENT_CAFFEINE_CLAUDE_PATTERN="$NOMATCH" AGENT_CAFFEINE_CODEX_PATTERN="$NOMATCH" "$SRC" janitor
{ [ -e "$T/holders/session-fresh" ] && [ -f "$T/caffeinate.pid" ]; } && ok "新鮮 holder 維持 / caffeinate 継続" || ng "holder=$([ -e "$T/holders/session-fresh" ] && echo kept || echo gone) pid_file=$([ -f "$T/caffeinate.pid" ] && echo exists || echo removed)"
rm -f "$T/holders/"*

echo "=== TEST5: agent 皆無 + grace 超過の古い holder → 消去 & 停止 ==="
printf '999999\n' >"$T/caffeinate.pid"
: >"$T/holders/session-old"
touch -t 202001010000 "$T/holders/session-old" # 2020 年に backdate → 確実に grace 超過
AGENT_CAFFEINE_CLAUDE_PATTERN="$NOMATCH" AGENT_CAFFEINE_CODEX_PATTERN="$NOMATCH" "$SRC" janitor
{ [ ! -e "$T/holders/session-old" ] && [ ! -f "$T/caffeinate.pid" ]; } && ok "古い holder 消去 / caffeinate 停止" || ng "holder=$([ -e "$T/holders/session-old" ] && echo kept || echo gone) pid_file=$([ -f "$T/caffeinate.pid" ] && echo exists || echo removed)"
rm -f "$T/holders/"*

echo "=== TEST6: 空パターンは「検出無効」（全プロセスに誤マッチして常時稼働扱いにならない） ==="
# CODEX_PATTERN 既定=空。空のまま pgrep -f \"\" を呼ぶと全プロセスにマッチして agents_alive が
# 常に true になりリーク掃除が無効化される回帰の検出。CLAUDE もマッチ無し→「全滅」と判定されるべき。
printf '999999\n' >"$T/caffeinate.pid"
: >"$T/holders/session-empty"
touch -t 202001010000 "$T/holders/session-empty"
AGENT_CAFFEINE_CLAUDE_PATTERN="$NOMATCH" AGENT_CAFFEINE_CODEX_PATTERN="" "$SRC" janitor
{ [ ! -e "$T/holders/session-empty" ] && [ ! -f "$T/caffeinate.pid" ]; } && ok "空パターン=無効として全滅判定" || ng "空パターンが全マッチしてしまった: holder=$([ -e "$T/holders/session-empty" ] && echo kept || echo gone)"

echo
echo "result: $pass passed, $fail failed"
[ "$fail" = "0" ]
