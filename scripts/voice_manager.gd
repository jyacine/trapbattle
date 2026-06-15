extends Node
class_name VoiceManager

# ── Voice chat over WebSocket relay ──────────────────────────────────────────
# Architecture:
#   1. Mic is open by default (always-on).  Press V or the on-screen button
#      to MUTE / UNMUTE (toggle).
#   2. Voice-activity detection (VAD): audio is only sent while you are actually
#      speaking — silence is never transmitted, which slashes server relay load.
#   3. Captured PCM is resampled to VOICE_RATE and quantised to 8-bit before it
#      is relayed through the server to all other peers (¼ the bandwidth of the
#      raw 44.1 kHz capture).
#   4. player_speaking_changed fires so the UI can show / hide the 🔊 icon.

signal player_speaking_changed(pid: int, is_speaking: bool)

const VOICE_RATE      := 11025   # send/playback rate — plenty for intelligible voice
const SEND_INTERVAL   := 0.06    # seconds between audio packets
const SPEAKING_TIMEOUT := 0.30   # silence after last packet → "stopped speaking"
const VAD_THRESHOLD   := 0.010   # mic RMS above this counts as speech (favor transmitting)
const VAD_HANGOVER    := 0.40    # keep transmitting this long after speech dips
const MIC_BUS         := "VoiceMic"

# ── Internal state ────────────────────────────────────────────────────────────
var _transmitting:  bool  = true  # true = mic open (not muted)
var _send_timer:    float = 0.0
var _mic_player:    AudioStreamPlayer
var _mic_capture:   AudioEffectCapture
var _capture_rate:  float = 44100.0  # actual AudioServer mix rate (mic capture rate)
var _vad_hangover:  float = 0.0      # >0 while still transmitting the speech tail
var _local_speaking: bool = false    # current VAD state for the local mic

# peer_id → AudioStreamGeneratorPlayback  (remote voices)
var _speakers:      Dictionary = {}
var _speaker_nodes: Dictionary = {}

# How long since we last received audio from each remote peer
var _speaking_timers: Dictionary = {}  # pid → float countdown

# Optional on-screen button set by UIManager
var voice_button: Button = null

# ─────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	_setup_mic()
	# Mic is open (not muted) but stays silent on the network until VAD hears speech.

func _setup_mic() -> void:
	_capture_rate = AudioServer.get_mix_rate()
	if AudioServer.get_bus_index(MIC_BUS) == -1:
		AudioServer.add_bus()
		var bus_idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(bus_idx, MIC_BUS)
		AudioServer.set_bus_send(bus_idx, "")   # capture only — no loopback
		AudioServer.add_bus_effect(bus_idx, AudioEffectCapture.new())

	var bus_idx = AudioServer.get_bus_index(MIC_BUS)
	_mic_capture = AudioServer.get_bus_effect(bus_idx, 0) as AudioEffectCapture

	_mic_player = AudioStreamPlayer.new()
	_mic_player.stream   = AudioStreamMicrophone.new()
	_mic_player.bus      = MIC_BUS
	_mic_player.autoplay = true
	add_child(_mic_player)

# ── Per-frame ─────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	if not multiplayer.has_multiplayer_peer():
		return

	# Tick down "is speaking" timers for remote peers
	for pid in _speaking_timers.keys().duplicate():
		_speaking_timers[pid] -= delta
		if _speaking_timers[pid] <= 0.0:
			_speaking_timers.erase(pid)
			player_speaking_changed.emit(pid, false)

	if _transmitting:
		_send_timer -= delta
		if _send_timer <= 0.0:
			_send_timer = SEND_INTERVAL
			_capture_and_send()

# ── Keyboard toggle (V = mute / unmute) ──────────────────────────────────────
func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.keycode == KEY_V \
			and event.pressed and not event.echo:
		if _transmitting:
			mute()
		else:
			unmute()

# ── Public mute API ───────────────────────────────────────────────────────────
func mute() -> void:
	_transmitting = false
	_vad_hangover = 0.0
	_local_speaking = false
	player_speaking_changed.emit(multiplayer.get_unique_id(), false)
	_update_button()

func unmute() -> void:
	_transmitting = true
	# Stays silent on the network until VAD detects speech again.
	_update_button()

# Kept for backward compat (UIManager button wired these up before)
func start_transmitting() -> void: unmute()
func stop_transmitting()  -> void: mute()

func _update_button() -> void:
	if voice_button == null or not is_instance_valid(voice_button): return
	if _transmitting:
		voice_button.text     = "🎤\nON"
		voice_button.modulate = Color(1, 1, 1)
	else:
		voice_button.text     = "🔇\nMUTE"
		voice_button.modulate = Color(1.0, 0.4, 0.4)

# ── Capture & send ────────────────────────────────────────────────────────────
func _capture_and_send() -> void:
	if _mic_capture == null: return
	var available = _mic_capture.get_frames_available()
	if available <= 0: return

	var frames = _mic_capture.get_buffer(available)

	# Voice-activity detection: RMS level of this chunk.
	var sum_sq := 0.0
	for i in frames.size():
		var s: float = frames[i].x
		sum_sq += s * s
	var rms := sqrt(sum_sq / float(max(1, frames.size())))

	if rms >= VAD_THRESHOLD:
		_vad_hangover = VAD_HANGOVER
	else:
		_vad_hangover = max(0.0, _vad_hangover - SEND_INTERVAL)

	var speaking := _vad_hangover > 0.0
	if speaking != _local_speaking:
		_local_speaking = speaking
		player_speaking_changed.emit(multiplayer.get_unique_id(), speaking)

	if not speaking:
		return   # silence — transmit nothing

	# Resample capture_rate → VOICE_RATE and quantise to 8-bit unsigned.
	var bytes := _resample_quantize(frames, _capture_rate, float(VOICE_RATE))
	if bytes.is_empty(): return

	var my_id = multiplayer.get_unique_id()
	if multiplayer.is_server():
		_rpc_play_voice.rpc(bytes, my_id)
	else:
		_rpc_voice.rpc_id(1, bytes, my_id)

# Linear-resample mono samples (frames[i].x) from src_rate to dst_rate and pack
# each as one unsigned byte. Robust to 44100 or 48000 Hz capture devices.
func _resample_quantize(frames: PackedVector2Array, src_rate: float, dst_rate: float) -> PackedByteArray:
	var n_in := frames.size()
	if n_in == 0 or src_rate <= 0.0:
		return PackedByteArray()
	var ratio := dst_rate / src_rate
	var n_out := int(n_in * ratio)
	if n_out <= 0:
		return PackedByteArray()
	var bytes := PackedByteArray()
	bytes.resize(n_out)
	for j in n_out:
		var src_pos := float(j) / ratio
		var i0 := int(src_pos)
		var i1: int = min(i0 + 1, n_in - 1)
		var frac := src_pos - float(i0)
		var f0: Vector2 = frames[i0]
		var f1: Vector2 = frames[i1]
		var s: float = f0.x + (f1.x - f0.x) * frac
		bytes[j] = int(clampf(s, -1.0, 1.0) * 127.0) + 128
	return bytes

# ── RPCs ──────────────────────────────────────────────────────────────────────

## Client → server: deliver audio + sender ID.
@rpc("any_peer", "call_remote", "unreliable")
func _rpc_voice(audio_bytes: PackedByteArray, sender_id: int) -> void:
	if not multiplayer.is_server(): return
	_rpc_play_voice.rpc(audio_bytes, sender_id)

## Server → all clients: play incoming audio.
@rpc("authority", "call_remote", "unreliable")
func _rpc_play_voice(audio_bytes: PackedByteArray, sender_id: int) -> void:
	if sender_id == multiplayer.get_unique_id(): return
	# Refresh / start "speaking" timer for this peer
	if not _speaking_timers.has(sender_id):
		player_speaking_changed.emit(sender_id, true)
	_speaking_timers[sender_id] = SPEAKING_TIMEOUT
	_push_to_speaker(sender_id, audio_bytes)

# ── Playback ──────────────────────────────────────────────────────────────────
func _push_to_speaker(sender_id: int, bytes: PackedByteArray) -> void:
	if not _speakers.has(sender_id):
		var gen    = AudioStreamGenerator.new()
		gen.mix_rate      = VOICE_RATE
		gen.buffer_length = 0.2
		var player = AudioStreamPlayer.new()
		player.stream    = gen
		player.volume_db = 0.0
		player.autoplay  = true
		add_child(player)
		_speaker_nodes[sender_id] = player
		_speakers[sender_id]      = player.get_stream_playback() as AudioStreamGeneratorPlayback

	var pb: AudioStreamGeneratorPlayback = _speakers[sender_id]
	if pb == null: return

	var frames = PackedVector2Array()
	frames.resize(bytes.size())
	for i in bytes.size():
		var s = (float(bytes[i]) - 128.0) / 127.0
		frames[i] = Vector2(s, s)
	pb.push_buffer(frames)

# ── Cleanup ───────────────────────────────────────────────────────────────────
func remove_speaker(pid: int) -> void:
	if _speaker_nodes.has(pid):
		var node = _speaker_nodes[pid]
		if is_instance_valid(node): node.queue_free()
		_speaker_nodes.erase(pid)
		_speakers.erase(pid)
	_speaking_timers.erase(pid)
	player_speaking_changed.emit(pid, false)
