extends Node
## Sfx — процедурно сгенерированные звуковые эффекты (autoload).
## Этап 1: без внешних ассетов — короткие синтезированные WAV (удар, взмах, боль,
## смерть врага, резонансный импульс, отсчёт, фанфары победы/поражения).
## На Этапе 7 заменяется финальным звуком; интерфейс play(name) сохраняется.

const RATE: int = 44100
const POOL_SIZE: int = 10

var _streams: Dictionary = {}
var _pool: Array[AudioStreamPlayer] = []
var _pool_index: int = 0
var _headless: bool = false

func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"
	for i in POOL_SIZE:
		var p := AudioStreamPlayer.new()
		p.bus = "Master"
		add_child(p)
		_pool.append(p)
	_build_sounds()
	## При аварийном/тестовом quit() _exit_tree автозагрузок не вызывается —
	## чистим аудио по сигналу tree_exiting корневого окна.
	get_tree().root.tree_exiting.connect(shutdown)

## Корректное освобождение аудио при завершении (без утечек ObjectDB на выходе).
## ВАЖНО: при get_tree().quit() tree_exiting может не эмитироваться — вызывайте
## shutdown() явно перед выходом (тесты, кнопка «Выйти»).
func shutdown() -> void:
	for p in _pool:
		if is_instance_valid(p):
			p.stop()
			p.stream = null
	_streams.clear()

func play(what: String, volume_db: float = 0.0, pitch: float = 1.0) -> void:
	if _headless or not _streams.has(what):
		return ## в headless не играем: тишина не нужна, а чистый выход тестов — да
	var p := _pool[_pool_index]
	_pool_index = (_pool_index + 1) % POOL_SIZE
	p.stream = _streams[what]
	p.volume_db = volume_db
	p.pitch_scale = pitch * randf_range(0.94, 1.06)
	p.play()

# ------------------------------------------------------------------ синтез

func _build_sounds() -> void:
	_streams["hit"] = _make(_noise_burst(0.09, 0.55, 900.0, 220.0))
	_streams["heavy_hit"] = _make(_mix([
		_noise_burst(0.14, 0.7, 500.0, 90.0),
		_tone(0.16, 110.0, 0.6, 55.0),
	]))
	_streams["swing"] = _make(_noise_burst(0.13, 0.16, 300.0, 2400.0))
	_streams["hurt"] = _make(_tone(0.18, 320.0, 0.5, 140.0))
	_streams["hero_down"] = _make(_mix([
		_tone(0.5, 300.0, 0.5, 80.0),
		_noise_burst(0.3, 0.3, 400.0, 120.0),
	]))
	_streams["enemy_die"] = _make(_mix([
		_tone(0.22, 520.0, 0.45, 160.0),
		_noise_burst(0.18, 0.4, 1200.0, 300.0),
	]))
	_streams["pulse"] = _make(_mix([
		_tone(0.6, 90.0, 0.5, 180.0),
		_tone(0.6, 180.0, 0.25, 360.0),
		_noise_burst(0.4, 0.2, 600.0, 1200.0),
	]))
	_streams["count"] = _make(_tone(0.08, 880.0, 0.35))
	_streams["count_go"] = _make(_tone(0.22, 1320.0, 0.4))
	_streams["evolve"] = _make(_mix([
		_arpeggio([392.0, 523.25, 659.25, 783.99, 1046.5, 1318.5], 0.09, 0.45),
		_tone(0.7, 120.0, 0.35, 480.0),
		_noise_burst(0.35, 0.18, 800.0, 3200.0),
	]))
	_streams["shockwave"] = _make(_mix([
		_noise_burst(0.22, 0.6, 400.0, 70.0),
		_tone(0.24, 95.0, 0.55, 45.0),
	]))
	_streams["victory"] = _make(_arpeggio([523.25, 659.25, 783.99, 1046.5], 0.14, 0.5))
	_streams["defeat"] = _make(_arpeggio([392.0, 311.13, 233.08], 0.24, 0.5))
	_streams["ui"] = _make(_tone(0.05, 660.0, 0.25))

func _make(samples: PackedFloat32Array) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		var v := clampi(int(samples[i] * 32767.0), -32768, 32767)
		bytes.encode_s16(i * 2, v)
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.stereo = false
	wav.data = bytes
	return wav

func _n_frames(sec: float) -> int:
	return int(sec * RATE)

## Затухающий шум с линейной развёрткой частоты «яркости» (простой lowpass одним полюсом).
func _noise_burst(sec: float, amp: float, freq_from: float, freq_to: float) -> PackedFloat32Array:
	var n := _n_frames(sec)
	var out := PackedFloat32Array()
	out.resize(n)
	var filtered := 0.0
	for i in n:
		var t := float(i) / n
		var cutoff := lerpf(freq_from, freq_to, t) / RATE
		filtered = lerpf(filtered, randf_range(-1.0, 1.0), clampf(cutoff * 6.0, 0.01, 1.0))
		var env := (1.0 - t) * (1.0 - t)
		out[i] = filtered * env * amp
	return out

## Синус с обертоном и экспоненциальным затуханием, опциональная развёртка частоты.
func _tone(sec: float, freq: float, amp: float, freq_end: float = -1.0) -> PackedFloat32Array:
	var n := _n_frames(sec)
	var out := PackedFloat32Array()
	out.resize(n)
	var phase := 0.0
	for i in n:
		var t := float(i) / n
		var f := freq if freq_end < 0.0 else lerpf(freq, freq_end, t)
		phase += TAU * f / RATE
		var env := exp(-4.5 * t) * minf(1.0, float(i) / 60.0)
		out[i] = (sin(phase) * 0.8 + sin(phase * 2.0) * 0.2) * env * amp
	return out

func _arpeggio(freqs: Array, note_sec: float, amp: float) -> PackedFloat32Array:
	var parts: Array[PackedFloat32Array] = []
	for f in freqs:
		parts.append(_tone(note_sec * 1.6, f, amp))
	var total := _n_frames(note_sec * (freqs.size() - 1)) + _n_frames(note_sec * 1.6)
	var out := PackedFloat32Array()
	out.resize(total)
	for idx in parts.size():
		var offset := _n_frames(note_sec * idx)
		var part := parts[idx]
		for i in part.size():
			if offset + i < total:
				out[offset + i] += part[i]
	return out

func _mix(parts: Array) -> PackedFloat32Array:
	var n := 0
	for p in parts:
		n = maxi(n, p.size())
	var out := PackedFloat32Array()
	out.resize(n)
	for p in parts:
		for i in p.size():
			out[i] += p[i]
	for i in n:
		out[i] = clampf(out[i], -1.0, 1.0)
	return out
