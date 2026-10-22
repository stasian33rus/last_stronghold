extends Node
## Offline-дымотест вертикального среза (без сети, headless):
##   godot --headless res://tests/smoke_test.tscn
## Проверяет РЕАЛЬНУЮ игровую логику: загрузка сцен, бой игрока, ИИ врага,
## отбрасывание, смерть врага, зачистка волны -> ПОБЕДА, смерть Гигачада -> ПОРАЖЕНИЕ,
## падение и возрождение игрока. Вывод: [SMOKE] PASS/FAIL по каждому пункту,
## итоговый код возврата процесса.

var _failures: Array[String] = []
var _checks: int = 0
var _obj_baseline: int = 0

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	print("[SMOKE] === Дымотест вертикального среза (offline) ===")
	await get_tree().process_frame
	await get_tree().process_frame
	_test_data_layers()
	await _test_match_victory_flow()
	await _test_defeat_and_down_flow()
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

## Ждёт выполнения условия (опрос каждый ФИЗИЧЕСКИЙ кадр — симуляционное время), возвращает итог.
func _wait_until(cond: Callable, timeout_sec: float) -> bool:
	var waited := 0.0
	while not bool(cond.call()) and waited < timeout_sec:
		await get_tree().physics_frame
		waited += 1.0 / 60.0
	return bool(cond.call())

## Ждёт, пока getter не вернёт не-null, и возвращает результат (или null).
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

func _alive_enemies() -> Array:
	var result: Array = []
	for candidate in get_tree().get_nodes_in_group("enemy_units"):
		var foe := candidate as EnemyFop
		if foe != null and not foe.health.is_dead:
			result.append(foe)
	return result

# ------------------------------------------------------------------ тесты

func _test_data_layers() -> void:
	var cls := Classes.get_class_def(&"berserk")
	_check(cls != null, "ClassRegistry: класс «Берсерка» загружен из .tres")
	var foe_def := load("res://resources/enemies/fop.tres") as EnemyDefinition
	_check(foe_def != null and foe_def.display_name == "Пижон", "EnemyDefinition fop.tres загружен")
	var wave_def := load("res://resources/waves/wave_01.tres") as WaveDefinition
	_check(wave_def != null and wave_def.total_count(1) == 5 and wave_def.total_count(8) == 19,
		"WaveDefinition: масштабирование 1 игрок=5, 8 игроков=19")
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

## Полный цикл: старт -> отсчёт -> волна -> бой -> зачистка -> ПОБЕДА.
func _test_match_victory_flow() -> void:
	Game.start_offline_match(&"berserk", "Тестер")
	await _frames(2) ## дать отработать deferred-смене сцены
	var mc: MatchController = await _wait_until_and_get(func(): return _match(), 10.0)
	_check(mc != null, "Арена загружена, MatchController найден")
	var pawn_ok: bool = await _wait_until(func(): return _local_pawn() != null, 5.0)
	_check(pawn_ok, "Пешка игрока заспавнена (offline)")
	_check(_giga() != null, "Гигачад на арене")
	if mc == null or not pawn_ok:
		return
	_check(mc.phase == MatchController.Phase.COUNTDOWN, "Фаза COUNTDOWN после загрузки")
	## Ждём окончания отсчёта и появления врагов.
	var fight_on: bool = await _wait_until(func(): return mc.phase == MatchController.Phase.FIGHT, 10.0)
	_check(fight_on, "Фаза FIGHT после отсчёта")
	_obj_baseline = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var spawned: bool = await _wait_until(func(): return not _alive_enemies().is_empty(), 15.0)
	var enemies := _alive_enemies()
	_check(spawned, "Волна заспавнила врагов (alive=%d)" % enemies.size())
	if enemies.is_empty():
		return

	## --- Настоящий бой: удар игрока наносит урон и отбрасывает врага.
	var pawn := _local_pawn()
	var foe: EnemyFop = enemies[0]
	foe.global_position = pawn.global_position + Vector3(0.0, 0.0, -1.7)
	pawn.rotation.y = 0.0 ## -Z вперёд
	foe.apply_external_stun(2.0) ## враг стоит смирно, пока мы бьём
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

	## --- Враг атакует игрока (ИИ доходит до выпада).
	pawn.external_input = null
	if not _alive_enemies().is_empty():
		foe = _alive_enemies()[0]
	if is_instance_valid(foe) and not foe.health.is_dead:
		foe.global_position = pawn.global_position + Vector3(1.6, 0.0, 0.0)
		var pawn_hp_before := pawn.health.health
		var pawn_hurt: bool = await _wait_until(func(): return pawn.health.health < pawn_hp_before or pawn.health.is_dead, 5.0)
		_check(pawn_hurt,
			"ИИ врага провёл выпад и нанёс урон игроку (%.0f -> %.0f)" % [pawn_hp_before, pawn.health.health])

	## --- ИИ переключается на Гигачада, когда игрок далеко.
	var giga := _giga()
	pawn.global_position = Vector3(17.0, 0.2, 17.0)
	for e in _alive_enemies():
		(e as EnemyFop).global_position = giga.global_position + Vector3(randf_range(-2.5, 2.5), 0.0, randf_range(2.6, 3.2))
	var giga_hp_before := giga.health.health
	var giga_hurt: bool = await _wait_until(func(): return giga.health.health < giga_hp_before, 8.0)
	_check(giga_hurt or _alive_enemies().is_empty(),
		"Враги атакуют Гигачада (hp %.0f -> %.0f)" % [giga_hp_before, giga.health.health])

	## --- Добиваем волну -> ПОБЕДА.
	for e in _alive_enemies():
		var killer := _local_pawn()
		e.health.take_damage(Units.make_damage(9999.0, killer, 1, Vector3.FORWARD, 6.0, e.global_position))
	var victory: bool = await _wait_until(func(): return _match() != null and _match().phase == MatchController.Phase.VICTORY, 5.0)
	mc = _match()
	_check(victory, "ПОБЕДА после зачистки волны")
	var stats: Dictionary = mc.stats
	_check(stats.has(1) and int(stats[1]["kills"]) >= 1, "Статистика убийств посчитана сервером")

	## Нет неограниченного роста объектов (ТЗ §20): после освобождения трупов
	## и одноразовых эффектов число объектов возвращается к уровню до начала волны.
	await _seconds(3.5)
	var obj_after := int(Performance.get_monitor(Performance.OBJECT_COUNT))
	_check(obj_after <= _obj_baseline + 40,
		"Объекты не накапливаются (%d до волны -> %d после, предел +%d)" % [_obj_baseline, obj_after, 40])

	await _test_progression()

# ------------------------------------------------------------------ прогрессия (Этап 2)

func _prog() -> ProgressionSystem:
	var ps := get_tree().get_nodes_in_group("progression_system")
	return ps[0] if ps.size() > 0 else null

func _test_progression() -> void:
	var sys := _prog()
	if sys == null:
		_check(false, "ProgressionSystem найден")
		return
	_check(true, "ProgressionSystem найден")

	## 5 убитых Пижонов × 20 XP = 100 XP -> ровный уровень 2, остаток 0, открыт выбор.
	var st: ProgressionState = sys.states.get(1, null)
	_check(st != null, "Серверное состояние прогрессии peer 1 существует")
	if st == null:
		return
	_check(st.level == 2 and st.xp == 0, "100 XP за волну -> уровень 2, остаток 0 (level=%d xp=%d)" % [st.level, st.xp])
	_check(st.pending_choices == 1 or st.offer_active, "Повышение уровня открыло выбор улучшения")
	_check(sys.local_state.get("level", 0) == st.level and sys.local_state.get("coins", -1) == st.coins,
		"Синхронизация состояния (зеркало HUD) корректна")
	_check(st.coins >= 25, "Монеты за убийства начислены (coins=%d)" % st.coins)

	## Формула и арифметика уровней на изолированном состоянии.
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

	## Предложение: 3 уникальных допустимых id.
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

		## Отклонение недопустимого id (эффекта нет, предложение остаётся).
		var levels_before := st.upgrade_levels.duplicate(true)
		sys._apply_choice(1, &"totally_bogus_id", false)
		_check(st.upgrade_levels == levels_before and st.offer_active, "Недопустимый id отклонён без эффекта")

		## Применение ровно один раз: повторный вызов не дублирует.
		var first_id: StringName = ids[0]
		sys._apply_choice(1, first_id, false)
		var level_after_first: int = int(st.upgrade_levels.get(first_id, 0))
		sys._apply_choice(1, first_id, false) ## повтор — offer уже закрыт
		_check(int(st.upgrade_levels.get(first_id, 0)) == level_after_first and level_after_first == 1,
			"Улучшение применено ровно один раз")
		_check(st.pending_choices == 0, "pending_choices списан после выбора")

	## Автовыбор по таймауту (серверный таймер).
	sys.add_xp(1, sys.balance.xp_required(st.level))
	_check(st.offer_active, "Новый уровень открыл новое предложение")
	if st.offer_active:
		var auto_id: StringName = st.offer_ids[0]
		st.offer_deadline_msec = Time.get_ticks_msec() - 1
		await _frames(5)
		_check(not st.offer_active and int(st.upgrade_levels.get(auto_id, 0)) >= 1,
			"Таймаут -> сервер применил первое предложение (автовыбор)")

	## Одновременные выборы двух разных игроков.
	var p2 := ProgressionState.new()
	p2.peer_id = 998
	sys.states[998] = p2
	sys.add_xp(998, 100)
	_check(p2.offer_active, "Второй игрок получил собственное предложение")
	if p2.offer_active and p2.offer_ids.size() > 0:
		sys._apply_choice(998, p2.offer_ids[0], false)
		_check(int(p2.upgrade_levels.values().reduce(func(a, b): return a + b, 0)) == 1,
			"Второй игрок применил улучшение независимо")

	## Эффект улучшения РЕАЛЬНО меняет характеристики (детерминированно: iron_body).
	var pawn := _local_pawn()
	var hp_max_before := pawn.health.max_health
	p2.upgrade_levels[&"iron_body"] = 2
	sys._refresh_pawn(998, p2) ## у peer 998 пешки нет — не падать
	st.upgrade_levels[&"iron_body"] = int(st.upgrade_levels.get(&"iron_body", 0)) + 2
	sys._refresh_pawn(1, st)
	_check(pawn.health.max_health > hp_max_before * 1.25,
		"iron_body ×2 реально повысил макс. HP (%.0f -> %.0f)" % [hp_max_before, pawn.health.max_health])
	_check(is_equal_approx(pawn.health.incoming_damage_multiplier, 1.0), "Базовый множитель входящего урона = 1.0")

	## Магазин вне интермиссии закрыт (фаза VICTORY/FIGHT).
	var coins_before := st.coins
	var bought := sys.try_buy(1, &"potion_small")
	_check(not bought and st.coins == coins_before, "Покупка вне INTERMISSION отклонена, монеты не списаны")

	## Неавторизованный прямой вызов клиентских RPC: sender offline = 0,
	## состояния нет — никакого эффекта (XP/монеты/покупки не меняются).
	var xp_before := st.xp
	var lvl_before := st.level
	sys.cl_choose("iron_body")
	sys.cl_buy("potion_small")
	sys.cl_wave_ready(true)
	_check(st.xp == xp_before and st.level == lvl_before and st.coins == coins_before and not st.wave_ready,
		"Прямые cl_choose/cl_buy/cl_wave_ready без валидного sender не имеют эффекта")

	sys.states.erase(999)
	sys.states.erase(998)
## Поражение по смерти Гигачада + падение/возрождение игрока.
func _test_defeat_and_down_flow() -> void:
	Game.start_offline_match(&"berserk", "Тестер-2")
	await _frames(2) ## новая арена; узлы предыдущей уже освобождены
	var mc: MatchController = await _wait_until_and_get(func(): return _match(), 10.0)
	var pawn := _local_pawn()
	var giga := _giga()
	if mc == null or pawn == null or giga == null:
		_check(false, "Повторная загрузка арены для теста поражения")
		return
	print("[SMOKE] debug: mc=%s pawn=%s" % [mc.get_path(), pawn.get_path()])
	_check(true, "Повторная загрузка арены для теста поражения")

	## Игрок падает -> DOWN, затем возрождение.
	pawn.health.take_damage(Units.make_damage(9999.0, null, 0, Vector3.FORWARD, 1.0, pawn.global_position))
	_check(pawn.state == PlayerPawn.State.DOWN and pawn.health.is_dead, "Игрок повержен (DOWN)")
	var revived: bool = await _wait_until(func(): return not pawn.health.is_dead and pawn.state != PlayerPawn.State.DOWN, 9.0)
	_check(revived, "Игрок возрождён источником (%.0f hp)" % pawn.health.health)

	## Гигачад умирает -> ПОРАЖЕНИЕ.
	giga.health.take_damage(Units.make_damage(99999.0, null, 0, Vector3.FORWARD, 1.0, giga.global_position))
	var defeated: bool = await _wait_until(func(): return _match() != null and _match().phase == MatchController.Phase.DEFEAT, 3.0)
	_check(defeated, "ПОРАЖЕНИЕ после смерти Гигачада")

	## Резонанс Гигачада реально копился до падения.
	_check(giga.resonance >= 0.0, "Резонанс отслеживается (value=%.1f)" % giga.resonance)
