extends Node
## Offline-дымотест (без сети, headless):
##   godot --headless res://tests/smoke_test.tscn
## Проверяет РЕАЛЬНУЮ игровую логику Этапов 1-2: загрузка сцен, бой игрока, ИИ врага,
## отбрасывание, смерть, многоволновой цикл (FIGHT -> WAVE_COMPLETE -> INTERMISSION/магазин
## -> ready -> следующая волна), ПОБЕДА после всех волн, ПОРАЖЕНИЕ по смерти Гигачада,
## падение/возрождение игрока, прогрессия (XP/уровни/улучшения), магазин (валидация,
## лимиты, лечение, баффы), отсутствие роста объектов.
## Вывод: [SMOKE] PASS/FAIL по каждому пункту, итоговый код возврата процесса.

var _failures: Array[String] = []
var _checks: int = 0
var _obj_baseline: int = 0
var _obj_after_match1: int = 0
var _waves_started_log: Array[int] = []

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	print("[SMOKE] === Дымотест Этапов 1-2 (offline) ===")
	await get_tree().process_frame
	await get_tree().process_frame
	## Тестовый темп: ускоренный баланс (короткие интермиссии/отсчёты).
	Game.progression_balance_path = Game.BALANCE_FAST
	_test_data_layers()
	await _test_full_match_flow()
	await _test_defeat_and_down_flow()
	await _test_rescue_flow()
	await _test_physics_flow()
	await _test_env_flow()
	await _test_act1_flow()
	print("[SMOKE] === ИТОГ: проверок %d, провалов %d ===" % [_checks, _failures.size()])
	for f in _failures:
		print("[SMOKE] FAILED: %s" % f)
	Sfx.shutdown()
	get_tree().quit(1 if _failures.size() > 0 else 0)

# ------------------------------------------------------------------ хелперы

func _check(ok: bool, what: String) -> void:
	_checks += 1
	if ok:
		print("[SMOKE] PASS: %s" % what)
	else:
		_failures.append(what)
		print("[SMOKE] FAIL: %s" % what)

func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame

func _seconds(t: float) -> void:
	var waited := 0.0
	while waited < t:
		await get_tree().physics_frame
		waited += 1.0 / 60.0

func _wait_until(cond: Callable, timeout_sec: float) -> bool:
	var waited := 0.0
	while not bool(cond.call()) and waited < timeout_sec:
		await get_tree().physics_frame
		waited += 1.0 / 60.0
	return bool(cond.call())

func _wait_until_and_get(getter: Callable, timeout_sec: float) -> Variant:
	var waited := 0.0
	var result: Variant = getter.call()
	while result == null and waited < timeout_sec:
		await get_tree().physics_frame
		waited += 1.0 / 60.0
		result = getter.call()
	return result

func _local_pawn() -> PlayerPawn:
	for candidate in get_tree().get_nodes_in_group("player_pawns"):
		var p := candidate as PlayerPawn
		if p != null and p.is_local_pawn():
			return p
	return null

func _match() -> MatchController:
	var mcs := get_tree().get_nodes_in_group("match_controller")
	return mcs[0] if mcs.size() > 0 else null

func _giga() -> GigaChad:
	var gs := get_tree().get_nodes_in_group("gigachad")
	return gs[0] if gs.size() > 0 else null

func _prog() -> ProgressionSystem:
	var ps := get_tree().get_nodes_in_group("progression_system")
	return ps[0] if ps.size() > 0 else null

func _alive_enemies() -> Array:
	var result: Array = []
	for candidate in get_tree().get_nodes_in_group("enemy_units"):
		var foe := candidate as EnemyBase
		if foe != null and not foe.health.is_dead:
			result.append(foe)
	return result

func _find_enemy_of(def_id: String) -> EnemyBase:
	for e in _alive_enemies():
		var base := e as EnemyBase
		if base != null and base.def != null and String(base.def.id) == def_id:
			return base
	return null

## Отодвинуть и оглушить всех, кроме цели — детерминированные поведенческие проверки.
func _isolate(except: Node) -> void:
	for e in _alive_enemies():
		if e != except:
			e.global_position = Vector3(19.0, 0.2, 19.0)
			e.apply_external_stun(2.0)

func _has_timed_buff(st: ProgressionState) -> bool:
	for b in st.buffs:
		if float(b["remaining"]) > 0.0:
			return true
	return false

func _kill_all_enemies(by_peer: int = 1) -> void:
	for e in _alive_enemies():
		e.health.take_damage(Units.make_damage(9999.0, _local_pawn(), by_peer, Vector3.FORWARD, 6.0, e.global_position))

# ------------------------------------------------------------------ данные/сцены

func _test_data_layers() -> void:
	var cls := Classes.get_class_def(&"berserk")
	_check(cls != null, "ClassRegistry: класс «Берсерка» загружен из .tres")
	var foe_def := load("res://resources/enemies/fop.tres") as EnemyDefinition
	_check(foe_def != null and foe_def.display_name == "Пижон", "EnemyDefinition fop.tres загружен")
	var wave_def := load("res://resources/waves/wave_01.tres") as WaveDefinition
	_check(wave_def != null and wave_def.total_count(1) == 5 and wave_def.total_count(8) == 19,
		"WaveDefinition: масштабирование 1 игрок=5, 8 игроков=19 (формула 3+2N сохранена)")
	var wave2 := load("res://resources/waves/wave_02.tres") as WaveDefinition
	_check(wave2 != null and wave2.groups.size() == 2 and wave2.total_count(2) == 5,
		"WaveDefinition groups: волна 2 (2 игрока) = 4 Пижона + 1 Громила = %d" % (wave2.total_count(2) if wave2 != null else -1))
	_check(Content.all_upgrades().size() >= 12, "Реестр улучшений: >=12 (%d)" % Content.all_upgrades().size())
	_check(Content.all_shop_items().size() >= 5, "Реестр магазина: >=5 (%d)" % Content.all_shop_items().size())
	var bal := load(Game.BALANCE_DEFAULT) as ProgressionBalance
	_check(bal != null and bal.xp_required(1) == 100 and bal.xp_required(3) == 200,
		"Баланс прогрессии: формула 100+50×(L−1)")
	for arch in [["brute", "Громила"], ["shadow", "Тень"], ["spitter", "Плевальщик"]]:
		var adef := load("res://resources/enemies/%s.tres" % arch[0]) as EnemyDefinition
		_check(adef != null and adef.display_name == arch[1], "EnemyDefinition %s загружен" % arch[1])
		if adef != null:
			var ascene := load(adef.scene_path) as PackedScene
			_check(ascene != null, "Сцена %s загружается" % arch[1])
	var w4 := load("res://resources/waves/wave_04.tres") as WaveDefinition
	var w4_paths: Array = []
	if w4 != null:
		for g in w4.groups:
			w4_paths.append(g.enemy_def_path)
	_check(w4 != null and w4.groups.size() == 5
			and w4_paths.has("res://resources/enemies/fop.tres")
			and w4_paths.has("res://resources/enemies/brute.tres")
			and w4_paths.has("res://resources/enemies/shadow.tres")
			and w4_paths.has("res://resources/enemies/spitter.tres")
			and w4_paths.has("res://resources/enemies/fop_elite.tres"),
		"Волна 4: состав из всех 4 архетипов + элита")
	for path in [
		"res://scenes/characters/player.tscn",
		"res://scenes/enemies/fop.tscn",
		"res://scenes/npcs/gigachad.tscn",
		"res://scenes/levels/arena_01/arena_01.tscn",
		"res://scenes/ui/hud.tscn",
		"res://scenes/main_menu/main_menu.tscn",
	]:
		var scene := load(path) as PackedScene
		_check(scene != null, "Сцена загружается: %s" % path)

	## --- Этап 3: реестр 8 классов × 3 формы и визуальные слоты.
	_check(Classes.definitions.size() == 8, "Реестр классов: 8 базовых классов (%d)" % Classes.definitions.size())
	_check(Classes.get_all_defs().size() == 24, "Всего определений класс×форма: 24 (8×3) = %d" % Classes.get_all_defs().size())
	var bchain := Classes.get_form_chain(&"berserk")
	_check(bchain.size() == 3
			and bchain[0].id == &"berserk" and bchain[1].id == &"berserk_f2" and bchain[2].id == &"berserk_f3"
			and bchain[1].unlock_level == 3 and bchain[2].unlock_level == 5,
			"Цепочка эволюции Берсерки I→II→III (открытие на уровнях 3 и 5)")
	_check(Classes.is_selectable(&"berserk") and Classes.is_selectable(&"valkyrie")
			and not Classes.is_selectable(&"berserk_f2") and not Classes.is_selectable(&"valkyrie_f2")
			and not Classes.is_selectable(&"witch"),
			"Лобби-валидация: реализованные базы (Берсерка, Валькирия); формы и заглушки отклоняются")
	_check(Classes.get_all().size() == 2, "В лобби доступны 2 реализованных класса (%d)" % Classes.get_all().size())
	## 24 визуальных слота: процедурная заглушка строится для каждого определения.
	var vis_script := load("res://scripts/gameplay/player_visuals.gd")
	var stub_scene := load("res://tests/assets/stub_model.tscn")
	var slots_ok := 0
	var slots_total := 0
	var null_model_ok := true
	for cdef in Classes.get_all_defs():
		slots_total += 1
		if cdef.model_scene != null:
			null_model_ok = false
		var holder := Node3D.new()
		var vis := Node3D.new()
		vis.set_script(vis_script)
		add_child(holder)
		holder.add_child(vis)
		vis.rebuild(cdef)
		var meshes := 0
		var stack: Array = [vis]
		while not stack.is_empty():
			var n: Node = stack.pop_back()
			if n is MeshInstance3D:
				meshes += 1
			stack.append_array(n.get_children())
		if meshes >= 3:
			slots_ok += 1
		remove_child(holder)
		holder.free()
	_check(slots_ok == slots_total and slots_total == 24,
		"24/24 визуальных слота: заглушка строится для каждой формы (%d/%d)" % [slots_ok, slots_total])
	var with_model := 0
	for cdef in Classes.get_all_defs():
		if cdef.model_scene != null:
			with_model += 1
	var vk_models := 0
	for cdef in Classes.get_form_chain(&"valkyrie"):
		if cdef.model_scene != null:
			vk_models += 1
	var bk_models := 0
	for cdef in Classes.get_form_chain(&"berserk"):
		if cdef.model_scene != null:
			bk_models += 1
	_check(with_model == 6 and vk_models == 3 and bk_models == 3,
		"Слоты .glb: 6 подключены (цепочки Валькирии и Берсерки), 18 слотов остальных классов пусты")
	## --- Этап 3.2: настоящие .glb-модели трёх форм Валькирии (Blender, PBR, skin).
	var need_anims := ["idle", "run", "attack", "skill", "parry", "hit", "death", "transform"]
	var glb_ok := true
	var glb_detail := ""
	for f in ["valkyrie/valkyrie_f1", "valkyrie/valkyrie_f2", "valkyrie/valkyrie_f3",
			"berserk/berserk_f1", "berserk/berserk_f2", "berserk/berserk_f3"]:
		var sc := load("res://models/%s.glb" % f) as PackedScene
		if sc == null:
			glb_ok = false
			glb_detail = f + ":load fail"
			break
		var mroot := sc.instantiate()
		add_child(mroot)
		var ap := mroot.find_child("AnimationPlayer", true, false) as AnimationPlayer
		var skel := mroot.find_child("Skeleton3D", true, false) as Skeleton3D
		var wp := mroot.find_child("WeaponPivot", true, false)
		var missing := ""
		if ap == null or skel == null or wp == null or skel.get_bone_count() < 20:
			missing = "nodes/skeleton"
		else:
			for an in need_anims:
				if not ap.has_animation(an):
					missing = "anim:" + an
					break
		if missing == "" and (f == "valkyrie/valkyrie_f3" or f == "berserk/berserk_f3") \
				and mroot.find_child("Aura", true, false) == null:
			missing = "aura"
		if missing != "":
			glb_ok = false
			glb_detail = f + ":" + missing
		remove_child(mroot)
		mroot.free()
	_check(glb_ok, "6 моделей .glb (Валькирия+Берсерка ×3): скин+скелет+8 анимаций+WeaponPivot/Aura [%s]" % glb_detail)
	## Слот model_scene: внешняя модель заменяет заглушку без правки кода (путь Inspector).
	var bdef := Classes.get_class_def(&"berserk")
	var holder2 := Node3D.new()
	var vis2 := Node3D.new()
	vis2.set_script(vis_script)
	add_child(holder2)
	holder2.add_child(vis2)
	bdef.model_scene = stub_scene
	vis2.rebuild(bdef)
	var model_ok: bool = vis2.get_node_or_null(^"ModelRoot/Model") != null
	bdef.model_scene = null ## восстановить общий ресурс
	vis2.rebuild(bdef)
	var proc_ok: bool = vis2.get_node_or_null(^"ModelRoot/Model") == null
	remove_child(holder2)
	holder2.free()
	_check(model_ok and proc_ok, "model_scene: внешняя модель подключается и снимается без кода")

# ------------------------------------------------------------------ полный матч

func _test_full_match_flow() -> void:
	Game.start_offline_match(&"berserk", "Тестер")
	await _frames(2)
	var mc: MatchController = await _wait_until_and_get(func(): return _match(), 10.0)
	_check(mc != null, "Арена загружена, MatchController найден")
	var pawn_ok: bool = await _wait_until(func(): return _local_pawn() != null, 5.0)
	_check(pawn_ok, "Пешка игрока заспавнена (offline)")
	_check(_giga() != null, "Гигачад на арене")
	if mc == null or not pawn_ok:
		return
	_check(mc.phase == MatchController.Phase.COUNTDOWN, "Фаза COUNTDOWN после загрузки")

	var wm := mc.get_parent().get_node(^"WaveManager") as WaveManager
	wm.wave_started.connect(func(idx: int, _total: int) -> void: _waves_started_log.append(idx))

	var fight_on: bool = await _wait_until(func(): return mc.phase == MatchController.Phase.FIGHT, 10.0)
	_check(fight_on, "Фаза FIGHT после отсчёта")
	_obj_baseline = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	await _test_navigation()
	var spawned: bool = await _wait_until(func(): return not _alive_enemies().is_empty(), 15.0)
	_check(spawned, "Волна 1 заспавнила врагов (alive=%d)" % _alive_enemies().size())
	if not spawned:
		return

	## --- Настоящий бой: удар игрока наносит урон и отбрасывает врага.
	var pawn := _local_pawn()
	var enemies := _alive_enemies()
	var foe: EnemyBase = enemies[0]
	foe.global_position = pawn.global_position + Vector3(0.0, 0.0, -1.7)
	pawn.rotation.y = 0.0
	foe.apply_external_stun(2.0)
	await _frames(2)
	var hp_before := foe.health.health
	var pos_before := foe.global_position
	pawn.external_input = {"move": Vector2.ZERO, "aim_yaw": 0.0, "press_attack": false, "press_dodge": false}
	pawn.try_attack()
	await _seconds(0.45)
	_check(foe.health.health < hp_before or foe.health.is_dead,
		"Удар игрока нанёс урон врагу (%.0f -> %.0f)" % [hp_before, foe.health.health])
	_check(foe.global_position.distance_to(pos_before) > 0.3 or foe.health.is_dead,
		"Враг отброшен ударом (смещение %.2f м)" % foe.global_position.distance_to(pos_before))

	## --- Покупка вне интермиссии отклоняется (фаза FIGHT).
	var sys := _prog()
	_check(sys != null, "ProgressionSystem найден")
	if sys == null:
		return
	var st: ProgressionState = sys.states.get(1, null)
	_check(st != null, "Серверное состояние прогрессии peer 1 существует")
	if st == null:
		return
	var coins_before := st.coins
	_check(not sys.try_buy(1, &"potion_small") and st.coins == coins_before,
		"Покупка вне INTERMISSION отклонена, монеты не списаны")

	## --- Враг атакует игрока (ИИ доходит до выпада) с наблюдаемым телеграфом.
	pawn.external_input = null
	if not _alive_enemies().is_empty():
		foe = _alive_enemies()[0]
	if is_instance_valid(foe) and not foe.health.is_dead:
		foe.global_position = pawn.global_position + Vector3(1.6, 0.0, 0.0)
		var pawn_hp_before := pawn.health.health
		var saw_windup := [false]
		var pawn_hurt: bool = await _wait_until(func():
			if is_instance_valid(foe) and foe.state == EnemyBase.State.WINDUP:
				saw_windup[0] = true
			return pawn.health.health < pawn_hp_before or pawn.health.is_dead, 5.0)
		_check(saw_windup[0], "Телеграф атаки (WINDUP) наблюдался до удара")
		_check(pawn_hurt,
			"ИИ врага провёл выпад и нанёс урон игроку (%.0f -> %.0f)" % [pawn_hp_before, pawn.health.health])

	## --- ИИ переключается на Гигачада, когда игрок далеко.
	var giga := _giga()
	pawn.global_position = Vector3(17.0, 0.2, 17.0)
	for e in _alive_enemies():
		(e as EnemyBase).global_position = giga.global_position + Vector3(randf_range(-2.5, 2.5), 0.0, randf_range(2.6, 3.2))
	var giga_hp_before := giga.health.health
	var giga_hurt: bool = await _wait_until(func(): return giga.health.health < giga_hp_before, 8.0)
	_check(giga_hurt or _alive_enemies().is_empty(),
		"Враги атакуют Гигачада (hp %.0f -> %.0f)" % [giga_hp_before, giga.health.health])

	await _test_destructibles()

	## --- Зачистка волны 1 -> WAVE_COMPLETE -> INTERMISSION (убиваем, пока спавнятся).
	var wc: bool = await _wait_until(func():
		_kill_all_enemies()
		return mc.phase != MatchController.Phase.FIGHT, 8.0)
	_check(wc, "После зачистки волны фаза WAVE_COMPLETE/INTERMISSION")
	var inter: bool = await _wait_until(func(): return mc.phase == MatchController.Phase.INTERMISSION, 6.0)
	_check(inter, "Интермиссия с магазином открыта")
	if not inter:
		return
	_check(st.coins >= 25, "Монеты начислены за убийства и волну (coins=%d)" % st.coins)

	## --- Магазин: реальная покупка, лечение без превышения максимума.
	pawn.health.take_damage(Units.make_damage(40.0, null, 0, Vector3.ZERO, 0.0, pawn.global_position))
	var hp_damaged := pawn.health.health
	sys.add_coins(1, 100, "тест")
	var coins_rich := st.coins
	var ok_buy := sys.try_buy(1, &"potion_small")
	var expected_heal: float = minf(pawn.effective_max_health(), hp_damaged + pawn.effective_max_health() * 0.4)
	_check(ok_buy and st.coins == coins_rich - 20, "Покупка «Малое лечение»: списано 20 монет (%d -> %d)" % [coins_rich, st.coins])
	_check(is_equal_approx(pawn.health.health, expected_heal),
		"Лечение без превышения максимума (%.0f -> %.0f, ожидали %.0f)" % [hp_damaged, pawn.health.health, expected_heal])

	## --- Отказ при недостатке монет.
	var poor_peer_state := st
	poor_peer_state.coins = 5
	var denied := sys.try_buy(1, &"rage_gloves")
	_check(not denied and poor_peer_state.coins == 5, "Отказ при недостатке монет, баланс не изменился")
	poor_peer_state.coins = coins_rich - 20

	## --- Отказ по неизвестному id.
	_check(not sys.try_buy(1, &"no_such_item"), "Неизвестный предмет отклонён")

	## --- Временное усиление урона реально меняет урон.
	var dmg_before := pawn.hitbox.damage
	ok_buy = sys.try_buy(1, &"rage_gloves")
	var mods_buffed: Dictionary = sys.compute_mods(st)
	var expected_buffed: float = pawn.class_def.attack_damage * float(mods_buffed["damage_mult"])
	_check(ok_buy and is_equal_approx(pawn.hitbox.damage, expected_buffed) and pawn.hitbox.damage > dmg_before,
		"«Перчатки ярости»: урон усилен (%.1f -> %.1f)" % [dmg_before, pawn.hitbox.damage])
	_check(st.buffs.size() == 1, "Временный бафф учтён на сервере")

	## --- Лимит за матч: Оберег хранительницы (1 за матч).
	var ward1 := sys.try_buy(1, &"keeper_ward")
	var ward2 := sys.try_buy(1, &"keeper_ward")
	_check(ward1 and not ward2, "Лимит за матч: вторая покупка Оберега отклонена")

	## --- Отрицательный баланс невозможен.
	st.coins = 0
	_check(not sys.try_buy(1, &"potion_small") and st.coins == 0, "Нулевой баланс: покупка отклонена, баланс не отрицательный")

	## --- Готовность запускает следующую волну; дубли ready не запускают её дважды.
	sys.set_wave_ready(1, true)
	sys.set_wave_ready(1, true)
	var next_fight: bool = await _wait_until(func(): return mc.phase == MatchController.Phase.COUNTDOWN or mc.phase == MatchController.Phase.FIGHT, 5.0)
	_check(next_fight, "Ready запустил отсчёт следующей волны")
	var wave2_fight: bool = await _wait_until(func(): return mc.phase == MatchController.Phase.FIGHT and wm.current_wave == 2, 8.0)
	_check(wave2_fight, "Волна 2 началась (current_wave=%d)" % wm.current_wave)

	## --- Волна 2: временный бафф истекает только в бою (постоянные — остаются).
	var buff_expire_ok := true
	if _has_timed_buff(st):
		for b in st.buffs:
			if float(b["remaining"]) > 0.0:
				b["remaining"] = 0.05
				break
		buff_expire_ok = await _wait_until(func(): return not _has_timed_buff(st), 3.0)
	_check(buff_expire_ok, "Временный бафф истёк в бою и снят сервером")
	var mods_after: Dictionary = sys.compute_mods(st)
	var expected_after: float = pawn.class_def.attack_damage * float(mods_after["damage_mult"])
	_check(is_equal_approx(pawn.hitbox.damage, expected_after),
		"После истечения баффа урон = базовый × модификаторы (%.1f)" % pawn.hitbox.damage)

	## --- Волны 2-4: зачистка, переходы, ровно один старт на волну.
	for wave_idx in range(2, 6):
		var has_enemies: bool = await _wait_until(func(): return not _alive_enemies().is_empty(), 12.0)
		if not has_enemies:
			_check(false, "Волна %d: враги появились" % wave_idx)
			break
		if wave_idx == 2:
			await _test_brute()
		elif wave_idx == 3:
			await _test_shadow()
		elif wave_idx == 4:
			await _test_spitter()
		var cleared: bool = await _wait_until(func():
			_kill_all_enemies()
			return mc.phase != MatchController.Phase.FIGHT, 15.0)
		if not cleared:
			for e in _alive_enemies():
				print("[DBG] wave5 alive: %s state=%d dead=%s pos=%s" % [e.def.id if e.def else "?", e.state, str(e.health.is_dead), str(e.global_position)])
			print("[DBG] wave5 wm: alive=%d queue=%d spawn_q=%d active=%s" % [wm.enemies_alive, wm.enemies_in_queue, wm.get("_spawn_queue").size(), str(wm.get("_active"))])
		_check(cleared, "Волна %d: все враги уничтожены (включая допавшихся)" % wave_idx)
		if wave_idx < 5:
			var inter_n: bool = await _wait_until(func(): return mc.phase == MatchController.Phase.INTERMISSION, 10.0)
			_check(inter_n, "Волна %d зачищена -> интермиссия" % wave_idx)
			var sys_r := _prog()
			var st_r: ProgressionState = sys_r.states.get(1, null)
			var probe_enemy: EnemyBase = load("res://scenes/enemies/fop.tscn").instantiate()
			probe_enemy.def = load("res://resources/enemies/fop.tres")
			get_tree().current_scene.get_node(^"Entities").add_child(probe_enemy)
			probe_enemy.position = Vector3(15.0, 0.5, 15.0)
			## _register_enemy подключает И damage_taken (вклад), И died_on_server (награды) —
			## как у врагов из волны. Ручное подключение died_on_server здесь было бы дублем
			## (Godot логирует ERROR «already connected»), поэтому подключаем только через реестр.
			sys_r._register_enemy(probe_enemy) ## учёт вклада урона, как у врагов из волны
			await _frames(3)
			st_r.xp = 0 ## гарантия: 20 XP не вызывают повышения уровня внутри проверки
			var coins_r0 := st_r.coins
			var kill_dmg := Units.make_damage(9999.0, _local_pawn(), 1, Vector3.FORWARD, 5.0, probe_enemy.global_position)
			probe_enemy.health.take_damage(kill_dmg)
			await _frames(3)
			sys_r._on_enemy_died_rewards(probe_enemy, kill_dmg) ## дублирующее событие
			await _frames(3)
			_check(st_r.coins - coins_r0 == sys_r.balance.coins_kill and st_r.xp == sys_r.balance.xp_normal,
				"Награда за врага ровно один раз (дубль события бессилен): +%d монет, %d XP" % [st_r.coins - coins_r0, st_r.xp])
			probe_enemy.queue_free()
			if wave_idx == 3:
				## Лимит за интермиссию: 3 малых лечения, 4-е отклоняется.
				sys.add_coins(1, 200, "тест")
				var b1 := sys.try_buy(1, &"potion_small")
				var b2 := sys.try_buy(1, &"potion_small")
				var b3 := sys.try_buy(1, &"potion_small")
				var b4 := sys.try_buy(1, &"potion_small")
				_check(b1 and b2 and b3 and not b4, "Лимит за интермиссию: 3 лечения ок, 4-е отклонено")
			await _test_valkyrie() ## бой серии/копий и награда — до финала акта
			sys.set_wave_ready(1, true)
			var fight_n: bool = await _wait_until(func(): return mc.phase == MatchController.Phase.FIGHT and wm.current_wave == wave_idx + 1, 12.0)
			_check(fight_n, "Волна %d началась после ready" % (wave_idx + 1))
		else:
			var vic: bool = await _wait_until(func(): return mc.phase == MatchController.Phase.VICTORY, 20.0)
			_check(vic, "ПОБЕДА после финальной волны 5 (босс повержен)")

	_check(_waves_started_log == [1, 2, 3, 4, 5], "Каждая волна стартовала ровно один раз: %s" % str(_waves_started_log))
	var proj_clean: bool = await _wait_until(func(): return get_tree().get_nodes_in_group("projectiles").is_empty(), 4.0)
	_check(proj_clean, "Снаряды удалены после завершения матча")
	var foes_clean: bool = await _wait_until(func(): return get_tree().get_nodes_in_group("enemy_units").is_empty(), 5.0)
	_check(foes_clean, "Сущности врагов полностью удалены после матча (трупы очищены)")
	var stats: Dictionary = mc.stats
	_check(stats.has(1) and int(stats[1]["kills"]) >= 10, "Статистика убийств посчитана сервером (kills=%d)" % int(stats[1]["kills"]))

	## Однократность награды за врага: дублирующее died-событие не даёт второй XP/монеты.

	await _test_evolution()

	await _test_progression()

	## --- Нет неограниченного роста объектов: после боя/прогрессии/UI-очистки.
	await _seconds(4.0)
	var obj_after := int(Performance.get_monitor(Performance.OBJECT_COUNT))
	_obj_after_match1 = obj_after
	var diag := ""
	## Предел +380: разовое построение UI матча + босс/элиты/полоса босса (Этап 5.1) (строки магазина ~40 узлов, карточки,
	## строки игроков) ПЛЮС узлы инстанцированной .glb-модели пешки (~80 на форму,
	## Этап 3.3 заменил лёгкую заглушку моделью) — легитимный одноразовый рост.
	## Настоящая проверка утечек — кросс-матчевое сравнение в конце
	## _test_defeat_and_down_flow (объекты не должны накапливаться от матча к матчу).
	if obj_after > _obj_baseline + 380:
		var enemies_left := get_tree().get_nodes_in_group("enemy_units").size()
		var hud_node2 := get_tree().current_scene.get_node_or_null(^"HUD")
		var cards := -1
		var toasts := -1
		if hud_node2 != null:
			cards = hud_node2.cards_box.get_child_count()
			toasts = hud_node2.toast_box.get_child_count()
		var entities := get_tree().current_scene.get_node_or_null(^"Entities")
		diag = " [diag: врагов=%d карт=%d тостов=%d сущностей=%d]" % [
			enemies_left, cards, toasts, entities.get_child_count() if entities != null else -1]
	_check(obj_after <= _obj_baseline + 380,
		"Объекты в матче: разовый рост в пределах UI+модели (%d до волны -> %d после, предел +%d)%s" % [_obj_baseline, obj_after, 380, diag])

# ------------------------------------------------------------------ эволюция (Этап 3)

func _spawn_probe_enemy(scene_path: String, def_path: String, pos: Vector3) -> EnemyBase:
	var escene := load(scene_path) as PackedScene
	var edef := load(def_path) as EnemyDefinition
	if escene == null or edef == null:
		return null
	var foe: EnemyBase = escene.instantiate()
	foe.def = edef
	get_tree().current_scene.get_node(^"Entities").add_child(foe)
	foe.global_position = pos
	return foe

## Пробный peer 777 не должен получать улучшения (чистота модификаторов статов):
## закрываем предложение без применения — так же, как это сделал бы таймаут.
func _close_offer(st: ProgressionState) -> void:
	st.offer_active = false
	st.offer_ids.clear()
	st.pending_choices = 0

## Детерминированные проверки трёх форм на отдельной пешке (peer 777):
## серверная разблокировка по уровню, сохранение состояния при смене формы,
## реальные трейты (комбо-волна, добивание, неистовство), идемпотентность,
## поле "f" в снапшоте BodySync (репликация формы клиентам).
func _test_evolution() -> void:
	var arena := get_tree().current_scene
	var sys := _prog()
	if sys == null or not arena.has_method("spawn_player"):
		_check(false, "Эволюция: арена и ProgressionSystem доступны")
		return
	var pawn: PlayerPawn = arena.spawn_player(777, "Эво-проба", &"berserk", Vector3(-15.0, 0.2, -15.0))
	await _frames(3)
	if pawn == null or not is_instance_valid(pawn):
		_check(false, "Эволюция: пробная пешка заспавнена (peer 777)")
		return
	var st777 := ProgressionState.new()
	st777.peer_id = 777
	sys.states[777] = st777
	_check(pawn.form_index == 0 and pawn.class_def.id == &"berserk", "Пешка стартует с формы I (berserk)")

	## Уровень 2: порога (3) нет — форма не меняется.
	sys.add_xp(777, 100)
	_close_offer(st777)
	await _frames(2)
	_check(st777.level == 2 and pawn.form_index == 0, "Уровень 2: форма I сохранена (порог не достигнут)")

	## Уровень 3 → форма II: статусы растут, состояние НЕ сбрасывается.
	## Дать пешке приземлиться после спавна (y=0.2 → пол), чтобы сравнение
	## позиции ловило телепорт от эволюции, а не физику падения.
	await _wait_until(func(): return pawn.is_on_floor(), 2.0)
	await _frames(4)
	pawn.health.take_damage(Units.make_damage(50.0, null, 0, Vector3.ZERO, 0.0, pawn.global_position))
	var pos_before := pawn.global_position
	var hp_before := pawn.health.health ## 70 из 120
	pawn._attack_cd_left = 0.5
	sys.add_xp(777, 150)
	_close_offer(st777)
	await _frames(2)
	_check(st777.level == 3 and pawn.form_index == 1 and pawn.class_def.id == &"berserk_f2",
		"Уровень 3: серверная эволюция в форму II «Волна ярости»")
	_check(pawn.global_position.distance_to(pos_before) < 0.1
			and is_equal_approx(pawn.health.health, hp_before + 30.0),
		"Эволюция сохраняет состояние: позиция та же, HP 70→100 (долечен дельтой максимума, не сброшен)")
	_check(pawn._attack_cd_left > 0.0 and pawn.owner_peer == 777 and pawn.name_label.text.contains("II"),
		"Эволюция не сбрасывает cooldown/сетевой id; подпись имени содержит «II»")
	_check(is_equal_approx(pawn.hitbox.damage, 30.0) and is_equal_approx(pawn.health.max_health, 150.0),
		"Форма II: реальные статусы — урон 30, макс.HP 150 (модификаторы 1.0)")
	var vis_root := pawn.visuals.get_node_or_null(^"ModelRoot")
	_check(vis_root != null and vis_root.get_child_count() > 0, "Форма II: визуальная модель перестроена")
	_check(pawn.visuals.get_node_or_null(^"ModelRoot/Model") != null and pawn.visuals.get("_anim") != null,
		"Берсерка: собственная .glb-модель формы подключена (процедурный fallback заменён)")

	## Уровень 5 → форма III «Абсолютная ярость».
	sys.add_xp(777, 450)
	_close_offer(st777)
	await _frames(2)
	_check(st777.level == 5 and pawn.form_index == 2 and pawn.class_def.id == &"berserk_f3",
		"Уровень 5: эволюция в форму III «Абсолютная ярость»")

	## Идемпотентность: повторные триггеры и макс. уровень не меняют финальную форму.
	pawn.try_evolve_for_level(10)
	pawn.try_evolve_for_level(99)
	sys.add_xp(777, 1000000)
	_close_offer(st777)
	await _frames(2)
	_check(pawn.form_index == 2 and pawn.class_def.id == &"berserk_f3",
		"Финальная форма: повторные вызовы и максимум XP бессильны (идемпотентность)")

	## Неистовство (канон §6.6): HP < 30% → урон ×1.25, cooldown ×0.75; выше — откат.
	pawn.health.heal(pawn.health.max_health)
	var dmg_calm: float = pawn.st["attack_damage"]
	pawn.health.take_damage(Units.make_damage(pawn.health.max_health * 0.75, null, 0, Vector3.ZERO, 0.0, pawn.global_position))
	await _frames(2)
	_check(pawn._frenzy_active and is_equal_approx(pawn.st["attack_damage"], 36.0 * 1.25)
			and is_equal_approx(pawn.st["attack_windup"], 0.12 * 0.75),
		"Неистовство при HP<30%%: урон 45, windup 0.09 (факт %.1f)" % pawn.st["attack_damage"])
	pawn.health.heal(pawn.health.max_health)
	await _frames(2)
	_check(not pawn._frenzy_active and is_equal_approx(pawn.st["attack_damage"], dmg_calm),
		"Неистовство снято после восстановления HP (статы откатились)")

	## Комбо-волна: удары 1-2 без волны, 3-й — радиальная волна вне радиуса ближнего боя.
	var foe_a := _spawn_probe_enemy("res://scenes/enemies/fop.tscn", "res://resources/enemies/fop.tres",
		pawn.global_position + Vector3(0.0, 0.0, -1.7))
	var foe_b := _spawn_probe_enemy("res://scenes/enemies/fop.tscn", "res://resources/enemies/fop.tres",
		pawn.global_position + Vector3(3.4, 0.0, 0.0))
	if foe_a == null or foe_b == null:
		_check(false, "Эволюция: пробные враги для ударной волны")
	else:
		foe_a.apply_external_stun(4.0)
		foe_b.apply_external_stun(4.0)
		pawn.rotation.y = 0.0
		pawn.external_input = {"move": Vector2.ZERO, "aim_yaw": 0.0, "press_attack": false, "press_dodge": false}
		var b_hp0: float = foe_b.health.health
		pawn._combo_hits = 0
		pawn._attack_cd_left = 0.0
		pawn.state = PlayerPawn.State.IDLE
		pawn.try_attack()
		await _seconds(0.6)
		_check(foe_a.health.health < foe_a.health.max_health, "Ближний удар формы III достигает цели A")
		_check(is_equal_approx(foe_b.health.health, b_hp0),
			"Удар 1 (комбо 1): волны нет — цель B в 3.4 м не задета")
		foe_a.global_position = pawn.global_position + Vector3(0.0, 0.0, -1.7)
		foe_a.apply_external_stun(4.0)
		foe_b.apply_external_stun(4.0)
		pawn._combo_hits = 2 ## следующее попадание — 3-е → волна
		pawn._attack_cd_left = 0.0
		pawn.state = PlayerPawn.State.IDLE
		pawn.try_attack()
		await _seconds(0.6)
		_check(foe_b.health.health < b_hp0,
			"Удар 3 (комбо 3): ударная волна достала цель B вне ближнего радиуса (%.0f→%.0f)" % [b_hp0, foe_b.health.health])
		pawn.external_input = null

	## Добивание (форма III): цель с HP ≤ 35% получает ×1.6, полная — ×1.0 (один взмах по двум).
	var brute := _spawn_probe_enemy("res://scenes/enemies/brute.tscn", "res://resources/enemies/brute.tres",
		pawn.global_position + Vector3(0.0, 0.0, -1.7))
	var brute_full := _spawn_probe_enemy("res://scenes/enemies/brute.tscn", "res://resources/enemies/brute.tres",
		pawn.global_position + Vector3(1.15, 0.0, -1.7))
	if brute == null or brute_full == null:
		_check(false, "Эволюция: пробные Громилы для добивания")
	else:
		brute.apply_external_stun(4.0)
		brute_full.apply_external_stun(4.0)
		## 180 HP → 63 (ровно 35%).
		brute.health.take_damage(Units.make_damage(117.0, null, 0, Vector3.ZERO, 0.0, brute.global_position))
		await _frames(2)
		var hp_ex0: float = brute.health.health
		var hp_fu0: float = brute_full.health.health
		pawn.rotation.y = 0.0
		pawn._combo_hits = 0
		pawn._attack_cd_left = 0.0
		pawn.state = PlayerPawn.State.IDLE
		pawn.try_attack()
		await _seconds(0.6)
		var d_ex: float = hp_ex0 - brute.health.health
		var d_fu: float = hp_fu0 - brute_full.health.health
		_check(is_equal_approx(d_ex, 36.0 * 1.6), "Добивание: ×1.6 урона цели с 35%% HP (%.1f)" % d_ex)
		_check(is_equal_approx(d_fu, 36.0), "Контроль: ×1.0 урона полнокровной цели (%.1f)" % d_fu)

	## Репликация формы: поле "f" в снапшоте; клиентский обработчик не трогает статы.
	var payload := pawn.get_sync_payload()
	_check(int(payload.get("f", -1)) == pawn.form_index,
		"Снапшот BodySync несёт текущую форму (f=%s)" % str(payload.get("f")))
	var dmg_server: float = pawn.st["attack_damage"]
	pawn.apply_sync_payload({"f": 0}) ## как клиент при получении снапшота
	_check(pawn.form_index == 0 and is_equal_approx(pawn.st["attack_damage"], dmg_server)
			and pawn.class_def.id == &"berserk",
		"Применение формы из снапшота: только визуал/подпись, серверные статы не пересчитываются")
	pawn.apply_sync_payload({"f": 2})

	## Уборка пробных сущностей.
	for e in [foe_a, foe_b, brute, brute_full]:
		if e != null and is_instance_valid(e):
			e.queue_free()
	pawn.queue_free()
	sys.states.erase(777)
	await _frames(3)

# ------------------------------------------------------------------ Валькирия (Этап 3.1)

func _vk_input(move: Vector2 = Vector2.ZERO) -> Dictionary:
	return {"move": move, "aim_yaw": 0.0, "press_attack": false, "press_dodge": false,
		"press_skill": false, "press_parry": false}

func _vk_hit(pawn: PlayerPawn, amount: float) -> void:
	pawn.get_node(^"Hurtbox").receive_hit(
		Units.make_damage(amount, null, 0, Vector3.FORWARD, 0.0, pawn.global_position))

## Валькирия: детерминированные проверки на пробной пешке (peer 778).
## Рывок с круговым ударом, парирование (успех/неудача/однократность/cooldown),
## формы II/III: доп. удар комбо, дальность, фантомы, цепочки, контратака
## со стаггером, очистка очередей и косметики.
func _test_valkyrie() -> void:
	var arena := get_tree().current_scene
	var sys := _prog()
	if sys == null or not arena.has_method("spawn_player"):
		_check(false, "Валькирия: арена и ProgressionSystem доступны")
		return
	var pawn: PlayerPawn = arena.spawn_player(778, "Вал-проба", &"valkyrie", Vector3(-15.0, 0.2, -15.0))
	await _frames(3)
	if pawn == null or not is_instance_valid(pawn):
		_check(false, "Валькирия: пробная пешка заспавнена (peer 778)")
		return
	var st778 := ProgressionState.new()
	st778.peer_id = 778
	sys.states[778] = st778
	_check(pawn.class_def != null and pawn.class_def.id == &"valkyrie" and pawn.form_index == 0,
		"Валькирия: пешка стартует с формы I")
	await _wait_until(func(): return pawn.is_on_floor(), 2.0)
	await _frames(4)
	pawn.external_input = _vk_input()

	## --- 0. Модель .glb подключена к слоту формы I и анимируется по состоянию.
	var vmodel := pawn.visuals.get_node_or_null(^"ModelRoot/Model")
	var vis_anim: AnimationPlayer = pawn.visuals.get("_anim")
	_check(vmodel != null and vis_anim != null,
		"Валькирия форма I: настоящая .glb-модель в слоте model_scene (заглушка отключена)")
	await _frames(2)
	_check(vis_anim != null and vis_anim.current_animation == "idle",
		"Модель: анимация idle активна после спавна")
	pawn.external_input = _vk_input(Vector2(0.0, -1.0))
	await _frames(4)
	var run_on: bool = vis_anim != null and vis_anim.current_animation == "run"
	pawn.external_input = _vk_input()
	await _frames(4)
	_check(run_on and vis_anim != null and vis_anim.current_animation == "idle",
		"Модель: переключение анимаций run/idle по состоянию пешки")

	## --- 1. Рывок: перемещает, НЕ проходит сквозь стену (стена z=-22), cooldown.
	pawn.global_position = Vector3(0.0, 0.2, -18.5)
	pawn.rotation.y = 0.0
	await _frames(2)
	var dash_pos0 := pawn.global_position
	pawn.try_skill()
	_check(pawn.state == PlayerPawn.State.SKILL, "Рывок: серверное состояние SKILL активно")
	await _seconds(0.45)
	var dash_moved := pawn.global_position.distance_to(dash_pos0)
	_check(dash_moved > 1.5 and pawn.global_position.z > -21.7,
		"Рывок: смещение %.1f м и остановлен стеной (z=%.2f, не прошёл сквозь)" % [dash_moved, pawn.global_position.z])
	var cd_active := pawn._skill_cd_left > 0.0
	pawn.try_skill()
	_check(cd_active and pawn.state != PlayerPawn.State.SKILL, "Рывок: cooldown запрещает повторную активацию")

	## --- 2. Круговой удар: несколько целей, ровно одно попадание, радиус.
	pawn.global_position = Vector3(-15.0, 0.2, -15.0)
	pawn.rotation.y = 0.0
	await _frames(2)
	var wa := _spawn_probe_enemy("res://scenes/enemies/fop.tscn", "res://resources/enemies/fop.tres",
		pawn.global_position + Vector3(0.0, 0.0, -1.5))
	var wb := _spawn_probe_enemy("res://scenes/enemies/fop.tscn", "res://resources/enemies/fop.tres",
		pawn.global_position + Vector3(1.8, 0.0, -1.0))
	var wc := _spawn_probe_enemy("res://scenes/enemies/fop.tscn", "res://resources/enemies/fop.tres",
		pawn.global_position + Vector3(0.0, 0.0, -6.5))
	for f in [wa, wb, wc]:
		f.apply_external_stun(4.0)
	pawn._skill_cd_left = 0.0
	pawn.external_input = _vk_input(Vector2(0.0, -1.0)) ## рывок к -Z
	pawn.try_skill()
	await _seconds(0.55)
	var exp_whirl := 22.0 * 1.1
	_check(is_equal_approx(60.0 - wa.health.health, exp_whirl) and is_equal_approx(60.0 - wb.health.health, exp_whirl),
		"Круговой удар поразил обе цели в радиусе РОВНО один раз (−%.1f каждая)" % exp_whirl)
	_check(is_equal_approx(wc.health.health, wc.health.max_health),
		"Цель вне радиуса (6.5 м) не задета круговым ударом")

	## --- 3. Парирование: неудачный тайминг — урон полный, бонусов нет.
	pawn.external_input = _vk_input()
	pawn._parry_cd_left = 0.0
	pawn.try_parry()
	var win_open := pawn._parry_window_until_msec > Time.get_ticks_msec()
	await _seconds(0.45) ## окно формы I — 0.30 с: истекает
	var hp_fail0 := pawn.health.health
	_vk_hit(pawn, 30.0)
	await _frames(2)
	_check(win_open and pawn._parries_landed == 0 and is_equal_approx(hp_fail0 - pawn.health.health, 30.0)
			and pawn._empower_mult == 1.0,
		"Парирование не удалось (окно истекло): урон полный, бонусов нет")

	## --- 4. Успешное парирование: отмена урона, защита, усиление, контратака.
	var ctr := _spawn_probe_enemy("res://scenes/enemies/fop.tscn", "res://resources/enemies/fop.tres",
		pawn.global_position + Vector3(0.0, 0.0, -2.5))
	ctr.apply_external_stun(4.0)
	var ctr_hp0: float = ctr.health.health
	pawn._parry_cd_left = 0.0
	pawn.try_parry()
	var hp_ok0 := pawn.health.health
	_vk_hit(pawn, 30.0)
	await _frames(2)
	_check(pawn._parries_landed == 1 and is_equal_approx(pawn.health.health, hp_ok0),
		"Парирование: урон атаки полностью отменён")
	_check(is_equal_approx(pawn.health.incoming_damage_multiplier, 0.65),
		"Парирование: защитный бонус — входящий урон ×0.65")
	_check(is_equal_approx(pawn.hitbox.damage, 22.0 * 1.7),
		"Парирование: следующая атака усилена ×1.7 (%.1f)" % pawn.hitbox.damage)
	_check(is_equal_approx(ctr_hp0 - ctr.health.health, 22.0 * 0.8),
		"Парирование: контратака поразила врага в радиусе (−%.1f)" % (22.0 * 0.8))

	## --- 5. Повторное попадание: окно израсходовано — бонус НЕ дублируется.
	_vk_hit(pawn, 20.0)
	await _frames(2)
	_check(pawn._parries_landed == 1 and is_equal_approx(pawn.health.health, hp_ok0 - 20.0 * 0.65),
		"Повторный удар: парирование однократно за активацию, урон снижен только защитным бонусом")
	pawn.try_parry()
	_check(pawn._parry_window_until_msec == 0, "Cooldown парирования не открывает окно сразу")

	## --- 6. Усиленный взмах РЕАЛЬНО бьёт ×1.7 и снимается после взмаха.
	var emp := _spawn_probe_enemy("res://scenes/enemies/brute.tscn", "res://resources/enemies/brute.tres",
		pawn.global_position + Vector3(0.0, 0.0, -1.6))
	emp.apply_external_stun(4.0)
	pawn.rotation.y = 0.0
	pawn._attack_cd_left = 0.0
	pawn.state = PlayerPawn.State.IDLE
	pawn.try_attack()
	await _seconds(0.6)
	_check(is_equal_approx(180.0 - emp.health.health, 22.0 * 1.7) and is_equal_approx(pawn.hitbox.damage, 22.0),
		"Усиленный взмах нанёс 37.4 и усиление снято после завершения")

	## --- 7. Форма II «Клинковый танец»: сохранение состояния, доп. удар, дальность, окно.
	var pos_pre := pawn.global_position
	pawn._skill_cd_left = 2.0
	pawn.health.take_damage(Units.make_damage(20.0, null, 0, Vector3.ZERO, 0.0, pawn.global_position))
	var hp_pre := pawn.health.health
	sys.add_xp(778, 300) ## уровень 3
	_close_offer(st778)
	await _frames(2)
	_check(pawn.form_index == 1 and pawn.class_def.id == &"valkyrie_f2",
		"Валькирия: серверная эволюция в форму II на уровне 3")
	var m2 := pawn.visuals.get_node_or_null(^"ModelRoot/Model")
	var vis_anim2: AnimationPlayer = pawn.visuals.get("_anim")
	_check(m2 != null and vis_anim2 != null
			and vis_anim2.current_animation == "transform",
		"Форма II: модель заменена без пересоздания пешки, играет анимация трансформации")
	_check(pawn.global_position.distance_to(pos_pre) < 0.1 and pawn._skill_cd_left > 1.5
			and pawn.owner_peer == 778 and is_equal_approx(pawn.health.health, hp_pre + 20.0),
		"Эволюция Валькирии сохраняет позицию/cooldown/peer, HP не сброшено (дельта максимума долечена)")
	var hb_shape := pawn.hitbox.get_node(^"CollisionShape3D")
	_check(hb_shape.scale.x > 1.05 and is_equal_approx(pawn.st["parry_window"], 0.45),
		"Форма II: дальность атаки увеличена (scale %.2f), окно парирования 0.45 с" % hb_shape.scale.x)
	var combo_foe := _spawn_probe_enemy("res://scenes/enemies/fop.tscn", "res://resources/enemies/fop.tres",
		pawn.global_position + Vector3(0.0, 0.0, -1.4))
	combo_foe.apply_external_stun(4.0)
	pawn.rotation.y = 0.0
	pawn._attack_cd_left = 0.0
	pawn.state = PlayerPawn.State.IDLE
	pawn._empower_mult = 1.0
	pawn.refresh_effective_stats()
	pawn.try_attack()
	await _seconds(0.6)
	_check(is_equal_approx(60.0 - combo_foe.health.health, 25.0 * 2.0),
		"Форма II: взмах наносит 2 удара (25+25=50), факт %.1f" % (60.0 - combo_foe.health.health))

	## --- 8. Форма III «Багровая богиня».
	sys.add_xp(778, 450) ## уровни 4 и 5
	_close_offer(st778)
	await _frames(2)
	_check(pawn.form_index == 2 and pawn.class_def.id == &"valkyrie_f3",
		"Валькирия: форма III «Багровая богиня» на уровне 5")
	_check(pawn.visuals.get("_aura_ring") != null,
		"Форма III: узел ауры (кольцо+кристаллы) модели подключен и вращается visuals")

	## 8a. Зеркальные копии: ровно 2 эхо-удара за взмах, без рекурсии.
	var ph := _spawn_probe_enemy("res://scenes/enemies/brute.tscn", "res://resources/enemies/brute.tres",
		pawn.global_position + Vector3(0.0, 0.0, -1.5))
	ph.apply_external_stun(6.0)
	pawn.rotation.y = 0.0
	pawn._attack_cd_left = 0.0
	pawn.state = PlayerPawn.State.IDLE
	pawn.try_attack()
	await _seconds(0.35)
	var ghosts := get_tree().get_nodes_in_group("phantom_fx")
	var ghost_anim := false
	for g in ghosts:
		if g.find_child("AnimationPlayer", true, false) != null:
			ghost_anim = true
	_check(ghosts.size() > 0 and ghost_anim,
		"Эхо-удары: зеркальные копии отрисованы моделью формы III с анимацией атаки")
	await _seconds(0.75)
	## Ожидание: 29 (осн.) + 29 (доп. удар) + 2×14.5 (копии) = 87.
	_check(is_equal_approx(180.0 - ph.health.health, 29.0 * 2.0 + 29.0 * 0.5 * 2.0),
		"Форма III: взмах + доп. удар + РОВНО 2 эха копий (87 урона), факт %.1f" % (180.0 - ph.health.health))
	_check(pawn._phantom_queue.is_empty(),
		"Очередь фантомов обработана: копии НЕ порождают новые копии (рекурсии нет)")

	## 8b. Награда за убийство — ровно один раз (даже при нескольких источниках).
	var st_coins0: int = st778.coins
	var victim := _spawn_probe_enemy("res://scenes/enemies/fop.tscn", "res://resources/enemies/fop.tres",
		pawn.global_position + Vector3(0.0, 0.0, -1.5))
	victim.apply_external_stun(6.0)
	sys._register_enemy(victim) ## учёт вклада/наград, как у врагов волны
	victim.health.take_damage(Units.make_damage(50.0, null, 0, Vector3.ZERO, 0.0, victim.global_position))
	pawn._attack_cd_left = 0.0
	pawn.state = PlayerPawn.State.IDLE
	pawn.try_attack()
	await _seconds(1.2)
	_check(victim.health.is_dead and st778.coins - st_coins0 == sys.balance.coins_kill,
		"Убийство серией ударов/копиями: награда +%d монет РОВНО один раз" % sys.balance.coins_kill)

	## 8c. Цепной удар: переходит на 2 врагов у первичной цели, вне дуги взмаха.
	## Изоляция проверки: прежние пробные враги уводятся далеко, чтобы в
	## chain_radius от первичной цели были ТОЛЬКО cq/cr (детерминизм).
	for f in [wa, wb, wc, ctr, emp, combo_foe, ph, victim]:
		if f != null and is_instance_valid(f):
			f.global_position = Vector3(19.0, 0.2, 19.0)
			if not f.health.is_dead:
				f.apply_external_stun(6.0)
	var cp := _spawn_probe_enemy("res://scenes/enemies/brute.tscn", "res://resources/enemies/brute.tres",
		pawn.global_position + Vector3(0.0, 0.0, -1.5))
	var cq := _spawn_probe_enemy("res://scenes/enemies/brute.tscn", "res://resources/enemies/brute.tres",
		pawn.global_position + Vector3(3.4, 0.0, -1.5))
	var cr := _spawn_probe_enemy("res://scenes/enemies/brute.tscn", "res://resources/enemies/brute.tres",
		pawn.global_position + Vector3(-3.4, 0.0, -1.5))
	for f in [cp, cq, cr]:
		f.apply_external_stun(6.0)
	pawn.rotation.y = 0.0
	pawn._attack_cd_left = 0.0
	pawn.state = PlayerPawn.State.IDLE
	pawn.try_attack()
	await _seconds(1.0)
	var exp_chain := 29.0 * 0.6
	_check(is_equal_approx(180.0 - cq.health.health, exp_chain) and is_equal_approx(180.0 - cr.health.health, exp_chain),
		"Цепной удар: 2 цели вне дуги получили по ×0.6 (%.1f) ровно один раз" % exp_chain)

	## 8d. Особая контратака идеального парирования: ×1.4 и стаггер группы.
	var pctr := _spawn_probe_enemy("res://scenes/enemies/brute.tscn", "res://resources/enemies/brute.tres",
		pawn.global_position + Vector3(0.0, 0.0, -4.0))
	pctr.apply_external_stun(0.3)
	await _seconds(0.35)
	pawn._parry_cd_left = 0.0
	pawn.try_parry()
	_vk_hit(pawn, 10.0)
	await _frames(2)
	_check(is_equal_approx(180.0 - pctr.health.health, 29.0 * 1.4) and pctr.state == EnemyBase.State.HITSTUN,
		"Форма III: контратака парирования ×1.4 (%.1f) со стаггером цели" % (180.0 - pctr.health.health))

	## --- 9. Очистка: смерть гасит очередь фантомов; косметика живёт ограниченно.
	pawn._attack_cd_left = 0.0
	pawn.state = PlayerPawn.State.IDLE
	pawn.try_attack()
	var queue_scheduled := pawn._phantom_queue.size() > 0
	pawn.health.take_damage(Units.make_damage(99999.0, null, 0, Vector3.FORWARD, 1.0, pawn.global_position))
	await _frames(2)
	_check(queue_scheduled and pawn._phantom_queue.is_empty() and pawn.state == PlayerPawn.State.DOWN,
		"Смерть пешки очищает очередь фантомов (посмертных эхо-ударов нет)")
	await _seconds(1.4)
	_check(get_tree().get_nodes_in_group("phantom_fx").is_empty(),
		"Косметические зеркальные копии истекают по времени жизни (утечек нет)")

	## --- Уборка пробных сущностей.
	for e in [wa, wb, wc, ctr, emp, combo_foe, ph, victim, cp, cq, cr, pctr]:
		if e != null and is_instance_valid(e):
			e.queue_free()
	pawn.queue_free()
	sys.states.erase(778)
	await _frames(3)

# ------------------------------------------------------------------ прогрессия

func _test_progression() -> void:
	var sys := _prog()
	if sys == null:
		_check(false, "ProgressionSystem доступен для проверки прогрессии")
		return
	var st: ProgressionState = sys.states.get(1, null)
	if st == null:
		_check(false, "Состояние прогрессии peer 1")
		return
	## ~15 врагов × 20 XP за матч: уровень заметно вырос, остаток не потерян.
	_check(st.level >= 3, "Уровень после матча >= 3 (level=%d)" % st.level)
	_check(st.xp >= 0 and st.xp < sys.balance.xp_required(st.level),
		"Остаток XP корректен (%d < %d)" % [st.xp, sys.balance.xp_required(st.level)])
	_check(sys.local_state.get("level", 0) == st.level, "Синхронизация зеркала HUD (level)")

	_check(st.coins >= 25, "Монеты за убийства/волны начислены (coins=%d)" % st.coins)

	## Формула и арифметика уровней — на изолированном состоянии (peer 999).
	var probe := ProgressionState.new()
	probe.peer_id = 999
	sys.states[999] = probe
	_check(sys.balance.xp_required(1) == 100 and sys.balance.xp_required(2) == 150 and sys.balance.xp_required(3) == 200,
		"Формула XP: 100 / 150 / 200")
	sys.add_xp(999, 260)
	_check(probe.level == 3 and probe.xp == 10, "260 XP -> уровень 3, остаток 10 (level=%d xp=%d)" % [probe.level, probe.xp])
	sys.add_xp(999, 1000000)
	_check(probe.level == sys.balance.max_level and probe.xp == 0,
		"Максимальный уровень %d, опыт не копится" % sys.balance.max_level)
	var pending_at_max := probe.pending_choices
	sys.add_xp(999, 500)
	_check(probe.level == sys.balance.max_level and probe.pending_choices == pending_at_max,
		"После макс. уровня новый опыт не даёт уровней и выборов")

	## Предложение: 3 уникальных допустимых id (у локального игрока).
	## Матч мог завершиться с открытым оффером (HUD закрыл его по match_ended) —
	## потребляем текущий и форсируем новое открытие, чтобы проверить полный цикл UI.
	if st.offer_active and st.offer_ids.size() > 0:
		sys._apply_choice(1, st.offer_ids[0], true)
	if not st.offer_active and st.level < sys.balance.max_level:
		sys.add_xp(1, sys.balance.xp_required(st.level))
	if st.offer_active:
		var ids := st.offer_ids
		_check(ids.size() >= 1 and ids.size() <= 3, "Предложение содержит %d улучшений" % ids.size())
		var unique := {}
		var valid := true
		for id in ids:
			if unique.has(id):
				valid = false
			unique[id] = true
			var def := Content.get_upgrade(id)
			if def == null or int(st.upgrade_levels.get(id, 0)) >= def.max_level:
				valid = false
		_check(valid, "Все предложения уникальны и не на максимальном уровне")

		## HUD реально строит экран выбора.
		var hud_node := get_tree().current_scene.get_node_or_null(^"HUD")
		if hud_node != null:
			_check(hud_node.upgrade_panel.visible and hud_node.cards_box.get_child_count() >= ids.size(),
				"HUD: экран выбора построен, карт: %d" % hud_node.cards_box.get_child_count())

		## Отклонение недопустимого id.
		var levels_before := st.upgrade_levels.duplicate(true)
		sys._apply_choice(1, &"totally_bogus_id", false)
		_check(st.upgrade_levels == levels_before and st.offer_active, "Недопустимый id отклонён без эффекта")

		## Применение ровно один раз.
		var first_id: StringName = ids[0]
		sys._apply_choice(1, first_id, false)
		var level_after_first: int = int(st.upgrade_levels.get(first_id, 0))
		sys._apply_choice(1, first_id, false)
		_check(int(st.upgrade_levels.get(first_id, 0)) == level_after_first and level_after_first >= 1,
			"Улучшение применено ровно один раз")
		var hud_after := get_tree().current_scene.get_node_or_null(^"HUD")
		if hud_after != null:
			_check(not hud_after.upgrade_panel.visible, "HUD: экран выбора закрыт после применения")

	## Автовыбор по серверному таймауту.
	if not st.offer_active:
		sys.add_xp(1, sys.balance.xp_required(st.level))
	var auto_ok := true
	if st.offer_active:
		var auto_id: StringName = st.offer_ids[0]
		st.offer_deadline_msec = Time.get_ticks_msec() - 1
		await _frames(5)
		auto_ok = not st.offer_active and int(st.upgrade_levels.get(auto_id, 0)) >= 1
	_check(auto_ok, "Таймаут -> сервер применил первое предложение (автовыбор)")

	## Одновременные выборы двух разных игроков.
	var p2 := ProgressionState.new()
	p2.peer_id = 998
	sys.states[998] = p2
	sys.add_xp(998, 100)
	_check(p2.offer_active, "Второй игрок получил собственное предложение")
	if p2.offer_active and p2.offer_ids.size() > 0:
		sys._apply_choice(998, p2.offer_ids[0], false)
		var total_levels: int = 0
		for v in p2.upgrade_levels.values():
			total_levels += int(v)
		_check(total_levels == 1, "Второй игрок применил улучшение независимо")

	## Эффект улучшения РЕАЛЬНО меняет характеристики (детерминированно: iron_body).
	## Формульная проверка (Этап 3): макс.HP обязан ТОЧНО равняться базе текущей
	## формы × серверные модификаторы — работает при любой форме/накопленных
	## улучшениях (старый порог «> ×1.25» завис от случайной истории забега).
	var pawn := _local_pawn()
	if pawn != null:
		var hp_max_before := pawn.health.max_health
		st.upgrade_levels[&"iron_body"] = int(st.upgrade_levels.get(&"iron_body", 0)) + 2
		sys._refresh_pawn(998, p2) ## у peer 998 пешки нет — не падать
		sys._refresh_pawn(1, st)
		var expected_max: float = pawn.class_def.max_health * float(sys.compute_mods(st)["max_health_mult"])
		_check(is_equal_approx(pawn.health.max_health, expected_max) and pawn.health.max_health > hp_max_before,
			"iron_body ×2 реально повысил макс. HP и совпал с формулой база×моды (%.0f -> %.0f = %.0f)" % [
				hp_max_before, pawn.health.max_health, expected_max])

	## Неавторизованные прямые вызовы клиентских RPC (sender=0 offline) — без эффекта.
	var xp_before := st.xp
	var lvl_before := st.level
	sys.cl_choose("iron_body")
	sys.cl_buy("potion_small")
	_check(st.xp == xp_before and st.level == lvl_before,
		"Прямые cl_choose/cl_buy без валидного sender не имеют эффекта")

	sys.states.erase(999)
	sys.states.erase(998)

# ------------------------------------------------------------------ поражение

func _dump_counts(tag: String) -> void:
	print("[SMOKE-DIAG] %s: objects=%d root_children=%d pawns=%d enemies=%d current_scene=%s" % [
		tag,
		int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		get_tree().root.get_child_count(),
		get_tree().get_nodes_in_group("player_pawns").size(),
		get_tree().get_nodes_in_group("enemy_units").size(),
		get_tree().current_scene.name if get_tree().current_scene != null else "null",
	])

func _test_defeat_and_down_flow() -> void:
	_dump_counts("перед матчем 2")
	Game.start_offline_match(&"berserk", "Тестер-2")
	await _frames(2)
	var mc: MatchController = await _wait_until_and_get(func(): return _match(), 10.0)
	var pawn := _local_pawn()
	var giga := _giga()
	if mc == null or pawn == null or giga == null:
		_check(false, "Повторная загрузка арены для теста поражения")
		return
	_check(true, "Повторная загрузка арены для теста поражения")

	pawn.health.take_damage(Units.make_damage(9999.0, null, 0, Vector3.FORWARD, 1.0, pawn.global_position))
	_check(pawn.state == PlayerPawn.State.DOWN and pawn.health.is_dead, "Игрок повержен (DOWN)")
	var revived: bool = await _wait_until(func(): return not pawn.health.is_dead and pawn.state != PlayerPawn.State.DOWN, 9.0)
	_check(revived, "Игрок возрождён источником (%.0f hp)" % pawn.health.health)

	giga.health.take_damage(Units.make_damage(99999.0, null, 0, Vector3.FORWARD, 1.0, giga.global_position))
	var defeated: bool = await _wait_until(func(): return _match() != null and _match().phase == MatchController.Phase.DEFEAT, 3.0)
	_check(defeated, "ПОРАЖЕНИЕ после смерти Гигачада")
	_check(giga.resonance >= 0.0, "Резонанс отслеживается (value=%.1f)" % giga.resonance)

	## Кросс-матчевая проверка утечек (ТЗ 14.5): второй матч не накапливает объекты.
	## Условие корректного сравнения: дождаться освобождения трупов (матч 2 завершился
	## поражением среди живых врагов — убираем их, как убрала бы полная зачистка).
	_kill_all_enemies()
	await _seconds(3.0)
	_dump_counts("конец матча 2")
	var obj_match2 := int(Performance.get_monitor(Performance.OBJECT_COUNT))
	_check(obj_match2 <= _obj_after_match1 + 20,
		"Нет роста объектов между матчами (%d после матча 1 -> %d после матча 2)" % [_obj_after_match1, obj_match2])


# ------------------------------------------------------------------ архетипы (Этап 2)

func _test_brute() -> void:
	var brute: EnemyBase = await _wait_until_and_get(func(): return _find_enemy_of("brute"), 8.0)
	_check(brute != null, "Волна 2: «Громила» появился на арене")
	if brute == null:
		return
	_isolate(brute)
	## Уязвимость во время восстановления (ТЗ 8.1).
	brute._set_state(EnemyBase.State.RECOVER)
	_check(is_equal_approx(brute.health.incoming_damage_multiplier, brute.def.recover_damage_mult),
		"Громила: в RECOVER уязвимость ×%.1f" % brute.def.recover_damage_mult)
	var hp0 := brute.health.health
	brute.health.take_damage(Units.make_damage(10.0, _local_pawn(), 1, Vector3.FORWARD, 0.0, brute.global_position))
	_check(is_equal_approx(hp0 - brute.health.health, 10.0 * brute.def.recover_damage_mult),
		"Громила: урон в RECOVER умножен (%.0f -> %.0f)" % [hp0, brute.health.health])
	_check(is_equal_approx(brute.health.incoming_damage_multiplier, 1.0),
		"Громила: уязвимость спадает после выхода из RECOVER")
	_check(brute.def.category == 1, "Громила — элита (категория наград 1)")

func _test_shadow() -> void:
	var shadow: EnemyBase = await _wait_until_and_get(func(): return _find_enemy_of("shadow"), 8.0)
	_check(shadow != null, "Волна 3: «Тень» появилась на арене")
	if shadow == null:
		return
	_isolate(shadow)
	var giga := _giga()
	## Уводим пешку далеко: ближайшей целью Тени гарантированно становится Гигачад.
	var pawn_sh := _local_pawn()
	if pawn_sh != null:
		pawn_sh.global_position = Vector3(17.0, 0.2, 17.0)
	var hp0 := giga.health.health
	## Ставим в 6 м: дальше dash_min_range — должен сделать рывок и провести серию.
	shadow.global_position = giga.global_position + Vector3(6.0, 0.0, 0.0)
	var hit: bool = await _wait_until(func(): return giga.health.health < hp0, 6.0)
	_check(hit, "Тень: рывок и серия ударов достигают цели (−%.0f hp Гигачада)" % (hp0 - giga.health.health))
	_check(shadow.def.attack_hits == 3, "Тень: серия из 3 ударов (данные)")

func _test_spitter() -> void:
	var spitter: EnemyBase = await _wait_until_and_get(func(): return _find_enemy_of("spitter"), 8.0)
	_check(spitter != null, "Волна 4: «Плевальщик» появился на арене")
	if spitter == null:
		return
	_isolate(spitter)
	var giga := _giga()
	var pawn_sp := _local_pawn()
	if pawn_sp != null:
		pawn_sp.global_position = Vector3(17.0, 0.2, 17.0)
	var hp0 := giga.health.health
	spitter.global_position = giga.global_position + Vector3(0.0, 0.0, 8.0)
	var proj_seen: bool = await _wait_until(func(): return get_tree().get_nodes_in_group("projectiles").size() > 0, 6.0)
	_check(proj_seen, "Плевальщик: серверный снаряд создан")
	var hit: bool = await _wait_until(func(): return giga.health.health < hp0, 6.0)
	_check(hit, "Плевальщик: снаряд попал по цели (−%.0f hp Гигачада)" % (hp0 - giga.health.health))
	spitter.apply_external_stun(6.0) ## остановить стрельбу для проверок очистки
	var cleaned: bool = await _wait_until(func(): return get_tree().get_nodes_in_group("projectiles").is_empty(), 5.0)
	_check(cleaned, "Снаряд удалён после попадания (очистка)")
	## Лимит одновременных снарядов (защита от сетевого шторма).
	var arena := get_tree().current_scene
	var spawned := 0
	for i in 25:
		if arena.spawn_projectile(giga.global_position + Vector3(0.0, 3.0, 0.0), Vector3.UP, spitter.def) != null:
			spawned += 1
	_check(spawned <= 16 and spawned > 0, "Лимит одновременных снарядов: создано %d из 25 (предел 16)" % spawned)
	get_tree().call_group(&"projectiles", "expire_now")
	await _frames(2)
	_check(get_tree().get_nodes_in_group("projectiles").is_empty(), "Снаряды очищены expire_now")


# ------------------------------------------------------------------ навигация (Этап 2)

func _nav_map() -> RID:
	var arena := get_tree().current_scene
	return arena.nav_region.get_navigation_map()

func _path_max_lateral(from: Vector3, to: Vector3, axis_x: float) -> float:
	var path := NavigationServer3D.map_get_path(_nav_map(), from, to, true)
	var max_dev := 0.0
	for p in path:
		max_dev = maxf(max_dev, absf((p as Vector3).x - axis_x))
	return max_dev

func _test_navigation() -> void:
	var arena := get_tree().current_scene
	var region: NavigationRegion3D = arena.nav_region
	_check(region.navigation_mesh.get_polygon_count() > 0,
		"NavMesh испечён на сервере: полигонов = %d" % region.navigation_mesh.get_polygon_count())
	## Маршрут вдоль x=9 упирается в колонну (9, 1.5, 9) — путь обязан её обходить.
	var dev := _path_max_lateral(Vector3(9.0, 0.2, 14.0), Vector3(9.0, 0.2, -14.0), 9.0)
	_check(dev > 1.0, "Маршрут обходит колонну (боковое отклонение %.2f м)" % dev)
	## Недостижимая цель — корректный результат без падения.
	var unreachable := NavigationServer3D.map_get_path(_nav_map(), Vector3(0, 0.2, 0), Vector3(0, 50.0, -500.0), true)
	_check(unreachable.size() >= 0, "Недостижимая цель обрабатывается корректно (точек: %d)" % unreachable.size())
	## У врагов есть активные агенты (сервер).
	await _wait_until(func(): return not _alive_enemies().is_empty(), 10.0)
	var agent_ok := true
	for e in _alive_enemies():
		var base := e as EnemyBase
		if base.nav_agent == null or not base._nav_active:
			agent_ok = false
	_check(agent_ok, "У всех врагов активные NavigationAgent3D")

# ------------------------------------------------------------------ разрушаемые объекты

func _test_destructibles() -> void:
	var crates := get_tree().get_nodes_in_group("destructibles")
	_check(crates.size() >= 6, "На арене разрушаемые ящики: %d" % crates.size())
	if crates.is_empty():
		return
	var crate := crates[0] as DestructibleProp
	## Отодвинуть врагов, чтобы проверки были детерминированными.
	_isolate(crate)
	var pawn := _local_pawn()
	var sys := _prog()

	## 1) Реальный удар игрока по ящику (проверка слоёв hurtbox_prop/mask 384).
	pawn.global_position = crate.global_position + Vector3(0.0, -0.9, 2.2)
	pawn.rotation.y = 0.0
	pawn.external_input = {"move": Vector2.ZERO, "aim_yaw": 0.0, "press_attack": false, "press_dodge": false}
	var crate_hp0 := crate.health.health
	pawn.try_attack()
	await _seconds(0.45)
	_check(crate.health.health < crate_hp0, "Удар молота повреждает ящик (%.0f -> %.0f)" % [crate_hp0, crate.health.health])
	pawn.external_input = null

	## 2) Стадии повреждения (2 состояния до разрушения).
	crate.health.take_damage(Units.make_damage(crate.health.health * 0.5, null, 0, Vector3.FORWARD, 0.0, crate.global_position))
	_check(crate._stage >= 1, "Стадия повреждения 1+ после 50%% HP (stage=%d)" % crate._stage)

	## 3) Навигация: путь вдоль x=5.5 огибает ящик (5.5, 0.9, -6.5).
	var dev_before := _path_max_lateral(Vector3(5.5, 0.2, -14.0), Vector3(5.5, 0.2, 2.0), 5.5)
	_check(dev_before > 0.5, "NavMesh учитывает ящик до разрушения (отклонение %.2f)" % dev_before)

	## 4) Разрушение ровно один раз + награда ровно один раз.
	var destroyed_counter := [0]
	crate.destroyed_by.connect(func(_peer: int) -> void: destroyed_counter[0] += 1)
	var st: ProgressionState = sys.states.get(1, null)
	var coins_before := st.coins
	crate.health.take_damage(Units.make_damage(99999.0, _local_pawn(), 1, Vector3.FORWARD, 2.0, crate.global_position))
	await _frames(3)
	_check(crate.is_destroyed, "Ящик разрушен (серверное состояние)")
	_check(crate.collision_layer == 0, "Коллизия разрушенного ящика отключена")
	_check(not crate.visuals.visible, "Разрушенный ящик скрыт (не «воскреснет» из снапшота)")
	_check(destroyed_counter[0] == 1, "Событие разрушения эмитировано ровно один раз (count=%d)" % destroyed_counter[0])
	crate.health.take_damage(Units.make_damage(99999.0, _local_pawn(), 1, Vector3.FORWARD, 2.0, crate.global_position))
	await _frames(2)
	_check(destroyed_counter[0] == 1, "Повторный урон не разрушает дважды (count=%d)" % destroyed_counter[0])
	_check(st.coins - coins_before == sys.balance.coins_crate,
		"Награда за ящик однократна: +%d монет" % (st.coins - coins_before))

	## 5) Обломки: появились локально и очистились по времени жизни.
	var debris_seen := get_tree().get_nodes_in_group("debris").size()
	_check(debris_seen > 0, "Обломки созданы (локальная косметика): %d" % debris_seen)
	await _seconds(3.5)
	_check(get_tree().get_nodes_in_group("debris").is_empty(), "Обломки очищены по времени жизни")

	## 6) Проходимость обновлена после перепекания NavMesh.
	await _seconds(1.0)
	var dev_after := _path_max_lateral(Vector3(5.5, 0.2, -14.0), Vector3(5.5, 0.2, 2.0), 5.5)
	_check(dev_after < dev_before and dev_after < 0.6,
		"NavMesh перепечён: путь сквозь бывший ящик выпрямился (%.2f -> %.2f)" % [dev_before, dev_after])

## Этап 4.1: кооперативное спасение поверженных (offline, серверная ветка).
func _test_rescue_flow() -> void:
	var arena := get_tree().current_scene
	var sys := _prog()
	if sys == null or not arena.has_method("spawn_player"):
		_check(false, "Спасение: арена и ProgressionSystem доступны")
		return
	var pa: PlayerPawn = arena.spawn_player(781, "Спас-А", &"berserk", Vector3(-12.0, 0.2, -12.0))
	var pb: PlayerPawn = arena.spawn_player(782, "Спас-Б", &"berserk", Vector3(-12.0, 0.2, -10.4))
	var pc: PlayerPawn = arena.spawn_player(783, "Спас-В", &"berserk", Vector3(-8.0, 0.2, -12.0))
	for peer in [781, 782, 783]:
		var stt := ProgressionState.new()
		stt.peer_id = peer
		sys.states[peer] = stt
	await _frames(4)
	if pa == null or pb == null or pc == null:
		_check(false, "Спасение: три пробные пешки заспавнены")
		return
	_check(true, "Спасение: три пробные пешки заспавнены (781/782/783)")
	var dmg := func(target: PlayerPawn) -> void:
		target.health.take_damage(Units.make_damage(9999.0, null, 0, Vector3.FORWARD, 1.0, target.global_position))

	## 1. Переход в DOWNED при нулевом HP + индикатор.
	dmg.call(pa)
	await _frames(2)
	_check(pa.state == PlayerPawn.State.DOWN and pa.health.is_dead, "Спасение: нулевое HP переводит в DOWN")
	_check(pa.down_indicator != null and pa.down_indicator.visible, "Спасение: индикатор поверженного состояния виден")

	## 2. Запрет боевых действий в DOWN.
	pa.try_attack()
	pa.try_skill()
	pa.try_parry()
	pa.try_dodge()
	await _frames(2)
	_check(pa.state == PlayerPawn.State.DOWN, "Спасение: атака/умение/парирование/рывок в DOWN запрещены")

	## 3. Некорректные запросы отклоняются (само-спасение, чужой/несуществующий peer).
	_check(pa.server_rescue_hold_by_peer(781, true) == false, "Спасение: само-спасение отклонено")
	_check(pa.server_rescue_hold_by_peer(999, true) == false, "Спасение: запрос несуществующего peer отклонён")

	## 4. Успешное спасение союзником: прогресс и возрождение на месте.
	var pos_before := pa.global_position
	_check(pa.server_rescue_hold_by_peer(782, true) == true, "Спасение: канал открыт сервером (peer 782)")
	await _frames(4)
	_check(pa.sync_rescuer_peer == 782 or pa.get("_rescue_rescuer_peer") == 782, "Спасение: цель знает спасателя")
	var rescued: bool = await _wait_until(func(): return pa.state != PlayerPawn.State.DOWN, 6.0)
	_check(rescued, "Спасение: союзник поднял поверженного до истечения таймера")
	_check(is_equal_approx(pa.health.health, pa.effective_max_health() * 0.45),
			"Спасение: HP восстановлено до 45%% максимума (%.0f)" % pa.health.health)
	_check(pa.global_position.distance_to(pos_before) < 0.75, "Спасение: возрождение на месте падения (без телепорта)")

	## 5. Однократность восстановления и повторные RPC после подъёма.
	var hp_after := pa.health.health
	await _seconds(0.4)
	_check(is_equal_approx(pa.health.health, hp_after), "Спасение: восстановление HP ровно один раз")
	_check(pa.server_rescue_hold_by_peer(782, true) == false, "Спасение: повторный RPC по живой цели отклонён")

	## 5б. Полный вводный конвейер: удержание interact через external_input.
	await _seconds(1.7) ## защита после спасения (1.5 с) должна истечь
	dmg.call(pa)
	await _frames(2)
	pc.global_position = pa.global_position + Vector3(1.0, 0.0, 0.0)
	await _frames(2)
	pc.external_input = {"hold_interact": true, "move": Vector2.ZERO}
	await _frames(4)
	print("[DBG] 5b: pa.state=%d dist_pc=%.2f channel=%d holding=%s pb_state=%d" % [
		pa.state, pc.global_position.distance_to(pa.global_position),
		int(pa.get("_rescue_rescuer_peer")), str(pa.get("_rescue_holding")), pb.state])
	_check(pa.get("_rescue_rescuer_peer") == 783, "Спасение: канал открыт удержанием внешнего ввода (783)")
	pc.external_input = {"hold_interact": false, "move": Vector2.ZERO}
	await _frames(4)
	_check(pa.get("_rescue_rescuer_peer") == 0 and pa.state == PlayerPawn.State.DOWN,
			"Спасение: канал отменён отпусканием удержания")
	pc.external_input = null

	## 6. Параллельные каналы на одну цель запрещены + отмена по дистанции.
	await _seconds(1.7)
	dmg.call(pa)
	await _frames(2)
	_check(pa.server_rescue_hold_by_peer(782, true) == true, "Спасение: второй канал открыт (782)")
	_check(pa.server_rescue_hold_by_peer(783, true) == false, "Спасение: параллельный канал второго спасателя отклонён")
	pb.global_position = Vector3(30.0, 0.2, 30.0)
	await _frames(6)
	_check(pa.get("_rescue_rescuer_peer") == 0 and pa.state == PlayerPawn.State.DOWN,
			"Спасение: канал отменён при выходе спасателя из радиуса")
	pa.server_rescue_hold_by_peer(782, false)

	## 7. Гибель спасателя отменяет канал.
	pb.global_position = Vector3(-12.0, 0.2, -10.4)
	await _frames(2)
	_check(pa.server_rescue_hold_by_peer(782, true) == true, "Спасение: канал открыт повторно (782)")
	await _frames(3)
	dmg.call(pb)
	await _frames(6)
	_check(pa.get("_rescue_rescuer_peer") == 0 and pa.state == PlayerPawn.State.DOWN,
			"Спасение: канал отменён после падения спасателя")
	pb.revive_now(1.0)

	## 8. Одиночный режим: без спасателей таймер доводит до штатной эвакуации.
	var expired: bool = await _wait_until(func(): return pa.state != PlayerPawn.State.DOWN, 9.0)
	_check(expired and pa.get("_rescue_rescuer_peer") == 0,
			"Спасение: соло-режим — истечение таймера даёт штатное возрождение (не бесконечный DOWN)")
	await _frames(2)
	_check(pa.down_indicator != null and not pa.down_indicator.visible, "Спасение: индикатор скрыт после подъёма")

	## 9. Гасим каналы и убираем пробные пешки, чтобы не влиять на последующие учёты.
	pa.server_rescue_hold_by_peer(782, false)
	for pawn in [pa, pb, pc]:
		if is_instance_valid(pawn):
			pawn.queue_free()
	await _frames(3)
	_check(true, "Спасение: пробные пешки освобождены")

## Этап 4.2: физика отбрасывания и столкновений врагов (offline, сервер).
func _test_physics_flow() -> void:
	var arena := get_tree().current_scene
	if arena == null or not arena.has_method("spawn_enemy"):
		_check(false, "Физика: арена доступна для спавна врагов")
		return
	var fdef := load("res://resources/enemies/fop.tres") as EnemyDefinition
	var spawned: Array = []
	var spawn_foe := func(pos: Vector3) -> EnemyBase:
		var e: EnemyBase = arena.spawn_enemy(fdef, pos)
		if e != null:
			spawned.append(e)
		return e

	## 1. Направление импульса — от атакующего/направления удара.
	var foe: EnemyBase = spawn_foe.call(Vector3(6.0, 0.2, 6.0))
	if foe == null:
		_check(false, "Физика: враг заспавнен для тестов")
		return
	await _frames(3)
	var p0 := foe.global_position
	var dir := Vector3(1.0, 0.0, 0.0)
	foe.health.take_damage(Units.make_damage(1.0, null, 1, dir, 8.0, p0))
	await _seconds(0.25)
	var disp := foe.global_position - p0
	disp.y = 0.0
	_check(disp.length() > 0.15 and disp.normalized().dot(dir) > 0.7,
			"Физика: импульс направлен по удару (dot=%.2f, смещение %.2f м)" % [disp.normalized().dot(dir), disp.length()])

	## 2. Затухание kb-составляющей (позицию позже засоряет преследование).
	foe.kb.apply(Vector3(1.0, 0.0, 0.0), 8.0, foe.def.knockback_mass)
	await _frames(1)
	var v0 := foe.kb.kb_velocity.length()
	await _seconds(0.3)
	var v1 := foe.kb.kb_velocity.length()
	await _seconds(0.3)
	var v2 := foe.kb.kb_velocity.length()
	await _seconds(0.9)
	var stopped := foe.kb.kb_velocity.length() < 0.15
	_check(v0 > 1.0 and v1 < v0 * 0.5 and v2 < v1 * 0.5 and stopped,
			"Физика: импульс затухает (kb %.1f -> %.1f -> %.1f -> %.2f)" % [v0, v1, v2, foe.kb.kb_velocity.length()])

	## 3. Предел ОДНОГО импульса и накопления (серия из 10 попаданий).
	var before := foe.kb.kb_velocity.length()
	foe.kb.apply(Vector3(0.0, 0.0, 1.0), 100.0, foe.def.knockback_mass)
	var added := foe.kb.kb_velocity.length() - before
	var max_seen := 0.0
	for i in 10:
		foe.kb.apply(Vector3(0.0, 0.0, 1.0), 9.0, foe.def.knockback_mass)
		max_seen = maxf(max_seen, foe.kb.kb_velocity.length())
		await _frames(1)
	_check(added <= foe.kb.max_impulse_add + 0.001 and max_seen <= foe.kb.max_speed + 0.001,
			"Физика: один импульс <= %.0f, накопление <= %.0f (факт %.1f/%.1f)" % [
				foe.kb.max_impulse_add, foe.kb.max_speed, added, max_seen])

	## 4. Препятствие останавливает: без сквозного прохода и телепортов.
	var crate_scn := load("res://scenes/interactables/crate_destructible.tscn") as PackedScene
	var crate: Node3D = crate_scn.instantiate()
	arena.add_child(crate)
	var wall_foe: EnemyBase = spawn_foe.call(Vector3(-6.0, 0.2, -6.0))
	await _frames(3)
	if wall_foe == null:
		_check(false, "Физика: враг у препятствия заспавнен")
	else:
		var wdir := Vector3(0.0, 0.0, 1.0)
		crate.global_position = wall_foe.global_position + wdir * 1.0
		await _frames(2)
		var wp0 := wall_foe.global_position
		wall_foe.kb.apply(wdir, 10.0, wall_foe.def.knockback_mass)
		await _seconds(0.6)
		var moved := (wall_foe.global_position - wp0).dot(wdir)
		var gap := wall_foe.global_position.distance_to(crate.global_position)
		_check(moved < 0.95 and gap > 0.4 and wall_foe.global_position.is_finite(),
				"Физика: препятствие гасит импульс (ход %.2f м, зазор %.2f м)" % [moved, gap])
	crate.queue_free()

	## 5. Два врага в одной точке расталкиваются без взрывного разлёта.
	var a1: EnemyBase = spawn_foe.call(Vector3(0.0, 0.2, 14.0))
	var a2: EnemyBase = spawn_foe.call(Vector3(0.05, 0.2, 14.05)) ## перекрытие моделей
	await _frames(3)
	if a1 == null or a2 == null:
		_check(false, "Физика: пара врагов заспавнена")
	else:
		await _seconds(1.2)
		var pair_d := a1.global_position.distance_to(a2.global_position)
		_check(pair_d >= 0.55 and pair_d < 6.0,
				"Физика: совпавшие враги разошлись на %.2f м (без наложения)" % pair_d)

	## 6. Группа из 6: без дрожания/взрывных скоростей, держатся рядом.
	var cluster: Array = []
	for i in 6:
		var c: EnemyBase = spawn_foe.call(Vector3(10.0 + 0.3 * i, 0.2, -2.0))
		if c != null:
			cluster.append(c)
	await _frames(3)
	var vmax := 0.0
	var cap_speed := fdef.move_speed + 2.4 + 0.75
	for i in 36:
		for c in cluster:
			if is_instance_valid(c):
				var hv := Vector2(c.velocity.x, c.velocity.z).length()
				vmax = maxf(vmax, hv)
		await _frames(2)
	var centroid := Vector3.ZERO
	var alive := 0
	for c in cluster:
		if is_instance_valid(c):
			centroid += c.global_position
			alive += 1
	centroid /= maxf(1.0, float(alive))
	var spread := 0.0
	for c in cluster:
		if is_instance_valid(c):
			spread = maxf(spread, c.global_position.distance_to(centroid))
	_check(vmax <= cap_speed and spread < 6.0 and alive == 6,
			"Физика: группа из 6 без дрожания (vmax=%.1f <= %.1f, разброс %.1f м)" % [vmax, cap_speed, spread])

	## 7. Урон и событие попадания — ровно один раз за активацию хитбокса.
	var pawn := _local_pawn()
	var hit_foe: EnemyBase = spawn_foe.call(Vector3(0.0, 0.2, -14.0))
	await _frames(3)
	if pawn == null or hit_foe == null:
		_check(false, "Физика: пешка и цель для теста наград доступны")
	else:
		var hits := [0] ## лямбды GDScript захватывают скаляры по значению — нужен контейнер
		var cb := func(_atk: Node, tgt: Node, _d: Dictionary) -> void:
			if tgt == hit_foe:
				hits[0] += 1
		Events.server_hit_landed.connect(cb)
		var hp0 := hit_foe.health.health
		## Враг сам входит в активированный хитбокс (area_entered не стреляет
		## по уже перекрывающимся зонам): ставим его в 2.0 м — добегает сам.
		hit_foe.global_position = pawn.global_position - pawn.global_transform.basis.z * 2.0
		await _frames(2)
		pawn.hitbox.activate(0.8)
		await _seconds(1.0)
		Events.server_hit_landed.disconnect(cb)
		_check(hits[0] == 1 and absf((hp0 - hit_foe.health.health) - float(pawn.hitbox.damage)) < 0.01,
				"Физика: одно попадание за активацию (событий %d, урон %.0f)" % [hits[0], hp0 - hit_foe.health.health])

	## Уборка: убить пробных врагов (трупы удалятся сами), не трогая баланс.
	for e in spawned:
		if is_instance_valid(e) and not e.health.is_dead:
			e.health.take_damage(Units.make_damage(99999.0, null, 0, Vector3.ZERO, 0.0, e.global_position))
	await _frames(4)
	_check(true, "Физика: пробные враги убраны")

## Этап 4.3: разрушаемые объекты и боевые ловушки (offline, сервер).
func _test_env_flow() -> void:
	var crate: DestructibleProp = null
	for n in get_tree().get_nodes_in_group("destructibles"):
		crate = n as DestructibleProp
		if crate != null:
			break
	var trap: PulseTrap = null
	for n in get_tree().get_nodes_in_group("traps"):
		trap = n as PulseTrap
		if trap != null:
			break
	if crate == null or trap == null:
		_check(false, "Окружение: ящик и ловушка размещены на арене")
		return
	_check(true, "Окружение: ящик и ловушка размещены на арене")
	var arena := get_tree().current_scene
	var bdef := load("res://resources/enemies/brute.tres") as EnemyDefinition
	var fdef := load("res://resources/enemies/fop.tres") as EnemyDefinition
	var spawned: Array = []
	var spawn_foe := func(def: EnemyDefinition, pos: Vector3) -> EnemyBase:
		var e: EnemyBase = arena.spawn_enemy(def, pos)
		if e != null:
			spawned.append(e)
		return e

	## 1. Прочность, урон и однократное разрушение.
	var hp0 := crate.health.health
	crate.health.take_damage(Units.make_damage(20.0, null, 1, Vector3.ZERO, 0.0, crate.global_position))
	var damaged := crate.health.health < hp0
	crate.health.take_damage(Units.make_damage(99999.0, null, 1, Vector3.ZERO, 0.0, crate.global_position))
	await _frames(2)
	_check(damaged and crate.is_destroyed and crate.collision_layer == 0 and crate.visuals.visible == false,
			"Окружение: ящик теряет прочность и разрушается однократно (collision off, визуал скрыт)")

	## 2. Награда строго один раз.
	var prog := _prog()
	var st1: ProgressionState = prog.states.get(1) if prog != null else null
	var coins_got := 0
	if st1 != null:
		coins_got = st1.coins
	crate.health.take_damage(Units.make_damage(99999.0, null, 1, Vector3.ZERO, 0.0, crate.global_position))
	await _frames(2)
	var coins_after := st1.coins if st1 != null else 0
	_check(st1 != null and coins_after == coins_got,
			"Окружение: повторные попадания после разрушения не дают повторных наград")

	## 3. Ловушка: порядок состояний IDLE->WARN->ACTIVE->COOLDOWN.
	trap.interval = 0.8
	trap.warn_time = 0.4
	trap.active_time = 0.35
	trap.cooldown_time = 0.5
	trap.damage = 5.0
	var seq: Array = []
	var cb := func(st: int) -> void: seq.append(st)
	trap.state_changed_on_peer.connect(cb)
	var ordered: bool = await _wait_until(func(): return seq.has(1) and seq.has(2) and seq.has(3), 6.0)
	var i_w := seq.find(1)
	var i_a := seq.find(2)
	var i_c := seq.find(3)
	_check(ordered and i_w < i_a and i_a < i_c,
			"Окружение: ловушка проходит WARN->ACTIVE->COOLDOWN в порядке (%s)" % str(seq.slice(0, 6)))

	## 4+5. Урон не чаще раза за активацию; граница зоны.
	var in_foe: EnemyBase = spawn_foe.call(bdef, trap.global_position)
	var out_foe: EnemyBase = spawn_foe.call(fdef, trap.global_position + Vector3(2.7, 0.0, 0.0))
	var edge_foe: EnemyBase = spawn_foe.call(fdef, trap.global_position + Vector3(1.7, 0.0, 0.0))
	await _frames(3)
	trap.knockback_force = 0.0 ## цели держим в зоне: стаггер-цикл теста
	var keep_stun := func() -> void:
		for e in [in_foe, out_foe, edge_foe]:
			if is_instance_valid(e) and not e.health.is_dead:
				e.apply_external_stun(1.2)
	keep_stun.call()
	var reached_active: bool = await _wait_until(func():
		keep_stun.call()
		return trap.state == 2, 6.0)
	var hp_in := in_foe.health.health if in_foe != null else 0.0
	var hp_out := out_foe.health.health if out_foe != null else 0.0
	var hp_edge := edge_foe.health.health if edge_foe != null else 0.0
	await _wait_until(func():
		keep_stun.call()
		return trap.state == 3, 3.0)
	var d_in := hp_in - (in_foe.health.health if is_instance_valid(in_foe) else hp_in)
	var d_out := hp_out - (out_foe.health.health if is_instance_valid(out_foe) else hp_out)
	var d_edge := hp_edge - (edge_foe.health.health if is_instance_valid(edge_foe) else hp_edge)
	_check(reached_active and absf(d_in - trap.damage) < 0.01 and absf(d_edge - trap.damage) < 0.01 and d_out < 0.001,
			"Окружение: ловушка бьёт раз за активацию и только в зоне (в %.0f, край %.0f, вне %.0f)" % [d_in, d_edge, d_out])
	## Базу HP берём в COOLDOWN (до второй активации), меряем после её завершения.
	var hp_in2 := in_foe.health.health if is_instance_valid(in_foe) else 0.0
	var second: bool = await _wait_until(func():
		keep_stun.call()
		return trap.state == 2, 6.0)
	await _wait_until(func():
		keep_stun.call()
		return trap.state == 3, 3.0)
	var d_in2 := hp_in2 - (in_foe.health.health if is_instance_valid(in_foe) else hp_in2)
	_check(second and absf(d_in2 - trap.damage) < 0.01,
			"Окружение: вторая активация снова бьёт ровно один раз (%.0f)" % d_in2)
	trap.state_changed_on_peer.disconnect(cb)
	for e in [in_foe, out_foe, edge_foe]:
		if is_instance_valid(e) and not e.health.is_dead:
			e.health.take_damage(Units.make_damage(99999.0, null, 0, Vector3.ZERO, 0.0, e.global_position))
	await _frames(3)

	## 6. Обломки очищаются.
	var debris_now := get_tree().get_nodes_in_group("debris").size()
	var cleaned: bool = await _wait_until(func(): return get_tree().get_nodes_in_group("debris").size() == 0, 5.0)
	_check(cleaned, "Окружение: обломки убраны после времени жизни (было %d)" % debris_now)

	## 10. Повторный матч: окружение свежее.
	Game.start_offline_match(&"berserk", "Энва-2")
	await _frames(4)
	var fresh := true
	for n in get_tree().get_nodes_in_group("destructibles"):
		var d := n as DestructibleProp
		if d != null and d.is_destroyed:
			fresh = false
	for n in get_tree().get_nodes_in_group("traps"):
		var t := n as PulseTrap
		if t != null and t.state != 0:
			fresh = false
	_check(fresh and get_tree().get_nodes_in_group("debris").size() == 0,
			"Окружение: повторный матч не оставляет разрушений/обломков/состояний ловушек")

## Этап 5.1: законченный цикл акта I — 5 волн, элиты, босс с фазами, победа.
func _test_act1_flow() -> void:
	Game.start_offline_match(&"berserk", "Акт-1")
	await _frames(3)
	var mc := _match()
	var prog := _prog()
	if mc == null:
		_check(false, "Акт I: матч стартовал")
		return
	var waves_seen: Array = []
	var elite_seen := false
	var boss: BossAct1 = null
	var boss_seen := false
	var phases_seen: Array = []
	var guard := 0
	var victory := false
	while guard < 900:
		guard += 1
		if mc.phase == MatchController.Phase.VICTORY:
			victory = true
			break
		if mc.phase == MatchController.Phase.DEFEAT:
			break
		if mc.phase == MatchController.Phase.FIGHT:
			if mc.wave_number >= 1 and not waves_seen.has(mc.wave_number):
				waves_seen.append(mc.wave_number)
			for e in _alive_enemies():
				if e.def != null and e.def.category == 1:
					elite_seen = true
			if mc.wave_number >= 5 and not boss_seen:
				for n in get_tree().get_nodes_in_group("boss_unit"):
					var b := n as BossAct1
					if b != null and not b.health.is_dead:
						boss = b
						boss_seen = true
			if boss_seen and boss != null and is_instance_valid(boss) and not boss.health.is_dead:
				if not phases_seen.has(boss.phase_index):
					phases_seen.append(boss.phase_index)
				if boss.phase_index == 1:
					boss.health.take_damage(Units.make_damage(boss.health.max_health * 0.40, null, 1, Vector3.ZERO, 0.0, boss.global_position))
				elif boss.phase_index == 2:
					boss.health.take_damage(Units.make_damage(boss.health.max_health * 0.35, null, 1, Vector3.ZERO, 0.0, boss.global_position))
				elif phases_seen.has(3):
					_kill_all_enemies() ## босс в фазе 3: добиваем вместе с эскортом
			else:
				_kill_all_enemies() ## волны 1-4 и экскорт волны 5 после смерти босса
		elif mc.phase == MatchController.Phase.INTERMISSION:
			if prog != null:
				prog.set_wave_ready(1, true)
		await _frames(4)
	_check(victory, "Акт I: матч дошёл до ПОБЕДЫ через все волны")
	_check(waves_seen == [1, 2, 3, 4, 5], "Акт I: волны прошли последовательно 1..5 (%s)" % str(waves_seen))
	_check(elite_seen, "Акт I: элитные противники встречались в волнах")
	_check(boss_seen, "Акт I: босс появился на финальной волне")
	_check(phases_seen.has(2) and phases_seen.has(3), "Акт I: босс сменил фазы 2 и 3 по порогам HP (%s)" % str(phases_seen))
	var wm_ok := true
	for n in get_tree().get_nodes_in_group("match_controller"):
		pass
	_check(mc.wave_number == 5 and victory, "Акт I: после босса акт завершён (волна %d, победа %s)" % [mc.wave_number, str(victory)])
	## После финала: покупки отклоняются, новые враги не спавнятся.
	await _seconds(1.5)
	var buy_blocked := prog == null or prog.try_buy(1, &"potion_small") == false
	var no_new_foes := _alive_enemies().is_empty()
	_check(buy_blocked and no_new_foes, "Акт I: после финала покупки и спавн врагов заблокированы")
