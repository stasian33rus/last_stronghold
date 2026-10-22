extends Node
## Classes — реестр игровых классов (autoload).
## Этап 1: один класс (Берсерка). Данные — ресурсы ClassDefinition из resources/classes/.
## Этап 6 добавит остальные 7 классов просто новыми .tres-файлами.

const CLASSES_DIR: String = "res://resources/classes/"

var definitions: Dictionary = {} ## StringName -> ClassDefinition
var order: Array[StringName] = []

func _ready() -> void:
	_scan()

func _scan() -> void:
	definitions.clear()
	order.clear()
	var dir := DirAccess.open(CLASSES_DIR)
	if dir == null:
		push_error("[Classes] Не открыть %s" % CLASSES_DIR)
		return
	dir.list_dir_begin()
	var file := dir.get_next()
	while file != "":
		if not dir.current_is_dir() and file.ends_with(".tres"):
			var res := load(CLASSES_DIR.path_join(file))
			if res is ClassDefinition:
				definitions[res.id] = res
				order.append(res.id)
			else:
				push_error("[Classes] %s не ClassDefinition" % file)
		file = dir.get_next()
	dir.list_dir_end()
	order.sort()
	if definitions.is_empty():
		push_error("[Classes] Классы не найдены!")
	print("[Classes] Загружено классов: %d (%s)" % [definitions.size(), ", ".join(order)])

func get_class_def(id: StringName) -> ClassDefinition:
	return definitions.get(id, null)

func get_default_id() -> StringName:
	return order[0] if order.size() > 0 else &"berserk"

func get_all() -> Array[ClassDefinition]:
	var result: Array[ClassDefinition] = []
	for id in order:
		result.append(definitions[id])
	return result
