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

	# Spawn gun boxes (3 per map)
	for i in 3:
		var gun_box = GunBox.new()
		gun_box.current_grid_pos = game_manager.get_random_floor_cell()
		add_child(gun_box)
		gun_box.name = "GunBox_%d" % i

	_create_lighting()

	# Voice chat — only in multiplayer. Must exist BEFORE _create_ui(): UIManager's
	# _ready() looks up "VoiceManager" to build the mic button and wire the speaking
	# indicator, so creating it afterwards left both silently disabled.
	if is_mp:
		voice_manager = VoiceManager.new()
		voice_manager.name = "VoiceManager"
		add_child(voice_manager)

	_create_ui()

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

	# ── Visuals: ONE MultiMesh draw call for every wall ───────────────────────
	# Previously each wall cell was a CSGBox3D. CSG geometry is rebuilt on the CPU
	# at runtime; with a 27×27 maze that is hundreds of CSG nodes, which tanks the
	# framerate on mobile web — worst when walls fill the view (i.e. up close).
	# The low, lurching framerate is what made turning feel abrupt and chaotic.
	# A MultiMeshInstance3D renders all walls in a single draw call instead.
	var wall_cells: Array = []
	for r in range(rows):
		for c in range(cols):
			if grid[r][c] == 1:
				wall_cells.append(Vector3((c + 0.5) * cs, wall_h / 2.0, (r + 0.5) * cs))

	if wall_cells.size() > 0:
		var box_mesh = BoxMesh.new()
		box_mesh.size = Vector3(cs, wall_h, cs)
		var mm = MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = box_mesh
		mm.instance_count = wall_cells.size()
		for i in range(wall_cells.size()):
			mm.set_instance_transform(i, Transform3D(Basis(), wall_cells[i]))
		var mmi = MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = wall_mat
		maze_node.add_child(mmi)

	# ── Collision: greedy-merge wall cells into seamless rectangles ────────────
	# One BoxShape per merged rectangle removes the internal seams between flush
	# per-cell boxes that caused the capsule to catch ("ghost collisions") when
	# sliding along a wall — the source of the chaotic turn-while-moving jitter.
	var used: Array = []
	for r in range(rows):
		var row_used: Array = []
		for c in range(cols): row_used.append(false)
		used.append(row_used)

	for r in range(rows):
		for c in range(cols):
			if grid[r][c] != 1 or used[r][c]: continue
			# Extend width along the row.
			var w := 1
			while c + w < cols and grid[r][c + w] == 1 and not used[r][c + w]: w += 1
			# Extend height while the full w-wide segment is wall & unused.
			var h := 1
			var grow := true
			while grow and r + h < rows:
				for cc in range(c, c + w):
					if grid[r + h][cc] != 1 or used[r + h][cc]: grow = false; break
				if grow: h += 1
			# Mark the rectangle consumed.
			for rr in range(r, r + h):
				for cc in range(c, c + w): used[rr][cc] = true
			# One static collider for the whole rectangle.
			var wall_body = StaticBody3D.new()
			wall_body.position = Vector3((c + w / 2.0) * cs, wall_h / 2.0, (r + h / 2.0) * cs)
			maze_node.add_child(wall_body)
			var col_shape = CollisionShape3D.new()
			var box_shape = BoxShape3D.new(); box_shape.size = Vector3(w * cs, wall_h, h * cs)
			col_shape.shape = box_shape; wall_body.add_child(col_shape)

	# Decorative, collision-free props that give each map its identity.
	_scatter_props(map_id, grid, rows, cols, cs, wall_h, maze_node)

# ── Map props (purely visual — no collision, never block gameplay) ────────────
# Two passes: an overhead layer (light bars / canopies, sitting above the maze)
# and a ground layer placed only in dead-end cells (3 wall neighbours) so props
# never obstruct a through-corridor. All meshes are MultiMesh batches → one draw
# call each, cheap on mobile web.
func _scatter_props(map_id: int, grid: Array, rows: int, cols: int, cs: float, wall_h: float, maze_node: Node3D) -> void:
	if map_id == 1:
		return   # Labyrinth stays bare

	# Collect wall cells and dead-end floor cells.
	var wall_cells:  Array = []
	var dead_ends:   Array = []
	for r in range(rows):
		for c in range(cols):
			if grid[r][c] == 1:
				wall_cells.append(Vector2i(c, r))
			else:
				var walls := 0
				if r <= 0 or grid[r - 1][c] == 1: walls += 1
				if r >= rows - 1 or grid[r + 1][c] == 1: walls += 1
				if c <= 0 or grid[r][c - 1] == 1: walls += 1
				if c >= cols - 1 or grid[r][c + 1] == 1: walls += 1
				if walls >= 3:
					dead_ends.append(Vector2i(c, r))

	match map_id:
		2: _props_garage(wall_cells, dead_ends, grid, rows, cols, cs, wall_h, maze_node)
		3: _props_forest(wall_cells, dead_ends, cs, wall_h, maze_node)
		4: _props_village(wall_cells, dead_ends, cs, wall_h, maze_node)
		5: _props_canyon(wall_cells, dead_ends, cs, wall_h, maze_node)
		6: _props_village_real(wall_cells, dead_ends, grid, rows, cols, cs, wall_h, maze_node)

# Add one MultiMeshInstance3D batching `mesh` at every transform in `xforms`.
func _add_multimesh(mesh: Mesh, mat: Material, xforms: Array, maze_node: Node3D) -> void:
	if xforms.is_empty(): return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	maze_node.add_child(mmi)

func _emissive_mat(col: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.emission_enabled = true; m.emission = col; m.emission_energy_multiplier = energy
	return m

func _solid_mat(col: Color, rough: float = 0.9) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col; m.roughness = rough
	return m

# Garage: a grid of glowing fluorescent bars under the ceiling + oil drums in dead-ends.
func _props_garage(_wall_cells: Array, dead_ends: Array, grid: Array, rows: int, cols: int, cs: float, wall_h: float, maze_node: Node3D) -> void:
	var bar_mesh := BoxMesh.new(); bar_mesh.size = Vector3(0.22, 0.10, 1.5)
	var bars: Array = []
	for r in range(2, rows - 1, 5):
		for c in range(2, cols - 1, 5):
			if grid[r][c] == 0:
				bars.append(Transform3D(Basis(), Vector3((c + 0.5) * cs, wall_h - 0.12, (r + 0.5) * cs)))
	_add_multimesh(bar_mesh, _emissive_mat(Color(0.95, 0.97, 0.85), 2.2), bars, maze_node)

	# Oil drums (red cylinders) in a subset of dead-ends.
	var drum_mesh := CylinderMesh.new()
	drum_mesh.top_radius = 0.34; drum_mesh.bottom_radius = 0.34; drum_mesh.height = 0.95
	var drums: Array = []
	for i in range(0, dead_ends.size(), 3):
		var cell: Vector2i = dead_ends[i]
		drums.append(Transform3D(Basis(), Vector3((cell.x + 0.5) * cs, 0.48, (cell.y + 0.5) * cs)))
	_add_multimesh(drum_mesh, _solid_mat(Color(0.65, 0.12, 0.10), 0.5), drums, maze_node)

# Forest: leafy canopies resting on top of hedge walls + bushes in dead-ends.
func _props_forest(wall_cells: Array, dead_ends: Array, cs: float, wall_h: float, maze_node: Node3D) -> void:
	var canopy_mesh := SphereMesh.new()
	canopy_mesh.radius = 1.05; canopy_mesh.height = 1.7
	var canopies: Array = []
	for i in range(wall_cells.size()):
		if i % 3 != 0: continue   # ~1/3 of walls get a treetop
		var cell: Vector2i = wall_cells[i]
		var hx: float = sin(float(i) * 12.9) * 437.5
		var hz: float = sin(float(i) * 78.2) * 731.4
		var jx: float = (hx - floorf(hx)) * 0.4 - 0.2
		var jz: float = (hz - floorf(hz)) * 0.4 - 0.2
		canopies.append(Transform3D(Basis(), Vector3((cell.x + 0.5) * cs + jx, wall_h + 0.5, (cell.y + 0.5) * cs + jz)))
	_add_multimesh(canopy_mesh, _solid_mat(Color(0.13, 0.40, 0.13), 0.95), canopies, maze_node)

	# Low bushes in dead-ends.
	var bush_mesh := SphereMesh.new(); bush_mesh.radius = 0.5; bush_mesh.height = 0.7
	var bushes: Array = []
	for i in range(0, dead_ends.size(), 2):
		var cell: Vector2i = dead_ends[i]
		bushes.append(Transform3D(Basis(), Vector3((cell.x + 0.5) * cs, 0.3, (cell.y + 0.5) * cs)))
	_add_multimesh(bush_mesh, _solid_mat(Color(0.10, 0.34, 0.12), 1.0), bushes, maze_node)

# Village: dead trees above walls, hanging lanterns, broken plank debris —
# Resident Evil-style abandoned village at night.
func _props_village(wall_cells: Array, dead_ends: Array, cs: float, wall_h: float, maze_node: Node3D) -> void:
	# Dead tree trunks poking above the roofline (1 in 5 wall cells).
	var trunk_mesh := CylinderMesh.new()
	trunk_mesh.top_radius = 0.05; trunk_mesh.bottom_radius = 0.14; trunk_mesh.height = 2.8
	var trunks: Array = []
	for i in range(wall_cells.size()):
		if i % 5 != 0: continue
		var cell: Vector2i = wall_cells[i]
		trunks.append(Transform3D(Basis(), Vector3((cell.x + 0.5) * cs, wall_h + 1.1, (cell.y + 0.5) * cs)))
	_add_multimesh(trunk_mesh, _solid_mat(Color(0.16, 0.11, 0.08), 1.0), trunks, maze_node)

	# Dead branches — thin cylinders tilted at ~50° in a random horizontal direction.
	var branch_mesh := CylinderMesh.new()
	branch_mesh.top_radius = 0.02; branch_mesh.bottom_radius = 0.05; branch_mesh.height = 1.1
	var branches: Array = []
	for i in range(wall_cells.size()):
		if i % 7 != 2: continue
		var cell: Vector2i = wall_cells[i]
		var h: float = sin(float(i) * 17.3) * 311.3
		var yaw: float = (h - floorf(h)) * TAU
		var axis := Vector3(sin(yaw), 0.0, cos(yaw))   # horizontal, unit length
		var basis  := Basis(axis, deg_to_rad(52.0))
		branches.append(Transform3D(basis, Vector3((cell.x + 0.5) * cs, wall_h + 1.65, (cell.y + 0.5) * cs)))
	_add_multimesh(branch_mesh, _solid_mat(Color(0.13, 0.09, 0.06), 1.0), branches, maze_node)

	# Hanging lanterns — small emissive boxes dangling near the top of walls (1 in 8).
	var lantern_mesh := BoxMesh.new(); lantern_mesh.size = Vector3(0.18, 0.22, 0.18)
	var lanterns: Array = []
	for i in range(wall_cells.size()):
		if i % 8 != 4: continue
		var cell: Vector2i = wall_cells[i]
		lanterns.append(Transform3D(Basis(), Vector3((cell.x + 0.5) * cs, wall_h - 0.30, (cell.y + 0.5) * cs)))
	_add_multimesh(lantern_mesh, _emissive_mat(Color(1.0, 0.52, 0.12), 2.8), lanterns, maze_node)

	# Broken planks scattered on the ground in dead-ends — random yaw rotation.
	var plank_mesh := BoxMesh.new(); plank_mesh.size = Vector3(0.60, 0.05, 0.13)
	var planks: Array = []
	for i in range(dead_ends.size()):
		var cell: Vector2i = dead_ends[i]
		var h: float = sin(float(i) * 23.5) * 511.7
		var angle: float = (h - floorf(h)) * TAU
		planks.append(Transform3D(Basis(Vector3.UP, angle), Vector3((cell.x + 0.5) * cs, 0.025, (cell.y + 0.5) * cs)))
	_add_multimesh(plank_mesh, _solid_mat(Color(0.22, 0.14, 0.07), 1.0), planks, maze_node)

# Canyon: jagged rock spires crowning the cliff walls + boulders in dead-ends —
# gives the maze an open badlands skyline without changing the layout.
func _props_canyon(wall_cells: Array, dead_ends: Array, cs: float, wall_h: float, maze_node: Node3D) -> void:
	var spire_mesh := CylinderMesh.new()
	spire_mesh.top_radius = 0.05; spire_mesh.bottom_radius = 0.55; spire_mesh.height = 1.7
	var spires: Array = []
	for i in range(wall_cells.size()):
		if i % 4 != 0: continue   # ~1/4 of walls get a spire
		var cell: Vector2i = wall_cells[i]
		var h: float = sin(float(i) * 21.7) * 311.3
		var jitter: float = (h - floorf(h)) * 0.5
		spires.append(Transform3D(Basis(), Vector3((cell.x + 0.5) * cs, wall_h + 0.7 + jitter, (cell.y + 0.5) * cs)))
	_add_multimesh(spire_mesh, _solid_mat(Color(0.55, 0.36, 0.22), 0.95), spires, maze_node)

	var rock_mesh := SphereMesh.new(); rock_mesh.radius = 0.55; rock_mesh.height = 0.8
	var rocks: Array = []
	for i in range(dead_ends.size()):
		var cell: Vector2i = dead_ends[i]
		rocks.append(Transform3D(Basis(), Vector3((cell.x + 0.5) * cs, 0.3, (cell.y + 0.5) * cs)))
	_add_multimesh(rock_mesh, _solid_mat(Color(0.50, 0.42, 0.34), 1.0), rocks, maze_node)

# Attach a StaticBody3D + BoxShape3D to a prop node so players can't walk through it.
func _add_prop_collision(prop: Node3D, shape_size: Vector3, shape_offset: Vector3) -> void:
	var sb := StaticBody3D.new()
	var cs3 := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = shape_size
	cs3.shape = box
	cs3.position = shape_offset
	sb.add_child(cs3)
	prop.add_child(sb)

# Village Real: scatter megakit glTF props (crates, vines, wagon, fences).
# Falls back to procedural _props_village() until the Godot editor imports the models.
func _props_village_real(wall_cells: Array, dead_ends: Array, grid: Array, rows: int, cols: int, cs: float, wall_h: float, maze_node: Node3D) -> void:
	var crate_scene  := load("res://assets/medieval_village_megakit/models/Prop_Crate.gltf") as PackedScene
	var vine1_scene  := load("res://assets/medieval_village_megakit/models/Prop_Vine1.gltf") as PackedScene
	var vine2_scene  := load("res://assets/medieval_village_megakit/models/Prop_Vine2.gltf") as PackedScene
	var wagon_scene  := load("res://assets/medieval_village_megakit/models/Prop_Wagon.gltf") as PackedScene
	var fence_scene  := load("res://assets/medieval_village_megakit/models/Prop_WoodenFence_Single.gltf") as PackedScene

	if crate_scene == null and vine1_scene == null:
		# Models not yet imported by the Godot editor — use procedural fallback.
		push_warning("Megakit models not imported; falling back to procedural village props.")
		_props_village(wall_cells, dead_ends, cs, wall_h, maze_node)
		return

	# Crates in dead-ends (max 20).
	var crate_count := 0
	for i in range(dead_ends.size()):
		if crate_count >= 20: break
		if i % 2 != 0: continue
		if crate_scene == null: break
		var cell: Vector2i = dead_ends[i]
		var inst := crate_scene.instantiate() as Node3D
		inst.position = Vector3((cell.x + 0.5) * cs, 0.0, (cell.y + 0.5) * cs)
		inst.rotation.y = float(i % 8) * PI * 0.25
		inst.scale = Vector3.ONE * 0.85
		maze_node.add_child(inst)
		_add_prop_collision(inst, Vector3(0.75, 0.75, 0.75), Vector3(0, 0.375, 0))
		crate_count += 1

	# Vines leaning on wall bases (max 15, sparse).
	var vine_count := 0
	for i in range(wall_cells.size()):
		if vine_count >= 15: break
		if i % 9 != 0: continue
		var scene := vine1_scene if (i % 2 == 0) else vine2_scene
		if scene == null: continue
		var cell: Vector2i = wall_cells[i]
		var inst := scene.instantiate() as Node3D
		inst.position = Vector3((cell.x + 0.5) * cs, 0.0, (cell.y + 0.5) * cs)
		inst.rotation.y = float(i % 4) * PI * 0.5
		inst.scale = Vector3.ONE * 0.8
		maze_node.add_child(inst)
		vine_count += 1

	# One wagon near the central plaza.
	if wagon_scene != null:
		var cc := cols / 2; var cr := rows / 2
		for dc: int in [2, -2, 3, -3, 1, -1]:
			var tc: int = cc + dc
			if tc >= 0 and tc < cols and grid[cr][tc] == 0:
				var inst := wagon_scene.instantiate() as Node3D
				inst.position = Vector3((tc + 0.5) * cs, 0.0, (cr + 0.5) * cs)
				inst.scale = Vector3.ONE * 0.75
				maze_node.add_child(inst)
				_add_prop_collision(inst, Vector3(1.8, 1.0, 0.9), Vector3(0, 0.5, 0))
				break

	# Fences along floor cells adjacent to walls — skip hallway cells so the
	# fence never blocks a corridor (hallway = ≤2 open cardinal neighbours).
	if fence_scene != null:
		var fence_count := 0
		for r in range(1, rows - 1):
			if fence_count >= 14: break
			for c in range(1, cols - 1):
				if fence_count >= 14: break
				if grid[r][c] != 0: continue
				if (r + c) % 7 != 0: continue
				# Count open cardinal neighbours.
				var open := 0
				for d: Array in [[0, 1], [0, -1], [1, 0], [-1, 0]]:
					var nr: int = r + d[0]; var nc: int = c + d[1]
					if nr >= 0 and nr < rows and nc >= 0 and nc < cols:
						if grid[nr][nc] == 0: open += 1
				if open <= 2: continue   # hallway or dead-end — skip
				var adj := false
				for dr in [-1, 0, 1]:
					if adj: break
					for dc in [-1, 0, 1]:
						if dr == 0 and dc == 0: continue
						if grid[r + dr][c + dc] == 1: adj = true; break
				if not adj: continue
				var inst := fence_scene.instantiate() as Node3D
				inst.position = Vector3((c + 0.5) * cs, 0.0, (r + 0.5) * cs)
				inst.rotation.y = float((r + c) % 4) * PI * 0.5
				inst.scale = Vector3.ONE * 0.9
				maze_node.add_child(inst)
				# Thin collision box along the fence length.
				_add_prop_collision(inst, Vector3(cs * 0.9, 1.2, 0.12), Vector3.ZERO)
				fence_count += 1

# ── Map materials ─────────────────────────────────────────────────────────────
func _make_wall_material(map_id: int) -> Material:
	if map_id == 6:
		# Village Real — UnevenBrick texture from megakit (requires editor import).
		# Falls back to a plain stone colour if not yet imported.
		var m := StandardMaterial3D.new()
		var tex := load("res://assets/medieval_village_megakit/textures/T_UnevenBrick_BaseColor.png") as Texture2D
		if tex:
			m.albedo_texture = tex
			m.uv1_scale = Vector3(2.5, 1.5, 1.0)
		else:
			m.albedo_color = Color(0.30, 0.26, 0.21)
		var norm := load("res://assets/medieval_village_megakit/textures/T_UnevenBrick_Normal.png") as Texture2D
		if norm:
			m.normal_enabled = true; m.normal_texture = norm; m.normal_scale = 1.2
		var rough := load("res://assets/medieval_village_megakit/textures/T_UnevenBrick_Roughness.png") as Texture2D
		if rough:
			m.roughness_texture = rough
			m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
		m.roughness = 0.90
		return m

	var shader = Shader.new()
	if map_id == 2:
		# Garage — corrugated sheet metal with rusty streaks.
		shader.code = """
shader_type spatial;
void fragment() {
	vec2 uv = UV * vec2(3.0, 7.0);
	float rib = 0.5 + 0.5 * sin(uv.y * 6.2831);
	vec3 metal = mix(vec3(0.28, 0.30, 0.34), vec3(0.46, 0.48, 0.52), rib);
	float rust = fract(sin(floor(uv.x) * 12.9 + floor(uv.y * 0.5) * 4.1) * 43758.5);
	metal = mix(metal, vec3(0.36, 0.18, 0.08), smoothstep(0.72, 1.0, rust) * 0.5);
	ALBEDO = metal; METALLIC = 0.55; ROUGHNESS = 0.42;
}
"""
	elif map_id == 3:
		# Forest — dense hedge foliage.
		shader.code = """
shader_type spatial;
void fragment() {
	vec2 uv = UV * 7.0;
	float n  = fract(sin(dot(floor(uv),       vec2(12.9, 78.2))) * 43758.5);
	float n2 = fract(sin(dot(floor(uv * 2.3), vec2(39.3, 11.1))) * 9123.0);
	vec3 leaf = mix(vec3(0.07, 0.26, 0.07), vec3(0.17, 0.46, 0.14), n);
	leaf = mix(leaf, vec3(0.04, 0.16, 0.05), n2 * 0.55);
	ALBEDO = leaf; ROUGHNESS = 0.95;
}
"""
	elif map_id == 4:
		# Village — crumbling mossy stone, like an old European building exterior.
		shader.code = """
shader_type spatial;
void fragment() {
	vec2 uv = UV * vec2(3.5, 2.5);
	float row = floor(uv.y);
	float offset = mod(row, 2.0) * 0.5;
	vec2 buv = vec2(uv.x + offset, uv.y);
	float bx = floor(buv.x); float by = floor(buv.y);
	float block_n = fract(sin(bx * 17.3 + by * 43.1) * 43758.5);
	vec3 stone = mix(vec3(0.24, 0.21, 0.18), vec3(0.36, 0.32, 0.27), block_n);
	float mx = abs(fract(buv.x) - 0.5) * 2.0;
	float my = abs(fract(buv.y) - 0.5) * 2.0;
	float mortar = step(0.86, max(mx, my));
	stone = mix(stone, vec3(0.14, 0.13, 0.12), mortar * 0.75);
	float moss = fract(sin(dot(floor(uv * 2.2), vec2(9.7, 31.1))) * 2375.0);
	stone = mix(stone, vec3(0.13, 0.22, 0.11), smoothstep(0.80, 1.0, moss) * 0.45);
	float damp = fract(sin(dot(floor(uv * 1.1), vec2(41.3, 7.9))) * 9123.0);
	stone *= (0.75 + 0.25 * damp);
	ALBEDO = stone; ROUGHNESS = 0.97;
}
"""
	elif map_id == 5:
		# Canyon — banded sandstone cliff strata.
		shader.code = """
shader_type spatial;
void fragment() {
	vec2 uv = UV * vec2(3.0, 4.0);
	float strata = floor(uv.y + sin(uv.x * 2.0) * 0.15);
	float band = fract(sin(strata * 17.3) * 9999.0);
	vec3 rock = mix(vec3(0.52, 0.30, 0.18), vec3(0.80, 0.54, 0.33), band);
	float n = fract(sin(dot(floor(uv * 4.0), vec2(12.9, 78.2))) * 43758.5);
	rock *= (0.85 + 0.15 * n);
	ALBEDO = rock; ROUGHNESS = 0.95;
}
"""
	else:
		# Labyrinth (1, default) — stone brickwork.
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
	var mat = ShaderMaterial.new(); mat.shader = shader; return mat

func _make_floor_material(map_id: int) -> Material:
	if map_id == 6:
		# Village Real — cobblestone tiles from megakit (requires editor import).
		var m := StandardMaterial3D.new()
		var tex := load("res://assets/medieval_village_megakit/textures/T_Brick_BaseColor.png") as Texture2D
		if tex:
			m.albedo_texture = tex
			m.uv1_scale = Vector3(5.0, 5.0, 1.0)
		else:
			m.albedo_color = Color(0.20, 0.17, 0.13)
		var norm := load("res://assets/medieval_village_megakit/textures/T_Brick_Normal.png") as Texture2D
		if norm:
			m.normal_enabled = true; m.normal_texture = norm; m.normal_scale = 0.8
		var rough := load("res://assets/medieval_village_megakit/textures/T_Brick_Roughness.png") as Texture2D
		if rough:
			m.roughness_texture = rough
			m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
		m.roughness = 0.92
		return m

	var shader = Shader.new()
	if map_id == 2:
		# Garage — poured concrete with oil stains.
		shader.code = """
shader_type spatial;
void fragment() {
	vec2 uv = UV * 8.0;
	float n = fract(sin(dot(floor(uv), vec2(12.9, 78.2))) * 43758.5);
	vec3 c = vec3(0.21, 0.21, 0.23) + (n - 0.5) * 0.05;
	float oil = fract(sin(dot(floor(uv * 0.5), vec2(31.7, 11.3))) * 2375.0);
	c = mix(c, vec3(0.05, 0.05, 0.07), smoothstep(0.84, 1.0, oil) * 0.8);
	ALBEDO = c; ROUGHNESS = 0.7; METALLIC = 0.1;
}
"""
	elif map_id == 3:
		# Forest — grass with worn dirt patches.
		shader.code = """
shader_type spatial;
void fragment() {
	vec2 uv = UV * 11.0;
	float n = fract(sin(dot(floor(uv), vec2(12.9, 78.2))) * 43758.5);
	vec3 grass = mix(vec3(0.11, 0.31, 0.09), vec3(0.21, 0.46, 0.14), n);
	float dirt = fract(sin(dot(floor(uv * 0.4), vec2(27.1, 9.7))) * 1551.0);
	grass = mix(grass, vec3(0.33, 0.25, 0.13), smoothstep(0.78, 1.0, dirt) * 0.7);
	ALBEDO = grass; ROUGHNESS = 1.0;
}
"""
	elif map_id == 4:
		# Village — wet dark cobblestones with reflective puddles.
		shader.code = """
shader_type spatial;
void fragment() {
	vec2 uv = UV * 7.0;
	float bx = floor(uv.x * 1.4); float by = floor(uv.y);
	float n = fract(sin(bx * 12.9 + by * 78.2) * 43758.5);
	vec3 stone = mix(vec3(0.14, 0.13, 0.12), vec3(0.24, 0.22, 0.20), n);
	float cx = abs(fract(uv.x * 1.4) - 0.5) * 2.0;
	float cy = abs(fract(uv.y) - 0.5) * 2.0;
	float seam = step(0.83, max(cx, cy));
	stone = mix(stone, vec3(0.07, 0.07, 0.07), seam * 0.85);
	float wet = fract(sin(dot(floor(uv * 0.28), vec2(31.7, 11.3))) * 2375.0);
	float is_wet = smoothstep(0.72, 1.0, wet);
	ALBEDO = mix(stone, stone * 0.45, is_wet);
	ROUGHNESS = mix(0.96, 0.04, is_wet);
	METALLIC = is_wet * 0.55;
}
"""
	elif map_id == 5:
		# Canyon — sun-baked sand with scattered rock.
		shader.code = """
shader_type spatial;
void fragment() {
	vec2 uv = UV * 10.0;
	float n = fract(sin(dot(floor(uv), vec2(12.9, 78.2))) * 43758.5);
	vec3 sand = mix(vec3(0.74, 0.58, 0.36), vec3(0.85, 0.69, 0.45), n);
	float rock = fract(sin(dot(floor(uv * 0.5), vec2(31.7, 11.3))) * 2375.0);
	sand = mix(sand, vec3(0.46, 0.34, 0.24), smoothstep(0.82, 1.0, rock) * 0.6);
	ALBEDO = sand; ROUGHNESS = 1.0;
}
"""
	else:
		# Labyrinth (1, default) — stone checker tiles.
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
	var mat = ShaderMaterial.new(); mat.shader = shader; return mat

func _make_ceiling_material(map_id: int) -> Material:
	var mat = StandardMaterial3D.new()
	if map_id == 2:
		# Garage — dark concrete soffit (lit by fluorescent prop bars).
		mat.albedo_color = Color(0.14, 0.14, 0.16); mat.roughness = 1.0
	elif map_id == 3:
		# Forest — bright open daytime sky (emissive so it reads as "outside").
		mat.albedo_color = Color(0.46, 0.66, 0.96); mat.roughness = 1.0
		mat.emission_enabled = true; mat.emission = Color(0.50, 0.68, 0.98)
		mat.emission_energy_multiplier = 0.9
	elif map_id == 4 or map_id == 6:
		# Village / Village Real — overcast moonlit night, almost no light from above.
		mat.albedo_color = Color(0.04, 0.05, 0.09); mat.roughness = 1.0
		mat.emission_enabled = true; mat.emission = Color(0.10, 0.12, 0.22)
		mat.emission_energy_multiplier = 0.28
	elif map_id == 5:
		# Canyon — bright open desert sky.
		mat.albedo_color = Color(0.52, 0.68, 0.92); mat.roughness = 1.0
		mat.emission_enabled = true; mat.emission = Color(0.58, 0.72, 0.96)
		mat.emission_energy_multiplier = 0.9
	else:
		# Labyrinth (1, default) — dark stone ceiling.
		mat.albedo_color = Color(0.12, 0.12, 0.15); mat.roughness = 1.0
	return mat

# ── Lighting ──────────────────────────────────────────────────────────────────
func _create_lighting() -> void:
	var dir_light = DirectionalLight3D.new()
	dir_light.rotation_degrees = Vector3(-45, 30, 0)
	var world_env = WorldEnvironment.new()
	var env = Environment.new()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	match Config.selected_map:
		2:  # Garage — cool, hazy fluorescent interior
			dir_light.light_color = Color(0.85, 0.90, 1.0); dir_light.light_energy = 0.35
			env.ambient_light_color = Color(0.26, 0.28, 0.32); env.ambient_light_energy = 1.1
			env.fog_enabled = true; env.fog_light_color = Color(0.30, 0.32, 0.36); env.fog_density = 0.020
		3:  # Forest — bright daylight, soft green distance haze
			dir_light.light_color = Color(1.0, 0.97, 0.85); dir_light.light_energy = 0.9
			env.ambient_light_color = Color(0.42, 0.52, 0.40); env.ambient_light_energy = 1.4
			env.fog_enabled = true; env.fog_light_color = Color(0.55, 0.70, 0.55); env.fog_density = 0.015
		4, 6:  # Village / Village Real — cold moonlight, very dark, heavy damp fog
			dir_light.light_color = Color(0.62, 0.70, 0.92); dir_light.light_energy = 0.22
			env.ambient_light_color = Color(0.07, 0.09, 0.15); env.ambient_light_energy = 0.65
			env.fog_enabled = true; env.fog_light_color = Color(0.10, 0.12, 0.18); env.fog_density = 0.060
		5:  # Canyon — harsh bright sun, faint dusty haze
			dir_light.light_color = Color(1.0, 0.93, 0.78); dir_light.light_energy = 1.0
			env.ambient_light_color = Color(0.48, 0.42, 0.34); env.ambient_light_energy = 1.3
			env.fog_enabled = true; env.fog_light_color = Color(0.72, 0.60, 0.45); env.fog_density = 0.012
		_:  # Labyrinth (1, default) — warm torchlit stone
			dir_light.light_color = Color(1.0, 0.85, 0.65); dir_light.light_energy = 0.5
			env.ambient_light_color = Color(0.35, 0.30, 0.25); env.ambient_light_energy = 1.0
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
