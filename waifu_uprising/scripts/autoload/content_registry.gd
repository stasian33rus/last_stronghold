extends Node
## Content — реестр улучшений и предметов магазина (autoload, Этап 2).
## Сканирует resources/upgrades/ и resources/shop/ — контент добавляется .tres-файлами.

const UPGRADES_DIR: String = "res://resources/upgrades/"
const SHOP_DIR: String = "res://resources/shop/"

var upgrades: Dictionary = {} ## StringName -> UpgradeDefinition
var upgrade_order: Array[StringName] = []
var shop_items: Dictionary = {} ## StringName -> ShopItemDefinition
var shop_order: Array[StringName] = []

func _ready() -> void:
	_scan_dir(UPGRADES_DIR, UpgradeDefinition, upgrades, upgrade_order)
	_scan_dir(SHOP_DIR, ShopItemDefinition, shop_items, shop_order)
	if upgrades.is_empty():
		push_error("[Content] Улучшения не найдены!")
	if shop_items.is_empty():
		push_error("[Content] Предметы магазина не найдены!")
	print("[Content] Улучшений: %d, предметов: %d" % [upgrades.size(), shop_items.size()])

func _scan_dir(path: String, expected: Variant, into: Dictionary, order: Array) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		push_error("[Content] Не открыть %s" % path)
		return
	dir.list_dir_begin()
	var file := dir.get_next()
	while file != "":
		if not dir.current_is_dir() and file.ends_with(".tres"):
			var res := load(path.path_join(file))
			if res != null and is_instance_of(res, expected):
				into[res.id] = res
				order.append(res.id)
			else:
				push_error("[Content] %s не ожидаемого типа" % file)
		file = dir.get_next()
	dir.list_dir_end()
	order.sort()

func get_upgrade(id: StringName) -> UpgradeDefinition:
	return upgrades.get(id, null)

func get_shop_item(id: StringName) -> ShopItemDefinition:
	return shop_items.get(id, null)

func all_upgrades() -> Array:
	var result: Array = []
	for id in upgrade_order:
		result.append(upgrades[id])
	return result

func all_shop_items() -> Array:
	var result: Array = []
	for id in shop_order:
		result.append(shop_items[id])
	return result
