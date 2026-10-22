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
		var foe := candidate as EnemyFop
		if foe != null and not foe.health.is_dead:
			result.append(foe)
	return result

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
	_check(wave2 != null and wave2.groups.size() >= 1 and wave2.total_count(2) == 4,
		"WaveDefinition groups: волна 2 (2 игрока) = %d" % (wave2.total_count(2) if wave2 != null else -1))
	_check(Content.all_upgrades().size() >= 12, "Реестр улучшений: >=12 (%d)" % Content.all_upgrades().size())
	_check(Content.all_shop_items().size() >= 5, "Реестр магазина: >=5 (%d)" % Content.all_shop_items().size())
	var bal := load(Game.BALANCE_DEFAULT) as ProgressionBalance
	_check(bal != null and bal.xp_required(1) == 100 and bal.xp_required(3) == 200,
		"Баланс прогрессии: формула 100+50×(L−1)")
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
	var spawned: bool = await _wait_until(func(): return not _alive_enemies().is_empty(), 15.0)
	_check(spawned, "Волна 1 заспавнила врагов (alive=%d)" % _alive_enemies().size())
	if not spawned:
		return

	## --- Настоящий бой: удар игрока наносит урон и отбрасывает врага.
	var pawn := _local_pawn()
	var enemies := _alive_enemies()
	var foe: EnemyFop = enemies[0]
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
	for wave_idx in range(2, 5):
		var has_enemies: bool = await _wait_until(func(): return not _alive_enemies().is_empty(), 12.0)
		if not has_enemies:
			_check(false, "Волна %d: враги появились" % wave_idx)
			break
		var cleared: bool = await _wait_until(func():
			_kill_all_enemies()
			return mc.phase != MatchController.Phase.FIGHT, 12.0)
		_check(cleared, "Волна %d: все враги уничтожены (включая допавшихся)" % wave_idx)
		if wave_idx < 4:
			var inter_n: bool = await _wait_until(func(): return mc.phase == MatchController.Phase.INTERMISSION, 10.0)
			_check(inter_n, "Волна %d зачищена -> интермиссия" % wave_idx)
			if wave_idx == 3:
				## Лимит за интермиссию: 3 малых лечения, 4-е отклоняется.
				sys.add_coins(1, 200, "тест")
				var b1 := sys.try_buy(1, &"potion_small")
				var b2 := sys.try_buy(1, &"potion_small")
				var b3 := sys.try_buy(1, &"potion_small")
				var b4 := sys.try_buy(1, &"potion_small")
				_check(b1 and b2 and b3 and not b4, "Лимит за интермиссию: 3 лечения ок, 4-е отклонено")
			sys.set_wave_ready(1, true)
			var fight_n: bool = await _wait_until(func(): return mc.phase == MatchController.Phase.FIGHT and wm.current_wave == wave_idx + 1, 12.0)
			_check(fight_n, "Волна %d началась после ready" % (wave_idx + 1))
		else:
			var vic: bool = await _wait_until(func(): return mc.phase == MatchController.Phase.VICTORY, 6.0)
			_check(vic, "ПОБЕДА после финальной волны 4")

	_check(_waves_started_log == [1, 2, 3, 4], "Каждая волна стартовала ровно один раз: %s" % str(_waves_started_log))
	var stats: Dictionary = mc.stats
	_check(stats.has(1) and int(stats[1]["kills"]) >= 10, "Статистика убийств посчитана сервером (kills=%d)" % int(stats[1]["kills"]))

	await _test_progression()

	## --- Нет неограниченного роста объектов: после боя/прогрессии/UI-очистки.
	await _seconds(4.0)
	var obj_after := int(Performance.get_monitor(Performance.OBJECT_COUNT))
	_obj_after_match1 = obj_after
	var diag := ""
	## Предел +150: разовое построение UI матча (строки магазина ~40 узлов, карточки,
	## строки игроков) — легитимный одноразовый рост. Настоящая проверка утечек —
	## кросс-матчевое сравнение в конце _test_defeat_and_down_flow (объекты не должны
	## накапливаться от матча к матчу).
	if obj_after > _obj_baseline + 150:
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
	_check(obj_after <= _obj_baseline + 150,
		"Объекты в матче: разовый рост в пределах UI (%d до волны -> %d после, предел +%d)%s" % [_obj_baseline, obj_after, 150, diag])

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
	var pawn := _local_pawn()
	if pawn != null:
		var hp_max_before := pawn.health.max_health
		st.upgrade_levels[&"iron_body"] = int(st.upgrade_levels.get(&"iron_body", 0)) + 2
		sys._refresh_pawn(998, p2) ## у peer 998 пешки нет — не падать
		sys._refresh_pawn(1, st)
		_check(pawn.health.max_health > hp_max_before * 1.25,
			"iron_body ×2 реально повысил макс. HP (%.0f -> %.0f)" % [hp_max_before, pawn.health.max_health])

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
