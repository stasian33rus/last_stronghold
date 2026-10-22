extends SceneTree
## Probe: NavigationServer3D runtime bake + agent path query + rebake (Godot 4.7.2, headless).
## Запуск: godot --headless --path . -s res://tests/probe_nav.gd
## Ожидание: result=OK (bake через группы, обход препятствия агентом, ускорение пути после re-bake).

func _init() -> void:
	_probe()

func _make_navmesh() -> NavigationMesh:
	var nav_mesh := NavigationMesh.new()
	nav_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nav_mesh.geometry_collision_mask = 1
	nav_mesh.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_GROUPS_EXPLICIT
	nav_mesh.geometry_source_group_name = &"nav_source"
	nav_mesh.cell_size = 0.25
	nav_mesh.cell_height = 0.25
	nav_mesh.agent_radius = 0.4
	nav_mesh.agent_height = 1.5
	nav_mesh.agent_max_climb = 0.5
	return nav_mesh

func _probe() -> void:
	var root_node := Node3D.new()
	get_root().add_child(root_node)

	## Пол 40x40
	var floor_body := StaticBody3D.new()
	var floor_col := CollisionShape3D.new()
	var floor_shape := BoxShape3D.new()
	floor_shape.size = Vector3(40, 0.5, 40)
	floor_col.shape = floor_shape
	floor_col.position = Vector3(0, -0.25, 0)
	floor_body.add_child(floor_col)
	floor_body.add_to_group("nav_source")
	root_node.add_child(floor_body)

	## Колонна-препятствие 2x3x2 в (0, 1.5, -5)
	var pillar := StaticBody3D.new()
	var pcol := CollisionShape3D.new()
	var pshape := BoxShape3D.new()
	pshape.size = Vector3(2, 3, 2)
	pcol.shape = pshape
	pillar.add_child(pcol)
	pillar.position = Vector3(0, 1.5, -5)
	pillar.add_to_group("nav_source")
	root_node.add_child(pillar)

	var region := NavigationRegion3D.new()
	region.navigation_mesh = _make_navmesh()
	root_node.add_child(region)

	await physics_frame
	region.bake_navigation_mesh(false)
	NavigationServer3D.map_force_update(region.get_navigation_map())
	await physics_frame
	var polys := region.navigation_mesh.get_polygon_count()
	print("PROBE polys=", polys)

	## Агент: путь (0,0,0) -> (0,0,-10) должен ОБХОДИТЬ колонну
	var agent_node := Node3D.new()
	agent_node.position = Vector3(0, 0.2, 0)
	root_node.add_child(agent_node)
	var agent := NavigationAgent3D.new()
	agent.path_desired_distance = 0.6
	agent.target_desired_distance = 0.6
	agent_node.add_child(agent)
	await physics_frame
	agent.target_position = Vector3(0, 0.2, -10)
	## Карта навигации синхронизируется асинхронно — опрашиваем до 3 секунд.
	var next1 := Vector3.ZERO
	var detour := false
	for _i in 180:
		await physics_frame
		next1 = agent.get_next_path_position()
		if absf(next1.x) > 0.8:
			detour = true
			break
	print("PROBE next_with_pillar=", next1)

	## Re-bake после «разрушения» колонны (crate destroyed -> проход открыт)
	pcol.set_deferred("disabled", true)
	pillar.remove_from_group("nav_source")
	region.bake_navigation_mesh(false)
	NavigationServer3D.map_force_update(region.get_navigation_map())
	await physics_frame
	await physics_frame
	agent.target_position = Vector3.ZERO
	await physics_frame
	agent.target_position = Vector3(0, 0.2, -10)
	var next2 := Vector3.ZERO
	var rebake_ok := false
	for _i in 180:
		await physics_frame
		next2 = agent.get_next_path_position()
		if absf(next2.x) < 0.6 and next2.z < -4.0:
			rebake_ok = true
			break
	print("PROBE next_after_rebake=", next2)

	## Запрос к недостижимой цели (за стеной) не должен ронять агента
	agent.target_position = Vector3(0, 50.0, -500.0)
	await physics_frame
	var next3: Vector3 = agent.get_next_path_position()
	print("PROBE unreachable next=", next3, " (graceful, no crash)")

	var ok := polys > 0 and detour and rebake_ok
	print("PROBE result=", "OK" if ok else "FAIL", " (polys>0=", polys > 0, " detour=", detour, " rebake=", rebake_ok, ")")
	quit(0 if ok else 1)
