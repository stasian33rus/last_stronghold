#!/usr/bin/env bash
# Сетевой тест АКТА II «Энергетический кортеж» (Этап 5.2): два headless-процесса,
# настоящий ENet/UDP. Оба пира сопровождают транспорт до точки эвакуации
# (ПОБЕДА), затем хост запрашивает реванш — второй матч обязан стартовать
# с чистым состоянием кортежа. Проверяется: транспорт виден обоим пирам,
# клиенту реплицируются ДВИЖЕНИЕ (прогресс маршрута) и ЗДОРОВЬЕ транспорта
# (хост наносит серверный урон), оба пира доходят до победы в обоих матчах.
# Использование: tests/run_convoy_test.sh [порт] [путь_к_godot]
set -u
PORT="${1:-24861}"
GODOT="${2:-/tmp/godot/Godot_v4.7.2-stable_linux.x86_64}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOGDIR="${LOGDIR:-/tmp}"

echo "== Тест акта II (кортеж, сеть): порт $PORT =="
cd "$PROJ" || exit 2

timeout 600 "$GODOT" --headless -- "+autotest=host" "+port=$PORT" "+fast=1" "+act2=1" "+rematch=1" > "$LOGDIR/convoy_host.log" 2>&1 &
HOST_PID=$!
sleep 5
timeout 600 "$GODOT" --headless -- "+autotest=client" "+ip=127.0.0.1" "+port=$PORT" "+fast=1" "+act2=1" "+rematch=1" > "$LOGDIR/convoy_client.log" 2>&1 &
CLIENT_PID=$!

wait "$CLIENT_PID"; CLIENT_EXIT=$?
wait "$HOST_PID"; HOST_EXIT=$?

echo "host exit=$HOST_EXIT client exit=$CLIENT_EXIT"
grep -h "\[AUTOTEST\]" "$LOGDIR/convoy_host.log" "$LOGDIR/convoy_client.log" | grep -E "CONVOY_SEEN|CONVOY_PROGRESS|CONVOY_HP_SYNC|RESULT" || true

SCRIPT_ERRORS=$(grep -hE "SCRIPT ERROR" "$LOGDIR/convoy_host.log" "$LOGDIR/convoy_client.log" | grep -v fontconfig | wc -l)
HOST_CONVOY=$(grep -c "CONVOY_SEEN host" "$LOGDIR/convoy_host.log")
CLIENT_CONVOY=$(grep -c "CONVOY_SEEN client" "$LOGDIR/convoy_client.log")
CLIENT_PROGRESS=$(grep -c "CONVOY_PROGRESS client" "$LOGDIR/convoy_client.log")
CLIENT_HP=$(grep -c "CONVOY_HP_SYNC client" "$LOGDIR/convoy_client.log")
REMATCH_OK=$(grep -h "REMATCH victory verified" "$LOGDIR/convoy_host.log" "$LOGDIR/convoy_client.log" | wc -l)
echo "script_errors=$SCRIPT_ERRORS host_convoy=$HOST_CONVOY client_convoy=$CLIENT_CONVOY client_progress=$CLIENT_PROGRESS client_hp=$CLIENT_HP rematch_confirmed=$REMATCH_OK/2"

if [ "$HOST_EXIT" -eq 0 ] && [ "$CLIENT_EXIT" -eq 0 ] && [ "$SCRIPT_ERRORS" -eq 0 ] \
   && [ "$HOST_CONVOY" -ge 2 ] && [ "$CLIENT_CONVOY" -ge 2 ] \
   && [ "$CLIENT_PROGRESS" -ge 2 ] && [ "$CLIENT_HP" -ge 2 ] && [ "$REMATCH_OK" -eq 2 ]; then
  echo "CONVOY_TEST=PASS"
  exit 0
else
  echo "CONVOY_TEST=FAIL"
  exit 1
fi
