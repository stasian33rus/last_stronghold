#!/usr/bin/bash
# Сетевой тест СПАСЕНИЯ (Этап 4.1): два headless-процесса Godot, настоящий ENet/UDP.
# Хост роняет СВОЮ пешку; клиент спасает её легитимным RPC sv_rescue_hold и видит
# репликацию DOWN/прогресса/возрождения. Затем клиент отключается прямо в канале —
# сервер обязан отменить канал без краша. Критерий PASS: exit 0 обоих,
# 0 script errors, хост видел local revived + DISCONNECT cleaned, клиент — remote revived.
# Использование: tests/run_rescue_test.sh [порт] [путь_к_godot]
set -u
PORT="${1:-24731}"
GODOT="${2:-/tmp/godot/Godot_v4.7.2-stable_linux.x86_64}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOGDIR="${LOGDIR:-/tmp}"

echo "== Тест спасения (сеть): порт $PORT, проект $PROJ =="
cd "$PROJ" || exit 2

timeout 300 "$GODOT" --headless -- "+autotest=host" "+port=$PORT" "+fast=1" "+rescue=1" > "$LOGDIR/rescue_host.log" 2>&1 &
HOST_PID=$!
sleep 5
timeout 300 "$GODOT" --headless -- "+autotest=client" "+ip=127.0.0.1" "+port=$PORT" "+fast=1" "+rescue=1" > "$LOGDIR/rescue_client.log" 2>&1 &
CLIENT_PID=$!

wait "$CLIENT_PID"; CLIENT_EXIT=$?
wait "$HOST_PID"; HOST_EXIT=$?

echo "host exit=$HOST_EXIT client exit=$CLIENT_EXIT"
grep -h "\[AUTOTEST\]" "$LOGDIR/rescue_host.log" "$LOGDIR/rescue_client.log" | grep -E "RESCUE|rescue" || true

SCRIPT_ERRORS=$(grep -hE "SCRIPT ERROR" "$LOGDIR/rescue_host.log" "$LOGDIR/rescue_client.log" | grep -v fontconfig | wc -l)
HOST_REVIVED=$(grep -c "RESCUE local revived" "$LOGDIR/rescue_host.log")
CLIENT_REVIVED=$(grep -c "RESCUE remote" "$LOGDIR/rescue_client.log")
HOST_CLEANED=$(grep -c "RESCUE_DISCONNECT cleaned=true" "$LOGDIR/rescue_host.log")
echo "script_errors=$SCRIPT_ERRORS host_revived=$HOST_REVIVED client_saw_revive=$CLIENT_REVIVED host_cleaned=$HOST_CLEANED"

if [ "$HOST_EXIT" -eq 0 ] && [ "$CLIENT_EXIT" -eq 0 ] && [ "$SCRIPT_ERRORS" -eq 0 ] \
   && [ "$HOST_REVIVED" -ge 1 ] && [ "$CLIENT_REVIVED" -ge 1 ] && [ "$HOST_CLEANED" -ge 1 ]; then
  echo "RESCUE_TEST=PASS"
  exit 0
else
  echo "RESCUE_TEST=FAIL"
  exit 1
fi
