class_name ProgressionBalance
extends Resource
## Баланс прогрессии и economy матча (Этап 2). Все числа — в данных, не в коде.

## Формула опыта: XP_required(level) = xp_base + xp_per_level * (level - 1).
@export var xp_base: int = 100
@export var xp_per_level: int = 50
@export var max_level: int = 10

## Награды за уничтожение (по категории врага, EnemyDefinition.category).
@export var xp_normal: int = 20
@export var xp_elite: int = 50
@export var xp_boss: int = 100
@export var xp_crate: int = 5

## Валюта.
@export var coins_kill: int = 5
@export var coins_wave_clear: int = 25
@export var coins_crate: int = 2

## Тайминги матча, сек.
@export var choice_time: float = 20.0       ## на выбор улучшения (серверный таймер)
@export var wave_complete_time: float = 2.5 ## пауза «волна отбита»
@export var intermission_time: float = 30.0 ## межволновая фаза с магазином
@export var next_wave_countdown: float = 5.0 ## отсчёт до следующей волны

func xp_required(level: int) -> int:
	return xp_base + xp_per_level * (maxi(1, level) - 1)

func xp_for_category(category: int) -> int:
	match category:
		1: return xp_elite
		2: return xp_boss
	return xp_normal
