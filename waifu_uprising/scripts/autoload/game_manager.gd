extends Node
## Game — поток матча и служебные режимы запуска (autoload).
## Разбирает аргументы командной строки:
##   +dedicated          — headless dedicated-сервер (без локального игрока)
##   +port=NNNNN         — порт (dedicated / автотесты)
##   +autotest=host|client — интеграционный сетевой тест (см. tests/autotest_runner.gd)
##   +rematch=1            — с +autotest: после победы сыграть второй матч (реванш)
##   +evolve=1             — с +autotest: проверка эволюции и её репликации клиенту
##   +ip=A.B.C.D         — адрес сервера для autotest=client
##   +fast=1             — ускоренный баланс прогрессии (короткие интермиссии — для тестов)

const MENU_SCENE: String = "res://scenes/main_menu/main_menu.tscn"
const ARENA_SCENE: String = "res://scenes/levels/arena_01/arena_01.tscn"
const BALANCE_DEFAULT: String = "res://resources/balance/progression.tres"
const BALANCE_FAST: String = "res://resources/balance/progression_fast.tres"

var match_seed: int = 0
var match_players_snapshot: Dictionary = {}
var rng := RandomNumberGenerator.new()
var progression_balance_path: String = BALANCE_DEFAULT

## Режимы автотестов.
var autotest_mode: String = ""
var autotest_port: int = Net.DEFAULT_PORT
var autotest_ip: String = "127.0.0.1"
var autotest_started: bool = false
var autotest_rematch: bool = false
var autotest_evolve: bool = false
var autotest_rescue: bool = false
var dedicated_mode: bool = false
var dedicated_port: int = Net.DEFAULT_PORT

func _ready() -> void:
	_parse_cmdline()
	Net.match_start_requested.connect(_on_match_start_requested)
	Net.returned_to_menu.connect(_on_returned_to_menu)
	if dedicated_mode:
		print("[Game] Запуск dedicated-сервера на порту %d" % dedicated_port)
		var err := Net.create_game(dedicated_port, true)
		if err != OK:
			push_error("[Game] Dedicated-сервер не запустился: %d" % err)
			get_tree().quit(1)

func _parse_cmdline() -> void:
	for arg in OS.get_cmdline_user_args():
		var a := arg.trim_prefix("+")
		if a == "dedicated":
			dedicated_mode = true
		elif a.begins_with("port="):
			var p := int(a.trim_prefix("port="))
			if p > 0:
				dedicated_port = p
				autotest_port = p
		elif a.begins_with("autotest="):
			autotest_mode = a.trim_prefix("autotest=")
		elif a == "rematch=1" or a == "rematch":
			autotest_rematch = true
		elif a == "evolve=1" or a == "evolve":
			autotest_evolve = true
		elif a == "rescue=1" or a == "rescue":
			autotest_rescue = true
		elif a.begins_with("ip="):
			autotest_ip = a.trim_prefix("ip=")
		elif a == "fast=1" or a == "fast":
			progression_balance_path = BALANCE_FAST

func _on_match_start_requested(scene_path: String, seed_value: int, players_snapshot: Dictionary) -> void:
	if Net.is_dedicated and Net.my_id() == 1:
		# Dedicated-сервер тоже загружает сцену (headless) и владеет симуляцией.
		pass
	match_seed = seed_value
	match_players_snapshot = players_snapshot
	rng.seed = seed_value
	print("[Game] Загрузка арены: %s (seed=%d)" % [scene_path, seed_value])
	get_tree().change_scene_to_file(scene_path)

func _on_returned_to_menu() -> void:
	if get_tree().current_scene != null and get_tree().current_scene.scene_file_path != MENU_SCENE:
		get_tree().change_scene_to_file(MENU_SCENE)

func leave_match_to_menu() -> void:
	Net.return_to_menu()
	if get_tree().current_scene != null and get_tree().current_scene.scene_file_path != MENU_SCENE:
		get_tree().change_scene_to_file(MENU_SCENE)

## Offline-матч (один процесс, без ENet): тот же серверный код, peer 1 = локальный игрок.
## Используется одиночными тестами и отладкой арены без сети.
func start_offline_match(pclass: StringName = &"berserk", pname: String = "Игрок") -> void:
	match_seed = randi()
	rng.seed = match_seed
	match_players_snapshot = {1: {"name": pname, "class_id": pclass, "ready": true}}
	Net.players = match_players_snapshot.duplicate(true)
	get_tree().change_scene_to_file(ARENA_SCENE)

## Случайный поток матча (спавны волн и т.п.) — детерминирован от match_seed.
func next_rand() -> int:
	return rng.randi()

func rand_range_f(from: float, to: float) -> float:
	return rng.randf_range(from, to)
