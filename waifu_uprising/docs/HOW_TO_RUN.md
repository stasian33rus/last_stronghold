# Как запустить игру и сервер

Требуется: **Godot 4.7.x stable** (проверено на 4.7.2). Движок: <https://godotengine.org/download>.

## 1. Игра через редактор (Windows/Linux, с графикой)

1. Откройте Godot → Import → выберите `waifu_uprising/project.godot`.
2. Нажмите **F5** (запуск главной сцены — главного меню).
3. Одиночная игра: **Создать комнату** → **Начать матч** (вы — хост listen-сервера).
4. Управление: WASD — движение, мышь — прицел, ЛКМ/J — удар молотом,
   Shift/Space — рывок, колесо — зум камеры, Esc — выход в меню,
   **1/2/3 или мышь — выбор улучшения** при повышении уровня.

## 2. Кооператив по сети (2–8 игроков)

ENet использует **UDP**. Порт по умолчанию **24560/UDP** — откройте его в
брандмауэре хоста и (при игре через интернет) пробросьте на роутере.

- **Хост**: меню → «Создать комнату» → передать друзьям IP. Дождаться игроков → «Начать матч».
- **Гость**: меню → имя, адрес хоста, порт → «Подключиться» → «Готов».
- Между волнами открыт **магазин**: покупки за монеты, кнопка «Готов к волне»
  запускает следующую волну досрочно (иначе — по таймеру).
- Подключение после начала матча в Этапе 2 по-прежнему отклоняется (ограничение задокументировано).

## 3. Запуск из командной строки (без редактора)

```bash
# Игра (с графикой):
godot --path waifu_uprising

# Dedicated-сервер (headless, Linux/VPS):
godot --headless --path waifu_uprising -- +dedicated +port=24560
# Матч стартует автоматически через 3 с, когда все подключившиеся отметят «Готов».
```

Параметры командной строки (после `--`):
`+dedicated` · `+port=N` · `+ip=A.B.C.D` · `+autotest=host|client` · `+fast=1`
(ускоренный баланс прогрессии/интермиссий — только для тестов) ·
`+rematch=1` (с `+autotest`: после победы сыграть второй матч — тест реванша).

Для VPS: разрешите `udp/N` в файрволе (`ufw allow N/udp`, в облачных консолях —
security group). Docker-обёртка планируется на Этапе 7 (ТЗ §17).

## 4. Тесты (headless, без графики)

```bash
# Offline-дымотест Этапов 1–2 — 120 проверок, exit code 0 = успех:
godot --headless --path waifu_uprising res://tests/smoke_test.tscn

# Интеграционный сетевой тест (хост+клиент, полный матч 4 волны с ботами):
waifu_uprising/tests/run_net_test.sh 24560 /путь/к/godot
# логи: /tmp/net_host.log, /tmp/net_client.log; «NET_TEST=PASS» = успех

# Тест РЕВАНША (хост+клиент, два полных матча подряд — перезапуск матча,
# очистка между матчами, синхронизация; критерий «REMATCH_TEST=PASS»):
waifu_uprising/tests/run_rematch_test.sh 24587 /путь/к/godot
# логи: /tmp/rematch_host.log, /tmp/rematch_client.log

# Dedicated-сервер + один клиент (вручную):
godot --headless --path waifu_uprising -- +dedicated +port=24590 +fast=1 &
godot --headless --path waifu_uprising -- +autotest=client +ip=127.0.0.1 +port=24590 +fast=1

# Probe навигации (bake/agent/rebake API NavigationServer3D):
godot --headless --path waifu_uprising -s res://tests/probe_nav.gd

# Диагностика атаки врага по Гигачаду (ручной инструмент):
godot --headless --path waifu_uprising res://tests/debug_giga.tscn
```

## 5. Проверка версии движка

```bash
godot --version   # ожидается 4.7.2.stable (или другая 4.7.x)
```

Проект не использует GDExtension/сторонние зависимости — только стандартный Godot 4.
NavigationMesh печётся рантаймом на сервере — editor-bake и дополнительные
инструменты не требуются.
