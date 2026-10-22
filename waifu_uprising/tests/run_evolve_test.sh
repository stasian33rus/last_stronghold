#!/usr/bin/env bash
# Сетевой тест ЭВОЛЮЦИИ (Этап 3): два headless-процесса Godot, настоящий ENet/UDP.
# Хост инжектирует себе XP до уровня 3 (серверный триггер), эволюционирует
# в форму II; клиент обязан увидеть смену формы ЧУЖОЙ пешки через репликацию
# BodySync (поле "f"). Матч играется до победы обеими сторонами.
# Критерий PASS: exit 0 обоих + 0 script errors + эволюция подтверждена с обеих сторон.
# Использование: tests/run_evolve_test.sh [порт] [путь_к_godot]
set -u
PORT="${1:-24592}"
GODOT="${2:-/tmp/godot/Godot_v4.7.2-stable_linux.x86_64}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOGDIR="${LOGDIR:-/tmp}"

echo "== Тест эволюции (сеть): порт $PORT, проект $PROJ =="
cd "$PROJ" || exit 2

timeout 300 "$GODOT" --headless -- "+autotest=host" "+port=$PORT" "+fast=1" "+evolve=1" > "$LOGDIR/evolve_host.log" 2>&1 &
HOST_PID=$!
sleep 5
timeout 300 "$GODOT" --headless -- "+autotest=client" "+ip=127.0.0.1" "+port=$PORT" "+fast=1" "+evolve=1" > "$LOGDIR/evolve_client.log" 2>&1 &
CLIENT_PID=$!

wait "$CLIENT_PID"; CLIENT_EXIT=$?
wait "$HOST_PID"; HOST_EXIT=$?

echo "host exit=$HOST_EXIT client exit=$CLIENT_EXIT"
grep -h "\[AUTOTEST\]" "$LOGDIR/evolve_host.log" "$LOGDIR/evolve_client.log" | grep -E "EVOLUTION|RESULT|evolve" || true

SCRIPT_ERRORS=$(grep -hE "SCRIPT ERROR" "$LOGDIR/evolve_host.log" "$LOGDIR/evolve_client.log" | grep -v fontconfig | wc -l)
HOST_EVO=$(grep -c "EVOLUTION local" "$LOGDIR/evolve_host.log")
CLIENT_EVO=$(grep -c "EVOLUTION remote" "$LOGDIR/evolve_client.log")
echo "script_errors=$SCRIPT_ERRORS host_evolved=$HOST_EVO client_saw_replication=$CLIENT_EVO"

if [ "$HOST_EXIT" -eq 0 ] && [ "$CLIENT_EXIT" -eq 0 ] && [ "$SCRIPT_ERRORS" -eq 0 ] \
   && [ "$HOST_EVO" -ge 1 ] && [ "$CLIENT_EVO" -ge 1 ]; then
  echo "EVOLVE_TEST=PASS"
  exit 0
else
  echo "EVOLVE_TEST=FAIL"
  exit 1
fi
