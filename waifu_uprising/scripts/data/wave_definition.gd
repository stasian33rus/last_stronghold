class_name WaveDefinition
extends Resource
## Описание волны: кто, сколько и как появляется.
## Масштабирование под 1-8 игроков: count_base + count_per_player * N (ТЗ §4).

@export var index: int = 1
@export var display_name: String = "Волна 1"
@export var intro_delay: float = 0.0 ## Пауза перед первым спавном волны.
@export var spawn_interval: float = 0.45 ## Интервал между появлениями отдельных врагов.
@export var max_alive: int = 10 ## Ограничение одновременных активных врагов (производительность, ТЗ §13).

@export var enemy_def_path: String = "res://resources/enemies/fop.tres"
@export var count_base: int = 3
@export var count_per_player: int = 2

func total_count(player_count: int) -> int:
	return count_base + count_per_player * maxi(1, player_count)
