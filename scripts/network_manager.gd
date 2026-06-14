extends Node
class_name NetworkManager

signal lobby_ready(seed_val: int)
signal lobby_updated(peer_ids: Array)
signal connected
signal peer_left(pid: int)   # pid = -1 means the whole server is gone

const PORT := 9999

# Assignments: peer_id -> player_index (set before lobby_ready fires)
var assignments: Dictionary = {}

# Whether this peer can start the game (first-connected / host)
var is_captain: bool = false

# Ordered list of all peer IDs in the lobby (index = player_index)
var _peers: Array = []

# Ping (round-trip time in ms); 0 for the host / singleplayer
var ping_ms: int = 0
var _ping_timer: float = 0.5   # send first ping quickly, then every 5 s

# ── Listen-server host ────────────────────────────────────────────────────────
func host_game() -> void:
	_peers      = [1]   # host is always index 0
	is_captain  = true
	assignments = { 1: 0 }

	var peer = WebSocketMultiplayerPeer.new()
	var err  = peer.create_server(PORT)
	if err != OK:
		push_error("NetworkManager: server creation failed (%d)" % err); return
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_on_host_peer_connected)
	multiplayer.peer_disconnected.connect(_on_host_peer_disconnected)
	# Immediately notify UI so the lobby room shows the host's own slot
	lobby_updated.emit(Array(_peers))

func _on_host_peer_connected(id: int) -> void:
	_peers.append(id)
	assignments[id] = _peers.size() - 1
	_rpc_lobby_update.rpc(Array(_peers))
	lobby_updated.emit(Array(_peers))

# ── Join (client connecting to listen-server or dedicated server) ─────────────
func join_game(ip: String) -> void:
	var url = "ws://%s:%d" % [ip, PORT]
	var peer = WebSocketMultiplayerPeer.new()
	var err  = peer.create_client(url)
	if err != OK:
		push_error("NetworkManager: connect to %s failed (%d)" % [url, err]); return
	multiplayer.multiplayer_peer = peer
	multiplayer.connected_to_server.connect(_on_connected_ok)
	multiplayer.connection_failed.connect(_on_conn_fail)
	multiplayer.server_disconnected.connect(_on_server_left)

func _on_connected_ok() -> void:
	connected.emit()

# ── Start the game ────────────────────────────────────────────────────────────
## Called by the captain (host / first joiner) when ready to start.
func request_start() -> void:
	if multiplayer.is_server():
		# Listen-server host: trigger directly
		_do_start()
	else:
		# Client connected to dedicated server: ask the server to start
		_rpc_request_start.rpc_id(1)

func _do_start() -> void:
	if _peers.size() < 1: return
	var s = randi()
	assignments.clear()
	for i in _peers.size():
		assignments[_peers[i]] = i
	_rpc_start_game.rpc(s, assignments)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_start() -> void:
	# Runs only on the server/host peer
	if not multiplayer.is_server(): return
	if _peers.size() < 2: return
	_do_start()

@rpc("authority", "call_local", "reliable")
func _rpc_start_game(seed_val: int, asns: Dictionary) -> void:
	assignments = asns
	is_captain = (asns.get(multiplayer.get_unique_id(), -1) == 0)
	lobby_ready.emit(seed_val)

# ── Lobby list broadcast (server → clients) ───────────────────────────────────
@rpc("authority", "call_remote", "reliable")
func _rpc_lobby_update(peers: Array) -> void:
	_peers     = peers
	is_captain = (_peers.size() > 0 and _peers[0] == multiplayer.get_unique_id())
	lobby_updated.emit(peers)

# ── Peer lifecycle ────────────────────────────────────────────────────────────
func _on_host_peer_disconnected(id: int) -> void:
	_peers.erase(id)
	assignments.erase(id)
	# Update lobby UI on all peers (harmless if game already started)
	_rpc_lobby_update.rpc(Array(_peers))
	lobby_updated.emit(Array(_peers))
	# Tell every peer (including self) to remove this player from the game world
	_rpc_peer_left.rpc(id)

## Reliable broadcast from server so every client removes the disconnected player.
@rpc("authority", "call_local", "reliable")
func _rpc_peer_left(pid: int) -> void:
	peer_left.emit(pid)

func _on_peer_disconnected(_id: int) -> void:
	pass  # server-side duplicate; handled by _on_host_peer_disconnected

func _on_conn_fail() -> void:
	push_error("NetworkManager: connection failed")

func _on_server_left() -> void:
	peer_left.emit(-1)   # -1 = host gone, caller should reload/quit

# ── Ping / pong ───────────────────────────────────────────────────────────────
# Client sends timestamp → server echoes it → client measures round-trip.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_ping(timestamp_ms: int) -> void:
	# Runs on the server: echo straight back to the sender only.
	_rpc_pong.rpc_id(multiplayer.get_remote_sender_id(), timestamp_ms)

@rpc("authority", "call_remote", "reliable")
func _rpc_pong(timestamp_ms: int) -> void:
	# Runs on the client: measure round-trip.
	ping_ms = Time.get_ticks_msec() - timestamp_ms

# ── Poll ──────────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	if multiplayer.has_multiplayer_peer():
		multiplayer.multiplayer_peer.poll()
		# Only clients ping the server (host ping to self is always 0)
		if not multiplayer.is_server():
			_ping_timer -= delta
			if _ping_timer <= 0.0:
				_ping_timer = 5.0
				_rpc_ping.rpc_id(1, Time.get_ticks_msec())
