extends Node3D

var game_manager:   GameManager
var trap_manager:   TrapManager
var sound_manager:  SoundManager
var network_manager: NetworkManager
var voice_manager:  VoiceManager

# peer_id -> player node (Player or Robot)
var _players: Dictionary = {}

# ────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	network_manager = NetworkManager.new()
	network_manager.name = "NetworkManager"
	add_child(network_manager)
	network_manager.peer_left.connect(_on_peer_left)
	network_manager.player_joined_mid_game.connect(_on_player_joined_mid_game)

	var lobby = LobbyUI.new()
	lobby.name = "LobbyUI"
	add_child(lobby)
	lobby.start_game.connect(_on_start_game)

# ── Game start ────────────────────────────────────────────────────────────────
func _on_start_game(seed_val: int, is_mp: bool) -> void:
	Config.maze_seed = seed_val

	game_manager = GameManager.new()
	game_manager.name = "GameManager"
	add_child(game_manager)

	_create_maze()

	if is_mp:
		_spawn_mp_players()
	else:
		_spawn_sp_players()

	trap_manager = TrapManager.new()
	trap_manager.name = "TrapManager"
	add_child(trap_manager)

	for p in _players.values():
		p.trap_manager = trap_manager

	sound_manager = SoundManager.new()
	sound_manager.name = "SoundManager"
	add_child(sound_manager)
	for p in _players.values():
		p.sound_manager = sound_manager
	trap_manager.sound_manager = sound_manager

	for i in range(game_manager.box_spawns.size()):
		var box = TrapBox.new()
		box.current_grid_pos = game_manager.box_spawns[i].duplicate()
		add_child(box)
		box.name = "TrapBox_%d" % i

	_create_lighting()
	_create_ui()

	# Voice chat — only in multiplayer
	if is_mp:
		voice_manager = VoiceManager.new()
		voice_manager.name = "VoiceManager"
		add_child(voice_manager)

# ── Single-player: human Player + Robot AI ────────────────────────────────────
func _spawn_sp_players() -> void:
	game_manager.register_player(1)
	var player = Player.new()
	player.name         = "Player"
	player.peer_id      = 1
	player.player_index = 0
	add_child(player)
	_players[1] = player

	game_manager.register_player(0)
	var robot = Robot.new()
	robot.name         = "Robot"
	robot.peer_id      = 0
	robot.player_index = 1
	add_child(robot)
	_players[0] = robot

	player.robot_ref = robot   # backward compat for robot.gd pathfinding reference

# ── Multiplayer: one Player node per connected peer ───────────────────────────
func _spawn_mp_players() -> void:
	var assignments = network_manager.assignments   # {peer_id: player_index}
	for pid in assignments:
		var idx = assignments[pid]
		game_manager.register_player(pid)

		var p = Player.new()
		p.name         = "Player_%d" % idx
		p.peer_id      = pid
		p.player_index = idx
		p.set_multiplayer_authority(pid)
		add_child(p)
		_players[pid] = p

# ── Maze geometry ─────────────────────────────────────────────────────────────
func _create_maze() -> void:
	var maze_node = Node3D.new(); maze_node.name = "Maze"; add_child(maze_node)
	var grid  = game_manager.grid
	var cols  = grid[0].size(); var rows = grid.size()
	var cs    = Config.CELL_SIZE; var wall_h = 3.0
	var map_id = Config.selected_map
	var wall_mat  = _make_wall_material(map_id)
	var floor_mat = _make_floor_material(map_id)
	var ceil_mat  = _make_ceiling_material(map_id)

	var floor_mesh = MeshInstance3D.new()
	var floor_plane = PlaneMesh.new(); floor_plane.size = Vector2(cols * cs, rows * cs)
	floor_mesh.mesh = floor_plane; floor_mesh.material_override = floor_mat
	floor_mesh.position = Vector3(cols * cs / 2.0, 0.0, rows * cs / 2.0)
	maze_node.add_child(floor_mesh)

	var ceil_mesh = MeshInstance3D.new()
	var ceil_plane = PlaneMesh.new(); ceil_plane.size = Vector2(cols * cs, rows * cs)
	ceil_mesh.mesh = ceil_plane; ceil_mesh.material_override = ceil_mat
	ceil_mesh.position = Vector3(cols * cs / 2.0, wall_h, rows * cs / 2.0)
	ceil_mesh.rotation.x = PI; maze_node.add_child(ceil_mesh)

	for r in range(rows):
		for c in range(cols):
			if grid[r][c] == 1:
				var wall_body = StaticBody3D.new()
				wall_body.position = Vector3((c + 0.5) * cs, wall_h / 2.0, (r + 0.5) * cs)
				maze_node.add_child(wall_body)
				var wall_vis = CSGBox3D.new()
				wall_vis.size = Vector3(cs, wall_h, cs); wall_vis.material = wall_mat
				wall_body.add_child(wall_vis)
				var col_shape = CollisionShape3D.new()
				var box_shape = BoxShape3D.new(); box_shape.size = Vector3(cs, wall_h, cs)
				col_shape.shape = box_shape; wall_body.add_child(col_shape)

# ── Map materials ─────────────────────────────────────────────────────────────
func _make_wall_material(map_id: int) -> Material:
	var shader = Shader.new()
	if map_id == 1:
		shader.code = """
shader_type spatial;
void fragment() {
	vec2 uv = UV * vec2(4.0, 2.5);
	float row = floor(uv.y);
	float offset = mod(row, 2.0) * 0.5;
	vec2 buv = vec2(uv.x + offset, uv.y);
	float mx = abs(fract(buv.x) - 0.5) * 2.0;
	float my = abs(fract(buv.y) - 0.5) * 2.0;
	float mortar = step(0.88, max(mx, my));
	vec3 brick = vec3(0.55 + fract(floor(buv.x) * 7.3 + row * 3.1) * 0.1, 0.28, 0.18);
	vec3 mort  = vec3(0.72, 0.70, 0.65);
	ALBEDO    = mix(brick, mort, mortar);
	ROUGHNESS = 0.9;
}
"""
	else:
		shader.code = """
shader_type spatial;
void fragment() {
	vec2 uv = UV * 6.0;
	float gx = floor(uv.x); float gy = floor(uv.y);
	float noise = fract(sin(gx * 127.1 + gy * 311.7) * 43758.5);
	vec3 ice_base = vec3(0.55, 0.75, 0.92); vec3 ice_dark = vec3(0.30, 0.55, 0.78);
	ALBEDO    = mix(ice_dark, ice_base, noise);
	ROUGHNESS = 0.05; METALLIC = 0.3; SPECULAR = 1.0;
	EMISSION  = vec3(0.05, 0.10, 0.22);
}
"""
	var mat = ShaderMaterial.new(); mat.shader = shader; return mat

func _make_floor_material(map_id: int) -> Material:
	var shader = Shader.new()
	if map_id == 1:
		shader.code = """
shader_type spatial;
void fragment() {
	vec2 uv = UV * 12.0;
	float gx = floor(uv.x); float gy = floor(uv.y);
	float checker = mod(gx + gy, 2.0);
	float noise = fract(sin(gx * 127.1 + gy * 311.7) * 43758.5);
	vec3 col = mix(vec3(0.28, 0.28, 0.30), vec3(0.22, 0.22, 0.24), checker);
	col += (noise - 0.5) * 0.04;
	ALBEDO = col; ROUGHNESS = 1.0;
}
"""
	else:
		shader.code = """
shader_type spatial;
void fragment() {
	vec2 uv = UV * 10.0;
	float gx = floor(uv.x); float gy = floor(uv.y);
	float noise = fract(sin(gx * 53.7 + gy * 127.3) * 43758.5);
	float crack = step(0.93, noise);
	vec3 col = mix(vec3(0.75, 0.88, 0.98), vec3(0.55, 0.72, 0.88), noise * 0.5);
	col = mix(col, vec3(0.3, 0.4, 0.55), crack);
	ALBEDO = col; ROUGHNESS = 0.08; METALLIC = 0.1; SPECULAR = 1.0;
}
"""
	var mat = ShaderMaterial.new(); mat.shader = shader; return mat

func _make_ceiling_material(map_id: int) -> Material:
	var mat = StandardMaterial3D.new()
	if map_id == 1:
		mat.albedo_color = Color(0.12, 0.12, 0.15); mat.roughness = 1.0
	else:
		mat.albedo_color = Color(0.25, 0.40, 0.60); mat.roughness = 0.3; mat.metallic = 0.2
		mat.emission_enabled = true; mat.emission = Color(0.05, 0.10, 0.20)
		mat.emission_energy_multiplier = 0.5
	return mat

# ── Lighting ──────────────────────────────────────────────────────────────────
func _create_lighting() -> void:
	var dir_light = DirectionalLight3D.new()
	dir_light.rotation_degrees = Vector3(-45, 30, 0)
	var world_env = WorldEnvironment.new()
	var env = Environment.new()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	if Config.selected_map == 1:
		dir_light.light_color = Color(1.0, 0.85, 0.65); dir_light.light_energy = 0.5
		env.ambient_light_color = Color(0.35, 0.30, 0.25); env.ambient_light_energy = 1.0
	else:
		dir_light.light_color = Color(0.65, 0.80, 1.0); dir_light.light_energy = 0.4
		env.ambient_light_color = Color(0.22, 0.30, 0.45); env.ambient_light_energy = 1.3
	add_child(dir_light)
	world_env.environment = env; add_child(world_env)

# ── Late-join: existing peers spawn one new player ────────────────────────────
func _on_player_joined_mid_game(pid: int, idx: int) -> void:
	if game_manager == null or not is_instance_valid(game_manager): return
	if _players.has(pid): return   # already spawned (shouldn't happen)

	game_manager.register_player(pid)

	var p = Player.new()
	p.name         = "Player_%d" % idx
	p.peer_id      = pid
	p.player_index = idx
	p.set_multiplayer_authority(pid)
	p.game_manager = game_manager
	add_child(p)
	p.trap_manager  = trap_manager
	p.sound_manager = sound_manager
	_players[pid] = p

# ── Peer disconnect ───────────────────────────────────────────────────────────
func _on_peer_left(pid: int) -> void:
	if pid == -1:
		# Host disconnected — reload to main menu
		get_tree().reload_current_scene()
		return

	# Remove the player node from the game world
	if _players.has(pid):
		var node = _players[pid]
		if is_instance_valid(node):
			node.queue_free()
		_players.erase(pid)

	# Clean up game_manager state so dead peer doesn't affect scoring / win-check
	if game_manager and is_instance_valid(game_manager):
		game_manager.player_ids.erase(pid)
		game_manager.hp.erase(pid)
		game_manager.lives.erase(pid)
		game_manager.kills.erase(pid)
		game_manager.effects.erase(pid)
		game_manager.respawning.erase(pid)
		game_manager._respawn_timers.erase(pid)
		game_manager._last_damager.erase(pid)

	# Free the voice speaker for that peer
	if voice_manager and is_instance_valid(voice_manager):
		voice_manager.remove_speaker(pid)

	# If the game is still running, check whether only one player remains
	if game_manager and is_instance_valid(game_manager):
		game_manager.check_win_condition()

# ── UI ────────────────────────────────────────────────────────────────────────
func _create_ui() -> void:
	var ui = UIManager.new()
	ui.name = "UI"
	add_child(ui)
	# UIManager discovers the local player via the "players" group in its _ready()
