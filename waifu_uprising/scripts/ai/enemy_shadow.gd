class_name EnemyShadow
extends EnemyBase
## «Тень» — быстрый мобильный противник (Этап 2, ТЗ 8.2).
## Короткие рывки к цели (dash_*), серия из attack_hits ударов с интервалом
## (реализована в базовом _advance_flurry), длинный RECOVER = окно наказаний.

var _dash_cd: float = 1.0
var _dash_left: float = 0.0
var _dash_dir := Vector3.ZERO

func _chase_move(delta: float, dir: Vector3, dist: float) -> void:
	_dash_cd -= delta
	if _dash_left > 0.0:
		_dash_left -= delta
		_ctrl_vel = _dash_dir * def.dash_speed
		return
	if def.dash_speed > 0.0 and dist > def.dash_min_range and dist < def.aggro_radius and _dash_cd <= 0.0:
		## Рывок к цели — конечен по времени (dash_duration), зациклиться не может.
		_dash_left = def.dash_duration
		_dash_cd = def.dash_cooldown
		_dash_dir = dir
		return
	super._chase_move(delta, dir, dist)
