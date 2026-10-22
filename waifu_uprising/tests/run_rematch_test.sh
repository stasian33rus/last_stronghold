#!/usr/bin/env bash
# Интеграционный тест РЕВАНША: два headless-процесса Godot, настоящий ENet/UDP.
# Хост и клиент играют полный матч до ПОБЕДЫ, затем хост запрашивает реванш
# («Ещё раз»): оба пира обязаны пережить перезагрузку сцены, корректно очистить
# объекты прошлого матча, снова подтвердить репликацию мира и победить во втором
# матче. Критерий PASS: exit 0 обоих процессов + 0 script errors + «REMATCH victory».
# Использование: tests/run_rematch_test.sh [порт] [путь_к_godot]
set -u
PORT="${1:-24587}"
GODOT="${2:-/tmp/godot/Godot_v4.7.2-stable_linux.x86_64}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOGDIR="${LOGDIR:-/tmp}"

echo "== Тест реванша: порт $PORT, проект $PROJ =="
cd "$PROJ" || exit 2

timeout 420 "$GODOT" --headless -- "+autotest=host" "+port=$PORT" "+fast=1" "+rematch=1" > "$LOGDIR/rematch_host.log" 2>&1 &
HOST_PID=$!
sleep 5
timeout 420 "$GODOT" --headless -- "+autotest=client" "+ip=127.0.0.1" "+port=$PORT" "+fast=1" "+rematch=1" > "$LOGDIR/rematch_client.log" 2>&1 &
CLIENT_PID=$!

wait "$CLIENT_PID"; CLIENT_EXIT=$?
wait "$HOST_PID"; HOST_EXIT=$?

echo "host exit=$HOST_EXIT client exit=$CLIENT_EXIT"
grep -h "\[AUTOTEST\]" "$LOGDIR/rematch_host.log" "$LOGDIR/rematch_client.log" || true

SCRIPT_ERRORS=$(grep -hE "SCRIPT ERROR" "$LOGDIR/rematch_host.log" "$LOGDIR/rematch_client.log" | grep -v fontconfig | wc -l)
REMATCH_OK=$(grep -h "REMATCH victory verified" "$LOGDIR/rematch_host.log" "$LOGDIR/rematch_client.log" | wc -l)
echo "script_errors=$SCRIPT_ERRORS rematch_confirmed=$REMATCH_OK/2"

if [ "$HOST_EXIT" -eq 0 ] && [ "$CLIENT_EXIT" -eq 0 ] && [ "$SCRIPT_ERRORS" -eq 0 ] && [ "$REMATCH_OK" -eq 2 ]; then
  echo "REMATCH_TEST=PASS"
  exit 0
else
  echo "REMATCH_TEST=FAIL"
  exit 1
fi
