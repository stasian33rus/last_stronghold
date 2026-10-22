extends Node3D
## Арена Акта I «Оборона последнего источника» — вертикальный срез (Этап 1).
## Сервер: спавнит пешки игроков и врагов через MultiplayerSpawner,
## ждёт подтверждения загрузки сцены от всех пиров, затем передаёт ход MatchController.

@onready var spawner: MultiplayerSpawner = $MultiplayerSpawner
@onready var match_controller: MatchController = $MatchController
@onready var wave_manager: WaveManager = $WaveManager
@onready var gigachad: GigaChad = $GigaChad

const PLAYER_SCENE: PackedScene = preload("res://scenes/characters/player.tscn")

func _ready() -> void:
	spawner.spawn_function = _on_spawn_request
	if Net.is_server():
		Net.peer_left.connect(_on_peer_left_during_match)
		_server_setup()
	else:
		## Клиент сообщает серверу, что сцена загружена (спавн начнётся после всех).
		match_controller.cl_scene_ready.rpc_id(1)

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
		"enemy":
			var def := load(str(data.get("def_path", ""))) as EnemyDefinition
			if def == null:
				push_error("[Arena] spawn_enemy: не найден EnemyDefinition")
				return null
			var enemy_scene := load(def.scene_path) as PackedScene
			if enemy_scene == null:
				push_error("[Arena] spawn_enemy: не найдена сцена %s" % def.scene_path)
				return null
			var foe: EnemyFop = enemy_scene.instantiate()
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
