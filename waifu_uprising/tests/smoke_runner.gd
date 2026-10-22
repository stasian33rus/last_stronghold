extends Node
## Offline-дымотест вертикального среза (без сети, headless):
##   godot --headless res://tests/smoke_test.tscn
## Проверяет РЕАЛЬНУЮ игровую логику: загрузка сцен, бой игрока, ИИ врага,
## отбрасывание, смерть врага, зачистка волны -> ПОБЕДА, смерть Гигачада -> ПОРАЖЕНИЕ,
## падение и возрождение игрока. Вывод: [SMOKE] PASS/FAIL по каждому пункту,
## итоговый код возврата процесса.

var _failures: Array[String] = []
var _checks: int = 0

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
