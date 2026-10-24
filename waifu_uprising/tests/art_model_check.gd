extends SceneTree
## Контракт-проверка художественной .glb-модели (Этап 3.4):
##   godot --headless --script res://tests/art_model_check.gd
## Сверяет модель с контрактом player_visuals.gd / smoke_runner.gd:
## AnimationPlayer c 8 анимациями, Skeleton3D >= 20 костей, WeaponPivot,
## материалы StandardMaterial3D (для эмиссив-косметики), габарит ~1.7-1.9 м.
## Выход: код 0 = PASS, 1 = FAIL. Печатает [ARTCHECK] строки.

const MODEL := "res://models/valkyrie/valkyrie_art_f1.glb"
const NEED_ANIMS := ["idle", "run", "attack", "skill", "parry", "hit", "death", "transform"]

func _init() -> void:
	var fails: Array[String] = []
	var sc := load(MODEL) as PackedScene
	if sc == null:
		print("[ARTCHECK] FAIL: не грузится ", MODEL)
		quit(1)
		return
	var root := sc.instantiate()
	var ap := root.find_child("AnimationPlayer", true, false) as AnimationPlayer
	var skel := root.find_child("Skeleton3D", true, false) as Skeleton3D
	var wp := root.find_child("WeaponPivot", true, false)
	print("[ARTCHECK] узел: AnimationPlayer=%s Skeleton3D=%s WeaponPivot=%s" % [ap != null, skel != null, wp != null])
	if ap == null or skel == null or wp == null:
		fails.append("nodes")
	if skel != null:
		print("[ARTCHECK] костей: %d" % skel.get_bone_count())
		if skel.get_bone_count() < 20:
			fails.append("bones<20")
	if ap != null:
		var names: Array[String] = []
		for an in ap.get_animation_list():
			names.append(an)
		print("[ARTCHECK] анимации: %s" % ", ".join(names))
		for an in NEED_ANIMS:
			if not ap.has_animation(an):
				fails.append("anim:" + an)
	## материалы: StandardMaterial3D (код косметики дублирует их под emission)
	var out := [true, 0]
	_walk_mats(root, out)
	print("[ARTCHECK] материалов MeshInstance проверено: %d, все StandardMaterial3D: %s" % [out[1], out[0]])
	if not out[0]:
		fails.append("materials")
	## габарит по визуальным узлам
	var bb := [Vector3.INF, Vector3(-INF, -INF, -INF)]
	_walk_bounds(root, bb)
	var mn: Vector3 = bb[0]
	var mx: Vector3 = bb[1]
	var hgt := mx.y - mn.y
	print("[ARTCHECK] габарит Y: %.2f..%.2f => рост %.2f м" % [mn.y, mx.y, hgt])
	if hgt < 1.5 or hgt > 2.0:
		fails.append("height")
	root.free()
	if fails.is_empty():
		print("[ARTCHECK] RESULT=PASS")
		quit(0)
	else:
		print("[ARTCHECK] RESULT=FAIL ", ", ".join(fails))
		quit(1)

func _walk_mats(n: Node, out: Array) -> void:
	for c in n.get_children():
		var mi := c as MeshInstance3D
		if mi != null and mi.mesh != null:
			out[1] = int(out[1]) + 1
			var m := mi.get_active_material(0)
			if m == null or not (m is StandardMaterial3D):
				out[0] = false
		_walk_mats(c, out)

func _walk_bounds(n: Node, bb: Array) -> void:
	for c in n.get_children():
		var mi := c as MeshInstance3D
		var is_body := mi != null and (mi.name.find("Head") >= 0 or mi.name.find("Body") >= 0
				or mi.name.find("Leg") >= 0 or mi.name.find("Arm") >= 0)
		if is_body and mi.mesh != null:
			var aabb := mi.mesh.get_aabb()
			for i in range(8):
				var corner := Vector3(
					aabb.position.x + (aabb.size.x if i & 1 else 0.0),
					aabb.position.y + (aabb.size.y if i & 2 else 0.0),
					aabb.position.z + (aabb.size.z if i & 4 else 0.0))
				var w := mi.global_transform * corner
				bb[0] = (bb[0] as Vector3).min(w)
				bb[1] = (bb[1] as Vector3).max(w)
		_walk_bounds(c, bb)
