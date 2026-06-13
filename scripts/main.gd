extends Node3D

var game_manager: GameManager
var player: Player
var robot: Robot
var trap_manager: TrapManager
var sound_manager: SoundManager

func _ready() -> void:
	# ── Game Manager ──────────────────────────────────────────────────────────
	game_manager = GameManager.new()
	add_child(game_manager)
	game_manager.name = "GameManager"

	# ── Maze geometry ─────────────────────────────────────────────────────────
	_create_maze()

	# ── Player (needs GameManager only) ───────────────────────────────────────
	player = Player.new()
	add_child(player)
	player.name = "Player"

	# ── Robot (needs GameManager only; TrapManager resolved lazily) ───────────
	robot = Robot.new()
	add_child(robot)
	robot.name = "Robot"

	# ── Trap Manager (added AFTER Player + Robot so get_node() succeeds) ──────
	trap_manager = TrapManager.new()
	add_child(trap_manager)
	trap_manager.name = "TrapManager"

	# Give Player a reference for trap pickup/throw handling
	player.trap_manager = trap_manager
	player.robot_ref    = robot

	# Sound manager
	sound_manager = SoundManager.new()
	add_child(sound_manager)
	sound_manager.name    = "SoundManager"
	player.sound_manager        = sound_manager
	robot.sound_manager         = sound_manager
	trap_manager.sound_manager  = sound_manager

	# ── Trap Boxes ────────────────────────────────────────────────────────────
	for i in range(game_manager.box_spawns.size()):
		var box = TrapBox.new()
		# Set spawn cell BEFORE add_child so _ready() → _snap_to_grid() uses it
		box.current_grid_pos = game_manager.box_spawns[i].duplicate()
		add_child(box)
		box.name = "TrapBox_%d" % i

	# ── Lighting ──────────────────────────────────────────────────────────────
	_create_lighting()

	# ── UI ────────────────────────────────────────────────────────────────────
	_create_ui()

# ── Maze geometry ─────────────────────────────────────────────────────────────
func _create_maze() -> void:
	var maze_node = Node3D.new()
	maze_node.name = "Maze"
	add_child(maze_node)

	var grid  = game_manager.grid
	var cols  = grid[0].size()
	var rows  = grid.size()
	var cs    = Config.CELL_SIZE
	var wall_h = 3.0

	var map_id = Config.selected_map
	var wall_mat  = _make_wall_material(map_id)
	var floor_mat = _make_floor_material(map_id)
	var ceil_mat  = _make_ceiling_material(map_id)

	# Floor
	var floor_mesh = MeshInstance3D.new()
	var floor_plane = PlaneMesh.new()
	floor_plane.size = Vector2(cols * cs, rows * cs)
	floor_mesh.mesh              = floor_plane
	floor_mesh.material_override = floor_mat
	floor_mesh.position          = Vector3(cols * cs / 2.0, 0.0, rows * cs / 2.0)
	maze_node.add_child(floor_mesh)

	# Ceiling
	var ceil_mesh = MeshInstance3D.new()
	var ceil_plane = PlaneMesh.new()
	ceil_plane.size = Vector2(cols * cs, rows * cs)
	ceil_mesh.mesh              = ceil_plane
	ceil_mesh.material_override = ceil_mat
	ceil_mesh.position          = Vector3(cols * cs / 2.0, wall_h, rows * cs / 2.0)
	ceil_mesh.rotation.x        = PI
	maze_node.add_child(ceil_mesh)

	# Walls
	for r in range(rows):
		for c in range(cols):
			if grid[r][c] == 1:
				var wall_body = StaticBody3D.new()
				wall_body.position = Vector3((c + 0.5) * cs, wall_h / 2.0, (r + 0.5) * cs)
				maze_node.add_child(wall_body)

				var wall_vis = CSGBox3D.new()
				wall_vis.size     = Vector3(cs, wall_h, cs)
				wall_vis.material = wall_mat
				wall_body.add_child(wall_vis)

				var col_shape = CollisionShape3D.new()
				var box_shape = BoxShape3D.new()
				box_shape.size      = Vector3(cs, wall_h, cs)
				col_shape.shape     = box_shape
				wall_body.add_child(col_shape)

# ── Map shaders / materials ───────────────────────────────────────────────────

# MAP 1 – Dungeon (brick walls, stone floor, dark ceiling)
# MAP 2 – Ice Cave (icy blue crystalline walls, frost floor, blue ceiling)

func _make_wall_material(map_id: int) -> Material:
	var shader = Shader.new()
	if map_id == 1:
		# Brick wall
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
		# Ice cave: blue crystal walls with faceted shimmer
		shader.code = """
shader_type spatial;
void fragment() {
	vec2 uv = UV * 6.0;
	float gx = floor(uv.x);
	float gy = floor(uv.y);
	float noise = fract(sin(gx * 127.1 + gy * 311.7) * 43758.5);
	vec3 ice_base = vec3(0.55, 0.75, 0.92);
	vec3 ice_dark = vec3(0.30, 0.55, 0.78);
	ALBEDO    = mix(ice_dark, ice_base, noise);
	ROUGHNESS = 0.05;
	METALLIC  = 0.3;
	SPECULAR  = 1.0;
	// Subtle blue emission for the glow effect
	EMISSION  = vec3(0.05, 0.10, 0.22);
}
"""
	var mat = ShaderMaterial.new()
	mat.shader = shader
	return mat

func _make_floor_material(map_id: int) -> Material:
	var shader = Shader.new()
	if map_id == 1:
		# Stone floor checkerboard
		shader.code = """
shader_type spatial;
void fragment() {
	vec2 uv = UV * 12.0;
	float gx = floor(uv.x);
	float gy = floor(uv.y);
	float checker = mod(gx + gy, 2.0);
	float noise = fract(sin(gx * 127.1 + gy * 311.7) * 43758.5);
	vec3 col = mix(vec3(0.28, 0.28, 0.30), vec3(0.22, 0.22, 0.24), checker);
	col += (noise - 0.5) * 0.04;
	ALBEDO    = col;
	ROUGHNESS = 1.0;
}
"""
	else:
		# Ice floor: glossy white-blue tiles with frost cracks
		shader.code = """
shader_type spatial;
void fragment() {
	vec2 uv = UV * 10.0;
	float gx = floor(uv.x);
	float gy = floor(uv.y);
	float noise = fract(sin(gx * 53.7 + gy * 127.3) * 43758.5);
	float crack = step(0.93, noise);
	vec3 col = mix(vec3(0.75, 0.88, 0.98), vec3(0.55, 0.72, 0.88), noise * 0.5);
	col = mix(col, vec3(0.3, 0.4, 0.55), crack);
	ALBEDO    = col;
	ROUGHNESS = 0.08;
	METALLIC  = 0.1;
	SPECULAR  = 1.0;
}
"""
	var mat = ShaderMaterial.new()
	mat.shader = shader
	return mat

func _make_ceiling_material(map_id: int) -> Material:
	var mat = StandardMaterial3D.new()
	if map_id == 1:
		mat.albedo_color = Color(0.12, 0.12, 0.15)
		mat.roughness    = 1.0
	else:
		mat.albedo_color = Color(0.25, 0.40, 0.60)
		mat.roughness    = 0.3
		mat.metallic     = 0.2
		mat.emission_enabled           = true
		mat.emission                   = Color(0.05, 0.10, 0.20)
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
		# Dungeon: warm dim torchlight feel
		dir_light.light_color  = Color(1.0, 0.85, 0.65)
		dir_light.light_energy = 0.5
		env.ambient_light_color  = Color(0.35, 0.30, 0.25)
		env.ambient_light_energy = 1.0
	else:
		# Ice cave: cold blue moonlight
		dir_light.light_color  = Color(0.65, 0.80, 1.0)
		dir_light.light_energy = 0.4
		env.ambient_light_color  = Color(0.22, 0.30, 0.45)
		env.ambient_light_energy = 1.3

	add_child(dir_light)
	world_env.environment = env
	add_child(world_env)

# ── UI ────────────────────────────────────────────────────────────────────────
func _create_ui() -> void:
	var ui = UIManager.new()
	add_child(ui)
	ui.name = "UI"
