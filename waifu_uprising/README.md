# ПОСЛЕДНИЙ ИСТОЧНИК: Waifu Uprising

Кооперативный 3D action roguelite (1–8 игроков) на **Godot 4.7.2 stable** / GDScript (типизированный).
Защитите Гигачада — последний источник энергии резонанса — от Ордена Гламура.

Текущее состояние: **Этап 2 — прогрессия, магазин, 4 архетипа врагов, NavMesh, разрушаемость**
(отчёты: `docs/STAGE1_REPORT.md`, `docs/STAGE2_REPORT.md`).

## Быстрый старт

```bash
# Одиночная игра: откройте проект в редакторе Godot 4.7.x и нажмите F5,
#   затем «Создать комнату» -> «Начать матч» (вы — хост listen-сервера).

# Dedicated-сервер без GUI (Linux/VPS):
godot --headless --path . -- +dedicated +port=24560

# Сетевой интеграционный тест (два headless-процесса, настоящий ENet/UDP):
tests/run_net_test.sh 24560

# Offline-дымотест игровой логики Этапов 1-2 (120 проверок):
godot --headless --path . res://tests/smoke_test.tscn
```

Подробности: [`docs/HOW_TO_RUN.md`](docs/HOW_TO_RUN.md) · Архитектура: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)

## Управление

| Действие | Клавиши |
|---|---|
| Движение | WASD / стрелки (относительно камеры) |
| Удар молотом | ЛКМ или J |
| Рывок-уклонение (i-frames) | Shift или Space |
| Зум камеры | Колесо мыши |
| Выбор улучшения | 1 / 2 / 3 или мышь |
| Выход в меню | Esc |

## Структура проекта

```
scenes/      игровые сцены (меню, арена, персонаж, 4 врага, снаряд, Гигачад, ящик, HUD)
scripts/     autoload/ (Net, Game, Classes, Content, Sfx, Events), gameplay/, ai/,
             combat/, networking/, physics/, progression/, data/, ui/, levels/
resources/   данные баланса: классы, враги, волны, улучшения, магазин (.tres)
tests/       smoke_test (offline-логика), autotest_runner (сеть), probe_nav, debug
docs/        архитектура, запуск, отчёты по этапам, план, GAME_DESIGN.md (ТЗ)
```

## Принципы

- **Server-authoritative**: урон, здоровье, волны, результат матча считает сервер (peer 1 или dedicated headless). Клиенты шлют команды ввода; важные RPC валидируются (отправитель == владелец пешки).
- **Данные отдельно от кода**: классы/враги/волны — ресурсы `.tres`, добавление контента не требует правки систем.
- **Композиция**: Health/Hitbox/Hurtbox/Knockback/BodySync — переиспользуемые компоненты.
- **Никаких имитаций**: каждая заявленная механика реально работает и покрыта тестами.
