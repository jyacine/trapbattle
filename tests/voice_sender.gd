extends SceneTree

const SERVER_HOST := "34-155-132-207.nip.io"
const CONNECT_TIMEOUT := 20.0
const LOBBY_TIMEOUT := 25.0
const GAME_START_TIMEOUT := 25.0
const SEND_INTERVAL := 0.02
const VOICE_RATE := 24000

var _main: Node = null
var _net: NetworkManager = null
var _voice: VoiceManager = null

var _connected := false
var _game_started := false
var _lobby_peers: Array = []

var _input_path := ""
var _status_path := ""

func _initialize() -> void:
	print("── E2E Voice Test: Sender ──")
	_parse_args()

	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)

	await process_frame
	await process_frame

	_net = _main.get_node_or_null("NetworkManager")
	if _net == null:
		_fail("NetworkManager not found")
		return

	_net.connected.connect(func():
		_connected = true
		print("[sender] connected")
	)

	_net.lobby_updated.connect(func(peers: Array):
		_lobby_peers = peers
		print("[sender] Lobby: %d peer(s)" % peers.size())
	)

	_net.lobby_ready.connect(func(_seed: int, _map: int):
		_game_started = true
		print("[sender] Game started")
	)

	_net.my_name = "E2E_Sender"
	_net.my_color_idx = 0
	print("[sender] Connecting → wss://%s" % SERVER_HOST)
	_net.join_game(SERVER_HOST)

	if not await _wait_until(func(): return _connected, CONNECT_TIMEOUT):
		_fail("connect timeout")
		return

	# Wait for the E2E receiver partner specifically (not just any peer).
	if not await _wait_until(func(): return _has_e2e_partner("E2E_Receiver"), LOBBY_TIMEOUT):
		_fail("E2E_Receiver not in lobby after %ds — is another test already running?" % int(LOBBY_TIMEOUT))
		return

	if _lobby_peers.size() > 2:
		print("[sender] WARNING: %d peers in lobby (including non-E2E players)" % _lobby_peers.size())

	# Server allows any peer to request start (no captain validation).
	print("[sender] requesting game start")
	_net.request_start()

	if not await _wait_until(func(): return _game_started, GAME_START_TIMEOUT):
		_fail("game start timeout")
		return

	if not await _wait_until(func():
		_voice = _main.get_node_or_null("VoiceManager")
		return _voice != null
	, 10.0):
		_fail("VoiceManager not found")
		return

	if _input_path == "":
		_fail("missing input=...")
		return

	var wav = _read_wav_mono_i16(_input_path)
	if wav.is_empty():
		_fail("cannot read wav")
		return

	var samples: PackedFloat32Array = wav["samples"]
	var sr: int = wav["rate"]
	if sr != VOICE_RATE:
		_fail("input sr must be %d, got %d" % [VOICE_RATE, sr])
		return

	print("[sender] WAV loaded: %d samples (%.2fs at %d Hz)" % [samples.size(), float(samples.size()) / sr, sr])

	var frame_len := int(VOICE_RATE * SEND_INTERVAL)
	var pred := 0
	var idx := 0
	var sent := 0

	for off in range(0, samples.size(), frame_len):
		var chunk: PackedFloat32Array = samples.slice(off, min(off + frame_len, samples.size()))
		if chunk.is_empty():
			continue

		var enc: Dictionary = VoiceManager.adpcm_encode(chunk, pred, idx)
		var bytes: PackedByteArray = enc["bytes"]
		pred = int(enc["predictor"])
		idx = int(enc["index"])

		var payload := PackedByteArray()
		payload.append(VoiceManager.VOICE_FMT_ADPCM)
		payload.append_array(bytes)
		var my_id = _main.multiplayer.get_unique_id()
		_voice._rpc_voice.rpc_id(1, payload, my_id)

		sent += 1
		await create_timer(SEND_INTERVAL).timeout

	print("[sender] voice packets sent: %d" % sent)
	print("E2E: voice send completed")
	_write_status("OK packets=%d" % sent)
	quit(0)

func _has_e2e_partner(name: String) -> bool:
	for pid in _net.player_names.keys():
		if _net.player_names[pid] == name:
			return true
	return false

func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("input="):
			_input_path = a.substr(6)
		elif a.begins_with("status="):
			_status_path = a.substr(7)

func _wait_until(pred: Callable, timeout_s: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while (Time.get_ticks_msec() - t0) / 1000.0 <= timeout_s:
		if pred.call():
			return true
		await process_frame
	return false


func _read_wav_mono_i16(path: String) -> Dictionary:
	var f = FileAccess.open(path, FileAccess.READ)
	if f == null or f.get_length() < 44:
		return {}
	var hdr = f.get_buffer(44)
	var ch = hdr.decode_u16(22)
	var sr = hdr.decode_u32(24)
	var bits = hdr.decode_u16(34)
	var data_sz = hdr.decode_u32(40)
	if ch != 1 or bits != 16:
		return {}
	var raw = f.get_buffer(data_sz)
	var n = raw.size() / 2
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var v = int(raw[i * 2]) | (int(raw[i * 2 + 1]) << 8)
		if v >= 32768: v -= 65536
		out[i] = float(v) / 32768.0
	return {"rate": int(sr), "samples": out}

func _write_status(msg: String) -> void:
	if _status_path == "": return
	var f = FileAccess.open(_status_path, FileAccess.WRITE)
	if f: f.store_string(msg + "\n")

func _fail(msg: String) -> void:
	push_error("[sender] FAIL: %s" % msg)
	_write_status("FAIL " + msg)
	quit(1)
