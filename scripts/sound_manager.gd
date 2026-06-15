extends Node

class_name SoundManager

const MIX_RATE := 22050.0

func play_footstep() -> void:
	_synth(_gen_footstep())

func play_pickup() -> void:
	_synth(_gen_pickup())

func play_trap_trigger() -> void:
	_synth(_gen_trap_trigger())

func play_gun_fire() -> void:
	_synth(_gen_gun_fire())

func play_gun_hit() -> void:
	_synth(_gen_gun_hit())

func _synth(buf: PackedVector2Array) -> void:
	if buf.is_empty():
		return
	var dur = float(buf.size()) / MIX_RATE
	var ap  = AudioStreamPlayer.new()
	var gen = AudioStreamGenerator.new()
	gen.mix_rate     = MIX_RATE
	gen.buffer_length = dur + 0.05
	ap.stream    = gen
	ap.volume_db = 0.0
	add_child(ap)
	ap.play()
	var pb = ap.get_stream_playback() as AudioStreamGeneratorPlayback
	if pb:
		pb.push_buffer(buf)
	get_tree().create_timer(dur + 0.2).timeout.connect(func():
		if is_instance_valid(ap): ap.queue_free()
	)

# Realistic stone footstep — two layers mixed together:
#   • Layer 1: sharp wideband click (heel strike transient, ~15 ms)
#   • Layer 2: low-frequency thud body (floor resonance, ~120 ms)
# Alternates left/right pan so consecutive steps sound distinct.
var _step_side: int = 0   # 0 = left, 1 = right

func _gen_footstep() -> PackedVector2Array:
	_step_side = 1 - _step_side
	var pan   = -0.30 if _step_side == 0 else 0.30   # slight L/R offset
	var n     = int(MIX_RATE * 0.13)
	var buf   = PackedVector2Array()
	buf.resize(n)

	# Randomise the thud pitch slightly so repeated steps don't sound identical
	var thud_freq = randf_range(68.0, 95.0)
	var phase := 0.0

	for i in n:
		var t = float(i) / MIX_RATE

		# ── click layer (heel strike) ─────────────────────────────────────────
		# Very fast decay, all harmonics (filtered noise)
		var click_env = exp(-t * 220.0)
		var click     = (randf() * 2.0 - 1.0) * click_env * 0.70

		# ── thud layer (floor resonance) ──────────────────────────────────────
		# Slow-decay sine at low frequency; slight pitch-drop on attack
		var pitch     = thud_freq * (1.0 + exp(-t * 80.0) * 0.40)
		phase        += TAU * pitch / MIX_RATE
		var thud_env  = exp(-t * 28.0)
		var thud      = sin(phase) * thud_env * 0.85

		# ── mix & pan ─────────────────────────────────────────────────────────
		var s = (click + thud) * 0.45
		buf[i] = Vector2(s * (1.0 - pan), s * (1.0 + pan))

	return buf

# Rising two-tone beep — picking up a trap box
func _gen_pickup() -> PackedVector2Array:
	var n   = int(MIX_RATE * 0.20)
	var buf = PackedVector2Array()
	buf.resize(n)
	var phase := 0.0
	for i in n:
		var freq = lerp(440.0, 880.0, float(i) / n)
		phase += TAU * freq / MIX_RATE
		var env = sin(PI * float(i) / n)
		var s   = sin(phase) * env * 0.50
		buf[i]  = Vector2(s, s)
	return buf

# Low descending thud + noise — stepping on a trap
func _gen_trap_trigger() -> PackedVector2Array:
	var n   = int(MIX_RATE * 0.50)
	var buf = PackedVector2Array()
	buf.resize(n)
	var phase := 0.0
	for i in n:
		var t    = float(i) / MIX_RATE
		var freq = lerp(220.0, 28.0, float(i) / n)
		phase   += TAU * freq / MIX_RATE
		var env  = exp(-t * 6.5)
		var noise = (randf() * 2.0 - 1.0) * 0.28
		var s    = (sin(phase) * 0.72 + noise) * env
		buf[i]   = Vector2(s, s)
	return buf

# Sharp noise crack — gun fires
func _gen_gun_fire() -> PackedVector2Array:
	var n   = int(MIX_RATE * 0.13)
	var buf = PackedVector2Array()
	buf.resize(n)
	var phase := 0.0
	for i in n:
		var t    = float(i) / MIX_RATE
		var env  = exp(-t * 28.0)
		# Short pitch-drop tone underneath the noise for a "bang" character
		phase   += TAU * lerp(1200.0, 200.0, float(i) / n) / MIX_RATE
		var noise = (randf() * 2.0 - 1.0)
		var s    = (noise * 0.75 + sin(phase) * 0.25) * env
		buf[i]   = Vector2(s, s)
	return buf

# Low thump with body — target hit by gun
func _gen_gun_hit() -> PackedVector2Array:
	var n   = int(MIX_RATE * 0.32)
	var buf = PackedVector2Array()
	buf.resize(n)
	var phase := 0.0
	for i in n:
		var t    = float(i) / MIX_RATE
		var freq = lerp(280.0, 55.0, minf(float(i) / n * 3.5, 1.0))
		phase   += TAU * freq / MIX_RATE
		var env  = exp(-t * 9.0)
		var noise = (randf() * 2.0 - 1.0) * 0.38
		var s    = (sin(phase) * 0.62 + noise) * env
		buf[i]   = Vector2(s, s)
	return buf
