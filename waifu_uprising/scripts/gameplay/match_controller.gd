class_name MatchController
extends Node
## Контроллер матча (сервер-authoritative, ТЗ §16/§20, Этап 2).
## Фазы: LOADING -> COUNTDOWN -> FIGHT -> WAVE_COMPLETE -> INTERMISSION(магазин)
##        -> COUNTDOWN -> FIGHT ... -> VICTORY | DEFEAT.
## Поражение: здоровье Гигачада = 0 (ТЗ §3). Победа: зачищены ВСЕ волны.
## Единственный state machine матча (второго конкурирующего нет); состояние фаз
## реплицируется клиентам (HUD опрашивает локальный узел).

enum Phase { LOADING = 0, COUNTDOWN = 1, FIGHT = 2, VICTORY = 3, DEFEAT = 4, WAVE_COMPLETE = 5, INTERMISSION = 6 }

const COUNTDOWN_SEC: float = 3.5
const SCENE_READY_TIMEOUT: float = 15.0
const STATE_BROADCAST_INTERVAL: float = 0.1

var phase: int = Phase.LOADING
var countdown: float = 0.0
var wave_number: int = 0
var waves_total: int = 1
var enemies_alive: int = 0
var enemies_left_total: int = 0
var match_time: float = 0.0
## peer_id -> {"name": String, "kills": int, "damage": float, "downs": int}
var stats: Dictionary = {}

var _ready_peers: Dictionary = {}
var _expected_peers: Array[int] = []
var _scene_ready_timeout: float = 0.0
var _state_acc: float = 0.0
var _gigachad: GigaChad
var _wave_manager: WaveManager
var _last_countdown_int: int = -1
var _progression: Node = null
var _wave_complete_left: float = 0.0
var _fights_started: int = 0
var _last_wave_alive: Array = []

signal phase_changed_local(new_phase: int)

func _ready() -> void:
	add_to_group("match_controller")
	_wave_manager = get_parent().get_node_or_null(^"WaveManager") as WaveManager
	if _wave_manager != null:
		_wave_manager.all_waves_cleared.connect(_on_all_waves_cleared)
		_wave_manager.wave_cleared.connect(_on_wave_cleared)
		_wave_manager.enemy_spawned.connect(_on_enemy_spawned)
		waves_total = _wave_manager.wave_count()
	var gigas := get_tree().get_nodes_in_group("gigachad")
	if gigas.size() > 0:
		_gigachad = gigas[0] as GigaChad
	if Net.is_server():
		_setup_server()

func _prog() -> Node:
	if _progression == null or not is_instance_valid(_progression):
		var ps := get_tree().get_nodes_in_group("progression_system")
		_progression = ps[0] if ps.size() > 0 else null
	return _progression

func _balance() -> ProgressionBalance:
	var prog := _prog()
	return prog.balance if prog != null else null

func _setup_server() -> void:
	stats.clear()
	for peer_id in Game.match_players_snapshot.keys():
		var pdata: Dictionary = Game.match_players_snapshot[peer_id]
		stats[peer_id] = {"name": str(pdata.get("name", "?")), "kills": 0, "damage": 0.0, "downs": 0}
	_expected_peers.clear()
	for peer_id in stats.keys():
		_expected_peers.append(int(peer_id))
	if not _expected_peers.has(1):
		_expected_peers.append(1)
	_ready_peers.clear()
	_scene_ready_timeout = SCENE_READY_TIMEOUT
	_mark_scene_ready(1)
	if _gigachad != null:
		_gigachad.defeated.connect(_on_gigachad_defeated)
	if not Net.is_online():
		_begin_countdown()

func notify_scene_ready(peer_id: int) -> void:
	if not Net.is_server():
		return
	_mark_scene_ready(peer_id)

func _mark_scene_ready(peer_id: int) -> void:
	if _ready_peers.has(peer_id):
		return
	_ready_peers[peer_id] = true
	print("[Match] Сцена готова у peer %d (%d/%d)" % [peer_id, _ready_peers.size(), _expected_peers.size()])
	var all_ready := true
	for pid in _expected_peers:
		if not _ready_peers.has(pid):
			all_ready = false
			break
	if all_ready and phase == Phase.LOADING:
		_begin_countdown()

func _begin_countdown() -> void:
	if phase != Phase.LOADING:
		return
	phase = Phase.COUNTDOWN
	countdown = COUNTDOWN_SEC
	_last_countdown_int = -1
	print("[Match] Все готовы — отсчёт")
	_broadcast_phase("")

func _process(delta: float) -> void:
	if not Net.is_server():
		return
	match phase:
		Phase.LOADING:
			_scene_ready_timeout -= delta
			if _scene_ready_timeout <= 0.0:
				push_warning("[Match] Таймаут ожидания загрузки сцены — стартуем")
				_begin_countdown()
		Phase.COUNTDOWN:
			countdown -= delta
			var ci := int(ceilf(countdown))
			if ci != _last_countdown_int and ci >= 0:
				_last_countdown_int = ci
				Events.local_announcement.emit(str(ci) if ci > 0 else "В БОЙ!", 0.9)
				Sfx.play("count_go" if ci == 0 else "count", -6.0)
			_tick_state_broadcast(delta)
			if countdown <= 0.0:
				phase = Phase.FIGHT
				if _fights_started == 0:
					match_time = 0.0
				_fights_started += 1
				_broadcast_phase("")
				if _wave_manager != null:
					if _fights_started == 1:
						_wave_manager.start_waves()
					else:
						_wave_manager.start_next_wave()
		Phase.FIGHT:
			match_time += delta
			_tick_state_broadcast(delta)
		Phase.WAVE_COMPLETE:
			_wave_complete_left -= delta
			_tick_state_broadcast(delta)
			if _wave_complete_left <= 0.0:
				_begin_intermission()
		Phase.INTERMISSION:
			countdown -= delta
			_tick_state_broadcast(delta)
			if countdown <= 0.0:
				_begin_next_wave_countdown()
		_:
			pass

func _tick_state_broadcast(delta: float) -> void:
	_state_acc += delta
	if _state_acc >= STATE_BROADCAST_INTERVAL:
		_state_acc = 0.0
		_broadcast_state()

func _broadcast_phase(announcement: String = "") -> void:
	if Net.is_online():
		cl_phase.rpc(phase, announcement)
	else:
		cl_phase(phase, announcement)

func _broadcast_state() -> void:
	if _wave_manager != null:
		wave_number = _wave_manager.current_wave
		enemies_alive = _wave_manager.enemies_alive
		enemies_left_total = _wave_manager.enemies_alive + _wave_manager.enemies_in_queue
	if Net.is_online():
		cl_state.rpc(wave_number, waves_total, enemies_left_total, enemies_alive, countdown, match_time, phase)
	else:
		cl_state(wave_number, waves_total, enemies_left_total, enemies_alive, countdown, match_time, phase)

@rpc("any_peer", "call_remote", "reliable")
func cl_scene_ready() -> void:
	if not Net.is_server():
		return
	notify_scene_ready(multiplayer.get_remote_sender_id())

@rpc("authority", "call_local", "reliable")
func cl_phase(new_phase: int, announcement: String) -> void:
	phase = new_phase
	phase_changed_local.emit(phase)
	if announcement != "":
		Events.local_announcement.emit(announcement, 2.0)
	if phase == Phase.VICTORY or phase == Phase.DEFEAT:
		Events.match_ended.emit(phase == Phase.VICTORY, stats)
	Events.match_phase_changed.emit(phase)

@rpc("authority", "call_local", "unreliable")
func cl_state(wave: int, waves_total_v: int, left_total: int, alive: int, cd: float, mtime: float, phase_v: int) -> void:
	wave_number = wave
	waves_total = waves_total_v
	enemies_left_total = left_total
	enemies_alive = alive
	countdown = cd
	match_time = mtime
	## Фаза дублируется в состоянии: ненадёжный канал не должен оставлять HUD в прошлом.
	if phase_v != phase and (phase_v == Phase.FIGHT or phase_v == Phase.INTERMISSION or phase_v == Phase.WAVE_COMPLETE):
		phase = phase_v

# ------------------------------------------------------------------ межволновой цикл

func _on_wave_cleared(index: int) -> void:
	if not Net.is_server():
		return
	if phase != Phase.FIGHT:
		return
	## Фиксируем результаты волны: кто остался в строю (для награды).
	_last_wave_alive = _alive_peer_ids()
	if _wave_manager != null and _wave_manager.has_more_waves():
		phase = Phase.WAVE_COMPLETE
		var bal := _balance()
		_wave_complete_left = bal.wave_complete_time if bal != null else 2.5
		_broadcast_phase("ВОЛНА %d ОТБИТА!" % index)
		Sfx.play("count_go", -4.0, 1.1)
	## Если волн больше нет — победу объявит all_waves_cleared (ровно один раз).

func _alive_peer_ids() -> Array:
	var alive: Array = []
	for node in get_tree().get_nodes_in_group("player_pawns"):
		var pawn := node as PlayerPawn
		if pawn != null and pawn.state != PlayerPawn.State.DOWN and not pawn.health.is_dead:
			alive.append(pawn.owner_peer)
	return alive

func _begin_intermission() -> void:
	if not Net.is_server() or phase != Phase.WAVE_COMPLETE:
		return
	phase = Phase.INTERMISSION
	var bal := _balance()
	countdown = bal.intermission_time if bal != null else 30.0
	print("[Match] Интермиссия: магазин открыт на %.0f с" % countdown)
	var prog := _prog()
	if prog != null:
		prog.on_intermission_start(_last_wave_alive)
	_broadcast_phase("Магазин открыт — готовьтесь к волне %d" % (wave_number + 1))

## Хук готовности (от ProgressionSystem) и истечение таймера ведут в один вход.
func on_wave_ready_changed() -> void:
	if not Net.is_server():
		return
	if phase == Phase.INTERMISSION and _prog() != null and _prog().are_all_wave_ready():
		_begin_next_wave_countdown()

func _begin_next_wave_countdown() -> void:
	if not Net.is_server() or phase != Phase.INTERMISSION:
		return
	var bal := _balance()
	phase = Phase.COUNTDOWN
	countdown = bal.next_wave_countdown if bal != null else COUNTDOWN_SEC
	_last_countdown_int = -1
	_broadcast_phase("")

# ------------------------------------------------------------------ исход матча

func _on_all_waves_cleared() -> void:
	if not Net.is_server() or phase != Phase.FIGHT:
		return
	_end_match(Phase.VICTORY)

func _on_gigachad_defeated() -> void:
	if not Net.is_server():
		return
	if phase == Phase.VICTORY or phase == Phase.DEFEAT:
		return
	_end_match(Phase.DEFEAT)

func _end_match(result_phase: int) -> void:
	phase = result_phase
	## Спавн волн немедленно прекращается (никаких врагов после победы/поражения).
	if _wave_manager != null:
		_wave_manager.stop_waves()
	_broadcast_state()
	print("[Match] Матч завершён: %s, время %.1f с" % ["ПОБЕДА" if result_phase == Phase.VICTORY else "ПОРАЖЕНИЕ", match_time])
	if Net.is_online():
		cl_final_stats.rpc(stats, match_time)
	_broadcast_phase("")

@rpc("authority", "call_local", "reliable")
func cl_final_stats(final_stats: Dictionary, final_time: float) -> void:
	stats = final_stats.duplicate(true)
	match_time = final_time

# ------------------------------------------------------------------ статистика боя

func _on_enemy_spawned(enemy: Node) -> void:
	if not Net.is_server():
		return
	var foe := enemy as EnemyFop
	if foe == null:
		return
	foe.health.damage_taken.connect(_on_enemy_damaged)
	foe.died_on_server.connect(_on_enemy_died_for_stats)

func _on_enemy_damaged(amount: float, damage: Dictionary) -> void:
	var attacker := int(damage.get("attacker_peer", 0))
	if stats.has(attacker):
		stats[attacker]["damage"] = float(stats[attacker]["damage"]) + amount

func _on_enemy_died_for_stats(_foe: EnemyFop, damage: Dictionary) -> void:
	register_kill(int(damage.get("attacker_peer", 0)))

func register_kill(attacker_peer: int) -> void:
	if stats.has(attacker_peer):
		stats[attacker_peer]["kills"] = int(stats[attacker_peer]["kills"]) + 1

func register_down(peer_id: int) -> void:
	if stats.has(peer_id):
		stats[peer_id]["downs"] = int(stats[peer_id]["downs"]) + 1
