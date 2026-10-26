extends Node3D
## Скрипт боевого уровня: арена Акта I «Оборона последнего источника» (Этап 1)
## и маршрут Акта II «Энергетический кортеж» (Этап 5.2) — общая серверная
## обвязка. Сервер: спавнит пешки игроков и врагов через MultiplayerSpawner,
## ждёт подтверждения загрузки сцены от всех пиров, затем передаёт ход MatchController.

@onready var spawner: MultiplayerSpawner = $MultiplayerSpawner
@onready var match_controller: MatchController = $MatchController
@onready var nav_region: NavigationRegion3D = $NavRegion
## Необязательные узлы: WaveManager и корневой GigaChad есть в Акте I;
## в Акте II (кортеж, Этап 5.2) спавн ведёт ConvoyDirector, а Гигачад едет
## грузом на транспорте — тех же имён узлов в сцене нет.
var wave_manager: WaveManager = null
var gigachad: GigaChad = null

var _nav_rebake_pending := false

const PLAYER_SCENE: PackedScene = preload("res://scenes/characters/player.tscn")

const MAX_PROJECTILES: int = 16

var _projectile_count: int = 0

func _ready() -> void:
	wave_manager = get_node_or_null(^"WaveManager") as WaveManager
	gigachad = get_node_or_null(^"GigaChad") as GigaChad
	add_to_group("arena")
	spawner.spawn_function = _on_spawn_request
	if Net.is_server():
		_bake_navigation()
		_connect_destructibles()
		Net.peer_left.connect(_on_peer_left_during_match)
		_server_setup()
	else:
		## Клиентам навигация не нужна (ИИ врагов — серверный): не тратим CPU на bake.
		nav_region.enabled = false
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


# ------------------------------------------------------------------ навигация (Этап 2)

## Runtime-bake NavigationMesh по статическим коллайдерам из группы "nav_source"
## (пол, стены, колонны, ящики). Выполняется один раз на сервере при загрузке
## арены и повторно — только после разрушений (см. request_nav_rebake).
func _bake_navigation() -> void:
	if nav_region == null or nav_region.navigation_mesh == null:
		push_error("[Arena] NavRegion/NavigationMesh не настроены")
		return
	nav_region.bake_navigation_mesh(false)
	NavigationServer3D.map_force_update(nav_region.get_navigation_map())
	print("[Arena] NavMesh испечён: полигонов = %d" % nav_region.navigation_mesh.get_polygon_count())

## Дебаунс: серия разрушений -> одно перепекание (не пересоздаём сетку каждый кадр).
func request_nav_rebake() -> void:
	if not Net.is_server() or _nav_rebake_pending:
		return
	_nav_rebake_pending = true
	get_tree().create_timer(0.4).timeout.connect(func() -> void:
		_nav_rebake_pending = false
		if Net.is_server() and is_inside_tree() and nav_region != null:
			nav_region.bake_navigation_mesh(false)
			NavigationServer3D.map_force_update(nav_region.get_navigation_map())
			print("[Arena] NavMesh перепечён после разрушений: полигонов = %d" % nav_region.navigation_mesh.get_polygon_count())
	)

# ------------------------------------------------------------------ разрушаемые объекты

func _connect_destructibles() -> void:
	var prog: ProgressionSystem = null
	var ps := get_tree().get_nodes_in_group("progression_system")
	if ps.size() > 0:
		prog = ps[0] as ProgressionSystem
	for node in get_tree().get_nodes_in_group("destructibles"):
		var prop := node as DestructibleProp
		if prop == null:
			continue
		if prog != null:
			prop.destroyed_by.connect(func(peer_id: int) -> void: prog.grant_prop_reward(peer_id))
