extends Node
## Интеграционный сетевой тест вертикального среза (запускается headless, ТЗ §20).
##
## Хост:   godot --headless -- +autotest=host +port=24560
## Клиент: godot --headless -- +autotest=client +ip=127.0.0.1 +port=24560
##
## Сценарий: реальное ENet-подключение -> лобби -> ready -> старт матча ->
## обе стороны управляют пешками (виртуальный ввод) -> бой с волной ->
## проверка победы и сетевой синхронизации. Результат: строка [AUTOTEST] RESULT=PASS/FAIL
## и код возврата процесса.

const CONNECT_TIMEOUT := 20.0
const LOBBY_TIMEOUT := 40.0
const MATCH_TIMEOUT := 170.0
const ATTACK_RANGE := 2.5
const ATTACK_PERIOD := 0.7

var mode: String = ""
var _phase: String = "connect"
var _phase_t: float = 0.0
var _attack_cd: float = 0.0
var _pawn: PlayerPawn
var _seen_enemy_motion := false
var _enemy_ref: Node3D
var _enemy_ref_pos := Vector3.ZERO
## Этап 4.2:_guard репликации врагов — без телепортов между кадрами клиента.
var _esm_prev := Vector3.ZERO
var _esm_init := false
var _enemies_seen := 0
var _match_done := false
var _finished := false
var _pawn_diag_printed := false
var _bot_probe_pos := Vector3.ZERO
var _bot_probe_t := 0.0
var _bot_strafe_t := 0.0
var _bot_strafe_sign := 1.0
var _sys: ProgressionSystem
var _mc: MatchController
var _offer_choice: StringName = &""
var _offer_delay := 0.0
var _intermission_served := false
var _rematch_done := false
var _matches_won := 0
## Эволюция (+evolve=1): хост форсирует уровень и проверяет форму у себя,
## клиент обязан увидеть форму ЧУЖОЙ пешки через репликацию BodySync ("f").
var _evo_injected := false
var _evo_local_form := -1
var _evo_remote_form := -1
## Спасение (+rescue=1): сервер роняет СВОЮ пешку, клиент спасает её реальным
## RPC sv_rescue_hold; проверяется репликация DOWN/прогресса/возрождения и
## очистка канала при отключении спасателя.
var _rsc_step := 0
var _rsc_t := 0.0
var _rsc_holding := false
var _rsc_hold_sent := false
var _rsc_reedge_done := false
## Ловушки/разрушения (+trap=1): синхронность состояний между пирами.
var _trap_conn := false
var _trap_seq: Array = []
var _tr_step := 0
var _act1_boss_seen := false
var _act1_phase_sync := false
var _tr_t := 0.0
var _rsc_progress_seen := false
var _rsc_revived_hp := -1.0

func _ready() -> void:
	mode = Game.autotest_mode
	Game.autotest_started = true
	Events.match_ended.connect(_on_match_ended)
	Events.upgrade_offer_opened.connect(_on_offer_opened)
	Events.unit_evolved.connect(_on_unit_evolved)
	Net.connection_failed.connect(func(reason: String) -> void: _finish(false, "connection failed: %s" % reason))
	match mode:
		"host":
			var err := Net.create_game(Game.autotest_port)
			if err != OK:
				_finish(false, "host: create_game failed %d" % err)
		"client":
			var err := Net.join_game(Game.autotest_ip, Game.autotest_port)
			if err != OK:
				_finish(false, "client: join_game failed %d" % err)
		_:
			_finish(false, "unknown autotest mode: %s" % mode)
	print("[AUTOTEST] старт: mode=%s port=%d" % [mode, Game.autotest_port])

func _physics_process(delta: float) -> void:
	if _match_done:
		return
	_phase_t += delta
	var limit := CONNECT_TIMEOUT if _phase == "connect" else (LOBBY_TIMEOUT if _phase == "lobby" else MATCH_TIMEOUT)
	if _phase_t > limit:
		_finish(false, "timeout in phase %s" % _phase)
		return
	match _phase:
		"connect":
			if Net.net_state == Net.NetState.IN_LOBBY:
				if mode == "client":
					## Evolve-тест: клиент играет Валькирией — проверка репликации
					## эволюции ВТОРОГО класса (у хоста — Берсерка).
					Net.set_local_class(&"valkyrie" if Game.autotest_evolve else Classes.get_default_id())
					Net.set_local_ready(true)
				_set_phase("lobby")
		"lobby":
			if mode == "host":
				if Net.get_player_count() >= 2 and Net.all_clients_ready():
					print("[AUTOTEST] host: все готовы — старт матча")
					Net.start_match(Game.ARENA_SCENE)
					_set_phase("match")
			else:
				if Net.net_state == Net.NetState.IN_MATCH:
					_set_phase("match")
		"match":
			_drive_pawn(delta)
			_handle_progression(delta)
			_handle_rescue_test(delta)
			_handle_trap_test(delta)
			_observe_act1()
			_check_sync()

func _set_phase(p: String) -> void:
	_phase = p
	_phase_t = 0.0

## Боты используют progression/shop RPC: автовыбор улучшения, покупка, ready.
func _handle_progression(delta: float) -> void:
	if _sys == null or not is_instance_valid(_sys):
		var ps := get_tree().get_nodes_in_group("progression_system")
		_sys = ps[0] if ps.size() > 0 else null
	if _mc == null or not is_instance_valid(_mc):
		var mcs := get_tree().get_nodes_in_group("match_controller")
		_mc = mcs[0] if mcs.size() > 0 else null
	if _sys == null or _mc == null:
		return
	if _offer_delay > 0.0:
		_offer_delay -= delta
		if _offer_delay <= 0.0 and _offer_choice != &"":
			var pick := _offer_choice
			_offer_choice = &""
			_sys.request_choose(pick)
	_inject_evolution_xp()
	if _mc.phase == MatchController.Phase.INTERMISSION:
		if not _intermission_served:
			_intermission_served = true
			## Покупка (сервер отклонит, если не хватает монет — это тоже валидный путь)
			_sys.request_buy(&"potion_small")
			_sys.request_wave_ready(true)
	elif _mc.phase == MatchController.Phase.FIGHT:
		_intermission_served = false

func _on_unit_evolved(unit: Node, fidx: int, fname: String) -> void:
	var is_local := _pawn != null and unit == _pawn
	if is_local:
		_evo_local_form = fidx
		print("[AUTOTEST] EVOLUTION local: форма %d «%s» (peer %d)" % [fidx + 1, fname, Net.my_id()])
	else:
		_evo_remote_form = fidx
		print("[AUTOTEST] EVOLUTION remote: увидели форму %d «%s» чужой пешки (репликация)" % [fidx + 1, fname])

## Инъекция XP хостом (серверная операция): детерминированно доводит уровень до
## порога эволюции (3) — клиент обязан получить форму через снапшоты BodySync.
func _inject_evolution_xp() -> void:
	if _evo_injected or mode != "host" or not Game.autotest_evolve:
		return
	if _sys == null or not is_instance_valid(_sys) or _mc == null or not is_instance_valid(_mc):
		return
	if _mc.phase != MatchController.Phase.FIGHT:
		return
	_evo_injected = true
	print("[AUTOTEST] evolve-тест: хост инжектирует XP всем пирам до уровня 3+ (серверный триггер эволюции)")
	for peer_id in _sys.states.keys():
		_sys.add_xp(int(peer_id), 400)

func _on_offer_opened(ids: Array, _deadline_msec: int) -> void:
	if ids.size() > 0:
		_offer_choice = ids[0]
		_offer_delay = 0.5

func _find_pawn() -> void:
	for candidate in get_tree().get_nodes_in_group("player_pawns"):
		var p := candidate as PlayerPawn
		if p != null and p.is_local_pawn():
			_pawn = p
			print("[AUTOTEST] local pawn найден: %s owner=%d my_id=%d" % [p.get_path(), p.owner_peer, Net.my_id()])
			return
	if not _pawn_diag_printed:
		_pawn_diag_printed = true
		var group := get_tree().get_nodes_in_group("player_pawns")
		var ids := []
		for g in group:
			ids.append((g as PlayerPawn).owner_peer if g is PlayerPawn else "?")
		print("[AUTOTEST] DIAG: пешка не найдена. my_id=%d group_size=%d owners=%s" % [Net.my_id(), group.size(), ids])

## Виртуальный ввод: защищаем Гигачада — целью выбираем врага, ближайшего к нему
## (а не к себе), по пути бьём любого, кто попал в радиус удара.
func _drive_pawn(delta: float) -> void:
	if _pawn == null or not is_instance_valid(_pawn):
		_find_pawn()
		return
	if Game.autotest_rescue and _rsc_holding:
		## Режим спасения: подходим к поверженному и держим interact
		## (атаки отменили бы канал); движение держит нас в радиусе.
		var mv := Vector2.ZERO
		var tgt := _remote_pawn_downed()
		if tgt != null:
			var d := tgt.global_position - _pawn.global_position
			d.y = 0.0
			if d.length() > 0.9:
				mv = Vector2(d.x, d.z).normalized()
		_pawn.external_input = {"move": mv, "aim_yaw": _pawn.aim_yaw, "hold_interact": true}
		return
	_attack_cd -= delta
	var target := _priority_enemy()
	var input := {"move": Vector2.ZERO, "aim_yaw": _pawn.aim_yaw, "press_attack": false, "press_dodge": false}
	var threat := _nearest_enemy_to(_pawn.global_position)
	if threat != null and threat.global_position.distance_to(_pawn.global_position) <= ATTACK_RANGE \
			and _attack_cd <= 0.0 and _pawn.state != PlayerPawn.State.DOWN:
		## Бей того, кто рядом, даже если основная цель дальше.
		var to_t: Vector3 = threat.global_position - _pawn.global_position
		to_t.y = 0.0
		if to_t.length() > 0.01:
			var d := to_t.normalized()
			input["aim_yaw"] = atan2(-d.x, -d.z)
		input["press_attack"] = true
		_attack_cd = ATTACK_PERIOD
	elif target != null:
		var to: Vector3 = target.global_position - _pawn.global_position
		to.y = 0.0
		var dist := to.length()
		var dir := to / dist if dist > 0.01 else Vector3.FORWARD
		input["aim_yaw"] = atan2(-dir.x, -dir.z)
		if dist > ATTACK_RANGE * 0.7:
			input["move"] = Vector2(dir.x, dir.z)
		if dist <= ATTACK_RANGE and _attack_cd <= 0.0 and _pawn.state != PlayerPawn.State.DOWN:
			input["press_attack"] = true
			_attack_cd = ATTACK_PERIOD
	else:
		## Врагов пока нет — идём к Гигачаду (не стоим в углу).
		var gigas := get_tree().get_nodes_in_group("gigachad")
		if gigas.size() > 0:
			var to_g: Vector3 = (gigas[0] as Node3D).global_position - _pawn.global_position
			to_g.y = 0.0
			if to_g.length() > 3.0:
				var dir_g := to_g.normalized()
				input["move"] = Vector2(dir_g.x, dir_g.z)
	_apply_bot_unstick(delta, input)
	_pawn.external_input = input

## Анти-застревание бота: если двигаемся, но не смещаемся — обходим вбок.
func _apply_bot_unstick(delta: float, input: Dictionary) -> void:
	_bot_probe_t -= delta
	if _bot_strafe_t > 0.0:
		_bot_strafe_t -= delta
	if _bot_probe_t <= 0.0:
		_bot_probe_t = 0.5
		var mv0: Vector2 = input["move"]
		if mv0.length() > 0.3 and _pawn.global_position.distance_to(_bot_probe_pos) < 0.4:
			_bot_strafe_t = 0.7
			_bot_strafe_sign = -_bot_strafe_sign
		_bot_probe_pos = _pawn.global_position
	if _bot_strafe_t > 0.0:
		var mv: Vector2 = input["move"]
		if mv.length() > 0.1:
			var perp := Vector2(-mv.y, mv.x).normalized() * _bot_strafe_sign
			input["move"] = (mv * 0.35 + perp * 0.95).limit_length(1.0)

## Враг, ближайший к Гигачаду (защитная тактика); если Гигачад пал — ближайший к пешке.
func _priority_enemy() -> Node3D:
	var gigas := get_tree().get_nodes_in_group("gigachad")
	var anchor := _pawn.global_position
	if gigas.size() > 0:
		var g := gigas[0] as GigaChad
		if g != null and not g.health.is_dead:
			anchor = g.global_position
	return _nearest_enemy_to(anchor)

func _nearest_enemy_to(anchor: Vector3) -> Node3D:
	var best: Node3D = null
	var best_d := 1e18
	for candidate in get_tree().get_nodes_in_group("enemy_units"):
		var foe := candidate as EnemyBase
		if foe == null or foe.health.is_dead or foe.state == EnemyBase.State.DEAD:
			continue
		var d := foe.global_position.distance_squared_to(anchor)
		if d < best_d:
			best_d = d
			best = foe
	return best

## Клиент: проверяем, что мир реально реплицируется (враги двигаются у нас).
func _check_sync() -> void:
	var enemies := get_tree().get_nodes_in_group("enemy_units")
	_enemies_seen = maxi(_enemies_seen, enemies.size())
	if mode != "client" or _seen_enemy_motion:
		return
	for candidate in enemies:
		var foe := candidate as Node3D
		if foe == null:
			continue
		if _enemy_ref == null or not is_instance_valid(_enemy_ref):
			_enemy_ref = foe
			_enemy_ref_pos = foe.global_position
			continue
		if foe == _enemy_ref and foe.global_position.distance_to(_enemy_ref_pos) > 0.4:
			_seen_enemy_motion = true
			print("[AUTOTEST] client: репликация мира подтверждена (движение врага)")
			return
	if mode == "client" and _seen_enemy_motion and _enemy_ref != null and is_instance_valid(_enemy_ref):
		## Согласованность физики (Этап 4.2): интерполяция без скачков; kb-импульсы
		## приходят снапшотами скорости, телепортов между кадрами быть не должно.
		if _esm_init and _enemy_ref.global_position.distance_to(_esm_prev) > 2.5:
			_finish(false, "enemy replication jump > 2.5 m per frame")
		_esm_prev = _enemy_ref.global_position
		_esm_init = true

func _on_match_ended(victory: bool, stats: Dictionary) -> void:
	if _match_done:
		return
	_match_done = true
	## Дамп прогрессии для отчёта: уровень/улучшения/монеты (серверные данные).
	if _sys != null and is_instance_valid(_sys):
		for peer_id in _sys.states.keys():
			var pst: ProgressionState = _sys.states[peer_id]
			print("[AUTOTEST] progression peer %d: level=%d xp=%d coins=%d upgrades=%s buffs=%d" % [
				peer_id, pst.level, pst.xp, pst.coins, str(pst.upgrade_levels), pst.buffs.size()])
		if _sys.states.is_empty() and not _sys.local_state.is_empty():
			var ls := _sys.local_state
			print("[AUTOTEST] progression local mirror: level=%s xp=%s coins=%s upgrades=%s" % [
				str(ls.get("level")), str(ls.get("xp")), str(ls.get("coins")), str(ls.get("upgrades"))])
	if not victory:
		_finish(false, "match ended in DEFEAT")
		return
	var problems: Array[String] = []
	if Net.get_player_count() < 1 and Net.is_online():
		problems.append("player_count < 1")
	if _enemies_seen < 1:
		problems.append("no enemies were spawned/seen")
	if mode == "client" and not _seen_enemy_motion:
		problems.append("world replication not observed on client")
	if stats.is_empty():
		problems.append("empty match stats")
	if _sys != null and is_instance_valid(_sys):
		for peer_id in _sys.states.keys():
			var pst: ProgressionState = _sys.states[peer_id]
			if pst.coins < 0:
				problems.append("negative coins peer %d" % peer_id)
			if pst.level < 1:
				problems.append("invalid level peer %d" % peer_id)
	if Game.autotest_evolve and _matches_won == 0:
		## Проверяется в первом матче evolve-прогона (_matches_won ещё не увеличен).
		if mode == "host":
			var host_form: int = _pawn.form_index if (_pawn != null and is_instance_valid(_pawn)) else -1
			if not _evo_injected:
				problems.append("evolve: XP injection never ran")
			if host_form < 1:
				problems.append("evolve: host pawn form=%d, expected >=1 (форма II)" % host_form)
		else:
			if _evo_local_form < 1:
				problems.append("evolve: client's own valkyrie pawn never reached form II (%d)" % _evo_local_form)
			if _evo_remote_form < 1:
				problems.append("evolve: client never saw remote form change (репликация 'f')")
	if not problems.is_empty():
		_finish(false, "; ".join(problems))
		return
	_matches_won += 1
	if Game.autotest_rematch and not _rematch_done:
		_rematch_done = true
		print("[AUTOTEST] Матч 1: ПОБЕДА подтверждена — запрашиваем реванш (перезапуск матча)")
		_begin_rematch()
		return
	var reason := "match victory verified (stats peers: %d, enemies seen: %d)" % [stats.size(), _enemies_seen]
	if _rematch_done:
		reason = "REMATCH victory verified: 2/2 matches (stats peers: %d, enemies seen: %d)" % [stats.size(), _enemies_seen]
	_finish(true, reason)

## Реванш (ТЗ: «Ещё раз» — ре-матч тем же составом с новым seed). Хост запрашивает
## новый матч; обе стороны должны пережить перезагрузку сцены, снова найти пешки,
## подтвердить репликацию мира и победить во втором матче. Проверяет очистку
## объектов/таймеров между матчами и синхронизацию состояния хост-клиент.
func _begin_rematch() -> void:
	_match_done = false
	_pawn = null
	_sys = null
	_mc = null
	_enemy_ref = null
	_enemy_ref_pos = Vector3.ZERO
	_seen_enemy_motion = false
	_enemies_seen = 0
	_intermission_served = false
	_offer_choice = &""
	_offer_delay = 0.0
	_phase = "match"
	_phase_t = 0.0
	if mode == "host":
		Net.request_rematch()
	else:
		print("[AUTOTEST] client: ожидаю реванш от хоста")

func _finish(passed: bool, reason: String) -> void:
	if _finished:
		return
	_finished = true
	print("[AUTOTEST] RESULT=%s mode=%s reason=%s" % ["PASS" if passed else "FAIL", mode, reason])
	_finish_async(passed)

func _finish_async(passed: bool) -> void:
	## Даём надёжным RPC (результат матча) долететь до второго пира,
	## затем закрываем ENet и выходим.
	await get_tree().create_timer(0.8).timeout
	Sfx.shutdown()
	Net.disconnect_game()
	get_tree().quit(0 if passed else 1)

## Сценарий кооперативного спасения (Этап 4.1), только при +rescue=1.
func _handle_rescue_test(delta: float) -> void:
	if not Game.autotest_rescue or _match_done:
		return
	if _pawn == null or not is_instance_valid(_pawn):
		_find_pawn()
		return
	if _mc == null or _mc.phase != MatchController.Phase.FIGHT:
		return
	_rsc_t += delta
	var remote_downed := _remote_pawn_downed()
	match mode:
		"host":
			match _rsc_step:
				0:
					if _rsc_t < 2.0:
						return
					var client_pawn := _remote_pawn()
					if client_pawn == null:
						return
					## Сервер подводит пешку клиента к своей и роняет СВОЮ.
					client_pawn.global_position = _pawn.global_position + Vector3(1.2, 0.0, 0.0)
					## Сценарная защита: спасатель не должен умереть от врагов,
					## пока стоит в канале (иначе канал отменится по смерти).
					client_pawn.health.grant_invulnerability(45.0)
					_pawn.health.take_damage(Units.make_damage(9999.0, null, 0, Vector3.ZERO, 0.0, _pawn.global_position))
					print("[AUTOTEST] rescue: хост повёржен, клиент рядом — жду спасения")
					_rsc_step = 1
					_rsc_t = 0.0
				1:
					if _pawn.state != PlayerPawn.State.DOWN:
						print("[AUTOTEST] RESCUE local revived: hp=%.0f (ожидалось %.0f)" % [_pawn.health.health, _pawn.effective_max_health() * 0.45])
						_rsc_revived_hp = _pawn.health.health
						_rsc_step = 2
						_rsc_t = 0.0
					elif _rsc_t > 12.0:
						_finish(false, "rescue: host pawn not revived in time")
				2:
					if _rsc_t < 1.8:
						return ## защита после спасения (1.5 с) должна истечь
					## Второй заход: канал открыт, затем клиент отключается —
					## сервер обязан отменить канал без краша. Бот хоста мог уйти
					## бить врагов — повторно подводим пешку клиента перед down.
					var cp2 := _remote_pawn()
					if cp2 != null:
						cp2.global_position = _pawn.global_position + Vector3(1.2, 0.0, 0.0)
					_pawn.health.take_damage(Units.make_damage(9999.0, null, 0, Vector3.ZERO, 0.0, _pawn.global_position))
					print("[AUTOTEST] rescue: хост повёржен повторно — жду канал и отключение клиента")
					_rsc_step = 3
					_rsc_t = 0.0
				3:
					var channel := int(_pawn.get("_rescue_rescuer_peer"))
					if channel != 0 and Net.get_player_count() < 2:
						## Клиент отключился: канал должен очиститься тиком сервера.
						_rsc_step = 4
						_rsc_wait_cleaned()
					elif _rsc_t > 25.0:
						_finish(false, "rescue: disconnect probe timeout")
				4:
					pass ## финализация в _rsc_wait_cleaned()
		"client":
			match _rsc_step:
				0:
					if remote_downed == null:
						return
					## Легитимный путь: удержание interact -> намерение -> RPC.
					_rsc_holding = true
					_rsc_hold_sent = true
					print("[AUTOTEST] rescue: клиент держит спасение (interact -> sv_rescue_hold)")
					_rsc_step = 1
					_rsc_t = 0.0
				1:
					var tgt := remote_downed_or_revived()
					if tgt != null and float(tgt.get("sync_rescue_progress")) > 0.05 and not _rsc_progress_seen:
						_rsc_progress_seen = true
						print("[AUTOTEST] rescue: прогресс реплицирован клиенту (%.0f%%)" % (float(tgt.get("sync_rescue_progress")) * 100.0))
					if tgt != null and tgt.state != PlayerPawn.State.DOWN:
						print("[AUTOTEST] RESCUE remote: клиент увидел возрождение чужой пешки (репликация)")
						_rsc_step = 2
						_rsc_t = 0.0
					elif _rsc_t > 12.0:
						_finish(false, "rescue: client never saw remote revive")
				2:
					## Ждём повторного падения хоста: намерение уже активно (hold),
					## канал должен открыться сам; затем отключаемся прямо в канале.
					var down2 := _remote_pawn_downed()
					if down2 == null:
						return
					if not _rsc_reedge_done:
						## Форсируем повторный край намерения (гонка репликации DOWN).
						_rsc_reedge_done = true
						_pawn._local_rescue_target = null
					if int(down2.get("sync_rescuer_peer")) != Net.my_id():
						return
					print("[AUTOTEST] rescue: канал 2 открыт намерением клиента — отключаемся в канале")
					_rsc_step = 3
					_rsc_t = 0.0
				3:
					if _rsc_t > 0.7:
						_finish(true, "rescue client scenario verified (disconnect in channel)")

func _remote_pawn() -> PlayerPawn:
	for n in get_tree().get_nodes_in_group("player_pawns"):
		var p := n as PlayerPawn
		if p != null and not p.is_local_pawn():
			return p
	return null

func _remote_pawn_downed() -> PlayerPawn:
	var p := _remote_pawn()
	if p != null and p.state == PlayerPawn.State.DOWN:
		return p
	return null

func remote_downed_or_revived() -> PlayerPawn:
	return _remote_pawn()

## Асинхронное ожидание очистки канала после отключения спасателя.
func _rsc_wait_cleaned() -> void:
	var cleaned: bool = false
	for i in 90:
		await get_tree().process_frame
		if int(_pawn.get("_rescue_rescuer_peer")) == 0:
			cleaned = true
			break
	print("[AUTOTEST] RESCUE_DISCONNECT cleaned=%s" % cleaned)
	if not is_equal_approx(_rsc_revived_hp, _pawn.effective_max_health() * 0.45):
		_finish(false, "rescue: revived hp mismatch on host")
	else:
		_finish(cleaned, "rescue host scenario verified")

## Сценарий синхронизации окружения (Этап 4.3): сервер разрушает ящик,
## ловушка циклит состояния; оба пира обязаны увидеть одно и то же.
func _handle_trap_test(delta: float) -> void:
	if not Game.autotest_trap or _match_done:
		return
	if _mc == null or _mc.phase != MatchController.Phase.FIGHT:
		return
	_tr_t += delta
	if not _trap_conn:
		for n in get_tree().get_nodes_in_group("traps"):
			var t := n as PulseTrap
			if t != null:
				t.state_changed_on_peer.connect(func(st: int) -> void: _trap_seq.append(st))
				_trap_conn = true
				break
		if not _trap_conn:
			return
	var crate: DestructibleProp = null
	for n in get_tree().get_nodes_in_group("destructibles"):
		crate = n as DestructibleProp
		if crate != null:
			break
	if crate == null:
		return
	match mode:
		"host":
			match _tr_step:
				0:
					if _tr_t < 2.0:
						return
					crate.health.take_damage(Units.make_damage(99999.0, null, 1, Vector3.ZERO, 0.0, crate.global_position))
					print("[AUTOTEST] trap: хост разрушил ящик (серверное уничтожение)")
					_tr_step = 1
					_tr_t = 0.0
				1:
					if crate.is_destroyed and _trap_seq.has(2):
						print("[AUTOTEST] TRAP_STATES host=%s crate_destroyed=1" % str(_trap_seq))
						_finish(true, "trap host scenario verified")
					elif _tr_t > 40.0:
						_finish(false, "trap: host saw no ACTIVE state")
		"client":
			match _tr_step:
				0:
					if crate.visuals.visible == false:
						print("[AUTOTEST] CRATE_SYNC client destroyed_seen=true")
						_tr_step = 1
						_tr_t = 0.0
					elif _tr_t > 40.0:
						_finish(false, "trap: client never saw crate destroyed")
				1:
					if _trap_seq.has(2):
						print("[AUTOTEST] TRAP_STATES client=%s" % str(_trap_seq))
						_finish(true, "trap client scenario verified")
					elif _tr_t > 40.0:
						_finish(false, "trap: client saw no ACTIVE state")

## Этап 5.1: наблюдение синхронности акта I (волны/босс) между пирами.
func _observe_act1() -> void:
	if not Game.autotest_act1:
		return
	var boss: BossAct1 = null
	for n in get_tree().get_nodes_in_group("boss_unit"):
		boss = n as BossAct1
		if boss != null:
			break
	if boss == null:
		return
	if not _act1_boss_seen:
		_act1_boss_seen = true
		print("[AUTOTEST] BOSS_SEEN %s: босс появился (репликация спавна)" % mode)
	if mode == "client" and not _act1_phase_sync and boss.health.health_factor() < 0.62:
		_act1_phase_sync = true
		print("[AUTOTEST] BOSS_PHASE_SYNC client: hp босса реплицирован (%.0f%%)" % (boss.health.health_factor() * 100.0))
