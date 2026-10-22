#!/usr/bin/env bash
# Интеграционный сетевой тест Этапа 1: два headless-процесса Godot, настоящий ENet/UDP.
# Хост создаёт комнату, клиент подключается, оба «играют» виртуальным вводом,
# матч должен закончиться ПОБЕДОЙ с подтверждённой синхронизацией.
# Использование: tests/run_net_test.sh [порт] [путь_к_godot]
set -u
PORT="${1:-24560}"
GODOT="${2:-/tmp/godot/Godot_v4.7.2-stable_linux.x86_64}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOGDIR="${LOGDIR:-/tmp}"

echo "== Сетевой тест: порт $PORT, проект $PROJ =="
cd "$PROJ" || exit 2

timeout 300 "$GODOT" --headless -- "+autotest=host" "+port=$PORT" "+fast=1" > "$LOGDIR/net_host.log" 2>&1 &
HOST_PID=$!
sleep 5
timeout 300 "$GODOT" --headless -- "+autotest=client" "+ip=127.0.0.1" "+port=$PORT" "+fast=1" > "$LOGDIR/net_client.log" 2>&1 &
CLIENT_PID=$!

wait "$CLIENT_PID"; CLIENT_EXIT=$?
wait "$HOST_PID"; HOST_EXIT=$?

echo "host exit=$HOST_EXIT client exit=$CLIENT_EXIT"
grep -h "\[AUTOTEST\]" "$LOGDIR/net_host.log" "$LOGDIR/net_client.log" || true

SCRIPT_ERRORS=$(grep -hE "SCRIPT ERROR" "$LOGDIR/net_host.log" "$LOGDIR/net_client.log" | grep -v fontconfig | wc -l)
echo "script_errors=$SCRIPT_ERRORS"

if [ "$HOST_EXIT" -eq 0 ] && [ "$CLIENT_EXIT" -eq 0 ] && [ "$SCRIPT_ERRORS" -eq 0 ]; then
  echo "NET_TEST=PASS"
  exit 0
else
  echo "NET_TEST=FAIL"
  exit 1
fi
