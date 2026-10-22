class_name Units
extends RefCounted
## Общие константы и фабрики боевых сущностей.
## Урон передаётся типизированным словарём DamageInfo (см. make_damage).

enum Team { NONE = 0, HERO = 1, ENEMY = 2, PROP = 3 }

const KILL_TRACKABLE_GROUPS: Array[StringName] = [&"enemy_units", &"hero_units"]

static func make_damage(
	amount: float,
	source_node: Node,
	attacker_peer: int,
	knockback_dir: Vector3,
	knockback_force: float,
	hit_position: Vector3
) -> Dictionary:
	return {
		"amount": amount,
		"source": source_node,
		"attacker_peer": attacker_peer,
		"knockback_dir": knockback_dir,
		"knockback_force": knockback_force,
		"hit_position": hit_position,
		"time_msec": Time.get_ticks_msec(),
	}

## Явная таблица враждебности: герои бьют врагов и разрушаемые объекты;
## враги бьют только героев (props не трогают, чтобы не ломать себе маршрут).
static func is_hostile(team_a: int, team_b: int) -> bool:
	if team_a == Team.HERO:
		return team_b == Team.ENEMY or team_b == Team.PROP
	if team_a == Team.ENEMY:
		return team_b == Team.HERO
	return false
