class_name ConvoySpawnEvent
extends Resource
## Событие спавна кортежа (Акт II, Этап 5.2): когда транспорт прошёл долю
## маршрута progress_threshold, директор спавнит группу врагов указанного
## архетипа с выбранной стороны от маршрута (ahead/behind/flank).
## Масштабирование под 1-8 игроков — как у волн: count_base + count_per_player * N.

@export_range(0.0, 1.0) var progress_threshold: float = 0.0
@export var enemy_def_path: String = "res://resources/enemies/raider.tres"
## Сторона появления относительно транспорта: "ahead" | "behind" | "flank".
@export var side: String = "ahead"
@export var count_base: int = 1
@export var count_per_player: int = 0

func total_count(player_count: int) -> int:
	return count_base + count_per_player * maxi(1, player_count)
