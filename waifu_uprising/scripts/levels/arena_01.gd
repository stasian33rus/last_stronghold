extends Node3D
## Арена Акта I «Оборона последнего источника» — вертикальный срез (Этап 1).
## Сервер: спавнит пешки игроков и врагов через MultiplayerSpawner,
## ждёт подтверждения загрузки сцены от всех пиров, затем передаёт ход MatchController.

@onready var spawner: MultiplayerSpawner = $MultiplayerSpawner
@onready var match_controller: MatchController = $MatchController
@onready var wave_manager: WaveManager = $WaveManager
@onready var gigachad: GigaChad = $GigaChad

const PLAYER_SCENE: PackedScene = preload("res://scenes/characters/player.tscn")

const MAX_PROJECTILES: int = 16

var _projectile_count: int = 0

func _ready() -> void:
	add_to_group("arena")
	spawner.spawn_function = _on_spawn_request
	if Net.is_server():
		Net.peer_left.connect(_on_peer_left_during_match)
		_server_setup()
	else:
		## Клиент сообщает серверу, что сцена загружена. Пакет может прийти раньше,
		## чем сервер сам сменит сцену (узел ещё не существует) — повторяем, пока
		## сервер не подтвердит выход из фазы LOADING.
		_send_scene_ready_with_retry()

func _send_scene_ready_with_retry() -> void:
	## Первая отправка — после короткой паузы: сервер обычно ещё достраивает свою
	## арену в этот момент (иначе RPC уйдёт в пустоту и будет залогирован как ошибка).
	await get_tree().create_timer(0.5).timeout
	var tries := 0
	while tries < 60 and is_inside_tree() and match_controller != null \
			and match_controller.phase == MatchController.Phase.LOADING:
		match_controller.cl_scene_ready.rpc_id(1)
		tries += 1
		await get_tree().create_timer(0.25).timeout

func _server_setup() -> void:
	var snapshot: Dictionary = Game.match_players_snapshot
	if snapshot.is_empty():
		snapshot = Net.players
	var spawn_points := get_tree().get_nodes_in_group("player_spawn_points")
	if spawn_points.is_empty():
		push_error("[Arena] Нет маркеров player_spawn_points")
		return
	var idx := 0
	for peer_id in snapshot.keys():
		var pdata: Dictionary = snapshot[peer_id]
		var marker: Marker3D = spawn_points[idx % spawn_points.size()]
		spawn_player(int(peer_id), str(pdata.get("name", "Игрок")), StringName(pdata.get("class_id", &"berserk")), marker.global_position)
		idx += 1
	print("[Arena] Заспавнено игроков: %d" % idx)

func spawn_player(peer_id: int, pname: String, class_id: StringName, pos: Vector3) -> Node:
	if not Net.is_server():
		return null
	return spawner.spawn({
		"kind": "player",
		"owner": peer_id,
		"pname": pname,
		"class_id": String(class_id),
		"pos": pos,
	})

func spawn_enemy(def: EnemyDefinition, pos: Vector3) -> Node:
	if not Net.is_server():
		return null
	return spawner.spawn({
		"kind": "enemy",
		"def_path": def.resource_path,
		"pos": pos,
	})

## Серверный снаряд Плевальщика: глобальный лимит одновременных (производительность,
## «никаких сетевых штормов»), очистка по попаданию/таймауту/концу матча.
func spawn_projectile(muzzle: Vector3, dir: Vector3, def: EnemyDefinition) -> Node:
	if not Net.is_server():
		return null
	if _projectile_count >= MAX_PROJECTILES:
		return null
	var node := spawner.spawn({
		"kind": "projectile",
		"scene": def.projectile_scene,
		"pos": muzzle,
		"dir": dir,
		"speed": def.projectile_speed,
		"dmg": def.attack_damage,
		"kb": def.attack_knockback,
		"life": def.projectile_lifetime,
	})
	if node != null:
		_projectile_count += 1
		node.tree_exited.connect(func() -> void: _projectile_count = maxi(0, _projectile_count - 1))
	return node

## Вызывается MultiplayerSpawner на ВСЕХ пирах с одинаковыми данными.
func _on_spawn_request(data: Dictionary) -> Node:
	match str(data.get("kind", "")):
		"player":
			var pawn: PlayerPawn = PLAYER_SCENE.instantiate()
			pawn.owner_peer = int(data.get("owner", 1))
			pawn.player_name = str(data.get("pname", "Игрок"))
			pawn.class_id = StringName(str(data.get("class_id", "berserk")))
			pawn.position = data.get("pos", Vector3.ZERO)
			return pawn
		"projectile":
			var proj_scene := load(str(data.get("scene", ""))) as PackedScene
			if proj_scene == null:
				push_error("[Arena] spawn_projectile: сцена не найдена")
				return null
			var proj: SpitProjectile = proj_scene.instantiate()
			proj.position = data.get("pos", Vector3.ZERO)
			proj.direction = data.get("dir", Vector3.FORWARD)
			proj.speed = float(data.get("speed", 15.0))
			proj.damage = float(data.get("dmg", 12.0))
			proj.knockback = float(data.get("kb", 3.0))
			proj.lifetime = float(data.get("life", 3.0))
			return proj
		"enemy":
			var def := load(str(data.get("def_path", ""))) as EnemyDefinition
			if def == null:
				push_error("[Arena] spawn_enemy: не найден EnemyDefinition")
				return null
			var enemy_scene := load(def.scene_path) as PackedScene
			if enemy_scene == null:
				push_error("[Arena] spawn_enemy: не найдена сцена %s" % def.scene_path)
				return null
			var foe: EnemyBase = enemy_scene.instantiate()
			foe.def = def
			foe.position = data.get("pos", Vector3.ZERO)
			return foe
	push_error("[Arena] Неизвестный spawn kind: %s" % str(data.get("kind", "?")))
	return null

## Отключение игрока во время матча: сервер убирает его пешку (спавнер синхронно
## удалит её и на клиентах). Матч продолжается, если остались другие (ТЗ §4).
func _on_peer_left_during_match(peer_id: int) -> void:
	if not Net.is_server():
		return
	for pawn in get_tree().get_nodes_in_group("player_pawns"):
		if pawn is PlayerPawn and pawn.owner_peer == peer_id:
			print("[Arena] Пешка отключившегося peer %d удалена" % peer_id)
			pawn.queue_free()
