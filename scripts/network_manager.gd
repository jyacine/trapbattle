extends Node
class_name NetworkManager

signal lobby_ready(seed_val: int)
signal connected
signal peer_left

const PORT := 9999

var my_role: String = "player"      # "player" | "robot"

# Peer IDs for both roles — populated before lobby_ready fires
var player_peer_id: int = 0
var robot_peer_id:  int = 0

# Listen-server only: the joining client's peer_id
var client_peer_id: int = -1

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

# ── Client (dedicated server OR listen server) ────────────────────────────────
func join_game(ip: String) -> void:
	my_role = "robot"   # tentative for listen-server; overwritten by _rpc_assign_role
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
	connected.emit()   # UI shows "waiting for opponent…"

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
