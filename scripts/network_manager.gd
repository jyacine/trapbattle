extends Node
class_name NetworkManager

signal lobby_ready(seed_val: int)   # fires on all peers (with the maze seed)
signal connected                    # client: TCP handshake done, waiting for role
signal peer_left

const PORT := 9999

var my_role: String = "player"      # "player" | "robot" | "server"
var is_dedicated_server: bool = false

# Peer IDs for both roles — set before lobby_ready fires on every peer
var player_peer_id: int = 0
var robot_peer_id:  int = 0

# Listen-server only: the joining client's peer_id
var client_peer_id: int = -1

# Dedicated-server only: peer_id -> role map
var _role_map: Dictionary = {}

# ── Listen server (host also plays as "player") ───────────────────────────────
func host_game() -> void:
	my_role        = "player"
	player_peer_id = 1   # host is always peer_id 1
	var peer = ENetMultiplayerPeer.new()
	var err  = peer.create_server(PORT, 2)
	if err != OK:
		push_error("NetworkManager: server creation failed (%d)" % err)
		return
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_on_listen_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

func _on_listen_peer_connected(id: int) -> void:
	client_peer_id = id
	robot_peer_id  = id
	lobby_ready.emit(randi())   # host picks seed; lobby_ui broadcasts via _rpc_start

# ── Dedicated server (no player on the server process) ───────────────────────
func start_dedicated_server() -> void:
	is_dedicated_server = true
	my_role = "server"
	var peer = ENetMultiplayerPeer.new()
	var err  = peer.create_server(PORT, 2)
	if err != OK:
		push_error("NetworkManager: dedicated server failed (%d)" % err)
		return
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_on_dedicated_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	print("[Server] Listening on port %d..." % PORT)

func _on_dedicated_peer_connected(id: int) -> void:
	var roles = ["player", "robot"]
	_role_map[id] = roles[_role_map.size() % 2]
	print("[Server] Peer %d -> %s  (%d/2)" % [id, _role_map[id], _role_map.size()])
	if _role_map.size() < 2:
		return
	# Both players connected: pick seed, assign roles, start
	var p_id = -1; var r_id = -1
	for pid in _role_map:
		if _role_map[pid] == "player": p_id = pid
		else:                          r_id = pid
	player_peer_id = p_id
	robot_peer_id  = r_id
	var s = randi()
	print("[Server] Starting — seed=%d  player=%d  robot=%d" % [s, p_id, r_id])
	_rpc_assign_role.rpc_id(p_id, "player", s, p_id, r_id)
	_rpc_assign_role.rpc_id(r_id, "robot",  s, p_id, r_id)
	lobby_ready.emit(s)   # server-side start (no lobby_ui on server)

# Sent from server to each client individually (call_remote = runs only on recipient)
@rpc("authority", "call_remote", "reliable")
func _rpc_assign_role(role: String, seed_val: int, p_peer: int, r_peer: int) -> void:
	my_role        = role
	player_peer_id = p_peer
	robot_peer_id  = r_peer
	print("[Client] Role=%s  seed=%d" % [role, seed_val])
	lobby_ready.emit(seed_val)

# ── Client (joins either server type) ────────────────────────────────────────
func join_game(ip: String) -> void:
	# Tentative role for listen-server; overwritten by _rpc_assign_role for dedicated
	my_role = "robot"
	var peer = ENetMultiplayerPeer.new()
	var err  = peer.create_client(ip, PORT)
	if err != OK:
		push_error("NetworkManager: connect to %s:%d failed (%d)" % [ip, PORT, err])
		return
	multiplayer.multiplayer_peer = peer
	multiplayer.connected_to_server.connect(_on_connected_ok)
	multiplayer.connection_failed.connect(_on_conn_fail)
	multiplayer.server_disconnected.connect(_on_server_left)

func _on_connected_ok() -> void:
	connected.emit()   # UI can show "waiting for opponent..."

func _on_peer_disconnected(_id: int) -> void:
	peer_left.emit()

func _on_conn_fail() -> void:
	push_error("NetworkManager: connection failed")

func _on_server_left() -> void:
	peer_left.emit()
