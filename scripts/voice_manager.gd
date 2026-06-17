extends Node
class_name VoiceManager

# ── Voice chat over WebSocket relay ──────────────────────────────────────────
# Architecture (server-relayed, like mainstream games / SFU middleware — NOT a
# P2P mesh, which would leak every player's IP and scale O(N²)):
#   1. Mic is open by default (always-on).  Press V or the on-screen button
#      to MUTE / UNMUTE (toggle).
#   2. Voice-activity detection (VAD): audio is only sent while you are actually
#      speaking — silence is never transmitted, which slashes server relay load.
#      Captured PCM is anti-alias downsampled to VOICE_RATE (16 kHz wideband) and
#      compressed with 4-bit IMA-ADPCM (~0.5 byte/sample ≈ 64 kbps while speaking)
#      before it is relayed through the server to all other peers. The server
#      forwards the bytes opaquely (no decode), so codec/rate are a client-only
#      concern — no server change is needed to tune them.
#   4. player_speaking_changed fires so the UI can show / hide the speaking icon.
#   NOTE: the mic bus is MUTED locally (see _setup_mic) so you never hear yourself.

signal player_speaking_changed(pid: int, is_speaking: bool)

const VOICE_RATE      := 16000   # send/playback rate — wideband voice (8 kHz band), clear
const SEND_INTERVAL   := 0.06    # seconds between audio packets
const SPEAKING_TIMEOUT := 0.30   # silence after last packet → "stopped speaking"
const VAD_THRESHOLD   := 0.010   # mic RMS above this counts as speech (favor transmitting)
const VAD_HANGOVER    := 0.40    # keep transmitting this long after speech dips
const MIC_BUS         := "VoiceMic"

# ── Jitter buffer (fixes choppy playback) ────────────────────────────────────
# Voice rides the game's WebSocket (TCP) multiplayer channel, so packets arrive in
# jittery bursts (TCP head-of-line blocking under loss). Pushing them straight into
# the audio generator underran it between bursts → choppy. Instead we QUEUE incoming
# audio per speaker and keep the generator topped up to a target depth, starting
# playout only after a small prebuffer. This trades a little latency for smoothness.
const GEN_BUFFER_LEN := 0.30    # AudioStreamGenerator internal buffer (s)
const JITTER_TARGET  := 0.12    # keep ~this much buffered in the generator (jitter tolerance)
const JITTER_PREBUF  := 0.12    # accumulate this much before (re)starting playout
const JITTER_MAX     := 0.40    # cap queued audio; drop oldest beyond this (bounds latency)

# ── WebRTC DataChannel transport (UDP — off the TCP/WebSocket plane) ──────────
# When enabled, voice flows over an UNRELIABLE/UNORDERED WebRTC DataChannel to the
# dedicated server (which relays it), instead of the reliable WebSocket RPC. That
# removes TCP head-of-line blocking — the root cause of choppiness under loss.
# Signaling (offer/answer/ICE) rides the existing reliable RPC channel.
#
# Topology: STAR (client <-> server), NOT a P2P mesh — same relay model as the WS
# path, so no player IPs are exposed to each other and it scales linearly.
#
# DEFAULT OFF. Enable ONLY once the dedicated server is deployed with the
# webrtc-native GDExtension (see trapbattle-server). Until the channel is OPEN,
# voice automatically falls back to the WebSocket relay, so flipping this on without
# a WebRTC-capable server simply keeps using WebSocket. The web client has WebRTC
# built in (browser), so no client-side addon is needed.
const USE_WEBRTC   := false
const RTC_STUN     := "stun:stun.l.google.com:19302"
const RTC_CH_ID    := 1          # negotiated DataChannel id — MUST match the server

# ── IMA-ADPCM codec tables (standard) ────────────────────────────────────────
# 4 bits/sample. Each relayed packet is self-contained: a 3-byte header carries
# the encoder's predictor (int16 LE) + step index (u8) at the packet's start, then
# the 4-bit codes (two per byte). Self-contained headers make packets robust to the
# loss/reorder of the unreliable voice RPC.
const _ADPCM_INDEX_TABLE: Array[int] = [-1, -1, -1, -1, 2, 4, 6, 8]
const _ADPCM_STEP_TABLE: Array[int] = [
	7, 8, 9, 10, 11, 12, 13, 14, 16, 17,
	19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
	50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
	130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
	337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
	876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
	2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358,
	5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
	15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
]

# ── Internal state ────────────────────────────────────────────────────────────
var _transmitting:  bool  = true  # true = mic open (not muted)
var _send_timer:    float = 0.0
var _mic_player:    AudioStreamPlayer
var _mic_capture:   AudioEffectCapture
var _capture_rate:  float = 44100.0  # actual AudioServer mix rate (mic capture rate)
var _vad_hangover:  float = 0.0      # >0 while still transmitting the speech tail
var _local_speaking: bool = false    # current VAD state for the local mic

# ADPCM encoder state, carried across packets for continuity (each packet still
# writes the current predictor/index into its header so the decoder stays in sync).
var _enc_predictor: int = 0
var _enc_index:     int = 0

# peer_id → AudioStreamGeneratorPlayback  (remote voices)
var _speakers:      Dictionary = {}
var _speaker_nodes: Dictionary = {}

# Per-speaker jitter buffer state
var _jq:     Dictionary = {}   # pid → PackedVector2Array (queued frames awaiting playout)
var _jq_pos: Dictionary = {}   # pid → int read offset into _jq[pid]
var _jq_play: Dictionary = {}  # pid → bool (true = playing, false = (re)prebuffering)

# How long since we last received audio from each remote peer
var _speaking_timers: Dictionary = {}  # pid → float countdown

# WebRTC voice link (client → server). Null unless USE_WEBRTC and negotiation began.
var _rtc:       WebRTCPeerConnection = null
var _vch:       WebRTCDataChannel    = null
var _rtc_open:  bool = false   # true once the DataChannel reaches STATE_OPEN

# Optional on-screen button + its icon, set by UIManager. The icon swaps between
# the mic (transmitting) and muted-speaker (muted) SVG textures.
var voice_button: Button = null
var voice_button_icon: TextureRect = null
const _MIC_TEX  := preload("res://assets/icons/icon_mic.svg")
const _MUTE_TEX := preload("res://assets/icons/icon_mute.svg")

# ─────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	_setup_mic()
	# Mic is open (not muted) but stays silent on the network until VAD hears speech.
	# Bring up the WebRTC voice link (clients only; the dedicated server answers).
	if USE_WEBRTC and not multiplayer.is_server():
		_setup_webrtc()

func _setup_mic() -> void:
	_capture_rate = AudioServer.get_mix_rate()
	if AudioServer.get_bus_index(MIC_BUS) == -1:
		AudioServer.add_bus()
		var new_idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(new_idx, MIC_BUS)
		AudioServer.add_bus_effect(new_idx, AudioEffectCapture.new())

	var bus_idx = AudioServer.get_bus_index(MIC_BUS)
	# MUTE the mic bus output so we never hear our own voice locally (monitoring
	# loopback — the cause of "I hear myself when talking"). The AudioEffectCapture
	# sits in the effect chain *before* the mute stage, so mic capture still works;
	# only the send to the speakers (Master) is silenced.
	AudioServer.set_bus_mute(bus_idx, true)
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

	# WebRTC: poll the connection and drain any incoming voice datagrams.
	if _rtc != null:
		_rtc.poll()
		if _vch != null:
			if not _rtc_open and _vch.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
				_rtc_open = true
			while _vch.get_available_packet_count() > 0:
				_on_voice_datagram(_vch.get_packet())

	if _transmitting:
		_send_timer -= delta
		if _send_timer <= 0.0:
			_send_timer = SEND_INTERVAL
			_capture_and_send()

	# Drain the jitter buffers into the audio generators at a steady depth.
	_pump_speakers()

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
	# Start the ADPCM stream fresh so the first packet after un-muting doesn't carry
	# a stale predictor from before. Stays silent on the network until VAD fires.
	_enc_predictor = 0
	_enc_index     = 0
	_update_button()

# Kept for backward compat (UIManager button wired these up before)
func start_transmitting() -> void: unmute()
func stop_transmitting()  -> void: mute()

func _update_button() -> void:
	if voice_button == null or not is_instance_valid(voice_button): return
	if _transmitting:
		voice_button.modulate = Color(1, 1, 1)
		if is_instance_valid(voice_button_icon):
			voice_button_icon.texture = _MIC_TEX
	else:
		voice_button.modulate = Color(1.0, 0.4, 0.4)
		if is_instance_valid(voice_button_icon):
			voice_button_icon.texture = _MUTE_TEX

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

	# Resample capture_rate → VOICE_RATE, then 4-bit IMA-ADPCM compress.
	var samples := _resample(frames, _capture_rate, float(VOICE_RATE))
	if samples.is_empty(): return
	var enc := adpcm_encode(samples, _enc_predictor, _enc_index)
	var bytes: PackedByteArray = enc["bytes"]
	_enc_predictor = enc["predictor"]
	_enc_index     = enc["index"]

	var my_id = multiplayer.get_unique_id()
	# Prefer the WebRTC DataChannel (UDP) when it is open; the server identifies the
	# sender by which channel the packet arrived on, so we send raw ADPCM here.
	if _rtc_open and _vch != null and _vch.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
		_vch.put_packet(bytes)
	elif multiplayer.is_server():
		_rpc_play_voice.rpc(bytes, my_id)
	else:
		_rpc_voice.rpc_id(1, bytes, my_id)

# Resample mono samples (frames[i].x) from src_rate to dst_rate, returning float
# samples in [-1, 1]. Robust to 44100 or 48000 Hz capture devices.
#
# When DOWNSAMPLING (the usual case: 44.1/48 kHz capture -> 16 kHz voice) we average
# all source samples that fall inside each output sample's window (a box low-pass)
# instead of point/linear sampling. Naive interpolation skips most input samples and
# folds frequencies above the new Nyquist back into the band as harsh aliasing noise
# — a major cause of the "bad quality". Averaging band-limits before decimation.
# When upsampling we fall back to linear interpolation.
func _resample(frames: PackedVector2Array, src_rate: float, dst_rate: float) -> PackedFloat32Array:
	var n_in := frames.size()
	if n_in == 0 or src_rate <= 0.0:
		return PackedFloat32Array()
	var ratio := dst_rate / src_rate
	var n_out := int(n_in * ratio)
	if n_out <= 0:
		return PackedFloat32Array()
	var out := PackedFloat32Array()
	out.resize(n_out)
	var step := src_rate / dst_rate   # input samples per output sample
	if step > 1.0:
		# Downsample: average the input window [j*step, (j+1)*step) — anti-aliasing.
		for j in n_out:
			var start_f := float(j) * step
			var end_f := start_f + step
			var i0 := int(start_f)
			var i1: int = min(int(end_f), n_in - 1)
			var sum := 0.0
			var cnt := 0
			for i in range(i0, i1 + 1):
				sum += frames[i].x
				cnt += 1
			out[j] = sum / float(max(1, cnt))
	else:
		# Upsample (or 1:1): linear interpolation.
		for j in n_out:
			var src_pos := float(j) / ratio
			var i0 := int(src_pos)
			var i1: int = min(i0 + 1, n_in - 1)
			var frac := src_pos - float(i0)
			var f0: Vector2 = frames[i0]
			var f1: Vector2 = frames[i1]
			out[j] = f0.x + (f1.x - f0.x) * frac
	return out

# ── IMA-ADPCM codec (static + pure → unit-testable headless) ──────────────────
# Encode float samples [-1,1] into a self-contained packet: 3-byte header
# (predictor int16 LE, step index u8) + 4-bit codes (two per byte). `predictor`
# and `index` seed the encoder (pass the carried state); the returned dict gives
# the bytes plus the updated state for the next packet.
static func adpcm_encode(samples: PackedFloat32Array, predictor: int, index: int) -> Dictionary:
	var bytes := PackedByteArray()
	var pred := clampi(predictor, -32768, 32767)
	var idx  := clampi(index, 0, 88)
	# Header
	bytes.append(pred & 0xFF)
	bytes.append((pred >> 8) & 0xFF)
	bytes.append(idx)

	var buffered := false
	var cache := 0
	for k in samples.size():
		var sample := int(clampf(samples[k], -1.0, 1.0) * 32767.0)
		var step: int = _ADPCM_STEP_TABLE[idx]
		var diff := sample - pred
		var code := 0
		if diff < 0:
			code = 8
			diff = -diff
		var tmp := step
		if diff >= tmp:
			code |= 4; diff -= tmp
		tmp >>= 1
		if diff >= tmp:
			code |= 2; diff -= tmp
		tmp >>= 1
		if diff >= tmp:
			code |= 1
		# Reconstruct predictor exactly as the decoder will.
		var diffq := step >> 3
		if code & 4: diffq += step
		if code & 2: diffq += step >> 1
		if code & 1: diffq += step >> 2
		if code & 8: pred -= diffq
		else:        pred += diffq
		pred = clampi(pred, -32768, 32767)
		idx  = clampi(idx + _ADPCM_INDEX_TABLE[code & 7], 0, 88)
		# Pack two 4-bit codes per byte (low nibble first).
		if not buffered:
			cache = code & 0x0F
			buffered = true
		else:
			bytes.append((cache & 0x0F) | ((code & 0x0F) << 4))
			buffered = false
	if buffered:
		bytes.append(cache & 0x0F)
	return { "bytes": bytes, "predictor": pred, "index": idx }

# Decode an ADPCM packet back into float samples [-1, 1]. Stateless: reads the
# predictor/index from the packet header, so a dropped/reordered packet can't
# corrupt later ones.
static func adpcm_decode(bytes: PackedByteArray) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if bytes.size() < 3:
		return out
	var pred := bytes[0] | (bytes[1] << 8)
	if pred >= 32768:
		pred -= 65536                      # sign-extend the int16
	var idx := clampi(bytes[2], 0, 88)
	out.resize((bytes.size() - 3) * 2)
	var oi := 0
	for bi in range(3, bytes.size()):
		var byte: int = bytes[bi]
		for half in 2:
			var code := (byte >> (4 * half)) & 0x0F
			var step: int = _ADPCM_STEP_TABLE[idx]
			var diffq := step >> 3
			if code & 4: diffq += step
			if code & 2: diffq += step >> 1
			if code & 1: diffq += step >> 2
			if code & 8: pred -= diffq
			else:        pred += diffq
			pred = clampi(pred, -32768, 32767)
			idx  = clampi(idx + _ADPCM_INDEX_TABLE[code & 7], 0, 88)
			out[oi] = float(pred) / 32767.0
			oi += 1
	return out

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

# ── WebRTC voice link (client side) ───────────────────────────────────────────
# Negotiate an unreliable/unordered DataChannel to the server. Signaling rides the
# existing reliable RPC channel. The channel is "negotiated" (both sides create it
# with the same id) so it needs no in-band SDP renegotiation.
func _setup_webrtc() -> void:
	_rtc = WebRTCPeerConnection.new()
	if _rtc.initialize({ "iceServers": [ { "urls": [RTC_STUN] } ] }) != OK:
		push_warning("[voice] WebRTC init failed — using WebSocket relay")
		_rtc = null
		return
	_rtc.session_description_created.connect(_on_rtc_sdp)
	_rtc.ice_candidate_created.connect(_on_rtc_ice)
	_vch = _rtc.create_data_channel("voice",
		{ "negotiated": true, "id": RTC_CH_ID, "ordered": false, "maxRetransmits": 0 })
	if _vch != null:
		_vch.write_mode = WebRTCDataChannel.WRITE_MODE_BINARY
	_rtc.create_offer()

func _on_rtc_sdp(type: String, sdp: String) -> void:
	if _rtc == null: return
	_rtc.set_local_description(type, sdp)
	if type == "offer":
		_rpc_voice_offer.rpc_id(1, sdp)

func _on_rtc_ice(media: String, index: int, name: String) -> void:
	_rpc_voice_ice.rpc_id(1, media, index, name)

# Incoming server-relayed datagram: [sender_id int32 LE][ADPCM bytes...]
func _on_voice_datagram(pkt: PackedByteArray) -> void:
	if pkt.size() < 5: return
	var sender_id := pkt.decode_s32(0)
	if sender_id == multiplayer.get_unique_id(): return
	var audio := pkt.slice(4)
	if not _speaking_timers.has(sender_id):
		player_speaking_changed.emit(sender_id, true)
	_speaking_timers[sender_id] = SPEAKING_TIMEOUT
	_push_to_speaker(sender_id, audio)

# ── Signaling RPCs (ride the reliable channel) ────────────────────────────────
# These must be declared with the IDENTICAL set + decorators on the server's voice
# node (trapbattle-server/scripts/voice_relay.gd) — Godot indexes @rpc methods by
# their position in the alphabetically-sorted list, so a mismatch misroutes calls.

## Client → server: SDP offer for the voice DataChannel. Handled on the server.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_voice_offer(_sdp: String) -> void:
	pass   # server-only handler

## Server → client: SDP answer.
@rpc("authority", "call_remote", "reliable")
func _rpc_voice_answer(sdp: String) -> void:
	if _rtc != null:
		_rtc.set_remote_description("answer", sdp)

## Trickle ICE, both directions (any_peer so the server can send it back).
@rpc("any_peer", "call_remote", "reliable")
func _rpc_voice_ice(media: String, index: int, name: String) -> void:
	if _rtc != null:
		_rtc.add_ice_candidate(media, index, name)

# ── Playback ──────────────────────────────────────────────────────────────────
# Decode an incoming packet and QUEUE it (the jitter buffer). _pump_speakers feeds
# the generator from the queue at a steady depth — never push straight to the
# generator here or bursty TCP arrival makes it underrun (choppy).
func _push_to_speaker(sender_id: int, bytes: PackedByteArray) -> void:
	if not _speakers.has(sender_id):
		var gen    = AudioStreamGenerator.new()
		gen.mix_rate      = VOICE_RATE
		gen.buffer_length = GEN_BUFFER_LEN
		var player = AudioStreamPlayer.new()
		player.stream    = gen
		player.volume_db = 0.0
		player.autoplay  = true
		add_child(player)
		_speaker_nodes[sender_id] = player
		_speakers[sender_id]      = player.get_stream_playback() as AudioStreamGeneratorPlayback
		_jq[sender_id]      = PackedVector2Array()
		_jq_pos[sender_id]  = 0
		_jq_play[sender_id] = false

	var mono := adpcm_decode(bytes)
	var frames := PackedVector2Array()
	frames.resize(mono.size())
	for i in mono.size():
		var s := mono[i]
		frames[i] = Vector2(s, s)

	var q: PackedVector2Array = _jq[sender_id]
	q.append_array(frames)
	# Bound queued latency: if a burst overfills, drop the oldest frames.
	var pos: int = _jq_pos[sender_id]
	var max_frames := int(JITTER_MAX * float(VOICE_RATE))
	if q.size() - pos > max_frames:
		q = q.slice(q.size() - max_frames)
		_jq_pos[sender_id] = 0
	_jq[sender_id] = q

# Feed each speaker's generator from its jitter queue, keeping ~JITTER_TARGET
# buffered. Playout starts only once JITTER_PREBUF has accumulated, and re-buffers
# after a full underrun so a single long gap doesn't cause continuous stutter.
func _pump_speakers() -> void:
	var rate := float(VOICE_RATE)
	var cap := int(GEN_BUFFER_LEN * rate)
	var target := int(JITTER_TARGET * rate)
	var prebuf := int(JITTER_PREBUF * rate)
	for pid in _speakers.keys():
		var pb: AudioStreamGeneratorPlayback = _speakers[pid]
		if pb == null:
			continue
		var q: PackedVector2Array = _jq.get(pid, PackedVector2Array())
		var pos: int = _jq_pos.get(pid, 0)
		var queued := q.size() - pos
		var buffered := cap - pb.get_frames_available()
		if not bool(_jq_play.get(pid, false)):
			if queued >= prebuf:
				_jq_play[pid] = true
			else:
				continue   # still prebuffering
		var deficit := target - buffered
		if deficit <= 0:
			continue       # generator already holds enough; keep the rest queued
		var n: int = min(deficit, queued)
		if n <= 0:
			if buffered <= 0:
				_jq_play[pid] = false   # fully drained → re-prebuffer
			continue
		pb.push_buffer(q.slice(pos, pos + n))
		pos += n
		_jq_pos[pid] = pos
		# Compact the queue periodically so the read offset can't grow unbounded.
		if pos > prebuf * 2:
			_jq[pid] = q.slice(pos)
			_jq_pos[pid] = 0

# ── Cleanup ───────────────────────────────────────────────────────────────────
func remove_speaker(pid: int) -> void:
	if _speaker_nodes.has(pid):
		var node = _speaker_nodes[pid]
		if is_instance_valid(node): node.queue_free()
		_speaker_nodes.erase(pid)
		_speakers.erase(pid)
	_jq.erase(pid)
	_jq_pos.erase(pid)
	_jq_play.erase(pid)
	_speaking_timers.erase(pid)
	player_speaking_changed.emit(pid, false)
