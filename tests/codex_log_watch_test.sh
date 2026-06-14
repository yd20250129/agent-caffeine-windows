#!/usr/bin/env bash
# watch-codex-logs-once のスモークテスト。
# 一時 sqlite DB を使い、Codex の app-server event を模擬する。
#
#   bash tests/codex_log_watch_test.sh
#
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/src/agent-caffeine"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export AGENT_CAFFEINE_STATE="$T/state"
mkdir -p "$AGENT_CAFFEINE_STATE/holders"
DB="$T/logs.sqlite"
export AGENT_CAFFEINE_CODEX_LOG_DB="$DB"

sqlite3 "$DB" <<'EOF'
create table logs (
  id integer primary key autoincrement,
  ts integer not null,
  ts_nanos integer not null,
  level text not null,
  target text not null,
  feedback_log_body text,
  module_path text,
  file text,
  line integer,
  thread_id text,
  process_uuid text,
  estimated_bytes integer not null default 0
);
EOF

FAKEBIN="$T/fakebin"
mkdir -p "$FAKEBIN"
export PATH="$FAKEBIN:$PATH"

cat >"$FAKEBIN/caffeinate" <<'EOF'
#!/usr/bin/env bash
trap 'exit 0' TERM INT
while :; do
  sleep 3600
done
EOF
chmod +x "$FAKEBIN/caffeinate"

insert_event() {
  sqlite3 "$DB" "
    insert into logs (ts, ts_nanos, level, target, feedback_log_body, estimated_bytes)
    values (strftime('%s','now'), 0, 'TRACE', 'codex_app_server::outgoing_message', '$1', 0);
  "
}

pass=0 fail=0
ok() {
  echo "  PASS: $1"
  pass=$((pass + 1))
}
ng() {
  echo "  FAIL: $1"
  fail=$((fail + 1))
}
holders() { find "$AGENT_CAFFEINE_STATE/holders" -type f | wc -l | tr -d ' '; }

echo "=== TEST1: event 無しなら holder を作らない ==="
"$SRC" watch-codex-logs-once
{ [ "$(holders)" = "0" ] && [ ! -f "$AGENT_CAFFEINE_STATE/caffeinate.pid" ]; } && ok "holder=0 / pid_file なし" || ng "holders=$(holders)"

echo "=== TEST2: item/started で codex holder を acquire ==="
insert_event "app-server event: item/started targeted_connections=1"
"$SRC" watch-codex-logs-once
{ [ -e "$AGENT_CAFFEINE_STATE/holders/codex" ] && [ -f "$AGENT_CAFFEINE_STATE/caffeinate.pid" ]; } && ok "codex holder 作成 / caffeinate 起動" || ng "holder=$([ -e "$AGENT_CAFFEINE_STATE/holders/codex" ] && echo yes || echo no)"

echo "=== TEST3: delta event なら holder を維持する ==="
insert_event "app-server event: item/agentMessage/delta targeted_connections=1"
"$SRC" watch-codex-logs-once
{ [ "$(holders)" = "1" ] && [ -e "$AGENT_CAFFEINE_STATE/holders/codex" ]; } && ok "delta event で active 維持" || ng "holders=$(holders)"

echo "=== TEST4: turn/completed で codex holder を release ==="
insert_event "app-server event: turn/completed targeted_connections=1"
"$SRC" watch-codex-logs-once
{ [ "$(holders)" = "0" ] && [ ! -f "$AGENT_CAFFEINE_STATE/caffeinate.pid" ]; } && ok "holder 解放 / caffeinate 停止" || ng "holders=$(holders) pid_file=$([ -f "$AGENT_CAFFEINE_STATE/caffeinate.pid" ] && echo exists || echo removed)"

echo "=== TEST5: 直近 event が completed なら再起動後も acquire しない ==="
"$SRC" watch-codex-logs-once
{ [ "$(holders)" = "0" ] && [ ! -f "$AGENT_CAFFEINE_STATE/caffeinate.pid" ]; } && ok "completed を引き継ぎ idle" || ng "holders=$(holders)"

echo "=== TEST6: DB が無いとエラーにする ==="
if AGENT_CAFFEINE_CODEX_LOG_DB="$T/missing.sqlite" "$SRC" watch-codex-logs-once >/dev/null 2>&1; then
  ng "missing DB で成功してしまった"
else
  ok "missing DB を拒否"
fi

echo
echo "result: $pass passed, $fail failed"
[ "$fail" = "0" ]
