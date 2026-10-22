class_name BodySync
extends Node
## BodySync — репликация состояния тела: сервер -> клиенты.
## Сервер периодически рассылает снапшоты (unreliable_ordered), клиенты
## интерполируют состояние с задержкой interp_delay (ТЗ §16: «состояние мира
## должно интерполироваться»). Владелец обязан реализовать:
##   get_sync_payload() -> Dictionary
##   apply_sync_payload(payload: Dictionary) -> void
## Соглашение о ключах: "p" (Vector3 позиция), "y" (float рыскание), "v" (Vector3 скорость)
## интерполируются непрерывно; остальные поля — дискретные, берутся из актуального снапшота.

signal payload_applied(payload: Dictionary)

@export var sync_interval: float = 0.05 ## 20 Гц — баланс трафика и плавности (Этап 7: дельта-сжатие).
@export var interp_delay_sec: float = 0.12
@export var warmup_sec: float = 0.3 ## Не слать снапшоты сразу: даём спавну доехать до клиентов.
@export var sync_enabled: bool = true

const BUFFER_MAX: int = 24
const BUFFER_TRIM_MSEC: int = 1000

var _owner3d: Node3D
var _acc: float = 0.0
var _warmup_left: float = 0.0
var _buffer: Array[Dictionary] = [] ## [{t: int(msec), payload: Dictionary}]

func _ready() -> void:
	_owner3d = get_parent() as Node3D
	_warmup_left = warmup_sec
	if _owner3d == null:
		push_error("[BodySync] Родитель должен быть Node3D")
		set_process(false)
		set_physics_process(false)
		return
	if not Net.is_online():
		set_process(false)
		set_physics_process(false)
	elif Net.is_server():
		set_process(false) ## серверу интерполяция не нужна
	else:
		set_physics_process(false) ## клиент только принимает и интерполирует в кадрах отрисовки

func _physics_process(delta: float) -> void:
	## Серверная рассылка снапшотов.
	if not sync_enabled:
		return
	if _warmup_left > 0.0:
		_warmup_left -= delta
		return
	_acc += delta
	if _acc >= sync_interval:
		_acc = 0.0
		if Net.is_online() and _owner3d.has_method("get_sync_payload"):
			_sv_snapshot.rpc(_owner3d.get_sync_payload())

@rpc("authority", "call_remote", "unreliable_ordered")
func _sv_snapshot(payload: Dictionary) -> void:
	if Net.is_server():
		return
	var entry := {"t": Time.get_ticks_msec(), "payload": payload}
	_buffer.append(entry)
	if _buffer.size() > BUFFER_MAX:
		_buffer.pop_front()

func _process(_delta: float) -> void:
	## Клиентская интерполяция — каждый кадр отрисовки.
	if _buffer.is_empty() or _owner3d == null:
		return
	var render_t := Time.get_ticks_msec() - int(interp_delay_sec * 1000.0)
	var a: Dictionary = _buffer[0]
	var b: Dictionary = _buffer[_buffer.size() - 1]
	if render_t <= int(a["t"]):
		b = a
	elif render_t >= int(b["t"]):
		a = b ## экстраполяцию не делаем — держим последний снапшот
	else:
		for i in range(_buffer.size() - 1):
			if int(_buffer[i]["t"]) <= render_t and int(_buffer[i + 1]["t"]) >= render_t:
				a = _buffer[i]
				b = _buffer[i + 1]
				break
	var pa: Dictionary = a["payload"]
	var pb: Dictionary = b["payload"]
	var f := 0.0
	var dt := int(b["t"]) - int(a["t"])
	if dt > 0:
		f = clampf(float(render_t - int(a["t"])) / float(dt), 0.0, 1.0)
	var out := pb.duplicate()
	if pa.has("p") and pb.has("p"):
		out["p"] = (pa["p"] as Vector3).lerp(pb["p"] as Vector3, f)
	if pa.has("y") and pb.has("y"):
		out["y"] = lerp_angle(float(pa["y"]), float(pb["y"]), f)
	if pa.has("v") and pb.has("v"):
		out["v"] = (pa["v"] as Vector3).lerp(pb["v"] as Vector3, f)
	if _owner3d.has_method("apply_sync_payload"):
		_owner3d.apply_sync_payload(out)
	payload_applied.emit(out)
	_trim_buffer(render_t)

func _trim_buffer(render_t: int) -> void:
	while _buffer.size() > 2 and int(_buffer[0]["t"]) < render_t - BUFFER_TRIM_MSEC:
		_buffer.pop_front()
