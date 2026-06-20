extends SceneTree

const SERVER_HOST := "172-174-208-254.nip.io"
const CONNECT_TIMEOUT := 20.0
const LOBBY_TIMEOUT := 30.0
const GAME_START_TIMEOUT := 30.0
const RECORD_TIMEOUT := 45.0
const IDLE_STOP_SEC := 1.2
const VOICE_RATE := 24000

var _main: Node = null
var _net: NetworkManager = null
var _voice: VoiceManager = null

var _connected := false
var _game_started := false
var _lobby_peers: Array = []

var _out_path := ""
var _rx := PackedFloat32Array()
var _last_voice_ms := 0
var _recording := false
var _sender_pid: int = 0  # peer_id of E2E_Sender, set after game start for filtering

func _initialize() -> void:
	print("── E2E Voice Test: Receiver ──")
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
		print("[receiver] connected")
	)

	_net.lobby_updated.connect(func(peers: Array):
		_lobby_peers = peers
		print("[receiver] Lobby: %d peer(s)" % peers.size())
	)

	_net.lobby_ready.connect(func(_seed: int):
		_game_started = true
		print("[receiver] Game started")
	)

	_net.my_name = "E2E_Receiver"
	_net.my_color_idx = 1
	print("[receiver] Connecting → wss://%s" % SERVER_HOST)
	_net.join_game(SERVER_HOST)

	if not await _wait_until(func(): return _connected, CONNECT_TIMEOUT):
		_fail("connect timeout")
		return

	# Wait for the E2E sender partner specifically (not just any peer).
	if not await _wait_until(func(): return _has_e2e_partner("E2E_Sender"), LOBBY_TIMEOUT):
		_fail("E2E_Sender not in lobby after %ds — is another test already running?" % int(LOBBY_TIMEOUT))
		return

	if _lobby_peers.size() > 2:
		print("[receiver] WARNING: %d peers in lobby (non-E2E players will be filtered)" % _lobby_peers.size())

	# Sender will call request_start(); receiver just waits for lobby_ready.
	if not await _wait_until(func(): return _game_started, GAME_START_TIMEOUT):
		_fail("game start timeout")
		return
	if not await _wait_until(func():
		_voice = _main.get_node_or_null("VoiceManager")
		return _voice != null
	, 10.0):
		_fail("VoiceManager not found")
		return
	if _out_path == "":
		_fail("missing output=...")
		return

	# Identify E2E_Sender by peer_id so we can filter out stray players' voice.
	for pid in _net.player_names.keys():
		if _net.player_names[pid] == "E2E_Sender":
			_sender_pid = pid
			break
	if _sender_pid == 0:
		_fail("cannot resolve E2E_Sender peer_id — stray player may have started the game")
		return
	print("[receiver] E2E_Sender peer_id = %d" % _sender_pid)

	_last_voice_ms = Time.get_ticks_msec()
	_voice.voice_received.connect(_on_voice_received)

	var t0 := Time.get_ticks_msec()
	while true:
		await process_frame
		var elapsed = float(Time.get_ticks_msec() - t0) / 1000.0
		if elapsed > RECORD_TIMEOUT:
			break
		if _recording:
			var idle = float(Time.get_ticks_msec() - _last_voice_ms) / 1000.0
			if idle > IDLE_STOP_SEC:
				break

	if _rx.is_empty():
		_fail("no received voice")
		return

	_write_wav_mono_i16(_out_path, _rx, VOICE_RATE)
	print("[receiver] wrote: %s (%d samples)" % [_out_path, _rx.size()])
	print("E2E: voice receive completed")
	quit(0)

func _on_voice_received(sender_id: int, samples: PackedFloat32Array) -> void:
	if _sender_pid != 0 and sender_id != _sender_pid:
		return  # ignore voice from non-E2E players
	_rx.append_array(samples)
	_recording = true
	_last_voice_ms = Time.get_ticks_msec()

func _has_e2e_partner(name: String) -> bool:
	for pid in _net.player_names.keys():
		if _net.player_names[pid] == name:
			return true
	return false

func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("output="):
			_out_path = a.substr(7)

func _wait_until(pred: Callable, timeout_s: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while (Time.get_ticks_msec() - t0) / 1000.0 <= timeout_s:
		if pred.call():
			return true
		await process_frame
	return false


func _write_wav_mono_i16(path: String, samples: PackedFloat32Array, rate: int) -> void:
	var f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_fail("cannot write wav")
		return
	var n = samples.size()
	var data_size = n * 2
	f.store_buffer("RIFF".to_ascii_buffer()); f.store_32(36 + data_size)
	f.store_buffer("WAVE".to_ascii_buffer())
	f.store_buffer("fmt ".to_ascii_buffer()); f.store_32(16); f.store_16(1); f.store_16(1)
	f.store_32(rate); f.store_32(rate * 2); f.store_16(2); f.store_16(16)
	f.store_buffer("data".to_ascii_buffer()); f.store_32(data_size)

	var raw := PackedByteArray()
	raw.resize(data_size)
	for i in n:
		var s = int(clampf(samples[i], -1.0, 1.0) * 32767.0)
		if s < 0: s += 65536
		raw[i * 2] = s & 0xFF
		raw[i * 2 + 1] = (s >> 8) & 0xFF
	f.store_buffer(raw)

func _fail(msg: String) -> void:
	push_error("[receiver] FAIL: %s" % msg)
	quit(1)
