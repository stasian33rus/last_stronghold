extends Control
## Главное меню + лобби (Этап 1): создание комнаты, подключение, список игроков,
## выбор класса, готовность, старт матча. Всё — настоящий ENet, без имитаций (ТЗ §18/§19).
## В режиме автотеста (Game.autotest_mode) управление передаётся AutoTestRunner.

@onready var name_edit: LineEdit = $Center/VBox/ConnectPanel/VBox/Row1/NameEdit
@onready var port_edit: LineEdit = $Center/VBox/ConnectPanel/VBox/Row1/PortEdit
@onready var ip_edit: LineEdit = $Center/VBox/ConnectPanel/VBox/Row2/IpEdit
@onready var host_button: Button = $Center/VBox/ConnectPanel/VBox/Row2/HostButton
@onready var join_button: Button = $Center/VBox/ConnectPanel/VBox/Row2/JoinButton
@onready var status_label: Label = $Center/VBox/ConnectPanel/VBox/StatusLabel
@onready var lobby_panel: PanelContainer = $Center/VBox/LobbyPanel
@onready var players_list: ItemList = $Center/VBox/LobbyPanel/VBox/PlayersList
@onready var act_option: OptionButton = $Center/VBox/LobbyPanel/VBox/ActRow/ActOption
@onready var class_option: OptionButton = $Center/VBox/LobbyPanel/VBox/Row/ClassOption
@onready var ready_check: CheckButton = $Center/VBox/LobbyPanel/VBox/Row/ReadyCheck
@onready var start_button: Button = $Center/VBox/LobbyPanel/VBox/Row/StartButton
@onready var hint_label: Label = $Center/VBox/LobbyPanel/VBox/HintLabel
@onready var quit_button: Button = $Center/VBox/QuitButton

var _autotest_runner: Node

func _ready() -> void:
	name_edit.text = Net.local_name
	port_edit.text = str(Net.DEFAULT_PORT)
	ip_edit.text = "127.0.0.1"
	lobby_panel.visible = false
	host_button.pressed.connect(_on_host)
	join_button.pressed.connect(_on_join)
	start_button.pressed.connect(_on_start)
	ready_check.toggled.connect(_on_ready_toggled)
	class_option.item_selected.connect(_on_class_selected)
	quit_button.pressed.connect(func() -> void:
		Sfx.shutdown()
		get_tree().quit())
	Net.lobby_changed.connect(_refresh_lobby)
	Net.connection_failed.connect(_on_connection_failed)
	Net.connection_succeeded.connect(_on_connection_succeeded)
	Net.returned_to_menu.connect(_on_returned_to_menu)
	_fill_classes()
	_fill_acts()
	_refresh_lobby()
	if Game.autotest_mode != "" and not Game.autotest_started:
		_start_autotest()

func _fill_classes() -> void:
	class_option.clear()
	for def in Classes.get_all():
		class_option.add_item("%s — %s" % [def.display_name, def.id], 0)
		class_option.set_item_metadata(class_option.item_count - 1, def.id)

## Выбор акта (Этап 5.2): хост запускает матч на выбранной сцене — акт II
## доступен сразу, без прохождения акта I.
func _fill_acts() -> void:
	act_option.clear()
	act_option.add_item("Акт I — Оборона последнего источника", 0)
	act_option.set_item_metadata(0, Game.ARENA_SCENE)
	act_option.add_item("Акт II — Энергетический кортеж (сопровождение)", 1)
	act_option.set_item_metadata(1, Game.ACT2_SCENE)

func _selected_scene() -> String:
	var idx := act_option.selected
	if idx < 0:
		return Game.ARENA_SCENE
	return str(act_option.get_item_metadata(idx))

func _selected_class_id() -> StringName:
	var idx := class_option.selected
	if idx < 0:
		return Classes.get_default_id()
	return class_option.get_item_metadata(idx)

# ------------------------------------------------------------------ действия

func _on_host() -> void:
	Net.local_name = Net.sanitize_name(name_edit.text, 1)
	var port := _parse_port()
	var err := Net.create_game(port)
	if err == OK:
		_set_status("Комната создана (порт %d). Ожидание игроков..." % port, Color(0.6, 1.0, 0.7))

func _on_join() -> void:
	Net.local_name = Net.sanitize_name(name_edit.text, Net.my_id())
	var port := _parse_port()
	var ip := ip_edit.text.strip_edges()
	if ip.is_empty():
		_set_status("Укажите адрес сервера", Color(1.0, 0.6, 0.6))
		return
	_set_status("Подключение к %s:%d ..." % [ip, port], Color(0.8, 0.85, 1.0))
	Net.join_game(ip, port)

func _parse_port() -> int:
	var p := int(port_edit.text)
	if p <= 0 or p > 65535:
		p = Net.DEFAULT_PORT
	return p

func _on_start() -> void:
	Sfx.play("ui")
	Net.start_match(_selected_scene())

func _on_ready_toggled(value: bool) -> void:
	Sfx.play("ui")
	Net.set_local_ready(value)

func _on_class_selected(_index: int) -> void:
	Net.set_local_class(_selected_class_id())

func _on_connection_failed(reason: String) -> void:
	_set_status(reason, Color(1.0, 0.5, 0.5))
	lobby_panel.visible = false

func _on_connection_succeeded() -> void:
	lobby_panel.visible = true
	_set_status("Подключено. Отметьте «Готов» — хост начнёт матч.", Color(0.7, 0.9, 1.0))

func _on_returned_to_menu() -> void:
	lobby_panel.visible = false
	_set_status("Соединение закрыто", Color(0.8, 0.8, 0.8))
	ready_check.set_pressed_no_signal(false)

func _refresh_lobby() -> void:
	var in_lobby := Net.net_state != Net.NetState.OFFLINE and Net.net_state != Net.NetState.JOINING
	lobby_panel.visible = in_lobby
	if not in_lobby:
		return
	players_list.clear()
	for peer_id in Net.players.keys():
		var pdata: Dictionary = Net.players[peer_id]
		var cls := Classes.get_class_def(StringName(str(pdata.get("class_id", ""))))
		var cls_name: String = cls.display_name if cls != null else str(pdata.get("class_id", "?"))
		var ready_mark: String = "✔" if pdata.get("ready", false) else "…"
		var you := " (вы)" if int(peer_id) == Net.my_id() else ""
		players_list.add_item("%s  [%s]  %s%s" % [str(pdata.get("name", "?")), ready_mark, cls_name, you])
	var is_host := Net.is_server() and Net.is_online()
	start_button.visible = is_host
	start_button.disabled = Net.players.is_empty()
	## Сцену матча выбирает хост (сервер авторитетно рассылает её в sv_start_match).
	act_option.disabled = not is_host
	hint_label.text = "Игроков: %d/%d · Хост начинает матч, когда все готовы" % [Net.players.size(), Net.MAX_PLAYERS]
	## Синхронизируем локальные контролы с состоянием лобби.
	var my := Net.my_id()
	if Net.players.has(my):
		ready_check.set_pressed_no_signal(bool(Net.players[my]["ready"]))
		var my_class := StringName(str(Net.players[my]["class_id"]))
		for i in class_option.item_count:
			if class_option.get_item_metadata(i) == my_class:
				class_option.select(i)
	if Net.is_dedicated:
		_set_status("Dedicated-сервер работает. Ожидание игроков...", Color(0.7, 0.9, 1.0))

func _set_status(text: String, color: Color) -> void:
	status_label.text = text
	status_label.add_theme_color_override("font_color", color)

# ------------------------------------------------------------------ автотест

func _start_autotest() -> void:
	print("[Menu] Режим автотеста: %s" % Game.autotest_mode)
	var script := load("res://tests/autotest_runner.gd")
	_autotest_runner = Node.new()
	_autotest_runner.name = "AutoTestRunner"
	_autotest_runner.set_script(script)
	## Вешаем на root (deferred — root ещё достраивает сцену меню), чтобы раннер
	## пережил смену сцены меню -> арена.
	get_tree().root.add_child.call_deferred(_autotest_runner)
