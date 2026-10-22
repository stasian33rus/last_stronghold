class_name VisualFx
extends RefCounted
## Локальные косметические эффекты (ТЗ §13/§16: декор симулируется локально).
## Ничего не меняет в игровой логике — только визуальная обратная связь.

static func hit_flash(unit: Node) -> void:
	var visuals := unit.get_node_or_null(^"Visuals")
	if visuals == null or not visuals.has_method("flash"):
		return
	visuals.flash()

static func damage_number(world_pos: Vector3, amount: float, color: Color) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.current_scene == null:
		return
	var label := Label3D.new()
	label.text = str(int(round(amount)))
	label.font_size = 44
	label.modulate = color
	label.outline_size = 8
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.pixel_size = 0.006
	tree.current_scene.add_child(label)
	label.global_position = world_pos + Vector3(randf_range(-0.3, 0.3), 0.6, randf_range(-0.3, 0.3))
	var tween := tree.create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "global_position", label.global_position + Vector3(0.0, 1.6, 0.0), 0.7)
	tween.tween_property(label, "modulate:a", 0.0, 0.7).set_delay(0.25)
	tween.chain().tween_callback(label.queue_free)

## Зеркальные копии «Багровой богини»: 2 полупрозрачных силуэта повторяют
## взмах (чисто локальная косметика — урон/цели считает сервер). Короткое
## время жизни, автоочистка tween-ом; группа "phantom_fx" для тестов уборки.
static func phantom_slash(unit: Node, color: Color) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.current_scene == null:
		return
	var n3 := unit as Node3D
	if n3 == null:
		return
	for i in 2:
		var ghost := Node3D.new()
		ghost.add_to_group("phantom_fx")
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(color.r, color.g, color.b, 0.32)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = 1.1
		var body := MeshInstance3D.new()
		var cap := CapsuleMesh.new()
		cap.radius = 0.26
		cap.height = 1.4
		body.mesh = cap
		body.material_override = mat
		body.position = Vector3(0.0, 0.9, 0.0)
		ghost.add_child(body)
		var blade := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.06, 0.02, 1.0)
		blade.mesh = bm
		blade.material_override = mat
		blade.position = Vector3(0.45, 1.0, -0.5)
		ghost.add_child(blade)
		tree.current_scene.add_child(ghost)
		ghost.global_position = n3.global_position + Vector3(0.7 - 1.4 * float(i), 0.0, 0.4)
		ghost.rotation.y = n3.rotation.y
		var tween := tree.create_tween()
		tween.set_parallel(true)
		tween.tween_property(ghost, "rotation:y", ghost.rotation.y + (2.2 if i == 0 else -2.2), 0.3)
		tween.tween_property(mat, "albedo_color:a", 0.0, 0.42).set_delay(0.08)
		tween.chain().tween_callback(ghost.queue_free)

static func ring_burst(world_pos: Vector3, color: Color, radius: float = 8.0) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.current_scene == null:
		return
	var mesh := TorusMesh.new()
	mesh.inner_radius = 0.85
	mesh.outer_radius = 1.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 3.0
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	tree.current_scene.add_child(mi)
	mi.global_position = world_pos + Vector3(0.0, 0.3, 0.0)
	mi.scale = Vector3(0.5, 0.5, 0.5)
	var tween := tree.create_tween()
	tween.set_parallel(true)
	tween.tween_property(mi, "scale", Vector3(radius, radius, radius), 0.55).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.55)
	tween.chain().tween_callback(mi.queue_free)
