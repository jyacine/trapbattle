extends Node
class_name NetworkManager

signal lobby_ready(seed_val: int)
signal lobby_updated(peer_ids: Array)
signal connected
signal peer_left(pid: int)            # pid = -1 means the whole server is gone
signal player_joined_mid_game(pid: int, player_index: int)  # late joiner during live game

const PORT := 9999

# Assignments: peer_id -> player_index (set before lobby_ready fires)
var assignments: Dictionary = {}

# Whether this peer can start the game (first-connected / host)
var is_captain: bool = false

# Ordered list of all peer IDs in the lobby (index = player_index)
var _peers: Array = []

# Player identity — set these before calling host_game() / join_game()
var my_name:      String = ""
var my_color_idx: int    = 0

# Lobby-wide name/color maps (peer_id -> value); updated by _rpc_lobby_update
var player_names:        Dictionary = {}
var player_color_indices: Dictionary = {}

# Ping (round-trip time in ms); 0 for the host / singleplayer
var ping_ms: int = 0
var _ping_timer: float = 0.5   # send first ping quickly, then every 1 s

# Late-join support — host tracks whether game is live
var game_started: bool = false   # public: read by LobbyUI to skip lobby on late join
var _game_seed:    int  = 0
var _game_map:     int  = 1   # map id chosen for the current match (synced to all)

# ── Listen-server host ────────────────────────────────────────────────────────
func host_game() -> void:
	_peers      = [1]   # host is always index 0
	is_captain  = true
	assignments = { 1: 0 }
	player_names[1]         = my_name
	player_color_indices[1] = my_color_idx

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
	if game_started:
		# Game already running — skip lobby handshake entirely.
		# Slot assignment + late-join RPC are sent in _rpc_join_info once the
		# peer sends their name/color.
		return
	assignments[id] = _peers.size() - 1
	# Broadcast current names/colors; the new peer will call _rpc_join_info shortly
	_rpc_lobby_update.rpc(Array(_peers), player_names, player_color_indices)
	lobby_updated.emit(Array(_peers))

# ── Join (client connecting to listen-server or dedicated server) ─────────────
func join_game(ip: String) -> void:
	# Connect over standard HTTPS port 443 (Caddy terminates TLS there and proxies
	# to the Godot backend). Using 443 avoids non-standard-port browser quirks.
	var url = "wss://%s" % ip
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
	_rpc_join_info.rpc_id(1, my_name, my_color_idx)

# ── Start the game ────────────────────────────────────────────────────────────
## Called by the captain (host / first joiner) when ready to start.
## map_id < 0 means "use the locally selected map" (Config.selected_map).
func request_start(map_id: int = -1) -> void:
	if map_id < 0:
		map_id = Config.selected_map
	if multiplayer.is_server():
		# Listen-server host: trigger directly
		_do_start(map_id)
	else:
		# Client connected to dedicated server: ask the server to start
		_rpc_request_start.rpc_id(1, map_id)

func _do_start(map_id: int) -> void:
	if _peers.size() < 1: return
	var s = randi()
	assignments.clear()
	for i in _peers.size():
		assignments[_peers[i]] = i
	game_started = true
	_game_seed    = s
	_game_map     = map_id
	_rpc_start_game.rpc(s, assignments, map_id)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_start(map_id: int) -> void:
	# Runs only on the server/host peer
	if not multiplayer.is_server(): return
	if _peers.size() < 2: return
	_do_start(map_id)

@rpc("authority", "call_local", "reliable")
func _rpc_start_game(seed_val: int, asns: Dictionary, map_id: int) -> void:
	assignments = asns
	_game_map   = map_id
	Config.selected_map = map_id
	is_captain = (asns.get(multiplayer.get_unique_id(), -1) == 0)
	lobby_ready.emit(seed_val)

# ── Client sends name and color preference to the server/host ────────────────
@rpc("any_peer", "call_remote", "reliable")
func _rpc_join_info(name: String, color_idx: int) -> void:
	if not multiplayer.is_server(): return
	var sender = multiplayer.get_remote_sender_id()
	player_names[sender]         = name
	player_color_indices[sender] = color_idx

	if game_started:
		# Give the late joiner the next free player-index slot
		var max_idx = -1
		for idx in assignments.values():
			if idx > max_idx: max_idx = idx
		var new_idx = max_idx + 1
		assignments[sender] = new_idx

		# Tell the newcomer to start the game immediately with current assignments
		_rpc_late_join.rpc_id(sender, _game_seed, assignments, _game_map)
		# Tell every peer (including the host itself) to spawn the new player
		_rpc_spawn_late_peer.rpc(sender, new_idx)
	else:
		_rpc_lobby_update.rpc(Array(_peers), player_names, player_color_indices)
		lobby_updated.emit(Array(_peers))

# ── Lobby list broadcast (server → clients) ───────────────────────────────────
@rpc("authority", "call_remote", "reliable")
func _rpc_lobby_update(peers: Array, names: Dictionary, color_idxs: Dictionary) -> void:
	_peers               = peers
	player_names         = names
	player_color_indices = color_idxs
	is_captain = (_peers.size() > 0 and _peers[0] == multiplayer.get_unique_id())
	lobby_updated.emit(peers)

# ── Peer lifecycle ────────────────────────────────────────────────────────────
func _on_host_peer_disconnected(id: int) -> void:
	_peers.erase(id)
	assignments.erase(id)
	player_names.erase(id)
	player_color_indices.erase(id)
	_rpc_lobby_update.rpc(Array(_peers), player_names, player_color_indices)
	lobby_updated.emit(Array(_peers))
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

# ── Late-join RPCs ───────────────────────────────────────────────────────────

## Server → newcomer only: skip lobby, start game immediately.
@rpc("authority", "call_remote", "reliable")
func _rpc_late_join(seed_val: int, asns: Dictionary, map_id: int) -> void:
	assignments = asns
	_game_map   = map_id
	Config.selected_map = map_id
	is_captain  = false
	lobby_ready.emit(seed_val)

## Server → all peers (call_local so host also runs it):
## spawn one new player node for the peer that just joined mid-game.
@rpc("authority", "call_local", "reliable")
func _rpc_spawn_late_peer(pid: int, player_index: int) -> void:
	# The late joiner handles their own spawn via lobby_ready / _spawn_mp_players
	if pid == multiplayer.get_unique_id(): return
	player_joined_mid_game.emit(pid, player_index)

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
		# Only clients ping the server, and only once FULLY connected. Calling an
		# RPC while the peer is still CONNECTING errors with "peer not connected".
		if not multiplayer.is_server() \
				and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			_ping_timer -= delta
			if _ping_timer <= 0.0:
				_ping_timer = 1.0
				_rpc_ping.rpc_id(1, Time.get_ticks_msec())
