class_name WaveGroup
extends Resource
## Группа спавна внутри волны: какой архетип, сколько (база + за игрока).

@export var enemy_def_path: String = "res://resources/enemies/fop.tres"
@export var count_base: int = 0
@export var count_per_player: int = 0

func total_count(player_count: int) -> int:
	return count_base + count_per_player * maxi(1, player_count)
