extends Node
func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	Game.progression_balance_path = Game.BALANCE_FAST
	Game.start_offline_match(&"berserk", "Дебаг")
	await get_tree().physics_frame
	await get_tree().physics_frame
	var mc: MatchController = null
	for i in 600:
		await get_tree().physics_frame
		var mcs := get_tree().get_nodes_in_group("match_controller")
		if mcs.size() > 0:
			mc = mcs[0]
		if mc != null and mc.phase == MatchController.Phase.FIGHT:
			break
	print("phase=", mc.phase if mc != null else "null")
	var giga: GigaChad = get_tree().get_nodes_in_group("gigachad")[0]
	var foe: EnemyBase = null
	for i in 600:
		await get_tree().physics_frame
		for e in get_tree().get_nodes_in_group("enemy_units"):
			if not (e as EnemyBase).health.is_dead:
				foe = e
				break
		if foe != null:
			break
	if foe == null:
		print("NO ENEMY")
		get_tree().quit(1)
		return
	for e in get_tree().get_nodes_in_group("enemy_units"):
		if e != foe:
			e.global_position = Vector3(19, 0.2, 19)
			e.apply_external_stun(60.0)
	foe.global_position = giga.global_position + Vector3(0, 0, 3.0)
	var pawn: PlayerPawn = null
	for p in get_tree().get_nodes_in_group("player_pawns"):
		if (p as PlayerPawn).is_local_pawn():
			pawn = p
	pawn.global_position = Vector3(17, 0.2, 17)
	var hp0 := giga.health.health
	for i in 12:
		for k in 30:
			await get_tree().physics_frame
		var dist: float = foe.global_position.distance_to(giga.global_position)
		var nav_ok: bool = foe.nav_agent != null and foe._nav_active
		var nextp: Vector3 = foe.nav_agent.get_next_path_position() if nav_ok else Vector3.ZERO
		var reachable: bool = foe.nav_agent.is_target_reachable() if nav_ok else false
		print("t=%.1f state=%d dist=%.2f giga_hp=%.0f ctrl=(%.1f,%.1f) nav=%s reach=%s next=%s agent_target=%s" % [
			i * 0.5, foe.state, dist, giga.health.health,
			foe._ctrl_vel.x, foe._ctrl_vel.z, nav_ok, reachable,
			nextp, foe.nav_agent.target_position if nav_ok else Vector3.ZERO])
	print("RESULT giga_damaged=", giga.health.health < hp0)
	get_tree().quit(0)
