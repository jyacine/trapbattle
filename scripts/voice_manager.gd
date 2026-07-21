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
signal voice_received(sender_id: int, samples: PackedFloat32Array)

const VOICE_RATE      := 24000   # send/playback rate — wideband voice (12 kHz band), clearer
const SEND_INTERVAL   := 0.02    # seconds between audio packets
const SPEAKING_TIMEOUT := 0.30   # silence after last packet → "stopped speaking"
const VAD_THRESHOLD   := 0.004   # mic RMS above this counts as speech (favor transmitting)
const VAD_HANGOVER    := 0.50    # keep transmitting this long after speech dips (smoother tails)
const MIC_BUS         := "VoiceMic"
# Pre-roll: audio kept from just BEFORE the VAD fires and prepended to the first
# burst, so soft word onsets below the threshold aren't clipped ("missed
# syllables"). 100 ms covers typical consonant attacks.
const PREROLL_S       := 0.10

# ── Jitter buffer (fixes choppy playback) ────────────────────────────────────
# In practice voice rides the WebSocket relay (TCP): the WebRTC DataChannel never
# opens for web clients (diag shows ch=CONNECTING), and TCP delivery is BURSTY —
# a delayed segment arrives together with everything queued behind it. The
# buffer is therefore tuned for TCP: deeper target/prebuf/cap trade ~100 ms of
# extra latency for far fewer underruns (each underrun = an audible chop, which
# players reported as "noisy / missing syllables").
const GEN_BUFFER_LEN := 0.20    # AudioStreamGenerator internal buffer (s)
const JITTER_TARGET  := 0.10    # keep ~100 ms buffered in the generator
# The pump runs once per game frame and must out-pace the per-frame drain:
# target must exceed VOICE_RATE/fps. At 17 fps the drain is ~1400 frames
# (58 ms); 100 ms (2400 frames) keeps the queue stable well below that.
const JITTER_PREBUF  := 0.06    # accumulate 60 ms before (re)starting playout
const JITTER_MAX     := 0.30    # cap queued audio at 300 ms (TCP bursts fit)
# Silence padding on underrun: push zeros so the generator keeps running (avoids
# click) and the restart is inaudible; matches JITTER_PREBUF.
const JITTER_SILENCE_PAD := 0.06  # seconds of zeros to push on each underrun restart

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
const USE_WEBRTC   := true
const RTC_STUN     := "stun:stun.l.google.com:19302"
# TURN relay (coturn on the game VM). REQUIRED for the DataChannel to open for
# clients behind symmetric NAT / CGNAT — i.e. essentially all MOBILE networks.
# STUN-only hole-punching works for home broadband but always fails on mobile,
# so those clients were stuck on the choppy TCP/WebSocket fallback. TURN relays
# their UDP through the server.
# These credentials are intentionally public (WebRTC always exposes TURN creds to
# the client). They grant ONLY relay use, are quota-capped in turnserver.conf,
# and are blocked from reaching internal/metadata IPs. Rotate by editing
# /etc/turnserver.conf on the VM and this line together (must match the server repo).
const RTC_TURN      := "turn:34.155.132.207:3478"
const RTC_TURN_USER := "tbvoice"
const RTC_TURN_PASS := "96d12f6eb70c28648c18d4decba76c6e"
const RTC_CH_ID    := 1          # negotiated DataChannel id — MUST match the server

# ICE server list shared by client PC setup — STUN for reflexive discovery, TURN
# (udp primary, tcp fallback for UDP-blocked networks) for the symmetric-NAT case.
static func _ice_servers() -> Array:
	return [
		{ "urls": [RTC_STUN] },
		{ "urls": [RTC_TURN, RTC_TURN + "?transport=tcp"],
		  "username": RTC_TURN_USER, "credential": RTC_TURN_PASS },
	]

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

# Opus codec via browser WebCodecs API (web-only). When true, all voice traffic
# uses Opus-encoded packets (VOICE_FMT_OPUS) instead of raw PCM16.
var _opus_web: bool = false

# Capture-rate: use AudioServer.get_mix_rate() — the authoritative browser audio rate.
# We previously tried frame-count calibration but AudioEffectCapture.get_frames_available()
# in the Godot Web export is unreliable: it returns 0 most ticks and delivers batches,
# so any frame-counting approach produces wildly wrong values (15 kHz, 29 kHz, 79 kHz).
# get_mix_rate() consistently returns the correct browser rate (48000 Hz in all observed
# sessions). _capture_rate is set once in _setup_mic() and never changed.
# Kept for diagnostic: we still observe frame counts to log what calibration would have
# measured — helpful for spotting browsers that genuinely lie about get_mix_rate().
const _RATE_CAL_SKIP  := 5
const _RATE_CAL_CALLS := 20
var _rate_cal_skipped:  int   = 0
var _rate_cal_frames:   int   = 0
var _rate_cal_done:     int   = 0
var _rate_cal_t0:       int   = -1
var _rate_cal_measured: float = -1.0   # stored once when calibration window closes

# Streaming resampler state. The mic is read in ~20 ms chunks; resampling each
# chunk independently (the old code) dropped a fractional sample and reset the
# averaging window at every chunk boundary, injecting a ~50 Hz buzz/roughness.
# We instead keep a continuous source buffer + fractional read cursor so the
# resample timeline never breaks across chunks.
var _rs_in:  PackedFloat32Array = PackedFloat32Array()  # unconsumed source samples
var _rs_pos: float = 0.0                                 # fractional cursor into _rs_in

# Rolling buffer of the most recent resampled audio captured while SILENT.
# Prepended to the first packet of each speech burst (see PREROLL_S).
var _preroll: PackedFloat32Array = PackedFloat32Array()

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

# Diagnostic counters — reported to server every DIAG_INTERVAL seconds.
const DIAG_INTERVAL := 10.0
var _diag_timer:    float = DIAG_INTERVAL  # fire once quickly at start
var _diag_tx_rtc:   int   = 0   # packets sent via DataChannel this interval
var _diag_tx_ws:    int   = 0   # packets sent via WebSocket this interval
var _diag_underrun: int   = 0   # times jitter buffer drained to zero this interval

# Optional on-screen button + its icon, set by UIManager. The icon swaps between
# the mic (transmitting) and muted-speaker (muted) SVG textures.
var voice_button: Button = null
var voice_button_icon: TextureRect = null
const _MIC_TEX  := preload("res://assets/icons/icon_mic.svg")
const _MUTE_TEX := preload("res://assets/icons/icon_mute.svg")

const VOICE_FMT_ADPCM := 0
const VOICE_FMT_PCM16 := 1
const VOICE_FMT_OPUS  := 2

# ─────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	_setup_mic()
	_init_opus_web()
	# Mic is open (not muted) but stays silent on the network until VAD hears speech.
	# Bring up the WebRTC voice link (clients only; the dedicated server answers).
	if USE_WEBRTC and not multiplayer.is_server():
		_setup_webrtc()

# Web Opus via WebCodecs — DISABLED. Live server diagnostics showed every web
# client stuck at tx_ws=0 with codec=opus: mic frames flowed (rate-cal measured
# ~50 kHz) but the browser AudioEncoder produced no packets. Chrome's WebCodecs
# Opus implementation only guarantees 48 kHz; our 24 kHz configure() fails
# asynchronously (the error lands in the browser console only) and the encode
# queue stays empty forever, so NOTHING is ever transmitted. Web now uses the
# PCM16-over-relay path, which the E2E test validates at SNR 64 dB.
# Re-enable only with a full 48 kHz pipeline (encoder + decoder + jitter rate).
const USE_OPUS_WEB := false

func _init_opus_web() -> void:
	if not USE_OPUS_WEB:
		return
	if not OS.has_feature("web"):
		return
	if not bool(JavaScriptBridge.eval("typeof AudioEncoder !== 'undefined'")):
		push_warning("[voice] WebCodecs AudioEncoder not available — using PCM16")
		return
	# Define the browser-side Opus glue entirely from GDScript so no HTML template
	# change is needed. Single-quoted JS strings avoid conflicts with GDScript quotes.
	var js: String = "window.TBVoice=(function(){var enc=null,decs={},encQ=[],decQ={},SR=24000;function init(sr,br){SR=sr;enc=new AudioEncoder({output:function(c){var b=new Uint8Array(c.byteLength);c.copyTo(b);encQ.push(b);},error:function(e){console.error('[TBVoice enc]',e);}});enc.configure({codec:'opus',sampleRate:sr,numberOfChannels:1,bitrate:br});}function encode(f32,ts){if(!enc)return;var ad=new AudioData({format:'f32-planar',sampleRate:SR,numberOfFrames:f32.length,numberOfChannels:1,timestamp:ts,data:f32});enc.encode(ad);ad.close();}function pollEnc(){return encQ.splice(0).map(function(b){return Array.from(b);});}function initDec(pid){if(decs[pid])return;decQ[pid]=[];var dec=new AudioDecoder({output:function(ad){var b=new Float32Array(ad.numberOfFrames);ad.copyTo(b,{planeIndex:0,format:'f32-planar'});decQ[pid].push(b);ad.close();},error:function(e){console.error('[TBVoice dec pid='+pid+']',e);}});dec.configure({codec:'opus',sampleRate:SR,numberOfChannels:1});decs[pid]=dec;}function decode(pid,bytes,ts){var dec=decs[pid];if(!dec)return;dec.decode(new EncodedAudioChunk({type:'key',timestamp:ts,data:bytes}));}function pollDec(pid){return(decQ[pid]||[]).splice(0).map(function(b){return Array.from(b);});}return{init:init,encode:encode,pollEnc:pollEnc,initDec:initDec,decode:decode,pollDec:pollDec};})();"
	JavaScriptBridge.eval(js, true)
	JavaScriptBridge.eval("window.TBVoice.init(%d, 32000)" % VOICE_RATE, true)
	_opus_web = true

func _setup_mic() -> void:
	_capture_rate = AudioServer.get_mix_rate()
	if AudioServer.get_bus_index(MIC_BUS) == -1:
		AudioServer.add_bus()
		var new_idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(new_idx, MIC_BUS)
		var cap_fx := AudioEffectCapture.new()
		# Default ring is 0.1 s: one mobile-web frame hitch >100 ms overflows it
		# and mic audio is lost before it is ever read ("missed words"). 0.5 s
		# rides out hitches; the catch-up read then drains the backlog.
		cap_fx.buffer_length = 0.5
		AudioServer.add_bus_effect(new_idx, cap_fx)

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
			var max_pkts := 8
			var n := 0
			while _vch.get_available_packet_count() > 0 and n < max_pkts:
				_on_voice_datagram(_vch.get_packet())
				n += 1

	# Periodic client-side diagnostic report sent to server.
	if multiplayer.get_unique_id() != 1:
		_diag_timer -= delta
		if _diag_timer <= 0.0:
			_diag_timer = DIAG_INTERVAL
			_send_diag()

	if _transmitting:
		_send_timer -= delta
		if _send_timer <= 0.0:
			_send_timer = SEND_INTERVAL
			_capture_and_send()

	if _opus_web:
		_poll_opus_encoded()
		_poll_opus_decoded()

	# Drain the jitter buffers into the audio generators at a steady depth.
	_pump_speakers()

# ── Keyboard toggle (M = mute / unmute; V is now cycle-gun in player.gd) ────
func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.keycode == KEY_M \
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
	# Start the ADPCM stream + resampler fresh so the first packet after un-muting
	# doesn't carry stale state. Stays silent on the network until VAD fires.
	_enc_predictor = 0
	_enc_index     = 0
	_resample_reset()
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

	# Auto-calibrate _capture_rate from actual frame arrivals.
	# We skip the first _RATE_CAL_SKIP calls (startup backlog drains during those
	# calls anyway) and average the next _RATE_CAL_CALLS calls. If the measured
	# rate differs from get_mix_rate() by >2 kHz we correct _capture_rate so the
	# resampler uses the right step ratio.
	if _rate_cal_skipped < _RATE_CAL_SKIP:
		_rate_cal_skipped += 1
	elif _rate_cal_done < _RATE_CAL_CALLS:
		if _rate_cal_t0 < 0:
			_rate_cal_t0 = Time.get_ticks_msec()
		_rate_cal_frames += available
		_rate_cal_done   += 1
		if _rate_cal_done == _RATE_CAL_CALLS:
			# Log-only: frame counting is unreliable in the Web export (AudioEffectCapture
			# returns 0 most ticks and delivers batches, inflating or shrinking the divisor).
			# We trust get_mix_rate() instead and never write _capture_rate here.
			var elapsed_ms := float(Time.get_ticks_msec() - _rate_cal_t0)
			_rate_cal_measured = float(_rate_cal_frames) / maxf(elapsed_ms * 0.001, 0.001)
			if _rate_cal_measured > 8000.0 and _rate_cal_measured < 200000.0 and absf(_rate_cal_measured - _capture_rate) > 2000.0:
				push_warning("[voice] frame-count measured %.0f Hz; using get_mix_rate()=%.0f Hz (%.0f frames / %.0f ms)" % [
					_rate_cal_measured, _capture_rate, _rate_cal_frames, elapsed_ms])

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
	var just_started := false
	if speaking != _local_speaking:
		_local_speaking = speaking
		player_speaking_changed.emit(multiplayer.get_unique_id(), speaking)
		if speaking:
			just_started = true
			# Fresh ADPCM stream per burst — safe because every packet carries the
			# predictor/index in its header, so the decoder can't click.
			_enc_predictor = 0
			_enc_index     = 0

	# Resample CONTINUOUSLY — during silence too. The old code reset the
	# resampler at every speech onset, discarding its buffered tail: combined
	# with the VAD threshold this clipped the first syllable of each sentence.
	var samples := _resample_stream(frames, _capture_rate, float(VOICE_RATE))

	if not speaking:
		# Not transmitting — keep the freshest PREROLL_S of audio so the next
		# burst can prepend the soft onset that sat below the VAD threshold.
		if not samples.is_empty():
			_preroll.append_array(samples)
			var maxn := int(PREROLL_S * float(VOICE_RATE))
			if _preroll.size() > maxn:
				_preroll = _preroll.slice(_preroll.size() - maxn)
		return

	if just_started and not _preroll.is_empty():
		var joined := PackedFloat32Array()
		joined.append_array(_preroll)
		joined.append_array(samples)
		samples  = joined
		_preroll = PackedFloat32Array()

	if samples.is_empty(): return

	var my_id = multiplayer.get_unique_id()

	# Send in ≤20 ms slices. After a frame hitch this call reads the whole
	# capture backlog at once; as ONE packet that can exceed the server's
	# MAX_VOICE_PACKET_BYTES sanity cap (1600 B) and be dropped WHOLE — heard
	# as a missing word right after every hitch (frequent on mobile web). The
	# onset pre-roll burst is also split. 480 samples ≈ 244 B ADPCM / 961 B PCM16.
	var chunk_n := 480
	var off := 0
	while off < samples.size():
		var part := samples.slice(off, mini(off + chunk_n, samples.size()))
		off += chunk_n
		_send_voice_packet(part, my_id)

# Dispatch one ≤20 ms slice over the active transport.
func _send_voice_packet(samples: PackedFloat32Array, my_id: int) -> void:
	if _opus_web:
		# Opus path: submit samples to the browser's AudioEncoder; encoded packets
		# are polled and sent in _poll_opus_encoded() each _process tick.
		var js_f32: JavaScriptObject = JavaScriptBridge.create_object("Float32Array", samples)
		JavaScriptBridge.get_interface("window")["_tbv_pcm"] = js_f32
		JavaScriptBridge.eval("window.TBVoice.encode(window._tbv_pcm, %d)" % Time.get_ticks_usec())
	elif _rtc_open and _vch != null and _vch.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
		# UDP DataChannel: PCM16 (bandwidth is not contended off the TCP plane).
		var payload := PackedByteArray()
		payload.append(VOICE_FMT_PCM16)
		payload.append_array(_pack_pcm16(samples))
		_vch.put_packet(payload)
		_diag_tx_rtc += 1
	else:
		# WebSocket relay (TCP): 4-bit IMA-ADPCM. PCM16 here was 384 kbps while
		# speaking — sharing the TCP pipe with gameplay RPCs it caused burst
		# congestion, jitter-cap drops and underruns ("noisy, missing syllables").
		# ADPCM is 96 kbps with round-trip error ~0.002 (inaudible for speech).
		var enc := adpcm_encode(samples, _enc_predictor, _enc_index)
		_enc_predictor = enc["predictor"]
		_enc_index     = enc["index"]
		var enc_bytes: PackedByteArray = enc["bytes"]
		var payload := PackedByteArray()
		payload.append(VOICE_FMT_ADPCM)
		payload.append_array(enc_bytes)
		if multiplayer.is_server():
			_rpc_play_voice.rpc(payload, my_id)      # listen-server broadcast
		else:
			_rpc_voice.rpc_id(1, payload, my_id)     # dedicated-server relay
		_diag_tx_ws += 1

# Poll the JS Opus encoder queue and send any completed packets over the active channel.
# Called every _process tick so the async output doesn't wait for the next VAD interval.
func _poll_opus_encoded() -> void:
	var raw = JavaScriptBridge.eval("(function(){var c=window.TBVoice.pollEnc(),r=[];for(var i=0;i<c.length;i++){r.push(c[i]);}return JSON.stringify(r);})()")
	if not raw is String:
		return
	var chunks = JSON.parse_string(raw)
	if not chunks is Array or chunks.is_empty():
		return
	var my_id: int = multiplayer.get_unique_id()
	for chunk in chunks:
		var payload := PackedByteArray()
		payload.append(VOICE_FMT_OPUS)
		for b in chunk:
			payload.append(int(b))
		if _rtc_open and _vch != null and _vch.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
			_vch.put_packet(payload)
			_diag_tx_rtc += 1
		elif multiplayer.is_server():
			_rpc_play_voice.rpc(payload, my_id)
			_diag_tx_ws += 1
		else:
			_rpc_voice.rpc_id(1, payload, my_id)
			_diag_tx_ws += 1

# Poll the JS Opus decoder queue for each active speaker and push decoded PCM to
# their jitter buffers. Called every _process tick so decoded audio is never stale.
func _poll_opus_decoded() -> void:
	for pid in _speakers.keys():
		var raw = JavaScriptBridge.eval("JSON.stringify(window.TBVoice.pollDec(%d))" % pid)
		if not raw is String:
			continue
		var frames = JSON.parse_string(raw)
		if not frames is Array:
			continue
		for frame in frames:
			if not frame is Array:
				continue
			var mono := PackedFloat32Array()
			mono.resize(frame.size())
			for i in frame.size():
				mono[i] = clampf(float(frame[i]), -1.0, 1.0)
			_push_pcm_to_jitter(pid, mono)

# Clear the streaming resampler + pre-roll (called on mute/unmute only — the
# resample timeline stays continuous across speech bursts).
func _resample_reset() -> void:
	_rs_in   = PackedFloat32Array()
	_rs_pos  = 0.0
	_preroll = PackedFloat32Array()

# Instance wrapper: append the new mic chunk (frames[i].x) to the persistent source
# buffer, then emit every destination sample that is now fully available, carrying
# the unconsumed tail + fractional phase to the next call. This keeps the resample
# timeline continuous across 20 ms chunks (no per-chunk window reset / dropped
# fractional sample — the old code's ~50 Hz buzz source).
func _resample_stream(frames: PackedVector2Array, src_rate: float, dst_rate: float) -> PackedFloat32Array:
	var base := _rs_in.size()
	_rs_in.resize(base + frames.size())
	for i in frames.size():
		_rs_in[base + i] = frames[i].x
	var r := resample_stream(_rs_in, src_rate, dst_rate, _rs_pos)
	_rs_in  = r["tail"]
	_rs_pos = r["pos"]
	return r["out"]

# Pure streaming resampler (static → unit-testable headless). Given a buffer of
# pending source samples, the rates, and the carried fractional cursor, returns:
#   out:  destination samples emitted this call ([-1, 1])
#   tail: source samples not yet consumed (carry to the next call)
#   pos:  fractional cursor within `tail`
# Resampling in chunks (accumulate into `tail`, feed back `pos`) yields the SAME
# stream as one-shot resampling — that continuity is what the tests assert.
#
# Downsampling (the usual 44.1/48 kHz -> 24 kHz) averages each output sample's
# source window with FRACTIONAL edge weights — a band-limiting low-pass that
# prevents aliasing. Upsampling uses linear interpolation.
static func resample_stream(src: PackedFloat32Array, src_rate: float, dst_rate: float, pos: float) -> Dictionary:
	var out := PackedFloat32Array()
	var n := src.size()
	if src_rate <= 0.0 or dst_rate <= 0.0 or n == 0:
		return { "out": out, "tail": src, "pos": pos }
	var step := src_rate / dst_rate   # source samples per output sample
	var p := pos
	if step > 1.0:
		# Downsample: fractional-weighted average over the window [p, p+step).
		while p + step <= float(n):
			var a := p
			var b := p + step
			var i0 := int(floor(a))
			var i1 := int(floor(b))
			var sum := 0.0
			var wsum := 0.0
			for i in range(i0, i1 + 1):
				if i < 0 or i >= n:
					continue
				var lo: float = maxf(a, float(i))
				var hi: float = minf(b, float(i + 1))
				var w: float = hi - lo
				if w <= 0.0:
					continue
				sum  += src[i] * w
				wsum += w
			out.append(sum / maxf(wsum, 1e-6))
			p += step
	else:
		# Upsample / 1:1: linear interpolation.
		while p + 1.0 <= float(n):
			var i0 := int(floor(p))
			var i1: int = mini(i0 + 1, n - 1)
			var frac := p - float(i0)
			out.append(src[i0] + (src[i1] - src[i0]) * frac)
			p += step
	# Drop fully-consumed source, keep the tail + fractional phase for next call.
	var consumed: int = mini(int(floor(p)), n)
	var tail: PackedFloat32Array = src.slice(consumed) if consumed > 0 else src
	return { "out": out, "tail": tail, "pos": p - float(consumed) }

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
	# Native builds need the webrtc-native GDExtension; without it
	# WebRTCPeerConnection.new() returns a non-functional object whose initialize()
	# fails. On web the browser supplies WebRTC. Either way: if we can't create +
	# initialize a peer connection, fall back to the WebSocket relay.
	# Do NOT probe-then-free: WebRTCPeerConnection is RefCounted and .free() on it
	# raises "Attempted to free a RefCounted object", which breaks the editor
	# debugger the moment a game is joined.
	var rtc := WebRTCPeerConnection.new()
	if rtc == null or rtc.initialize({ "iceServers": _ice_servers() }) != OK:
		push_warning("[voice] WebRTC unavailable — using WebSocket relay")
		return
	_rtc = rtc
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

## Client → server: periodic voice quality diagnostic. Server logs the payload.
## Alphabetically between _rpc_voice_answer and _rpc_voice_ice — MUST stay here
## to keep RPC indices in sync with voice_relay.gd on the server.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_voice_diag(_payload: String) -> void:
	pass   # server-only — handled in voice_relay.gd

## Trickle ICE, both directions (any_peer so the server can send it back).
@rpc("any_peer", "call_remote", "reliable")
func _rpc_voice_ice(media: String, index: int, name: String) -> void:
	if _rtc != null:
		_rtc.add_ice_candidate(media, index, name)

# ── Client-side diagnostics ───────────────────────────────────────────────────
func _send_diag() -> void:
	var ch_state := "none"
	if _vch != null:
		var s: int = _vch.get_ready_state()
		ch_state = ["CONNECTING","OPEN","CLOSING","CLOSED"][s] if s < 4 else str(s)

	var jitter_info := ""
	for pid in _jq.keys():
		var q: PackedVector2Array = _jq.get(pid, PackedVector2Array())
		var pos: int = _jq_pos.get(pid, 0)
		var queued_ms := int(float(q.size() - pos) / float(VOICE_RATE) * 1000.0)
		var playing: bool = bool(_jq_play.get(pid, false))
		jitter_info += " peer%d:q%dms(%s)" % [pid, queued_ms, "play" if playing else "prebuf"]

	var cal_str := "pending"
	if _rate_cal_measured >= 0.0:
		cal_str = "%.0fHz" % _rate_cal_measured
	var codec_str := "opus" if _opus_web else ("pcm16" if _rtc_open else "adpcm")
	var payload := "peer=%d path=%s ch=%s cap=%.0fHz cal=%s codec=%s tx_rtc=%d tx_ws=%d underruns=%d jitter=[%s]" % [
		multiplayer.get_unique_id(),
		"UDP/DataChannel" if _rtc_open else "WebSocket",
		ch_state,
		_capture_rate,
		cal_str,
		codec_str,
		_diag_tx_rtc, _diag_tx_ws, _diag_underrun,
		jitter_info.strip_edges()
	]
	_diag_tx_rtc   = 0
	_diag_tx_ws    = 0
	_diag_underrun = 0
	_rpc_voice_diag.rpc_id(1, payload)

# ── Playback ──────────────────────────────────────────────────────────────────
# Decode an incoming packet and QUEUE it (the jitter buffer). _pump_speakers feeds
# the generator from the queue at a steady depth — never push straight to the
# generator here or bursty TCP arrival makes it underrun (choppy).
func _push_to_speaker(sender_id: int, bytes: PackedByteArray) -> void:
	if bytes.size() < 2:
		return

	var fmt := int(bytes[0])
	var body := bytes.slice(1)
	if not _speakers.has(sender_id):
		var gen    = AudioStreamGenerator.new()
		gen.mix_rate      = VOICE_RATE
		gen.buffer_length = GEN_BUFFER_LEN
		var player = AudioStreamPlayer3D.new()
		player.stream       = gen
		player.autoplay     = true
		# Web export defaults to SAMPLE playback (audio/general/default_playback_type.web),
		# which cannot play an AudioStreamGenerator — the speaker would be silent
		# in browsers. Force STREAM playback (native already defaults to it).
		player.playback_type = AudioServer.PLAYBACK_TYPE_STREAM
		# Spatial voice, tuned so it can never be inaudible:
		#  - max_distance = 0  → no hard cutoff (unit_size=3/max=40 made distant
		#    teammates silent in the 54-unit maze — reported as "voice broken")
		#  - unit_size = 12    → gentle inverse-distance falloff, still directional
		#  - filter cutoff 20.5 kHz → disable the default distance low-pass
		#    (5 kHz default muffles speech badly)
		player.max_distance = 0.0
		player.unit_size    = 12.0
		player.attenuation_filter_cutoff_hz = 20500
		add_child(player)
		player.play()   # belt & braces alongside autoplay — playback must be live
		var pb := player.get_stream_playback() as AudioStreamGeneratorPlayback
		if pb == null:
			# Playback not obtainable (should not happen once playing) — drop the
			# node so the NEXT packet recreates the speaker instead of leaving a
			# permanently silent entry in _speakers.
			push_warning("[voice] no generator playback for peer %d — retrying on next packet" % sender_id)
			player.queue_free()
			return
		_speaker_nodes[sender_id] = player
		_speakers[sender_id]      = pb
		_jq[sender_id]      = PackedVector2Array()
		_jq_pos[sender_id]  = 0
		_jq_play[sender_id] = false

	if fmt == VOICE_FMT_OPUS and _opus_web:
		# Async: submit to the JS decoder; _poll_opus_decoded() pushes PCM next frame.
		JavaScriptBridge.eval("window.TBVoice.initDec(%d)" % sender_id)
		var js_bytes: JavaScriptObject = JavaScriptBridge.create_object("Uint8Array", body)
		JavaScriptBridge.get_interface("window")["_tbv_opus"] = js_bytes
		JavaScriptBridge.eval("window.TBVoice.decode(%d, window._tbv_opus, %d)" % [sender_id, Time.get_ticks_usec()])
		return

	var mono: PackedFloat32Array
	if fmt == VOICE_FMT_PCM16:
		mono = _unpack_pcm16(body)
	else:
		mono = adpcm_decode(body)
	_push_pcm_to_jitter(sender_id, mono)

# Append decoded mono PCM to sender_id's jitter queue, emitting voice_received and
# capping the queue at JITTER_MAX to prevent unbounded latency growth.
func _push_pcm_to_jitter(sender_id: int, mono: PackedFloat32Array) -> void:
	voice_received.emit(sender_id, mono)
	var frames := PackedVector2Array()
	frames.resize(mono.size())
	for i in mono.size():
		var s := mono[i]
		frames[i] = Vector2(s, s)
	var q: PackedVector2Array = _jq[sender_id]
	q.append_array(frames)
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
				# Generator drained: push a short silence pad so the audio stream keeps
				# running smoothly (no click), then enter prebuf mode. The listener hears
				# soft silence during the pad rather than an abrupt stop.
				var pad := int(JITTER_SILENCE_PAD * rate)
				var silence := PackedVector2Array()
				silence.resize(pad)
				pb.push_buffer(silence)
				_jq_play[pid] = false   # re-prebuffer after the silence plays out
				_diag_underrun += 1
			continue
		pb.push_buffer(q.slice(pos, pos + n))
		pos += n
		_jq_pos[pid] = pos
		# Compact the queue periodically so the read offset can't grow unbounded.
		if pos > prebuf * 2:
			_jq[pid] = q.slice(pos)
			_jq_pos[pid] = 0

# ── Spatial audio positioning ─────────────────────────────────────────────────
# Called by main.gd each frame with the remote peer's world position so the
# AudioStreamPlayer3D node tracks them through the maze.
func set_speaker_position(pid: int, pos: Vector3) -> void:
	var node = _speaker_nodes.get(pid)
	if node != null and is_instance_valid(node):
		node.global_position = pos

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
	
static func _pack_pcm16(samples: PackedFloat32Array) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(samples.size() * 2)
	for i in samples.size():
		var s := int(clampf(samples[i], -1.0, 1.0) * 32767.0)
		if s < 0: s += 65536
		out[i * 2] = s & 0xFF
		out[i * 2 + 1] = (s >> 8) & 0xFF
	return out

static func _unpack_pcm16(bytes: PackedByteArray) -> PackedFloat32Array:
	var n := bytes.size() / 2
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var v := int(bytes[i * 2]) | (int(bytes[i * 2 + 1]) << 8)
		if v >= 32768: v -= 65536
		out[i] = float(v) / 32767.0
	return out
