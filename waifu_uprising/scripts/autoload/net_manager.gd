extends Node
## Net — менеджер сети и лобби (autoload).
## Модель: server-authoritative (ТЗ §16). Сервер (peer 1) владеет состоянием матча;
## клиенты отправляют команды и получают подтверждённое состояние.
## Одиночная игра = listen-сервер или полный offline (has peer == null) — код один и тот же.

signal connection_succeeded
signal connection_failed(reason: String)
signal lobby_changed
signal peer_joined(peer_id: int, player_name: String)
signal peer_left(peer_id: int)
signal match_start_requested(scene_path: String, match_seed: int, players_snapshot: Dictionary)
signal returned_to_menu

const DEFAULT_PORT: int = 24560
const MAX_PLAYERS: int = 8
const HELLO_TIMEOUT_SEC: float = 6.0
const DEFAULT_CLASS: StringName = &"berserk"

enum NetState { OFFLINE, HOSTING, JOINING, IN_LOBBY, IN_MATCH }

var net_state: int = NetState.OFFLINE
var is_dedicated: bool = false
## peer_id -> {"name": String, "class_id": StringName, "ready": bool}
var players: Dictionary = {}
var local_name: String = "Игрок"
var match_seed: int = 0
var current_match_scene: String = ""
var max_players: int = MAX_PLAYERS

var _hello_timers: Dictionary = {}

func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

# ---------------------------------------------------------------- основы

func is_online() -> bool:
	return multiplayer.multiplayer_peer is ENetMultiplayerPeer

## Сервер ли мы (offline считаем себя сервером — единый код для одиночной игры).
func is_server() -> bool:
	if not is_online():
		return true
	return multiplayer.is_server()

func my_id() -> int:
	if not is_online():
		return 1
	return multiplayer.get_unique_id()

func get_player_count() -> int:
	return players.size()

func get_peer_ids() -> Array:
	return players.keys()

# ---------------------------------------------------------------- создание / подключение

func create_game(port: int = DEFAULT_PORT, dedicated: bool = false) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_PLAYERS)
	if err != OK:
		connection_failed.emit("Не удалось создать сервер на порту %d (код %d)" % [port, err])
		return err
	multiplayer.multiplayer_peer = peer
	is_dedicated = dedicated
	net_state = NetState.IN_LOBBY
	players.clear()
	if not is_dedicated:
		_add_player(1, local_name, DEFAULT_CLASS)
	print("[Net] Комната создана: порт %d, dedicated=%s" % [port, str(dedicated)])
	lobby_changed.emit()
	connection_succeeded.emit()
	return OK

func join_game(ip: String, port: int = DEFAULT_PORT) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, port)
	if err != OK:
		connection_failed.emit("Не удалось инициировать подключение к %s:%d" % [ip, port])
		return err
	net_state = NetState.JOINING
	multiplayer.multiplayer_peer = peer
	print("[Net] Подключение к %s:%d ..." % [ip, port])
	return OK

func disconnect_game() -> void:
	if is_online():
		## Явный offline-пир (не null): rpc() с call_local продолжают работать локально
		## без ошибок «no multiplayer peer is active».
		multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	net_state = NetState.OFFLINE
	is_dedicated = false
	players.clear()
	_hello_timers.clear()

## Локальный выход в меню (для клиента — с разрывом соединения).
func return_to_menu() -> void:
	disconnect_game()
	returned_to_menu.emit()

# ---------------------------------------------------------------- лобби

func _on_peer_connected(id: int) -> void:
	if not is_server():
		return
	if net_state == NetState.IN_MATCH:
		# Этап 1: подключение во время матча не поддерживается (документированное ограничение).
		print("[Net] Отказ peer %d: матч уже идёт" % id)
		multiplayer.multiplayer_peer.disconnect_peer(id)
		return
	print("[Net] Peer %d подключился, ожидаем hello" % id)
	var timer := get_tree().create_timer(HELLO_TIMEOUT_SEC)
	_hello_timers[id] = timer
	timer.timeout.connect(func() -> void:
		if players.has(id) or net_state == NetState.IN_MATCH:
			return
		print("[Net] Peer %d не представился — отключаем" % id)
		if is_online():
			multiplayer.multiplayer_peer.disconnect_peer(id)
	)

func _on_peer_disconnected(id: int) -> void:
	if is_server():
		if players.has(id):
			players.erase(id)
			print("[Net] Игрок покинул комнату: peer %d" % id)
			_broadcast_lobby()
			peer_left.emit(id)
	_hello_timers.erase(id)
	if not is_server():
		peer_left.emit(id)

func _on_connected_to_server() -> void:
	net_state = NetState.IN_LOBBY
	cl_hello.rpc_id(1, local_name)
	connection_succeeded.emit()

func _on_connection_failed() -> void:
	net_state = NetState.OFFLINE
	multiplayer.multiplayer_peer = null
	connection_failed.emit("Сервер не ответил или отклонил подключение")

func _on_server_disconnected() -> void:
	print("[Net] Соединение с сервером потеряно")
	disconnect_game()
	returned_to_menu.emit()

func _add_player(peer_id: int, pname: String, class_id: StringName) -> void:
	players[peer_id] = {"name": pname, "class_id": class_id, "ready": false}
	peer_joined.emit(peer_id, pname)

static func sanitize_name(raw: String, peer_id: int) -> String:
	var clean := ""
	for ch in raw.strip_edges():
		if ch.unicode_at(0) >= 32:
			clean += ch
		if clean.length() >= 20:
			break
	if clean.is_empty():
		clean = "Игрок %d" % peer_id
	return clean

# ---------------------------------------------------------------- RPC лобби

@rpc("any_peer", "call_remote", "reliable")
func cl_hello(pname: String) -> void:
	if not is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if net_state == NetState.IN_MATCH:
		multiplayer.multiplayer_peer.disconnect_peer(sender)
		return
	if players.has(sender):
		return
	if players.size() >= max_players - (1 if is_dedicated else 0):
		multiplayer.multiplayer_peer.disconnect_peer(sender)
		return
	_add_player(sender, sanitize_name(pname, sender), DEFAULT_CLASS)
	print("[Net] Игрок зарегистрирован: peer %d (%s)" % [sender, players[sender]["name"]])
	_broadcast_lobby()

@rpc("authority", "call_local", "reliable")
func sv_lobby_state(state: Dictionary) -> void:
	players = state.duplicate(true)
	lobby_changed.emit()

func _broadcast_lobby() -> void:
	if is_online():
		sv_lobby_state.rpc(players)
	else:
		sv_lobby_state(players)

func set_local_ready(value: bool) -> void:
	if not is_online():
		return
	if is_server():
		_sv_set_ready(my_id(), value)
	else:
		cl_set_ready.rpc_id(1, value)

func set_local_class(class_id: StringName) -> void:
	if not is_online():
		return
	if is_server():
		_sv_set_class(my_id(), class_id)
	else:
		cl_set_class.rpc_id(1, class_id)

@rpc("any_peer", "call_remote", "reliable")
func cl_set_ready(value: bool) -> void:
	if not is_server():
		return
	_sv_set_ready(multiplayer.get_remote_sender_id(), value)

@rpc("any_peer", "call_remote", "reliable")
func cl_set_class(class_id: String) -> void:
	if not is_server():
		return
	_sv_set_class(multiplayer.get_remote_sender_id(), StringName(class_id))

func _sv_set_ready(peer_id: int, value: bool) -> void:
	if players.has(peer_id):
		players[peer_id]["ready"] = bool(value)
		_broadcast_lobby()
		_maybe_dedicated_autostart()

## Dedicated-сервер: хоста-игрока нет, поэтому стартуем автоматически,
## когда все подключившиеся игроки готовы (с задержкой 3 с на опоздавших).
var _dedicated_start_scheduled := false

func _maybe_dedicated_autostart() -> void:
	if not (is_dedicated and net_state == NetState.IN_LOBBY) or _dedicated_start_scheduled:
		return
	if not all_clients_ready():
		return
	_dedicated_start_scheduled = true
	print("[Net] Dedicated: все игроки готовы, старт матча через 3 с")
	get_tree().create_timer(3.0).timeout.connect(func() -> void:
		_dedicated_start_scheduled = false
		if net_state == NetState.IN_LOBBY and all_clients_ready():
			start_match(Game.ARENA_SCENE)
	)

func _sv_set_class(peer_id: int, class_id: StringName) -> void:
	## Валидация (Этап 3): принимаются только РЕАЛИЗОВАННЫЕ базовые формы I —
	## id форм II/III и заглушки классов из очереди разработки отклоняются.
	if players.has(peer_id) and Classes.is_selectable(class_id):
		players[peer_id]["class_id"] = class_id
		_broadcast_lobby()

func all_players_ready() -> bool:
	if players.is_empty():
		return false
	for pdata in players.values():
		if not pdata["ready"]:
			return false
	return true

## Все КЛИЕНТЫ готовы (хосту ready не нужен — он сам жмёт «Старт»).
## Для dedicated-сервера готовы должны быть все зарегистрированные игроки.
func all_clients_ready() -> bool:
	if players.is_empty():
		return false
	var clients := 0
	for peer_id in players.keys():
		if int(peer_id) == 1 and not is_dedicated:
			continue
		clients += 1
		if not players[int(peer_id)]["ready"]:
			return false
	return clients >= 1

# ---------------------------------------------------------------- старт матча

func start_match(scene_path: String) -> void:
	if not is_server():
		return
	if players.is_empty():
		print("[Net] Нет игроков — матч не начат")
		return
	match_seed = randi()
	current_match_scene = scene_path
	net_state = NetState.IN_MATCH
	print("[Net] Старт матча: scene=%s seed=%d players=%d" % [scene_path, match_seed, players.size()])
	if is_online():
		sv_start_match.rpc(scene_path, match_seed, players.duplicate(true))
	else:
		sv_start_match(scene_path, match_seed, players.duplicate(true))

func request_rematch() -> void:
	if current_match_scene == "":
		return
	if is_server():
		start_match(current_match_scene)
	elif is_online():
		cl_request_rematch.rpc_id(1)

@rpc("any_peer", "call_remote", "reliable")
func cl_request_rematch() -> void:
	if not is_server() or net_state != NetState.IN_MATCH:
		return
	start_match(current_match_scene)

@rpc("authority", "call_local", "reliable")
func sv_start_match(scene_path: String, seed_value: int, players_snapshot: Dictionary) -> void:
	net_state = NetState.IN_MATCH
	match_seed = seed_value
	current_match_scene = scene_path
	if not is_dedicated or my_id() != 1:
		players = players_snapshot.duplicate(true)
	match_start_requested.emit(scene_path, seed_value, players_snapshot)
