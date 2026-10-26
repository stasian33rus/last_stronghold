extends CanvasLayer
## HUD вертикального среза: здоровье и резонанс Гигачада, здоровье локального игрока,
## список игроков, состояние волны, анонсы и экран результата (ТЗ §18).
## Всё читается из РЕАЛЬНОГО состояния матча (опрос узлов + события Events),
## никаких декоративных заглушек.

var _pawn: PlayerPawn
var _giga: GigaChad
var _mc: MatchController
var _sys: ProgressionSystem
var _pawn_search_acc: float = 0.0
var _rows: Dictionary = {} ## peer_id -> {"box": HBoxContainer, "fill": ColorRect, "label": Label}
var _ended_shown := false
var _offer_ids: Array = []
var _offer_deadline_msec: int = 0
var _buffs_shown_hash: int = 0
var _local_prog: Dictionary = {}
var _local_prog_level: int = 0
var rescue_label: Label ## Этап 4.1: прогресс спасения союзника локальным игроком
var boss_back: ColorRect ## Этап 5.1: полоса здоровья босса акта I
var boss_fill: ColorRect
var boss_label: Label
var convoy_back: ColorRect ## Этап 5.2: здоровье транспорта кортежа (акт II)
var convoy_fill: ColorRect
var convoy_label: Label
var convoy_prog_back: ColorRect ## прогресс маршрута кортежа
var convoy_prog_fill: ColorRect
var repair_label: Label ## подсказка/прогресс ремонта для локального игрока

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
@onready var level_badge: Label = $BottomLeft/XpRow/LevelBadge
@onready var xp_back: ColorRect = $BottomLeft/XpRow/XpBack
@onready var xp_fill: ColorRect = $BottomLeft/XpRow/XpBack/Fill
@onready var coins_label: Label = $BottomLeft/XpRow/CoinsLabel
@onready var buff_box: HBoxContainer = $BuffBox
@onready var upgrades_label: Label = $UpgradesLabel
@onready var toast_box: VBoxContainer = $ToastBox
@onready var upgrade_panel: Control = $UpgradePanel
@onready var offer_title: Label = $UpgradePanel/Center/OfferTitle
@onready var cards_box: HBoxContainer = $UpgradePanel/Center/CardsBox
@onready var offer_timer_back: ColorRect = $UpgradePanel/Center/TimerBack
@onready var offer_timer_fill: ColorRect = $UpgradePanel/Center/TimerBack/Fill
@onready var shop_panel: PanelContainer = $ShopPanel
@onready var shop_title: Label = $ShopPanel/VBox/ShopTitle
@onready var shop_timer: Label = $ShopPanel/VBox/ShopTimer
@onready var shop_items_box: VBoxContainer = $ShopPanel/VBox/ItemsBox
@onready var ready_check: CheckButton = $ShopPanel/VBox/ReadyRow/ReadyCheck
@onready var ready_state_label: Label = $ShopPanel/VBox/ReadyRow/ReadyStateLabel

var debug_label: Label

func _ready() -> void:
	result_panel.visible = false
	## Техническая диагностика (FPS/рендерер/драйвер) — СКРЫТА в обычном режиме,
	## включается клавишей F3 (действие debug_overlay).
	debug_label = Label.new()
	debug_label.name = "DebugLabel"
	debug_label.visible = false
	debug_label.add_theme_font_size_override("font_size", 14)
	debug_label.add_theme_color_override("font_color", Color(0.7, 1.0, 0.7))
	debug_label.anchors_preset = 5 ## центр-верх
	debug_label.offset_top = 64.0
	debug_label.offset_bottom = 110.0
	add_child(debug_label)
	rescue_label = Label.new()
	rescue_label.name = "RescueLabel"
	rescue_label.visible = false
	rescue_label.add_theme_font_size_override("font_size", 16)
	rescue_label.add_theme_color_override("font_color", Color(0.55, 1.0, 0.7))
	local_state_label.get_parent().add_child(rescue_label)
	## Полоса босса: под полосой Гигачада, видна только пока босс жив.
	boss_back = ColorRect.new()
	boss_back.name = "BossHealthBack"
	boss_back.color = Color(0.15, 0.13, 0.1, 0.85)
	boss_back.size = Vector2(420.0, 14.0)
	boss_back.position = Vector2(giga_health_back.position.x - 60.0, giga_health_back.position.y + giga_health_back.size.y + 6.0)
	boss_back.visible = false
	giga_health_back.get_parent().add_child(boss_back)
	boss_fill = ColorRect.new()
	boss_fill.name = "Fill"
	boss_fill.color = Color(1.0, 0.8, 0.25)
	boss_fill.size = Vector2(420.0, 14.0)
	boss_back.add_child(boss_fill)
	boss_label = Label.new()
	boss_label.name = "BossLabel"
	boss_label.add_theme_font_size_override("font_size", 13)
	boss_label.position = Vector2(0.0, -18.0)
	boss_back.add_child(boss_label)
	## Полосы кортежа (Этап 5.2): тот же слот, что у полосы босса — акты
	## не показываются одновременно. HP + тонкая полоса прогресса маршрута.
	convoy_back = ColorRect.new()
	convoy_back.name = "ConvoyHealthBack"
	convoy_back.color = Color(0.08, 0.15, 0.15, 0.85)
	convoy_back.size = Vector2(420.0, 14.0)
	convoy_back.position = boss_back.position
	convoy_back.visible = false
	giga_health_back.get_parent().add_child(convoy_back)
	convoy_fill = ColorRect.new()
	convoy_fill.name = "Fill"
	convoy_fill.color = Color(0.35, 1.0, 0.85)
	convoy_fill.size = Vector2(420.0, 14.0)
	convoy_back.add_child(convoy_fill)
	convoy_label = Label.new()
	convoy_label.name = "ConvoyLabel"
	convoy_label.add_theme_font_size_override("font_size", 13)
	convoy_label.position = Vector2(0.0, -18.0)
	convoy_back.add_child(convoy_label)
	convoy_prog_back = ColorRect.new()
	convoy_prog_back.name = "ConvoyProgressBack"
	convoy_prog_back.color = Color(0.12, 0.12, 0.16, 0.85)
	convoy_prog_back.size = Vector2(420.0, 5.0)
	convoy_prog_back.position = Vector2(0.0, 17.0)
	convoy_back.add_child(convoy_prog_back)
	convoy_prog_fill = ColorRect.new()
	convoy_prog_fill.name = "Fill"
	convoy_prog_fill.color = Color(1.0, 0.8, 0.3)
	convoy_prog_fill.size = Vector2(0.0, 5.0)
	convoy_prog_back.add_child(convoy_prog_fill)
	repair_label = Label.new()
	repair_label.name = "RepairLabel"
	repair_label.visible = false
	repair_label.add_theme_font_size_override("font_size", 16)
	repair_label.add_theme_color_override("font_color", Color(0.55, 0.95, 1.0))
	local_state_label.get_parent().add_child(repair_label)
	upgrade_panel.visible = false
	shop_panel.visible = false
	ready_check.toggled.connect(_on_ready_toggled)
	Events.wave_ready_state_changed.connect(_on_wave_ready_states)
	announcement_label.modulate.a = 0.0
	rematch_button.pressed.connect(_on_rematch)
	menu_button.pressed.connect(_on_menu)
	Events.match_ended.connect(_on_match_ended)
	Events.local_announcement.connect(_show_announcement)
	Events.local_toast.connect(_on_toast)
	Events.upgrade_offer_opened.connect(_on_offer_opened)
	Events.upgrade_offer_closed.connect(_on_offer_closed)
	Events.progression_updated.connect(func(payload: Dictionary) -> void: _local_prog = payload)
	Events.shop_result_msg.connect(_on_shop_result)
	Events.unit_evolved.connect(_on_unit_evolved)
	set_process(true)
	var mcs := get_tree().get_nodes_in_group("match_controller")
	_mc = mcs[0] if mcs.size() > 0 else null
	var gigas := get_tree().get_nodes_in_group("gigachad")
	_giga = gigas[0] if gigas.size() > 0 else null

var _debug_acc := 0.0

func _update_debug(delta: float) -> void:
	if debug_label == null or not debug_label.visible:
		return
	_debug_acc += delta
	if _debug_acc < 0.5:
		return
	_debug_acc = 0.0
	debug_label.text = "FPS: %d | %s | %s | %dx%d" % [
		Engine.get_frames_per_second(),
		str(ProjectSettings.get_setting("rendering/renderer/rendering_method")),
		RenderingServer.get_current_rendering_driver_name(),
		get_viewport().get_visible_rect().size.x,
		get_viewport().get_visible_rect().size.y]

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("debug_overlay"):
		debug_label.visible = not debug_label.visible
		return
	if upgrade_panel.visible:
		if event.is_action_pressed("choose_1"):
			_request_offer_choice(0)
			return
		if event.is_action_pressed("choose_2"):
			_request_offer_choice(1)
			return
		if event.is_action_pressed("choose_3"):
			_request_offer_choice(2)
			return
	if event.is_action_pressed("menu_cancel"):
		_on_menu()

func _process(delta: float) -> void:
	_update_debug(delta)
	_find_local_pawn(delta)
	_find_system()
	_update_giga()
	_update_local()
	_update_boss()
	_update_convoy()
	_update_wave()
	_update_players_list()
	_update_progression()
	_update_offer_timer()
	_update_shop()

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
			_refresh_local_name()
			return

func _refresh_local_name() -> void:
	if _pawn == null or not is_instance_valid(_pawn):
		return
	local_name_label.text = "%s — %s" % [_pawn.player_name, _display_class(_pawn)]
	if _local_prog_level > 0:
		local_name_label.text += " · Ур. %d" % _local_prog_level

## Имя класса с текущей формой эволюции (форма I — просто класс).
func _display_class(pawn: PlayerPawn) -> String:
	var base := Classes.get_class_def(pawn.class_id)
	var base_name := base.display_name if base != null else String(pawn.class_id)
	if pawn.form_index > 0 and pawn.class_def != null:
		return "%s · %s" % [base_name, pawn.class_def.display_name]
	return base_name

## Эволюция локальной пешки — мгновенно обновить подпись (без ожидания payload).
func _on_unit_evolved(unit: Node, _form_index: int, _form_name: String) -> void:
	if unit == _pawn:
		_refresh_local_name()

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
		local_state_label.text = "ВЫ ПОВЕРЖЕНЫ — %.1f с до эвакуации; союзник рядом поднимет вас (R)" % maxf(_pawn.sync_down_timer, 0.0)
		local_state_label.modulate = Color(1.0, 0.5, 0.5)
	else:
		local_state_label.text = ""
	_update_rescue_label()

## Этап 5.1: полоса босса (серверное здоровье реплицируется BodySync-снапшотами).
func _update_boss() -> void:
	if boss_back == null:
		return
	var boss: BossAct1 = null
	for n in get_tree().get_nodes_in_group("boss_unit"):
		boss = n as BossAct1
		if boss != null:
			break
	var show := boss != null and is_instance_valid(boss) and not boss.health.is_dead
	boss_back.visible = show
	if not show:
		return
	boss_fill.offset_right = boss_back.size.x * boss.health.health_factor()
	boss_label.text = "%s — фаза %d/3" % [boss.def.display_name, boss.phase_index]

## Этап 5.2: полосы кортежа (акт II). Читают РЕПЛИЦИРОВАННОЕ состояние
## транспорта (BodySync-снапшоты) — как полоса босса в акте I.
func _update_convoy() -> void:
	if convoy_back == null:
		return
	var t := _convoy()
	var show := t != null and is_instance_valid(t) and not t.health.is_dead
	convoy_back.visible = show
	if not show:
		if repair_label != null:
			repair_label.visible = false
		return
	convoy_fill.offset_right = convoy_back.size.x * t.health.health_factor()
	convoy_prog_fill.size.x = convoy_prog_back.size.x * t.progress_factor()
	convoy_label.text = "КОРТЕЖ %d/%d · маршрут %d%% · ремонт: %d" % [
		int(ceil(t.health.health)), int(t.health.max_health),
		int(t.progress_factor() * 100.0), t.repair_charges]
	_update_repair_label(t)

func _update_repair_label(t: ConvoyTransport) -> void:
	if repair_label == null:
		return
	var near := _pawn != null and is_instance_valid(_pawn) \
		and not _pawn.health.is_dead and _pawn.state != PlayerPawn.State.DOWN \
		and _pawn.global_position.distance_to(t.global_position) <= ConvoyTransport.REPAIR_RADIUS + 0.8
	repair_label.visible = near
	if not near:
		return
	if t.health.health >= t.health.max_health:
		repair_label.text = "Кортеж цел"
	elif t.repair_charges <= 0:
		repair_label.text = "Ремонт: заряды исчерпаны"
	elif t.repair_progress > 0.0:
		repair_label.text = "Ремонт кортежа: %d%% — удерживайте R" % int(t.repair_progress * 100.0)
	else:
		repair_label.text = "Ремонт кортежа: удерживайте R (+%d HP, зарядов: %d)" % [int(t.repair_amount), t.repair_charges]

func _convoy() -> ConvoyTransport:
	for n in get_tree().get_nodes_in_group("convoy_transport"):
		var t := n as ConvoyTransport
		if t != null:
			return t
	return null

## Этап 4.1: локальный игрок как спасатель — прогресс канала на цели.
func _update_rescue_label() -> void:
	if rescue_label == null:
		return
	var target: PlayerPawn = null
	for n in get_tree().get_nodes_in_group("player_pawns"):
		var p := n as PlayerPawn
		if p != null and p.sync_rescuer_peer == Net.my_id() and p.state == PlayerPawn.State.DOWN:
			target = p
			break
	rescue_label.visible = target != null
	if target != null:
		rescue_label.text = "Спасение %s: %d%% — удерживайте R" % [target.player_name, int(target.sync_rescue_progress * 100.0)]

func _update_wave() -> void:
	if _mc == null:
		return
	match _mc.phase:
		MatchController.Phase.COUNTDOWN:
			var n := int(ceil(_mc.countdown))
			wave_label.text = ("ПРИГОТОВЬТЕСЬ: %d" % n) if n > 0 else "В БОЙ!"
			enemies_label.text = ""
		MatchController.Phase.FIGHT:
			var convoy := _convoy()
			if convoy != null:
				## Акт II: вместо номера волны — прогресс маршрута кортежа.
				wave_label.text = "СОПРОВОЖДЕНИЕ КОРТЕЖА — %d%% маршрута" % int(convoy.progress_factor() * 100.0)
			else:
				wave_label.text = "ВОЛНА %d / %d" % [maxi(1, _mc.wave_number), _mc.waves_total]
			enemies_label.text = "Противников: %d" % _mc.enemies_left_total
		MatchController.Phase.WAVE_COMPLETE:
			wave_label.text = "ВОЛНА %d ОТБИТА!" % maxi(1, _mc.wave_number)
			enemies_label.text = ""
		MatchController.Phase.INTERMISSION:
			wave_label.text = "МЕЖДУ ВОЛНАМИ"
			enemies_label.text = ""
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
	## Окно смены сцены (реванш стартует из этого же сигнала): вне дерева HUD
	## уже не обслуживает экран результата — его строит HUD новой сцены.
	if not is_inside_tree():
		return
	_ended_shown = true
	if upgrade_panel.visible:
		_on_offer_closed()
	result_title.text = "ПОБЕДА!" if victory else "ПОРАЖЕНИЕ"
	result_title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3) if victory else Color(1.0, 0.35, 0.4))
	var lines: Array[String] = []
	var convoy := _convoy()
	if victory:
		lines.append("Кортеж прибыл к точке эвакуации! Источник спасён." if convoy != null else "Источник отстоян! Гигачад гордится вами.")
	else:
		if convoy != null and convoy.health.is_dead:
			lines.append("Кортеж уничтожен... Орден Гламура забрал источник.")
		elif convoy != null:
			lines.append("Груз Гигачада пал... Кортеж не доехал.")
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


# ------------------------------------------------------------------ прогрессия (Этап 2)

func _find_system() -> void:
	if _sys != null and is_instance_valid(_sys):
		return
	var ps := get_tree().get_nodes_in_group("progression_system")
	_sys = ps[0] if ps.size() > 0 else null

func _update_progression() -> void:
	if _sys == null:
		return
	var payload: Dictionary = _sys.local_state
	if payload.is_empty():
		payload = _local_prog
	if payload.is_empty():
		return
	var level := int(payload.get("level", 1))
	var xp := int(payload.get("xp", 0))
	var xp_need := maxi(1, int(payload.get("xp_need", 100)))
	level_badge.text = "УР %d" % level
	xp_fill.offset_right = xp_back.size.x * clampf(float(xp) / float(xp_need), 0.0, 1.0)
	coins_label.text = "Монеты: %d" % int(payload.get("coins", 0))
	_update_upgrades_list(payload)
	_local_prog_level = level
	if _pawn != null and is_instance_valid(_pawn):
		local_name_label.text = "%s — %s · Ур. %d" % [_pawn.player_name, _display_class(_pawn), level]
	_update_buffs(payload)

func _update_buffs(payload: Dictionary) -> void:
	var buffs: Array = payload.get("buffs", [])
	var h := buffs.hash()
	if h == _buffs_shown_hash:
		return
	_buffs_shown_hash = h
	for child in buff_box.get_children():
		child.queue_free()
	for b in buffs:
		var label := Label.new()
		var eff := int(b.get("effect", -1))
		var value := float(b.get("value", 0.0))
		var remaining := float(b.get("remaining", -1.0))
		var time_text := "постоянно" if remaining < 0.0 else "%.0f с" % remaining
		match eff:
			ShopItemDefinition.Effect.DAMAGE_BUFF_TIMED:
				label.text = "Урон +%d%% (%s)" % [int(value * 100.0), time_text]
				label.add_theme_color_override("font_color", Color(1.0, 0.65, 0.4))
			ShopItemDefinition.Effect.DAMAGE_TAKEN_PERM:
				label.text = "Защита +%d%% (%s)" % [int(value * 100.0), time_text]
				label.add_theme_color_override("font_color", Color(0.55, 0.8, 1.0))
			ShopItemDefinition.Effect.LIFESTEAL_ON_KILL:
				label.text = "Вампиризм +%d%%" % int(value * 100.0)
				label.add_theme_color_override("font_color", Color(1.0, 0.5, 0.65))
			_:
				label.text = "Эффект"
		label.add_theme_font_size_override("font_size", 14)
		buff_box.add_child(label)

func _update_offer_timer() -> void:
	if not upgrade_panel.visible:
		return
	var now := Time.get_ticks_msec()
	var left := maxi(0, _offer_deadline_msec - now)
	var total := 1.0
	if _sys != null and _sys.balance != null:
		total = maxf(0.001, _sys.balance.choice_time * 1000.0)
	offer_timer_fill.offset_right = offer_timer_back.size.x * clampf(float(left) / total, 0.0, 1.0)

func _on_offer_opened(ids: Array, deadline_msec: int) -> void:
	_offer_ids = ids
	_offer_deadline_msec = deadline_msec
	_build_offer_cards()
	upgrade_panel.visible = true
	var level := int(_sys.local_state.get("level", 1)) if _sys != null else 1
	offer_title.text = "УРОВЕНЬ %d — ВЫБЕРИТЕ УЛУЧШЕНИЕ" % level
	Sfx.play("count_go", -8.0, 1.2)

func _on_offer_closed() -> void:
	upgrade_panel.visible = false
	for child in cards_box.get_children():
		child.queue_free()
	_offer_ids = []

func _build_offer_cards() -> void:
	for child in cards_box.get_children():
		child.queue_free()
	var taken: Dictionary = {}
	if _sys != null:
		taken = _sys.local_state.get("upgrades", {})
	for i in _offer_ids.size():
		var def := Content.get_upgrade(_offer_ids[i])
		if def == null:
			continue
		cards_box.add_child(_make_card(def, i, int(taken.get(def.id, 0))))

func _make_card(def: UpgradeDefinition, index: int, taken_level: int) -> Control:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(250, 330)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.07, 0.16, 0.96)
	style.border_color = UpgradeDefinition.rarity_color(def.rarity)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(12.0)
	card.add_theme_stylebox_override("panel", style)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	card.add_child(vbox)

	var glyph := Label.new()
	glyph.text = def.glyph
	glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	glyph.add_theme_font_size_override("font_size", 46)
	glyph.add_theme_color_override("font_color", def.color)
	vbox.add_child(glyph)

	var title := Label.new()
	title.text = def.display_name
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	vbox.add_child(title)

	var rarity := Label.new()
	rarity.text = UpgradeDefinition.rarity_name(def.rarity)
	rarity.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rarity.add_theme_font_size_override("font_size", 13)
	rarity.add_theme_color_override("font_color", UpgradeDefinition.rarity_color(def.rarity))
	vbox.add_child(rarity)

	var desc := Label.new()
	desc.text = def.description
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size = Vector2(210, 90)
	desc.add_theme_font_size_override("font_size", 14)
	vbox.add_child(desc)

	var level_label := Label.new()
	level_label.text = "Уровень: %d → %d из %d" % [taken_level, taken_level + 1, def.max_level]
	level_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	level_label.add_theme_font_size_override("font_size", 13)
	level_label.add_theme_color_override("font_color", Color(0.75, 0.78, 0.9))
	vbox.add_child(level_label)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(spacer)

	var button := Button.new()
	button.text = "Взять  [%d]" % (index + 1)
	button.add_theme_font_size_override("font_size", 17)
	button.pressed.connect(_request_offer_choice.bind(index))
	vbox.add_child(button)
	return card

func _request_offer_choice(index: int) -> void:
	if index < 0 or index >= _offer_ids.size():
		return
	if _sys == null:
		_find_system()
	if _sys == null:
		return
	Sfx.play("ui")
	_sys.request_choose(_offer_ids[index])

# ------------------------------------------------------------------ тосты

func _on_toast(text: String, kind: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 15)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	match kind:
		"xp":
			label.add_theme_color_override("font_color", Color(0.75, 0.6, 1.0))
		"coins":
			label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.35))
		"levelup":
			label.add_theme_color_override("font_color", Color(0.45, 1.0, 0.75))
			Sfx.play("count_go", -6.0, 1.4)
		"shop":
			label.add_theme_color_override("font_color", Color(0.5, 0.95, 1.0))
		_:
			label.add_theme_color_override("font_color", Color(0.85, 0.87, 0.95))
	toast_box.add_child(label)
	while toast_box.get_child_count() > 5:
		var oldest := toast_box.get_child(0)
		toast_box.remove_child(oldest)
		oldest.queue_free()
	var tween := create_tween()
	tween.tween_interval(2.2)
	tween.tween_property(label, "modulate:a", 0.0, 0.6)
	tween.tween_callback(label.queue_free)


func _on_shop_result(ok: bool, text: String) -> void:
	_on_toast(text, "shop" if ok else "info")
	Sfx.play("ui" if ok else "hurt", -10.0)


# ------------------------------------------------------------------ магазин (Этап 2)

var _shop_rows: Dictionary = {} ## item_id -> {"button": Button, "price_label": Label}
var _shop_built := false
var _ready_map: Dictionary = {}

func _on_ready_toggled(value: bool) -> void:
	if _sys == null:
		_find_system()
	if _sys != null:
		Sfx.play("ui")
		_sys.request_wave_ready(value)

func _on_wave_ready_states(states: Dictionary) -> void:
	_ready_map = states
	var ready_count := 0
	for v in states.values():
		if v:
			ready_count += 1
	ready_state_label.text = "Готовы: %d / %d" % [ready_count, states.size()]

func _update_shop() -> void:
	if _mc == null:
		return
	var intermission := _mc.phase == MatchController.Phase.INTERMISSION
	shop_panel.visible = intermission and not _ended_shown
	if not intermission:
		return
	if not _shop_built:
		_build_shop_items()
		shop_built_guard()
	shop_title.text = "МАГАЗИН ИСТОЧНИКА — волна %d отбита" % maxi(1, _mc.wave_number)
	shop_timer.text = "Следующая волна через: %d с" % int(ceil(_mc.countdown))
	## Доступность покупок по текущему балансу (баланс — из серверного зеркала).
	var coins := 0
	var wave_ready := false
	if _sys != null:
		coins = int(_sys.local_state.get("coins", 0))
		wave_ready = bool(_sys.local_state.get("wave_ready", false))
	ready_check.set_pressed_no_signal(wave_ready)
	for item_id in _shop_rows.keys():
		var row: Dictionary = _shop_rows[item_id]
		var def := Content.get_shop_item(item_id)
		if def != null:
			(row["button"] as Button).disabled = coins < def.price

func shop_built_guard() -> void:
	_shop_built = true

func _build_shop_items() -> void:
	for child in shop_items_box.get_children():
		child.queue_free()
	_shop_rows.clear()
	for def in Content.all_shop_items():
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		var glyph := Label.new()
		glyph.text = def.glyph
		glyph.add_theme_font_size_override("font_size", 22)
		glyph.add_theme_color_override("font_color", def.color)
		glyph.custom_minimum_size = Vector2(30, 0)
		row.add_child(glyph)
		var info := VBoxContainer.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var name_label := Label.new()
		name_label.text = def.display_name
		name_label.add_theme_font_size_override("font_size", 15)
		info.add_child(name_label)
		var desc_label := Label.new()
		desc_label.text = def.description
		desc_label.add_theme_font_size_override("font_size", 12)
		desc_label.add_theme_color_override("font_color", Color(0.72, 0.74, 0.85))
		desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		info.add_child(desc_label)
		row.add_child(info)
		var price_label := Label.new()
		price_label.text = "%d" % def.price
		price_label.add_theme_font_size_override("font_size", 16)
		price_label.add_theme_color_override("font_color", Color(1, 0.85, 0.35))
		price_label.custom_minimum_size = Vector2(40, 0)
		row.add_child(price_label)
		var buy := Button.new()
		buy.text = "Купить"
		buy.add_theme_font_size_override("font_size", 14)
		var item_id: StringName = def.id
		buy.pressed.connect(func() -> void:
			if _sys != null:
				Sfx.play("ui")
				_sys.request_buy(item_id)
		)
		row.add_child(buy)
		shop_items_box.add_child(row)
		_shop_rows[def.id] = {"button": buy, "price_label": price_label}


var _upgrades_hash: int = -1

## Список взятых улучшений с уровнями (компактно, без перегрузки HUD).
func _update_upgrades_list(payload: Dictionary) -> void:
	var upgrades: Dictionary = payload.get("upgrades", {})
	var h := upgrades.hash()
	if h == _upgrades_hash:
		return
	_upgrades_hash = h
	var parts: Array[String] = []
	for id in upgrades.keys():
		var def := Content.get_upgrade(id)
		if def != null:
			parts.append("%s×%d" % [def.display_name, int(upgrades[id])])
	if parts.is_empty():
		upgrades_label.text = ""
	else:
		upgrades_label.text = "Улучшения: " + " · ".join(parts)
