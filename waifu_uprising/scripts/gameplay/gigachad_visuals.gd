extends Node3D
## Визуал Гигачада (Этап 1 — примитивы: гипертрофированная мускулатура, тёмные очки,
## красные плавки — узнаваемый силуэт даже на расстоянии камеры, ТЗ §8).
## Свечение резонанса усиливается по мере накопления энергии.

var giga ## GigaChad (скрипт-владелец)
var _time: float = 0.0
var _pulse_tween: Tween
var _base_scale: Vector3

@onready var glow: OmniLight3D = $Glow
@onready var torso: MeshInstance3D = $Torso
@onready var arm_l: MeshInstance3D = $ArmL
@onready var arm_r: MeshInstance3D = $ArmR

func _ready() -> void:
	giga = get_parent()
	_base_scale = scale

func _process(delta: float) -> void:
	if giga == null or not is_instance_valid(giga):
		return
	_time += delta
	var resonance: float = giga.resonance
	var res_factor: float = clampf(resonance / 100.0, 0.0, 1.0)
	## Дыхание + «флекс» руками; интенсивность растёт с резонансом.
	var breath := sin(_time * (1.6 + res_factor * 2.2))
	scale = _base_scale * (1.0 + breath * (0.008 + res_factor * 0.02))
	if arm_l != null:
		arm_l.rotation.z = 0.55 + breath * (0.05 + res_factor * 0.12)
	if arm_r != null:
		arm_r.rotation.z = -0.55 - breath * (0.05 + res_factor * 0.12)
	if glow != null:
		glow.light_energy = 0.5 + res_factor * 2.5 + sin(_time * 6.0) * 0.15 * res_factor
		var c := Color(0.2, 0.9, 1.0).lerp(Color(1.0, 0.85, 0.3), res_factor * 0.5)
		glow.light_color = c
	## Мёртвое состояние — гаснет.
	if giga.state == giga.State.DOWN:
		if glow != null:
			glow.light_energy = lerpf(glow.light_energy, 0.0, delta * 4.0)
		rotation.x = lerpf(rotation.x, -0.45, delta * 3.0)

## Всплеск при разряде резонанса (вызывается fx_pulse RPC).
func play_pulse() -> void:
	if _pulse_tween != null and _pulse_tween.is_valid():
		_pulse_tween.kill()
	_pulse_tween = create_tween()
	_pulse_tween.tween_property(self, "scale", _base_scale * 1.18, 0.12)
	_pulse_tween.tween_property(self, "scale", _base_scale, 0.4).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)

func flash() -> void:
	if torso == null:
		return
	var mat := torso.get_active_material(0).duplicate() as StandardMaterial3D
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.8, 0.8)
	mat.emission_energy_multiplier = 3.0
	torso.material_override = mat
	var tween := create_tween()
	tween.tween_interval(0.09)
	tween.tween_callback(func() -> void: torso.material_override = null)
