extends SceneTree
## Bidirectional E2E voice peer.
## Args: input=<path>  output=<path>  [captain]
##   captain → this peer requests game start; the other peer just waits.
## Both peers send their input WAV as ADPCM while simultaneously recording
## all incoming voice from the partner. On silence, writes output WAV and exits.

const SERVER_HOST        := "172-174-208-254.nip.io"
const CONNECT_TIMEOUT    := 20.0
const LOBBY_TIMEOUT      := 30.0
const GAME_START_TIMEOUT := 30.0
const SEND_INTERVAL      := 0.02
const IDLE_STOP_SEC      := 2.0
const RECORD_TIMEOUT     := 60.0
const VOICE_RATE         := 24000

var _main:  Node           = null
var _net:   NetworkManager = null
var _voice: VoiceManager   = null

var _connected:     bool  = false
var _game_started:  bool  = false
var _lobby_peers:   Array = []

var _is_captain: bool   = false
var _input_path: String = ""
var _out_path:   String = ""

var _rx:            PackedFloat32Array
var _last_voice_ms: int  = 0
var _recording:     bool = false

func _initialize() -> void:
	_parse_args()
	var tag := "[p1]" if _is_captain else "[p2]"
	print("── E2E Voice Test: %s ──" % ("P1 Captain" if _is_captain else "P2"))

	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)
	await process_frame
	await process_frame

	_net = _main.get_node_or_null("NetworkManager")
	if _net == null:
		_fail("NetworkManager not found"); return

	_net.connected.connect(func():
		_connected = true
		print("%s connected" % tag)
	)
	_net.lobby_updated.connect(func(peers: Array):
		_lobby_peers = peers
		print("%s Lobby: %d peer(s)" % [tag, peers.size()])
	)
	_net.lobby_ready.connect(func(_seed: int, _map: int):
		_game_started = true
		print("%s Game started" % tag)
	)

	_net.my_name      = "E2E_P1" if _is_captain else "E2E_P2"
	_net.my_color_idx = 0        if _is_captain else 1
	print("%s Connecting → wss://%s" % [tag, SERVER_HOST])
	_net.join_game(SERVER_HOST)

	if not await _wait_until(func(): return _connected, CONNECT_TIMEOUT):
		_fail("connect timeout"); return

	if not await _wait_until(func(): return _lobby_peers.size() >= 2, LOBBY_TIMEOUT):
		_fail("partner did not join lobby"); return

	if _is_captain:
		print("%s requesting game start" % tag)
		_net.request_start()

	if not await _wait_until(func(): return _game_started, GAME_START_TIMEOUT):
		_fail("game start timeout"); return

	if not await _wait_until(func():
		_voice = _main.get_node_or_null("VoiceManager")
		return _voice != null
	, 10.0):
		_fail("VoiceManager not found"); return

	if _input_path == "" or _out_path == "":
		_fail("missing input= or output= args"); return

	var wav := _read_wav_mono_i16(_input_path)
	if wav.is_empty():
		_fail("cannot read input wav"); return

	var samples: PackedFloat32Array = wav["samples"]
	var sr: int = wav["rate"]
	if sr != VOICE_RATE:
		_fail("input sr must be %d, got %d" % [VOICE_RATE, sr]); return

	print("%s WAV: %d samples (%.2fs)" % [tag, samples.size(), float(samples.size()) / sr])

	_last_voice_ms = Time.get_ticks_msec()
	_voice.voice_received.connect(_on_voice_received)

	# ── Send loop — voice_received fires in the 20 ms gaps between sends ────────
	# PCM16 matches the real in-game WebSocket fallback path (voice_manager.gd).
	var frame_len := int(VOICE_RATE * SEND_INTERVAL)
	var sent := 0
	for off in range(0, samples.size(), frame_len):
		var chunk: PackedFloat32Array = samples.slice(off, mini(off + frame_len, samples.size()))
		if chunk.is_empty(): continue
		var payload := PackedByteArray()
		payload.append(VoiceManager.VOICE_FMT_PCM16)
		payload.append_array(VoiceManager._pack_pcm16(chunk))
		_voice._rpc_voice.rpc_id(1, payload, _main.multiplayer.get_unique_id())
		sent += 1
		await create_timer(SEND_INTERVAL).timeout

	print("%s sent %d packets — waiting for partner's voice tail" % [tag, sent])

	# ── Wait until the partner's stream goes silent ──────────────────────────────
	var t0 := Time.get_ticks_msec()
	while true:
		await process_frame
		if float(Time.get_ticks_msec() - t0) / 1000.0 > RECORD_TIMEOUT: break
		if _recording:
			if float(Time.get_ticks_msec() - _last_voice_ms) / 1000.0 > IDLE_STOP_SEC: break

	if _rx.is_empty():
		_fail("no received voice"); return

	_write_wav_mono_i16(_out_path, _rx, VOICE_RATE)
	print("%s wrote %d samples → %s" % [tag, _rx.size(), _out_path])
	print("E2E: peer done")
	quit(0)


func _on_voice_received(_sender_id: int, voice_samples: PackedFloat32Array) -> void:
	_rx.append_array(voice_samples)
	_recording     = true
	_last_voice_ms = Time.get_ticks_msec()


func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		if   a.begins_with("input="):  _input_path = a.substr(6)
		elif a.begins_with("output="): _out_path   = a.substr(7)
		elif a == "captain":           _is_captain = true


func _wait_until(pred: Callable, timeout_s: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while (Time.get_ticks_msec() - t0) / 1000.0 <= timeout_s:
		if pred.call(): return true
		await process_frame
	return false


func _read_wav_mono_i16(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null or f.get_length() < 44: return {}
	var hdr     := f.get_buffer(44)
	var ch      := hdr.decode_u16(22)
	var sr      := hdr.decode_u32(24)
	var bits    := hdr.decode_u16(34)
	var data_sz := hdr.decode_u32(40)
	if ch != 1 or bits != 16: return {}
	var raw := f.get_buffer(data_sz)
	var n   := raw.size() / 2
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var v := int(raw[i * 2]) | (int(raw[i * 2 + 1]) << 8)
		if v >= 32768: v -= 65536
		out[i] = float(v) / 32768.0
	return {"rate": int(sr), "samples": out}


func _write_wav_mono_i16(path: String, samples: PackedFloat32Array, rate: int) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null: _fail("cannot write %s" % path); return
	var n         := samples.size()
	var data_size := n * 2
	f.store_buffer("RIFF".to_ascii_buffer()); f.store_32(36 + data_size)
	f.store_buffer("WAVE".to_ascii_buffer())
	f.store_buffer("fmt ".to_ascii_buffer()); f.store_32(16); f.store_16(1); f.store_16(1)
	f.store_32(rate); f.store_32(rate * 2); f.store_16(2); f.store_16(16)
	f.store_buffer("data".to_ascii_buffer()); f.store_32(data_size)
	var raw := PackedByteArray()
	raw.resize(data_size)
	for i in n:
		var s := int(clampf(samples[i], -1.0, 1.0) * 32767.0)
		if s < 0: s += 65536
		raw[i * 2]     = s & 0xFF
		raw[i * 2 + 1] = (s >> 8) & 0xFF
	f.store_buffer(raw)


func _fail(msg: String) -> void:
	push_error("[peer] FAIL: %s" % msg)
	quit(1)
