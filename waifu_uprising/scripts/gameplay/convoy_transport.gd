class_name ConvoyTransport
extends CharacterBody3D
## Энергетический транспорт Акта II «Кортеж» (Этап 5.2).
## Защищаемый объект сопровождения: сервер авторитетно ведёт его по маршруту
## (контрольные точки с короткими остановками), считает здоровье, блокировку
## врагами и ремонт силами игроков. Клиенты получают состояние снапшотами
## BodySync (позиция/HP/прогресс маршрута/заряды ремонта/канал ремонта).
##
## Правила (сервер):
##  - движение только в фазе FIGHT; вне её транспорт стоит (отсчёт/финал);
##  - живой враг ближе block_radius останавливает кортеж (блокировка движения);
##  - контрольная точка = короткая остановка + событие + заряд ремонта команде;
##  - конечная точка маршрута -> сигнал arrived (победа акта — MatchController);
##  - здоровье 0 -> сигнал destroyed (поражение — MatchController);
##  - ремонт: игрок рядом удерживает interact (как спасение 4.1); сервер ведёт
##    канал, по завершении списывает ОДИН заряд и лечит ОДИН раз; повторные
##    сетевые события удержания лишь продлевают намерение (дедупликация
##    таймштампом), повторный ремонт невозможен до истечения кулдауна.

enum TState { IDLE = 0, MOVING = 1, CHECKPOINT = 2, BLOCKED = 3, ARRIVED = 4, DESTROYED = 5 }

signal checkpoint_reached(index: int)
signal arrived
signal destroyed

const REPAIR_RADIUS: float = 3.2      ## серверный радиус канала ремонта
const HOLD_STALE_MSEC: int = 600      ## намерение удержания протухает без повторов

@export var max_health: float = 900.0
@export var move_speed: float = 3.2
## Маршрут: упорядоченные контрольные точки. Первая — старт, последние
## промежуточные — остановки-события, финальная — точка эвакуации.
@export var route_points: Array[Vector3] = []
@export var checkpoint_stop_time: float = 2.0
@export var block_radius: float = 2.6
@export var repair_amount: float = 150.0
@export var repair_hold_time: float = 1.4
@export var repair_cooldown: float = 3.5
@export var repair_charges_start: int = 2
@export var repair_charges_max: int = 4

var team: int = Units.Team.HERO
var owner_peer: int = 1
var state: int = TState.IDLE
## Пройденное расстояние по маршруту (метры) и полная длина маршрута.
var route_distance: float = 0.0
var total_distance: float = 0.0
var repair_charges: int = 2
var repair_progress: float = 0.0 ## 0..1 — канал ремонта (реплицируется)
var repair_peer: int = 0         ## чей канал сейчас открыт

var _cum: Array[float] = []      ## накопленные расстояния до точек маршрута
var _next_checkpoint: int = 1    ## индекс следующей контрольной точки
var _stop_left: float = 0.0
var _cooldown_left: float = 0.0
var _hold_requests: Dictionary = {} ## peer_id -> msec последнего намерения
var _mc: MatchController = null

@onready var health: HealthComponent = $Health
@onready var visuals: Node3D = $Visuals

func _ready() -> void:
	add_to_group("convoy_transport")
	add_to_group("hero_units")
	repair_charges = repair_charges_start
	health.setup(max_health)
	health.died.connect(_on_destroyed)
	_build_route()
	_apply_route_transform()

func get_health() -> HealthComponent:
	return health

func _build_route() -> void:
	_cum.clear()
	total_distance = 0.0
	var acc := 0.0
	for i in route_points.size():
		if i > 0:
			acc += route_points[i].distance_to(route_points[i - 1])
		_cum.append(acc)
	total_distance = acc
	if route_points.is_empty():
		push_error("[Convoy] Маршрут пуст — транспорт не сможет двигаться")

# ------------------------------------------------------------------ серверный тик

func _physics_process(delta: float) -> void:
	if not Net.is_server():
		return
	if state == TState.ARRIVED or state == TState.DESTROYED:
		return
	if _mc == null or not is_instance_valid(_mc):
		var mcs := get_tree().get_nodes_in_group("match_controller")
		_mc = mcs[0] as MatchController if mcs.size() > 0 else null
	_cooldown_left = maxf(0.0, _cooldown_left - delta)
	_tick_repair(delta)
	if _mc == null or _mc.phase != MatchController.Phase.FIGHT:
		return ## вне боя транспорт не едет (отсчёт, победа, поражение)
	match state:
		TState.CHECKPOINT:
			_stop_left -= delta
			if _stop_left <= 0.0:
				state = TState.MOVING
		_:
			if _is_blocked():
				if state != TState.BLOCKED:
					state = TState.BLOCKED
				return
			if state != TState.MOVING:
				state = TState.MOVING
			_advance(delta)

func _advance(delta: float) -> void:
	route_distance = minf(total_distance, route_distance + move_speed * delta)
	_apply_route_transform()
	if _next_checkpoint >= route_points.size():
		return
	if route_distance < _cum[_next_checkpoint]:
		return
	if _next_checkpoint == route_points.size() - 1:
		_next_checkpoint += 1
		_on_arrived()
		return
	state = TState.CHECKPOINT
	_stop_left = checkpoint_stop_time
	repair_charges = mini(repair_charges_max, repair_charges + 1)
	var idx := _next_checkpoint
	_next_checkpoint += 1
	checkpoint_reached.emit(idx)
	fx_checkpoint.rpc(idx)

## Живой враг рядом = кортеж остановлен (часть врагов специально выбегает
## вперёд по маршруту — см. convoy_lead у рейдеров/барьеров).
func _is_blocked() -> bool:
	for n in get_tree().get_nodes_in_group("enemy_units"):
		var foe := n as EnemyBase
		if foe == null or not is_instance_valid(foe) or foe.health.is_dead:
			continue
		if foe.state == EnemyBase.State.DEAD:
			continue
		var d := foe.global_position - global_position
		d.y = 0.0
		if d.length() <= block_radius:
			return true
	return false

func _on_arrived() -> void:
	if state == TState.ARRIVED:
		return
	state = TState.ARRIVED
	print("[Convoy] Транспорт достиг конечной точки маршрута")
	fx_arrived.rpc()
	arrived.emit()

func _on_destroyed(_damage: Dictionary) -> void:
	if not Net.is_server() or state == TState.DESTROYED:
		return
	state = TState.DESTROYED
	print("[Convoy] Транспорт уничтожен")
	fx_destroyed.rpc()
	destroyed.emit()

func on_damage_received(damage: Dictionary) -> void:
	if not Net.is_server():
		return
	fx_hit.rpc(damage.get("hit_position", global_position), float(damage.get("amount", 0.0)))

# ------------------------------------------------------------------ маршрут (утилиты)

func progress_factor() -> float:
	if total_distance <= 0.0:
		return 0.0
	return clampf(route_distance / total_distance, 0.0, 1.0)

func route_point_at(dist: float) -> Vector3:
	if route_points.is_empty():
		return global_position
	if route_points.size() == 1:
		return route_points[0]
	var d := clampf(dist, 0.0, total_distance)
	for i in range(1, route_points.size()):
		if d <= _cum[i] or i == route_points.size() - 1:
			var seg_len := _cum[i] - _cum[i - 1]
			var f := 0.0 if seg_len <= 0.0001 else (d - _cum[i - 1]) / seg_len
			return route_points[i - 1].lerp(route_points[i], clampf(f, 0.0, 1.0))
	return route_points[route_points.size() - 1]

## Точка маршрута впереди/позади текущей позиции — используют ИИ-блокеры
## (перекрытие пути) и директор кортежа (позиции спавна).
func get_point_ahead(meters: float) -> Vector3:
	return route_point_at(route_distance + maxf(0.0, meters))

func get_point_behind(meters: float) -> Vector3:
	return route_point_at(route_distance - maxf(0.0, meters))

## Расстояние до следующей контрольной точки (тесты/HUD).
func next_checkpoint_distance() -> float:
	if _next_checkpoint < _cum.size():
		return _cum[_next_checkpoint]
	return total_distance

func _apply_route_transform() -> void:
	if route_points.is_empty():
		return
	var pos := route_point_at(route_distance)
	global_position = pos
	var look := route_point_at(minf(route_distance + 0.6, total_distance))
	var dir := look - pos
	dir.y = 0.0
	if dir.length_squared() > 0.0001:
		rotation.y = atan2(-dir.x, -dir.z)

## Серверный тестовый/отладочный вход: установить прогресс маршрута (0..1).
func force_progress(fraction: float) -> void:
	if not Net.is_server():
		return
	route_distance = clampf(fraction, 0.0, 1.0) * total_distance
	_next_checkpoint = 1
	while _next_checkpoint < _cum.size() and _cum[_next_checkpoint] <= route_distance:
		_next_checkpoint += 1
	if state == TState.CHECKPOINT:
		state = TState.MOVING
	_apply_route_transform()

# ------------------------------------------------------------------ ремонт (сервер)

## RPC-намерение клиента (зеркало паттерна sv_rescue_hold из 4.1): владение
## пешкой и условия проверяются сервером; повторные пакеты лишь обновляют
## таймштамп — сам ремонт происходит строго один раз на завершённый канал.
@rpc("any_peer", "call_remote", "reliable")
func sv_repair_hold(holding: bool) -> void:
	if not Net.is_server() or not is_inside_tree():
		return
	server_repair_hold_by_peer(multiplayer.get_remote_sender_id(), holding)

func server_repair_hold_by_peer(sender: int, holding: bool) -> bool:
	if not Net.is_server() or sender <= 0:
		return false
	if not holding:
		_hold_requests.erase(sender)
		return true
	var pawn := _pawn_of(sender)
	if pawn == null or pawn.health.is_dead or pawn.state == PlayerPawn.State.DOWN:
		_hold_requests.erase(sender)
		return false
	if pawn.global_position.distance_to(global_position) > REPAIR_RADIUS + 1.0:
		## Заметно вне радиуса — намерение не регистрируем (клиент повторит).
		return false
	_hold_requests[sender] = Time.get_ticks_msec()
	return true

func _tick_repair(delta: float) -> void:
	if _mc == null or _mc.phase != MatchController.Phase.FIGHT:
		_decay_repair_channel(delta)
		return
	if repair_charges <= 0 or _cooldown_left > 0.0 or health.health >= health.max_health:
		_decay_repair_channel(delta)
		return
	var pawn := _active_repair_pawn()
	if pawn == null:
		_decay_repair_channel(delta)
		return
	if repair_peer == 0:
		repair_peer = pawn.owner_peer
		repair_progress = 0.0
		fx_repair_start.rpc(repair_peer)
	elif repair_peer != pawn.owner_peer:
		return ## канал занят другим игроком (как в спасении 4.1)
	repair_progress += delta / repair_hold_time
	if repair_progress >= 1.0:
		_complete_repair()

func _decay_repair_channel(delta: float) -> void:
	if repair_progress > 0.0:
		repair_progress = maxf(0.0, repair_progress - delta * 2.0)
		if repair_progress <= 0.0:
			repair_peer = 0

## Одно подтверждённое действие (завершённый канал) = ровно один ремонт:
## заряд списывается и лечение применяется атомарно на сервере.
func _complete_repair() -> void:
	if repair_charges <= 0 or state == TState.DESTROYED or state == TState.ARRIVED:
		_reset_repair_channel()
		return
	repair_charges -= 1
	_cooldown_left = repair_cooldown
	health.heal(repair_amount)
	var who := repair_peer
	_reset_repair_channel()
	print("[Convoy] Ремонт выполнен peer %d (зарядов осталось: %d)" % [who, repair_charges])
	fx_repair_done.rpc(who)

func _reset_repair_channel() -> void:
	repair_progress = 0.0
	repair_peer = 0

func _active_repair_pawn() -> PlayerPawn:
	var now := Time.get_ticks_msec()
	var best: PlayerPawn = null
	var best_d := 1e9
	for peer_id in _hold_requests.keys():
		if now - int(_hold_requests[peer_id]) > HOLD_STALE_MSEC:
			continue
		var pawn := _pawn_of(int(peer_id))
		if pawn == null or pawn.health.is_dead or pawn.state == PlayerPawn.State.DOWN:
			continue
		var d := pawn.global_position.distance_to(global_position)
		if d > REPAIR_RADIUS:
			continue
		if _is_rescuing(pawn):
			continue ## спасение союзника (4.1) имеет приоритет над ремонтом
		if d < best_d:
			best_d = d
			best = pawn
	return best

func _is_rescuing(pawn: PlayerPawn) -> bool:
	for n in get_tree().get_nodes_in_group("player_pawns"):
		var p := n as PlayerPawn
		if p != null and p.state == PlayerPawn.State.DOWN and p._rescue_rescuer_peer == pawn.owner_peer:
			return true
	return false

func _pawn_of(peer: int) -> PlayerPawn:
	for n in get_tree().get_nodes_in_group("player_pawns"):
		var p := n as PlayerPawn
		if p != null and p.owner_peer == peer:
			return p
	return null

# ------------------------------------------------------------------ репликация

func get_sync_payload() -> Dictionary:
	return {
		"p": global_position,
		"y": rotation.y,
		"s": state,
		"hp": health.health,
		"dead": health.is_dead,
		"prog": progress_factor(),
		"ch": repair_charges,
		"rp": repair_progress,
		"cp": _next_checkpoint,
	}

func apply_sync_payload(payload: Dictionary) -> void:
	if payload.has("p"):
		global_position = payload["p"]
	if payload.has("y"):
		rotation.y = payload["y"]
	if payload.has("hp"):
		health.replicate_state(float(payload["hp"]), bool(payload.get("dead", false)))
	if payload.has("prog"):
		route_distance = float(payload["prog"]) * total_distance
	if payload.has("ch"):
		repair_charges = int(payload["ch"])
	if payload.has("rp"):
		repair_progress = float(payload["rp"])
	if payload.has("cp"):
		_next_checkpoint = int(payload["cp"])
	var new_state := int(payload.get("s", state))
	if new_state != state:
		state = new_state
		Events.sync_state_changed.emit(self, state)

# ------------------------------------------------------------------ косметические RPC

@rpc("authority", "call_local", "unreliable")
func fx_hit(hit_pos: Vector3, amount: float) -> void:
	VisualFx.hit_flash(self)
	VisualFx.damage_number(hit_pos, amount, Color(1.0, 0.65, 0.4))
	Sfx.play("hurt", -6.0, 0.5)

@rpc("authority", "call_local", "reliable")
func fx_checkpoint(index: int) -> void:
	VisualFx.ring_burst(global_position, Color(0.35, 0.9, 1.0), 5.0)
	Sfx.play("count_go", -6.0, 1.2)
	Events.local_announcement.emit("КОНТРОЛЬНАЯ ТОЧКА %d — кортеж делает остановку" % index, 2.0)

@rpc("authority", "call_local", "reliable")
func fx_arrived() -> void:
	VisualFx.ring_burst(global_position, Color(1.0, 0.85, 0.3), 8.0)
	Sfx.play("victory", -4.0)

@rpc("authority", "call_local", "reliable")
func fx_destroyed() -> void:
	VisualFx.ring_burst(global_position, Color(1.0, 0.35, 0.2), 7.0)
	Sfx.play("defeat", -4.0)
	if visuals != null:
		var tilt := create_tween()
		tilt.tween_property(visuals, "rotation:z", 0.28, 0.6)

@rpc("authority", "call_local", "reliable")
func fx_repair_start(peer_id: int) -> void:
	Sfx.play("ui", -10.0, 0.8)

@rpc("authority", "call_local", "reliable")
func fx_repair_done(peer_id: int) -> void:
	VisualFx.ring_burst(global_position + Vector3(0.0, 1.2, 0.0), Color(0.4, 1.0, 0.6), 3.2)
	Sfx.play("pulse", -8.0, 1.4)
	Events.local_toast.emit("Кортеж отремонтирован (peer %d)" % peer_id, "info")
