extends Node
## Classes — реестр игровых классов (autoload).
## Этап 3: 8 классов × 3 формы эволюции = 24 ClassDefinition в resources/classes/.
##  - формы I (form_index == 0) — выбираемые классы; в лобби доступны только
##    implemented == true (полностью реализованные);
##  - формы II/III — звенья evolution_chain формы I, открываются сервером;
##  - get_class_def(id) решает ЛЮБОЙ id (базовый или формы) — совместимость
##    с валидацией лобби и кодом Этапов 1-2 сохранена.

const CLASSES_DIR: String = "res://resources/classes/"

var definitions: Dictionary = {} ## StringName -> ClassDefinition (ТОЛЬКО базовые формы I)
var order: Array[StringName] = [] ## id выбираемых классов (реализованные, отсортированы)
var all_by_id: Dictionary = {} ## StringName -> ClassDefinition (все 24, включая формы II/III)

func _ready() -> void:
	_scan()

func _scan() -> void:
	definitions.clear()
	order.clear()
	all_by_id.clear()
	var dir := DirAccess.open(CLASSES_DIR)
	if dir == null:
		push_error("[Classes] Не открыть %s" % CLASSES_DIR)
		return
	var all_defs: Array[ClassDefinition] = []
	dir.list_dir_begin()
	var file := dir.get_next()
	while file != "":
		if not dir.current_is_dir() and file.ends_with(".tres"):
			var res := load(CLASSES_DIR.path_join(file))
			if res is ClassDefinition:
				all_defs.append(res)
			else:
				push_error("[Classes] %s не ClassDefinition" % file)
		file = dir.get_next()
	dir.list_dir_end()
	## Базовые формы (form_index == 0) — выбираемые классы; все defs — в all_by_id.
	for def in all_defs:
		if all_by_id.has(def.id):
			push_error("[Classes] Дубликат id класса: %s" % def.id)
		all_by_id[def.id] = def
		if def.form_index == 0:
			definitions[def.id] = def
			if def.implemented:
				order.append(def.id)
	order.sort()
	if definitions.is_empty():
		push_error("[Classes] Классы не найдены!")
	if order.is_empty():
		push_error("[Classes] Нет ни одного реализованного класса (implemented)!")
	print("[Classes] Загружено классов: %d (реализовано: %s), всего форм: %d" % [
		definitions.size(), ", ".join(order), all_by_id.size()])

## Любой def по id (базовый или форма II/III). Совместим с кодом Этапов 1-2.
func get_class_def(id: StringName) -> ClassDefinition:
	return all_by_id.get(id, null)

## Цепочка форм класса: [I, II, III] (формы II/III — из evolution_chain базы).
func get_form_chain(base_id: StringName) -> Array[ClassDefinition]:
	var result: Array[ClassDefinition] = []
	var base := definitions.get(base_id, null) as ClassDefinition
	if base == null:
		return result
	result.append(base)
	for link in base.evolution_chain:
		var form := link as ClassDefinition
		if form != null:
			result.append(form)
	return result

## Def конкретной формы (idx 0..2); вне цепочки — null.
func get_form_def(base_id: StringName, idx: int) -> ClassDefinition:
	var chain := get_form_chain(base_id)
	if idx >= 0 and idx < chain.size():
		return chain[idx]
	return null

## Следующая форма для эволюции (или null, если форма финальная).
func get_next_form(base_id: StringName, current_form: int) -> ClassDefinition:
	return get_form_def(base_id, current_form + 1)

## Разрешён ли класс для выбора в лобби (реализован и является формой I).
func is_selectable(id: StringName) -> bool:
	var def := all_by_id.get(id, null) as ClassDefinition
	return def != null and def.form_index == 0 and def.implemented

func get_default_id() -> StringName:
	return order[0] if order.size() > 0 else &"berserk"

## Реализованные базовые классы для лобби/UI.
func get_all() -> Array[ClassDefinition]:
	var result: Array[ClassDefinition] = []
	for id in order:
		result.append(definitions[id])
	return result

## Все 24 определения (включая формы II/III и заглушки) — для тестов/инструментов.
func get_all_defs() -> Array[ClassDefinition]:
	var result: Array[ClassDefinition] = []
	var ids := all_by_id.keys()
	ids.sort()
	for id in ids:
		result.append(all_by_id[id])
	return result
