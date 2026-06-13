extends Node
class_name NetworkManager

signal lobby_ready
signal peer_left

const PORT := 9999

# "player" = host (peer_id 1), "robot" = joining client
var my_role: String = "player"
var client_peer_id: int = -1

func host_game() -> void:
	my_role = "player"
	var peer = ENetMultiplayerPeer.new()
	var err = peer.create_server(PORT, 2)
	if err != OK:
		push_error("NetworkManager: server creation failed (%d)" % err)
		return
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

func join_game(ip: String) -> void:
	my_role = "robot"
	var peer = ENetMultiplayerPeer.new()
	var err = peer.create_client(ip, PORT)
	if err != OK:
		push_error("NetworkManager: connect failed (%d)" % err)
		return
	multiplayer.multiplayer_peer = peer
	multiplayer.connected_to_server.connect(_on_connected_ok)
	multiplayer.connection_failed.connect(_on_conn_fail)
	multiplayer.server_disconnected.connect(_on_server_left)

func _on_peer_connected(id: int) -> void:
	if multiplayer.is_server():
		client_peer_id = id
		lobby_ready.emit()

func _on_peer_disconnected(_id: int) -> void:
	peer_left.emit()

func _on_connected_ok() -> void:
	lobby_ready.emit()

func _on_conn_fail() -> void:
	push_error("NetworkManager: connection failed")

func _on_server_left() -> void:
	peer_left.emit()
