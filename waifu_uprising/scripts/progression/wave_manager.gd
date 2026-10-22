class_name WaveManager
extends Node
## Менеджер волн (сервер). Этап 2: несколько волн, состав группами архетипов,
## масштабирование 1-8 игроков: count_base + count_per_player * N (ТЗ §4/§9).
## Данные — WaveDefinition (.tres), спавн — через MultiplayerSpawner арены.

signal wave_started(index: int, total_enemies: int)
signal enemy_spawned(enemy: Node)
signal wave_cleared(index: int)
signal all_waves_cleared

@export var wave_paths: Array[String] = ["res://resources/waves/wave_01.tres"]

var current_wave: int = 0
var enemies_alive: int = 0
var enemies_in_queue: int = 0
var total_this_wave: int = 0

var _active: bool = false
var _spawn_acc: float = 0.0
var _wave_def: WaveDefinition
var _spawn_queue: Array[String] = [] ## пути EnemyDefinition в порядке спавна
var _rng := RandomNumberGenerator.new()

func wave_count() -> int:
	return wave_paths.size()

func has_more_waves() -> bool:
	return current_wave < wave_paths.size()

## Старт первой волны (вход из отсчёта).
func start_waves() -> void:
	if not Net.is_server():
		return
	_rng.seed = Game.match_seed + 777
	current_wave = 0
	_start_next_wave()

## Старт следующей волны (вход после интермиссии).
func start_next_wave() -> void:
	if not Net.is_server():
		return
	if not _active:
		_start_next_wave()

## Остановка спавна (конец матча: победа/поражение) — очередь гасится, живые остаются.
func stop_waves() -> void:
	_active = false
	_spawn_queue.clear()
	enemies_in_queue = 0

func _start_next_wave() -> void:
	current_wave += 1
	if current_wave > wave_paths.size():
		all_waves_cleared.emit()
		return
	_wave_def = load(wave_paths[current_wave - 1]) as WaveDefinition
	if _wave_def == null:
		push_error("[WaveManager] Не найден ресурс волны: %s" % wave_paths[current_wave - 1])
		return
	_spawn_queue = _build_queue(_wave_def, Net.get_player_count())
	total_this_wave = _spawn_queue.size()
	enemies_in_queue = total_this_wave
	enemies_alive = 0
	_spawn_acc = _wave_def.intro_delay
	_active = true
	print("[WaveManager] Волна %d/%d: %d врагов (игроков: %d)" % [current_wave, wave_paths.size(), total_this_wave, Net.get_player_count()])
	wave_started.emit(current_wave, total_this_wave)

## Детерминированная очередь спавна: группы перемешиваются seeded-RNG (сервер).
func _build_queue(def: WaveDefinition, player_count: int) -> Array[String]:
	var queue: Array[String] = []
	if def.groups.is_empty():
		for i in def.total_count(player_count):
			queue.append(def.enemy_def_path)
	else:
		for g in def.groups:
			for i in g.total_count(player_count):
				queue.append(g.enemy_def_path)
	## Перемешивание Фишером-Йетсом от серверного RNG — порядок воспроизводим.
	for i in range(queue.size() - 1, 0, -1):
		var j := _rng.randi() % (i + 1)
		var tmp: String = queue[i]
		queue[i] = queue[j]
		queue[j] = tmp
	return queue

func _physics_process(delta: float) -> void:
	if not Net.is_server() or not _active or _wave_def == null:
		return
	_spawn_acc -= delta
	if _spawn_acc <= 0.0 and enemies_in_queue > 0 and enemies_alive < _wave_def.max_alive:
		_spawn_acc = _wave_def.spawn_interval
		_spawn_one()

func _spawn_one() -> void:
	var arena := get_parent()
	if arena == null or not arena.has_method("spawn_enemy"):
		push_error("[WaveManager] Родитель не предоставляет spawn_enemy()")
		return
	if _spawn_queue.is_empty():
		return
	var def_path: String = _spawn_queue.pop_front()
	var def := load(def_path) as EnemyDefinition
	if def == null:
		push_error("[WaveManager] Не найден EnemyDefinition: %s" % def_path)
		return
	var points := get_tree().get_nodes_in_group("enemy_spawn_points")
	if points.is_empty():
		push_error("[WaveManager] Нет маркеров enemy_spawn_points")
		return
	var marker: Marker3D = points[_rng.randi() % points.size()]
	var jitter := Vector3(_rng.randf_range(-1.5, 1.5), 0.1, _rng.randf_range(-1.5, 1.5))
	var enemy: EnemyFop = arena.spawn_enemy(def, marker.global_position + jitter)
	if enemy != null:
		enemies_in_queue -= 1
		enemies_alive += 1
		enemy.died_on_server.connect(_on_enemy_died)
		enemy_spawned.emit(enemy)
	else:
		## Спавн не удался — не теряем счётчик (иначе волна «зависнет» недосчитанной).
		_spawn_queue.push_front(def_path)

func _on_enemy_died(_enemy: EnemyFop, _damage: Dictionary) -> void:
	enemies_alive = maxi(0, enemies_alive - 1)
	if not _active:
		return
	if enemies_in_queue <= 0 and _spawn_queue.is_empty() and enemies_alive <= 0:
		_active = false
		print("[WaveManager] Волна %d зачищена" % current_wave)
		wave_cleared.emit(current_wave)
		if current_wave >= wave_paths.size():
			all_waves_cleared.emit()
