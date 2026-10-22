extends CanvasLayer
## HUD вертикального среза: здоровье и резонанс Гигачада, здоровье локального игрока,
## список игроков, состояние волны, анонсы и экран результата (ТЗ §18).
## Всё читается из РЕАЛЬНОГО состояния матча (опрос узлов + события Events),
## никаких декоративных заглушек.

var _pawn: PlayerPawn
var _giga: GigaChad
var _mc: MatchController
var _pawn_search_acc: float = 0.0
var _rows: Dictionary = {} ## peer_id -> {"box": HBoxContainer, "fill": ColorRect, "label": Label}
var _ended_shown := false

@onready var giga_label: Label = $TopCenter/GigaLabel
@onready var giga_health_back: ColorRect = $TopCenter/GigaHealthBack
@onready var giga_health_fill: ColorRect = $TopCenter/GigaHealthBack/Fill
@onready var giga_hp_text: Label = $TopCenter/GigaHealthBack/HpText
@onready var giga_res_back: ColorRect = $TopCenter/GigaResBack
@onready var giga_res_fill: ColorRect = $TopCenter/GigaResBack/Fill
@onready var wave_label: Label = $WavePanel/WaveLabel
@onready var enemies_label: Label = $WavePanel/EnemiesLabel
@onready var time_label: Label = $WavePanel/TimeLabel
@onready var players_box: VBoxContainer = $PlayersPanel
@onready var local_name_label: Label = $BottomLeft/LocalNameLabel
@onready var local_health_back: ColorRect = $BottomLeft/LocalHealthBack
@onready var local_health_fill: ColorRect = $BottomLeft/LocalHealthBack/Fill
@onready var local_state_label: Label = $BottomLeft/LocalStateLabel
@onready var announcement_label: Label = $AnnouncementLabel
@onready var result_panel: PanelContainer = $ResultPanel
@onready var result_title: Label = $ResultPanel/VBox/ResultTitle
@onready var result_stats: Label = $ResultPanel/VBox/ResultStats
@onready var rematch_button: Button = $ResultPanel/VBox/Buttons/RematchButton
@onready var menu_button: Button = $ResultPanel/VBox/Buttons/MenuButton

func _ready() -> void:
	result_panel.visible = false
	announcement_label.modulate.a = 0.0
	rematch_button.pressed.connect(_on_rematch)
	menu_button.pressed.connect(_on_menu)
	Events.match_ended.connect(_on_match_ended)
	Events.local_announcement.connect(_show_announcement)
	var mcs := get_tree().get_nodes_in_group("match_controller")
	_mc = mcs[0] if mcs.size() > 0 else null
	var gigas := get_tree().get_nodes_in_group("gigachad")
	_giga = gigas[0] if gigas.size() > 0 else null

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("menu_cancel"):
		_on_menu()

func _process(delta: float) -> void:
	_find_local_pawn(delta)
	_update_giga()
	_update_local()
	_update_wave()
	_update_players_list()

func _find_local_pawn(delta: float) -> void:
	if _pawn != null and is_instance_valid(_pawn):
		return
	_pawn_search_acc -= delta
	if _pawn_search_acc > 0.0:
		return
	_pawn_search_acc = 0.25
	for candidate in get_tree().get_nodes_in_group("player_pawns"):
		if candidate is PlayerPawn and candidate.is_local_pawn():
			_pawn = candidate
			local_name_label.text = "%s — %s" % [_pawn.player_name, _display_class(_pawn.class_id)]
			return

func _display_class(class_id: StringName) -> String:
	var def := Classes.get_class_def(class_id)
	return def.display_name if def != null else String(class_id)

func _update_giga() -> void:
	if _giga == null or not is_instance_valid(_giga):
		giga_label.text = "ГИГАЧАД — УТРАЧЕН"
		giga_health_fill.offset_right = 0.0
		return
	var h := _giga.health
	giga_health_fill.offset_right = giga_health_back.size.x * h.health_factor()
	giga_hp_text.text = "%d / %d" % [int(ceil(h.health)), int(h.max_health)]
	giga_res_fill.offset_right = giga_res_back.size.x * clampf(_giga.resonance / 100.0, 0.0, 1.0)
	giga_label.text = "ГИГАЧАД — ПОСЛЕДНИЙ ИСТОЧНИК" if not h.is_dead else "ГИГАЧАД ПОВЕРЖЕН"

func _update_local() -> void:
	if _pawn == null or not is_instance_valid(_pawn):
		return
	var h := _pawn.health
	local_health_fill.offset_right = local_health_back.size.x * h.health_factor()
	if _pawn.state == PlayerPawn.State.DOWN:
		local_state_label.text = "ВЫ ПОВЕРЖЕНЫ — источник возрождает вас..."
		local_state_label.modulate = Color(1.0, 0.5, 0.5)
	else:
		local_state_label.text = ""

func _update_wave() -> void:
	if _mc == null:
		return
	match _mc.phase:
		MatchController.Phase.COUNTDOWN:
			var n := int(ceil(_mc.countdown))
			wave_label.text = ("ПРИГОТОВЬТЕСЬ: %d" % n) if n > 0 else "В БОЙ!"
			enemies_label.text = ""
		MatchController.Phase.FIGHT:
			wave_label.text = "ВОЛНА %d" % maxi(1, _mc.wave_number)
			enemies_label.text = "Противников: %d" % _mc.enemies_left_total
		MatchController.Phase.VICTORY:
			wave_label.text = "ВОЛНА ОТБИТА"
			enemies_label.text = ""
		MatchController.Phase.DEFEAT:
			wave_label.text = "—"
			enemies_label.text = ""
		_:
			wave_label.text = "ЗАГРУЗКА..."
			enemies_label.text = ""
	time_label.text = "Время: %02d:%02d" % [int(_mc.match_time) / 60, int(_mc.match_time) % 60]

func _update_players_list() -> void:
	## Строки списка игроков: имя + мини-полоска здоровья. Удаление строк отключившихся.
	var alive_ids := {}
	for candidate in get_tree().get_nodes_in_group("player_pawns"):
		var p := candidate as PlayerPawn
		if p == null:
			continue
		alive_ids[p.owner_peer] = true
		if not _rows.has(p.owner_peer):
			_rows[p.owner_peer] = _make_row(p)
		var row: Dictionary = _rows[p.owner_peer]
		var factor := p.health.health_factor()
		(row["fill"] as ColorRect).offset_right = 120.0 * factor
		var suffix := "  (повержена)" if p.state == PlayerPawn.State.DOWN else ""
		(row["label"] as Label).text = "%s%s" % [p.player_name, suffix]
	for peer_id in _rows.keys():
		if not alive_ids.has(peer_id):
			(_rows[peer_id]["box"] as Control).queue_free()
			_rows.erase(peer_id)

func _make_row(p: PlayerPawn) -> Dictionary:
	var box := HBoxContainer.new()
	var label := Label.new()
	label.text = p.player_name
	label.add_theme_font_size_override("font_size", 14)
	label.custom_minimum_size = Vector2(130, 0)
	var back := ColorRect.new()
	back.color = Color(0.08, 0.07, 0.12, 0.85)
	back.custom_minimum_size = Vector2(120, 10)
	back.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var fill := ColorRect.new()
	fill.color = Color(0.35, 0.85, 1.0)
	fill.anchor_bottom = 1.0
	fill.offset_right = 120.0
	back.add_child(fill)
	box.add_child(label)
	box.add_child(back)
	players_box.add_child(box)
	return {"box": box, "label": label, "fill": fill}

func _show_announcement(text: String, duration: float) -> void:
	announcement_label.text = text
	announcement_label.modulate.a = 1.0
	var tween := create_tween()
	tween.tween_interval(maxf(0.2, duration - 0.35))
	tween.tween_property(announcement_label, "modulate:a", 0.0, 0.35)

func _on_match_ended(victory: bool, stats: Dictionary) -> void:
	if _ended_shown:
		return
	_ended_shown = true
	result_title.text = "ПОБЕДА!" if victory else "ПОРАЖЕНИЕ"
	result_title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3) if victory else Color(1.0, 0.35, 0.4))
	var lines: Array[String] = []
	if victory:
		lines.append("Источник отстоян! Гигачад гордится вами.")
	else:
		lines.append("Гигачад пал... Орден Гламура ликует.")
	lines.append("")
	for peer_id in stats.keys():
		var s: Dictionary = stats[peer_id]
		lines.append("%s — убийств: %d, урон: %d, падений: %d" % [
			str(s.get("name", "?")), int(s.get("kills", 0)), int(s.get("damage", 0)), int(s.get("downs", 0)),
		])
	lines.append("")
	if _mc != null:
		lines.append("Время матча: %02d:%02d" % [int(_mc.match_time) / 60, int(_mc.match_time) % 60])
	result_stats.text = "\n".join(lines)
	rematch_button.visible = Net.is_server() and Net.is_online()
	result_panel.visible = true
	Sfx.play("victory" if victory else "defeat", -2.0)

func _on_rematch() -> void:
	Sfx.play("ui")
	Net.request_rematch()

func _on_menu() -> void:
	Sfx.play("ui")
	Game.leave_match_to_menu()
