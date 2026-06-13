extends Node
class_name NetworkManager

signal lobby_ready(seed_val: int)
signal connected
signal peer_left

const PORT := 9999

var my_role: String = "player"

var player_peer_id: int = 0
var robot_peer_id:  int = 0
var client_peer_id: int = -1

# ── Listen server ─────────────────────────────────────────────────────────────
func host_game() -> void:
	my_role        = "player"
	player_peer_id = 1
	var peer = WebSocketMultiplayerPeer.new()
	var err  = peer.create_server(PORT)
	if err != OK:
		push_error("NetworkManager: server creation failed (%d)" % err)
		return
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_on_listen_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

func _on_listen_peer_connected(id: int) -> void:
	client_peer_id = id
	robot_peer_id  = id
	lobby_ready.emit(randi())

# ── Client ────────────────────────────────────────────────────────────────────
func join_game(ip: String) -> void:
	my_role = "robot"
	var url = "ws://%s:%d" % [ip, PORT]
	var peer = WebSocketMultiplayerPeer.new()
	var err  = peer.create_client(url)
	if err != OK:
		push_error("NetworkManager: connect to %s failed (%d)" % [url, err])
		return
	multiplayer.multiplayer_peer = peer
	multiplayer.connected_to_server.connect(_on_connected_ok)
	multiplayer.connection_failed.connect(_on_conn_fail)
	multiplayer.server_disconnected.connect(_on_server_left)

func _on_connected_ok() -> void:
	connected.emit()

# Sent from the dedicated server to assign each client their role + maze seed.
@rpc("authority", "call_remote", "reliable")
func _rpc_assign_role(role: String, seed_val: int, p_peer: int, r_peer: int) -> void:
	my_role        = role
	player_peer_id = p_peer
	robot_peer_id  = r_peer
	print("[Client] Role=%s  seed=%d" % [role, seed_val])
	lobby_ready.emit(seed_val)

func _on_peer_disconnected(_id: int) -> void:
	peer_left.emit()

func _on_conn_fail() -> void:
	push_error("NetworkManager: connection failed")

func _on_server_left() -> void:
	peer_left.emit()

# WebSocketMultiplayerPeer must be polled manually every frame.
func _process(_delta: float) -> void:
	if multiplayer.has_multiplayer_peer():
		multiplayer.multiplayer_peer.poll()
