#!/usr/bin/bash
# Сетевой тест ОКРУЖЕНИЯ (Этап 4.3): сервер разрушает ящик, ловушка циклит;
# клиент обязан увидеть разрушение и те же состояния ловушки.
# Критерий PASS: exit 0 обоих, 0 script errors, host и client видели ACTIVE,
# клиент видел синхронное разрушение ящика.
set -u
PORT="${1:-24821}"
GODOT="${2:-/tmp/godot/Godot_v4.7.2-stable_linux.x86_64}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOGDIR="${LOGDIR:-/tmp}"
echo "== Тест ловушек/разрушений (сеть): порт $PORT =="
cd "$PROJ" || exit 2
timeout 300 "$GODOT" --headless -- "+autotest=host" "+port=$PORT" "+fast=1" "+trap=1" > "$LOGDIR/trap_host.log" 2>&1 &
HOST_PID=$!
sleep 5
timeout 300 "$GODOT" --headless -- "+autotest=client" "+ip=127.0.0.1" "+port=$PORT" "+fast=1" "+trap=1" > "$LOGDIR/trap_client.log" 2>&1 &
CLIENT_PID=$!
wait "$CLIENT_PID"; CLIENT_EXIT=$?
wait "$HOST_PID"; HOST_EXIT=$?
echo "host exit=$HOST_EXIT client exit=$CLIENT_EXIT"
grep -h "\[AUTOTEST\]" "$LOGDIR/trap_host.log" "$LOGDIR/trap_client.log" | grep -E "TRAP_STATES|CRATE_SYNC|trap:" || true
SCRIPT_ERRORS=$(grep -hE "SCRIPT ERROR" "$LOGDIR/trap_host.log" "$LOGDIR/trap_client.log" | grep -v fontconfig | wc -l)
HOST_STATES=$(grep -c "TRAP_STATES host=" "$LOGDIR/trap_host.log")
CLIENT_STATES=$(grep -c "TRAP_STATES client=" "$LOGDIR/trap_client.log")
CLIENT_CRATE=$(grep -c "CRATE_SYNC client destroyed_seen=true" "$LOGDIR/trap_client.log")
echo "script_errors=$SCRIPT_ERRORS host_states=$HOST_STATES client_states=$CLIENT_STATES client_crate=$CLIENT_CRATE"
if [ "$HOST_EXIT" -eq 0 ] && [ "$CLIENT_EXIT" -eq 0 ] && [ "$SCRIPT_ERRORS" -eq 0 ] \
   && [ "$HOST_STATES" -ge 1 ] && [ "$CLIENT_STATES" -ge 1 ] && [ "$CLIENT_CRATE" -ge 1 ]; then
  echo "TRAP_TEST=PASS"
  exit 0
else
  echo "TRAP_TEST=FAIL"
  exit 1
fi
