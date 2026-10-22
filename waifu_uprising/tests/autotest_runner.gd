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
var _enemies_seen := 0
var _match_done := false

func _ready() -> void:
	mode = Game.autotest_mode
	Events.match_ended.connect(_on_match_ended)
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
					Net.set_local_class(Classes.get_default_id())
					Net.set_local_ready(true)
				_set_phase("lobby")
		"lobby":
			if mode == "host":
				if Net.get_player_count() >= 2 and Net.all_players_ready():
					print("[AUTOTEST] host: все готовы — старт матча")
					Net.start_match(Game.ARENA_SCENE)
					_set_phase("match")
			else:
				if Net.net_state == Net.NetState.IN_MATCH:
					_set_phase("match")
		"match":
			_drive_pawn(delta)
			_check_sync()

func _set_phase(p: String) -> void:
	_phase = p
	_phase_t = 0.0

func _find_pawn() -> void:
	for candidate in get_tree().get_nodes_in_group("player_pawns"):
		var p := candidate as PlayerPawn
		if p != null and p.is_local_pawn():
			_pawn = p
			return

## Виртуальный ввод: идём к ближайшему врагу, бьём в диапазоне, целясь в него.
func _drive_pawn(delta: float) -> void:
	if _pawn == null or not is_instance_valid(_pawn):
		_find_pawn()
		return
	_attack_cd -= delta
	var target := _nearest_enemy()
	var input := {"move": Vector2.ZERO, "aim_yaw": _pawn.aim_yaw, "press_attack": false, "press_dodge": false}
	if target != null:
		var to := target.global_position - _pawn.global_position
		to.y = 0.0
		var dist := to.length()
		var dir := to / dist if dist > 0.01 else Vector3.FORWARD
		input["aim_yaw"] = atan2(-dir.x, -dir.z)
		if dist > ATTACK_RANGE * 0.75:
			input["move"] = Vector2(dir.x, dir.z)
		if dist <= ATTACK_RANGE and _attack_cd <= 0.0 and _pawn.state != PlayerPawn.State.DOWN:
			input["press_attack"] = true
			_attack_cd = ATTACK_PERIOD
	elif _pawn.health.is_dead == false:
		## Врагов пока нет — идём к Гигачаду (не стоим в углу).
		var gigas := get_tree().get_nodes_in_group("gigachad")
		if gigas.size() > 0:
			var to: Vector3 = (gigas[0] as Node3D).global_position - _pawn.global_position
			to.y = 0.0
			if to.length() > 3.0:
				var dir := to.normalized()
				input["move"] = Vector2(dir.x, dir.z)
	_pawn.external_input = input

func _nearest_enemy() -> Node3D:
	var best: Node3D = null
	var best_d := 1e9
	for candidate in get_tree().get_nodes_in_group("enemy_units"):
		var foe := candidate as EnemyFop
		if foe == null or foe.health.is_dead or foe.state == EnemyFop.State.DEAD:
			continue
		if _pawn == null:
			break
		var d := foe.global_position.distance_squared_to(_pawn.global_position)
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

func _on_match_ended(victory: bool, stats: Dictionary) -> void:
	if _match_done:
		return
	_match_done = true
	if not victory:
		_finish(false, "match ended in DEFEAT")
		return
	var problems: Array[String] = []
	if Net.get_player_count() < 2 and Net.is_online():
		problems.append("player_count < 2")
	if _enemies_seen < 1:
		problems.append("no enemies were spawned/seen")
	if mode == "client" and not _seen_enemy_motion:
		problems.append("world replication not observed on client")
	if stats.is_empty():
		problems.append("empty match stats")
	if problems.is_empty():
		_finish(true, "match victory verified (stats peers: %d, enemies seen: %d)" % [stats.size(), _enemies_seen])
	else:
		_finish(false, "; ".join(problems))

func _finish(passed: bool, reason: String) -> void:
	print("[AUTOTEST] RESULT=%s mode=%s reason=%s" % ["PASS" if passed else "FAIL", mode, reason])
	get_tree().quit(0 if passed else 1)
