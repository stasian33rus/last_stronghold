extends Node
## Визуальная витрина (Этап 3.3): скриншоты ПРЯМО ИЗ GODOT с реальными игровыми
## моделями и игровой (риговой) камерой. offline-матч на арене, probe-пешки
## (Валькирия формы I/II/III + Берсерка), кадровые снимки lineup/крупных планов/
## боевых ситуаций в docs/screenshots (или +shotdir=...).
## Запуск (software GL, виртуальный дисплей):
##   xvfb-run -a godot --rendering-driver opengl3 --rendering-method gl_compatibility \
##     --resolution 800x450 --path . res://tests/visual_showcase.tscn -- +shotdir=/abs/dir
## Особенность software-рендера: долгие первые кадры (компиляция шейдеров
## llvmpipe) — перед съёмкой адаптивный прогрев до освещённого кадра; бои на
## время линейки «заморожены» (тестовая заморозка, геймплей не меняет).

var _shot_dir := "res://docs/screenshots"
var _shots := 0
var _guard_full := true

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("+shotdir="):
			_shot_dir = a.trim_prefix("+shotdir=")
	DirAccess.make_dir_recursive_absolute(_shot_dir)
	get_tree().create_timer(900.0).timeout.connect(func() -> void:
		print("[SHOWCASE] watchdog: выход по таймауту")
		get_tree().quit(3))
	_run.call_deferred()

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func _match() -> MatchController:
	var mcs := get_tree().get_nodes_in_group("match_controller")
	return mcs[0] if mcs.size() > 0 else null

func _prog() -> Node:
	var ps := get_tree().get_nodes_in_group("progression_system")
	return ps[0] if ps.size() > 0 else null

func _local_pawn() -> PlayerPawn:
	for c in get_tree().get_nodes_in_group("player_pawns"):
		var p := c as PlayerPawn
		if p != null and p.is_local_pawn():
			return p
	return null

func _wait_until(cond: Callable, timeout_sec: float) -> bool:
	## Реальное время: на software-рендере кадры редкие, «кадровые» секунды
	## растягивались бы в минуты.
	var t0 := Time.get_ticks_msec()
	while not bool(cond.call()) and (Time.get_ticks_msec() - t0) < int(timeout_sec * 1000.0):
		await get_tree().process_frame
	return bool(cond.call())

## Заморозка боя на время съёмки линейки: Гигачад и пешки живы, враги оглушены
## и отодвинуты. В боевой секции (_guard_full=false) — только лечение защитника.
func _guard_once() -> void:
	for g in get_tree().get_nodes_in_group("gigachad"):
		var h := (g as Node).get_node_or_null(^"Health") as HealthComponent
		if h != null and not h.is_dead:
			h.heal(10000.0)
	for pp in get_tree().get_nodes_in_group("player_pawns"):
		var pawn := pp as PlayerPawn
		if pawn != null and pawn.state != PlayerPawn.State.DOWN:
			pawn.health.heal(10000.0)
	if not _guard_full:
		return
	for ee in get_tree().get_nodes_in_group("enemy_units"):
		var foe := ee as EnemyBase
		if foe != null and not foe.health.is_dead:
			foe.apply_external_stun(6.0)
			foe.global_position = Vector3(19.0, 0.2, 19.0)

func _shot(name: String) -> void:
	_guard_once()
	await get_tree().process_frame
	await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	var path := _shot_dir.path_join(name)
	var err := img.save_png(path)
	_shots += 1
	print("[SHOT] %s err=%d" % [name, err])

## Кадрирование игровой камерой: пешка-наблюдатель ставится в точку, риговая
## камера следует за ней (zoom_factor — штатный зум колеса мыши).
func _rig_frame(t: Node3D, zoom: float) -> void:
	var p := _local_pawn()
	if p == null or p.camera_rig == null:
		return
	p.camera_rig.target = t
	p.camera_rig.zoom_factor = zoom

## Замедление игрового времени: на software-рендере кадр живёт ~0.5 с реальных —
## без замедления фазы атак/трансформаций проскакивают между кадрами.
func _slow(factor: float) -> void:
	Engine.time_scale = factor

func _vk_input(move: Vector2 = Vector2.ZERO) -> Dictionary:
	return {"move": move, "aim_yaw": 0.0, "press_attack": false, "press_dodge": false,
		"press_skill": false, "press_parry": false}

func _consume_offers(sys: Node) -> void:
	var st = sys.states.get(1, null)
	var guard := 0
	while st != null and st.offer_active and guard < 5:
		guard += 1
		if st.offer_ids.size() > 0:
			sys._apply_choice(1, st.offer_ids[0], true)
		else:
			st.offer_active = false

func _run() -> void:
	print("[SHOWCASE] старт, shotdir=%s" % _shot_dir)
	await _frames(3)
	Game.progression_balance_path = Game.BALANCE_FAST
	Game.start_offline_match(&"valkyrie", "Валькирия")
	var ok := await _wait_until(func(): return _match() != null and _local_pawn() != null, 10.0)
	if not ok:
		push_error("[SHOWCASE] арена/пешка не поднялись")
		get_tree().quit(1)
		return
	var mc := _match()
	var pawn := _local_pawn()
	## Программный рендер (llvmpipe): тени directional отключаем — на software GL
	## они могут гасить источники света; в игре на реальном GPU тени штатные.
	for lname in ["KeyLight", "FillLight"]:
		var dl := get_tree().current_scene.get_node_or_null(NodePath(lname)) as DirectionalLight3D
		if dl != null:
			dl.shadow_enabled = false
	## Линейка форм: probe-пешки во время COUNTDOWN (враги ещё не спавнились).
	await _wait_until(func(): return mc.phase == MatchController.Phase.COUNTDOWN, 5.0)
	var arena := get_tree().current_scene
	var sys := _prog()
	var p1: PlayerPawn = arena.spawn_player(780, "Форма I", &"valkyrie", Vector3(-1.4, 0.2, 0.0))
	var p2: PlayerPawn = arena.spawn_player(777, "Форма II", &"valkyrie", Vector3(1.4, 0.2, 0.0))
	var p3: PlayerPawn = arena.spawn_player(778, "Форма III", &"valkyrie", Vector3(4.2, 0.2, 0.0))
	var pb: PlayerPawn = arena.spawn_player(779, "Берсерка", &"berserk", Vector3(-4.2, 0.2, 0.0))
	await _frames(5)
	if sys != null:
		var st2 := ProgressionState.new(); st2.peer_id = 777; sys.states[777] = st2
		var st3 := ProgressionState.new(); st3.peer_id = 778; sys.states[778] = st3
		sys.add_xp(777, 300) ## уровень 3 → форма II
		sys.add_xp(778, 750) ## уровень 5 → форма III
	for q in [pawn, p1, p2, p3, pb]:
		var p := q as PlayerPawn
		if p != null:
			p.rotation.y = PI ## лицом к камере (камера приходит с +Z)
			p.external_input = _vk_input()
	## Наблюдатель уходит из кадра; его камера будет целиться в probe-пешек.
	pawn.global_position = Vector3(0.0, -18.0, 0.2)
	await _frames(50) ## трансформации доигрывают, idle-цикл активен
	## Программная проверка положения/масштаба моделей (не под полом, не скрыты).
	for q in [pawn, p1, p2, p3, pb]:
		var p := q as PlayerPawn
		if p == null:
			continue
		var mroot: Node3D = p.visuals.get_node_or_null(^"ModelRoot")
		var model: Node3D = p.visuals.get_node_or_null(^"ModelRoot/Model")
		if model == null and p.class_id == &"valkyrie":
			print("[SHOWCASE] FAIL: у Валькирии нет модели (fallback?)")
		if mroot != null:
			var aabb := AABB()
			var first := true
			var stack: Array = [mroot]
			while not stack.is_empty():
				var n: Node = stack.pop_back()
				if n is MeshInstance3D:
					var mi := n as MeshInstance3D
					var ga := mi.global_transform * mi.get_aabb()
					aabb = ga if first else aabb.merge(ga)
					first = false
				stack.append_array(n.get_children())
			print("[SHOWCASE] %s: видима=%s aabb_y=[%.2f..%.2f] центр_xz=(%.2f,%.2f) пешка=(%.2f,%.2f)" % [
				p.player_name, str(mroot.visible), aabb.position.y, aabb.end.y,
				aabb.get_center().x, aabb.get_center().z, p.global_position.x, p.global_position.z])
	## Прогрев software-рендера: ждём освещённый кадр (центр экрана, вне HUD).
	print("[SHOWCASE] прогрев рендера (компиляция шейдеров llvmpipe)...")
	var t0 := Time.get_ticks_msec()
	var lit := false
	var last_probe := 0
	while not lit or (Time.get_ticks_msec() - t0) < 60000:
		if (Time.get_ticks_msec() - t0) > 420000:
			break
		_guard_once()
		await get_tree().process_frame
		if Time.get_ticks_msec() - last_probe < 5000:
			continue
		last_probe = Time.get_ticks_msec()
		var img := get_viewport().get_texture().get_image()
		var sum := 0.0
		var n := 0
		for px in [Vector2i(400, 225), Vector2i(400, 170), Vector2i(300, 250),
				Vector2i(500, 250), Vector2i(400, 120), Vector2i(250, 150)]:
			sum += img.get_pixel(px.x, px.y).v
			n += 1
		if sum / float(n) > 0.10:
			lit = true
	print("[SHOWCASE] прогрев завершён за %.0f с, lit=%s" % [(Time.get_ticks_msec() - t0) / 1000.0, str(lit)])
	## Линейка и крупные планы — игровой камерой пешки-наблюдателя.
	_rig_frame(p2, 1.45)
	await _shot("01_lineup_four_forms.png")
	_rig_frame(p1, 0.7)
	await _shot("02_valkyrie_form1_closeup.png")
	_rig_frame(p2, 0.7)
	await _shot("03_valkyrie_form2_closeup.png")
	_rig_frame(p3, 0.75)
	await _shot("04_valkyrie_form3_closeup.png")
	_rig_frame(pb, 0.7)
	await _shot("05_berserk_closeup.png")
	## Боевые кадры: врагов ставим кольцом вокруг наблюдателя, заморозку снимаем.
	_guard_full = false
	var i := 0
	for ee in get_tree().get_nodes_in_group("enemy_units"):
		var foe := ee as EnemyBase
		if foe != null and not foe.health.is_dead:
			var ang := TAU * float(i) / 5.0
			foe.global_position = pawn.global_position + Vector3(cos(ang) * 3.2, 0.2, sin(ang) * 3.2)
			i += 1
	pawn.global_position = Vector3(0.0, -1.0, 0.2)
	_rig_frame(pawn, 1.0)
	var fight_on := await _wait_until(func(): return mc.phase == MatchController.Phase.FIGHT, 12.0)
	var foes_near := await _wait_until(func():
		for f in get_tree().get_nodes_in_group("enemy_units"):
			if (f as Node3D).global_position.distance_to(pawn.global_position) < 6.0:
				return true
		return false, 20.0)
	_slow(0.25)
	if foes_near:
		pawn.try_attack()
		await _frames(3)
	await _shot("06_gameplay_valkyrie_combat.png")
	pawn.try_skill()
	await _frames(2)
	await _shot("07_valkyrie_skill_dash.png")
	pawn.try_parry()
	await _frames(2)
	await _shot("08_valkyrie_parry_stance.png")
	_slow(1.0)
	## Эволюция локальной пешки в бою: трансформация и форма III в игре.
	if sys != null:
		_slow(0.15)
		sys.add_xp(1, 300)
		_consume_offers(sys)
		await _frames(3)
		await _shot("09_valkyrie_evolve_transform.png")
		_slow(1.0)
		sys.add_xp(1, 450)
		_consume_offers(sys)
		await _frames(60)
		_consume_offers(sys)
		await _shot("10_valkyrie_form3_in_game.png")
	## Берсерка: взмах молота крупным планом.
	if pb != null:
		_rig_frame(pb, 0.75)
		_slow(0.25)
		pb.try_attack()
		await _frames(3)
		await _shot("11_berserk_attack.png")
		_slow(1.0)
	print("[SHOWCASE] готово, снимков: %d" % _shots)
	get_tree().quit(0)
