class_name WaveManager
extends Node
## Менеджер волн (сервер). Этап 1: одна короткая волна «Пижонов».
## Масштабирование под 1-8 игроков: count_base + count_per_player * N (ТЗ §4).
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
var _rng := RandomNumberGenerator.new()

func start_waves() -> void:
	if not Net.is_server():
		return
	_rng.seed = Game.match_seed + 777
	current_wave = 0
	_start_next_wave()

func _start_next_wave() -> void:
	current_wave += 1
	if current_wave > wave_paths.size():
		all_waves_cleared.emit()
		return
	_wave_def = load(wave_paths[current_wave - 1]) as WaveDefinition
	if _wave_def == null:
		push_error("[WaveManager] Не найден ресурс волны: %s" % wave_paths[current_wave - 1])
		return
	total_this_wave = _wave_def.total_count(Net.get_player_count())
	enemies_in_queue = total_this_wave
	enemies_alive = 0
	_spawn_acc = _wave_def.intro_delay
	_active = true
	print("[WaveManager] Волна %d: %d врагов (игроков: %d)" % [current_wave, total_this_wave, Net.get_player_count()])
	wave_started.emit(current_wave, total_this_wave)

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
	var def := load(_wave_def.enemy_def_path) as EnemyDefinition
	if def == null:
		push_error("[WaveManager] Не найден EnemyDefinition: %s" % _wave_def.enemy_def_path)
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

func _on_enemy_died(_enemy: EnemyFop, _damage: Dictionary) -> void:
	enemies_alive = maxi(0, enemies_alive - 1)
	if not _active:
		return
	if enemies_in_queue <= 0 and enemies_alive <= 0:
		_active = false
		print("[WaveManager] Волна %d зачищена" % current_wave)
		wave_cleared.emit(current_wave)
		if current_wave >= wave_paths.size():
			all_waves_cleared.emit()
