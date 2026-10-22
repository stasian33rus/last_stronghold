class_name EnemySpitter
extends EnemyBase
## «Плевальщик» — дальний бой (Этап 2, ТЗ 8.3).
## Держит дистанцию keep_distance, отступает при сближении, стреляет
## серверными снарядами с телеграфом (WINDUP). Снаряды создаёт ТОЛЬКО сервер
## через MultiplayerSpawner; клиент не может создать авторитетный снаряд.

func _chase_move(delta: float, dir: Vector3, dist: float) -> void:
	## Анти-застревание имеет приоритет (иначе может зажать в углу).
	if _strafe_timer > 0.0:
		var perp := Vector3(-dir.z, 0.0, dir.x) * _strafe_sign
		_ctrl_vel.x = move_toward(_ctrl_vel.x, perp.x * def.move_speed, def.acceleration * delta)
		_ctrl_vel.z = move_toward(_ctrl_vel.z, perp.z * def.move_speed, def.acceleration * delta)
		return
	var desired := Vector3.ZERO
	if dist < def.min_distance:
		desired = -dir * def.move_speed ## отход, если игрок подошёл вплотную
	elif dist > def.keep_distance:
		desired = dir * def.move_speed ## подход до огневой дистанции
	else:
		## Держим дистанцию, слегка смещаясь в сторону (перепозиционирование).
		desired = Vector3(-dir.z, 0.0, dir.x) * (def.move_speed * 0.3 * _strafe_sign)
	_ctrl_vel.x = move_toward(_ctrl_vel.x, desired.x, def.acceleration * delta)
	_ctrl_vel.z = move_toward(_ctrl_vel.z, desired.z, def.acceleration * delta)

func _begin_strike() -> void:
	## Серверный снаряд вместо ближнего хитбокса.
	var arenas := get_tree().get_nodes_in_group("arena")
	if arenas.is_empty():
		return
	var dir := _dir_to_target()
	var muzzle := global_position + Vector3(0.0, 1.25, 0.0) + dir * 0.75
	(arenas[0] as Node).call("spawn_projectile", muzzle, dir, def)
	fx_shoot.rpc()

@rpc("authority", "call_local", "unreliable")
func fx_shoot() -> void:
	Sfx.play("swing", -8.0, 0.55)
