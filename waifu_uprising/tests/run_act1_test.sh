#!/usr/bin/bash
# Сетевой тест АКТА I (Этап 5.1): оба пира проходят акт до победы; проверяется
# синхронность появления босса и репликация его здоровья/фаз.
set -u
PORT="${1:-24851}"
GODOT="${2:-/tmp/godot/Godot_v4.7.2-stable_linux.x86_64}"
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
LOGDIR="${LOGDIR:-/tmp}"
echo "== Тест акта I (сеть): порт $PORT =="
cd "$PROJ" || exit 2
timeout 400 "$GODOT" --headless -- "+autotest=host" "+port=$PORT" "+fast=1" "+act1=1" > "$LOGDIR/act1_host.log" 2>&1 &
HOST_PID=$!
sleep 5
timeout 400 "$GODOT" --headless -- "+autotest=client" "+ip=127.0.0.1" "+port=$PORT" "+fast=1" "+act1=1" > "$LOGDIR/act1_client.log" 2>&1 &
CLIENT_PID=$!
wait "$CLIENT_PID"; CLIENT_EXIT=$?
wait "$HOST_PID"; HOST_EXIT=$?
echo "host exit=$HOST_EXIT client exit=$CLIENT_EXIT"
grep -h "\[AUTOTEST\]" "$LOGDIR/act1_host.log" "$LOGDIR/act1_client.log" | grep -E "BOSS_SEEN|BOSS_PHASE_SYNC|RESULT" || true
SCRIPT_ERRORS=$(grep -hE "SCRIPT ERROR" "$LOGDIR/act1_host.log" "$LOGDIR/act1_client.log" | grep -v fontconfig | wc -l)
HOST_BOSS=$(grep -c "BOSS_SEEN host" "$LOGDIR/act1_host.log")
CLIENT_BOSS=$(grep -c "BOSS_SEEN client" "$LOGDIR/act1_client.log")
CLIENT_PHASE=$(grep -c "BOSS_PHASE_SYNC client" "$LOGDIR/act1_client.log")
echo "script_errors=$SCRIPT_ERRORS host_boss=$HOST_BOSS client_boss=$CLIENT_BOSS client_phase=$CLIENT_PHASE"
if [ "$HOST_EXIT" -eq 0 ] && [ "$CLIENT_EXIT" -eq 0 ] && [ "$SCRIPT_ERRORS" -eq 0 ] \
   && [ "$HOST_BOSS" -ge 1 ] && [ "$CLIENT_BOSS" -ge 1 ] && [ "$CLIENT_PHASE" -ge 1 ]; then
  echo "ACT1_TEST=PASS"
  exit 0
else
  echo "ACT1_TEST=FAIL"
  exit 1
fi
