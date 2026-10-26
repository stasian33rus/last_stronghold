class_name ConvoyDirector
extends Node
## Директор кортежа (Акт II, Этап 5.2) — серверный спавн рейдеров Ордена
## по прогрессу маршрута транспорта. Переиспользует боевую систему Акта I:
## спавн через arena.spawn_enemy (MultiplayerSpawner), награды/XP — через
## сигнал enemy_spawned (его подключают ProgressionSystem и MatchController),
## детерминированность — серверный RNG от Game.match_seed.
##
## Враги появляются впереди (ahead), позади (behind) или сбоку (flank) от
## маршрута; позиция считается от текущей точки транспорта, а не от статичных
## маркеров. Остановка матча (stop_spawning) гасит очередь — после финала
## спавна нет (проверяется тестами).

signal enemy_spawned(enemy: Node)

@export var events: Array[ConvoySpawnEvent] = []
@export var spawn_interval: float = 0.55
@export var max_alive: int = 8
## Границы карты (кламп позиций спавна, чтобы враги не появлялись за стенами).
@export var clamp_x: float = 52.0
@export var clamp_z: float = 11.0

var active: bool = false
var enemies_alive: int = 0
var events_fired: int = 0

var _queue: Array[Dictionary] = [] ## {def: String, side: String}
var _fired: Array[bool] = []
var _spawn_acc: float = 0.0
var _rng := RandomNumberGenerator.new()
var _transport: ConvoyTransport = null

func _ready() -> void:
	add_to_group("convoy_director")
	_fired.clear()
	for i in events.size():
		_fired.append(false)

## Старт спавна (из MatchController при первом входе в FIGHT).
func start_convoy() -> void:
	if not Net.is_server():
		return
	_rng.seed = Game.match_seed + 991
	active = true
	_spawn_acc = 0.8 ## короткая вводная пауза: первая группа не падает на голову
	print("[Convoy] Директор кортежа запущен: событий %d" % events.size())

## Остановка (финал матча): очередь гасится, живые враги остаются — их
## добивание уже не влияет на исход.
func stop_spawning() -> void:
	active = false
	_queue.clear()

func pending_count() -> int:
	return _queue.size()

func _physics_process(delta: float) -> void:
	if not Net.is_server() or not active:
		return
	_ensure_transport()
	if _transport == null or not is_instance_valid(_transport):
		return
	if _transport.state == ConvoyTransport.TState.ARRIVED or _transport.state == ConvoyTransport.TState.DESTROYED:
		return
	_fire_events_by_progress()
	_spawn_acc -= delta
	if _spawn_acc <= 0.0 and not _queue.is_empty() and enemies_alive < max_alive:
		_spawn_acc = spawn_interval
		_spawn_one()

func _ensure_transport() -> void:
	if _transport != null and is_instance_valid(_transport):
		return
	var ts := get_tree().get_nodes_in_group("convoy_transport")
	_transport = ts[0] as ConvoyTransport if ts.size() > 0 else null

func _fire_events_by_progress() -> void:
	var prog := _transport.progress_factor()
	for i in events.size():
		if _fired[i] or prog < events[i].progress_threshold:
			continue
		_fired[i] = true
		events_fired += 1
		var ev := events[i]
		var count := ev.total_count(Net.get_player_count())
		for k in count:
			_queue.append({"def": ev.enemy_def_path, "side": ev.side})
		print("[Convoy] Событие %d (прогресс %.0f%%): %s x%d (%s)" % [
			i + 1, prog * 100.0, ev.enemy_def_path.get_file(), count, ev.side])

func _spawn_one() -> void:
	var arena := get_parent()
	if arena == null or not arena.has_method("spawn_enemy"):
		push_error("[Convoy] Родитель не предоставляет spawn_enemy()")
		return
	if _queue.is_empty():
		return
	var item: Dictionary = _queue.pop_front()
	var def := load(str(item["def"])) as EnemyDefinition
	if def == null:
		push_error("[Convoy] Не найден EnemyDefinition: %s" % str(item["def"]))
		return
	var enemy: EnemyBase = arena.spawn_enemy(def, _spawn_position(str(item["side"])))
	if enemy != null:
		enemies_alive += 1
		enemy.died_on_server.connect(_on_enemy_died)
		enemy_spawned.emit(enemy)
	else:
		## Спавн не удался (лимиты) — возвращаем в очередь, счётчик не теряем.
		_queue.push_front(item)

func _spawn_position(side: String) -> Vector3:
	var p: Vector3
	match side:
		"ahead":
			p = _transport.get_point_ahead(12.0 + _rng.randf_range(0.0, 4.0))
		"behind":
			p = _transport.get_point_behind(9.0 + _rng.randf_range(0.0, 3.0))
		_:
			## flank: сбоку от маршрута недалеко от транспорта.
			var base := _transport.global_position
			var fwd := _transport.get_point_ahead(3.0) - base
			fwd.y = 0.0
			if fwd.length_squared() < 0.0001:
				fwd = Vector3.FORWARD
			fwd = fwd.normalized()
			var perp := Vector3(-fwd.z, 0.0, fwd.x)
			if _rng.randf() < 0.5:
				perp = -perp
			p = base + fwd * _rng.randf_range(0.0, 4.0) + perp * (7.0 + _rng.randf_range(0.0, 3.0))
	p.x = clampf(p.x + _rng.randf_range(-2.0, 2.0), -clamp_x, clamp_x)
	p.z = clampf(p.z + _rng.randf_range(-2.0, 2.0), -clamp_z, clamp_z)
	p.y = 0.1
	return p

func _on_enemy_died(_enemy: EnemyBase, _damage: Dictionary) -> void:
	enemies_alive = maxi(0, enemies_alive - 1)
