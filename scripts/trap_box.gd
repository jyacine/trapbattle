extends Node3D

class_name TrapBox

# ── References ────────────────────────────────────────────────────────────────
var game_manager: GameManager

# ── State ─────────────────────────────────────────────────────────────────────
var trap_type: int        = 0
var current_grid_pos: Array = [0, 0]

# ── Visuals ───────────────────────────────────────────────────────────────────
var _box_mesh: CSGBox3D
var _lid_mesh: CSGBox3D
var _box_mat: StandardMaterial3D
var _lid_mat: StandardMaterial3D
var _light: OmniLight3D
var _label_mesh: MeshInstance3D
var _billboard: Label3D

# ── Light cycling ─────────────────────────────────────────────────────────────
var _light_phase: float   = 0.0

# ────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	game_manager = get_parent().get_node("GameManager")
	add_to_group("trap_boxes")
	_assign_random_trap()
	_build_visual()
	_snap_to_grid()

# ────────────────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	if not game_manager.is_playing:
		return

	# Animate: gentle bob + rotating light
	_light_phase += delta * 1.8
	if _light:
		var trap_col = Config.TRAP_COLORS[trap_type]
		# Pulse brightness
		_light.light_energy = 1.8 + sin(_light_phase) * 0.6
		# Shift hue slightly over time for a magical shimmer
		var shimmer_r = trap_col.r + sin(_light_phase * 0.7) * 0.15
		var shimmer_g = trap_col.g + sin(_light_phase * 1.1) * 0.15
		var shimmer_b = trap_col.b + sin(_light_phase * 1.5) * 0.15
		_light.light_color = Color(
			clamp(shimmer_r, 0.0, 1.0),
			clamp(shimmer_g, 0.0, 1.0),
			clamp(shimmer_b, 0.0, 1.0)
		)

	# Bob up/down
	var bob_y = sin(_light_phase * 1.2) * 0.08
	if _box_mesh:
		_box_mesh.position.y = 0.3 + bob_y
	if _lid_mesh:
		_lid_mesh.position.y = 0.62 + bob_y
	# Light hovers above box
	if _light:
		_light.position.y = 1.2 + bob_y

	# Spin
	rotation.y += delta * 1.5

func _snap_to_grid() -> void:
	var cs = Config.CELL_SIZE
	position = Vector3(
		(current_grid_pos[0] + 0.5) * cs,
		0.0,
		(current_grid_pos[1] + 0.5) * cs
	)

# ── After pickup: move box to a new random position with a new trap ───────────
func respawn_box() -> void:
	var new_cell = game_manager.get_random_floor_cell()
	current_grid_pos = new_cell
	_snap_to_grid()
	_assign_random_trap()
	_update_colors()

func _assign_random_trap() -> void:
	trap_type = randi() % 15   # 0-14

func _update_colors() -> void:
	var col = Config.TRAP_COLORS[trap_type]
	if _box_mat:
		_box_mat.albedo_color  = col.darkened(0.3)
		_box_mat.emission      = col
		_box_mat.emission_energy_multiplier = 0.4
	if _lid_mat:
		_lid_mat.albedo_color  = col
		_lid_mat.emission      = col
		_lid_mat.emission_energy_multiplier = 0.6
	if _light:
		_light.light_color = col
	if _billboard:
		_billboard.text = Config.TRAP_NAMES[trap_type]

# ── Build the crate visual ────────────────────────────────────────────────────
func _build_visual() -> void:
	var col = Config.TRAP_COLORS[trap_type]

	# Crate body
	_box_mat = StandardMaterial3D.new()
	_box_mat.albedo_color               = col.darkened(0.3)
	_box_mat.emission_enabled           = true
	_box_mat.emission                   = col
	_box_mat.emission_energy_multiplier = 0.4
	_box_mat.roughness                  = 0.7

	_box_mesh = CSGBox3D.new()
	_box_mesh.size     = Vector3(0.5, 0.45, 0.5)
	_box_mesh.position = Vector3(0, 0.3, 0)
	_box_mesh.material = _box_mat
	add_child(_box_mesh)

	# Lid (slightly wider)
	_lid_mat = StandardMaterial3D.new()
	_lid_mat.albedo_color               = col
	_lid_mat.emission_enabled           = true
	_lid_mat.emission                   = col
	_lid_mat.emission_energy_multiplier = 0.6
	_lid_mat.roughness                  = 0.5

	_lid_mesh = CSGBox3D.new()
	_lid_mesh.size     = Vector3(0.54, 0.10, 0.54)
	_lid_mesh.position = Vector3(0, 0.62, 0)
	_lid_mesh.material = _lid_mat
	add_child(_lid_mesh)

	# Floating label
	_billboard = Label3D.new()
	_billboard.text        = Config.TRAP_NAMES[trap_type]
	_billboard.font_size   = 24
	_billboard.modulate    = Color.WHITE
	_billboard.position    = Vector3(0, 1.5, 0)
	_billboard.billboard   = BaseMaterial3D.BILLBOARD_ENABLED
	_billboard.no_depth_test = true
	add_child(_billboard)

	# Glowing point light above the crate
	_light = OmniLight3D.new()
	_light.light_color  = col
	_light.light_energy = 2.0
	_light.omni_range   = 4.5
	_light.position     = Vector3(0, 1.2, 0)
	add_child(_light)

	# "?" question mark floating above
	var qmark = Label3D.new()
	qmark.text          = "?"
	qmark.font_size     = 48
	qmark.modulate      = Color.YELLOW
	qmark.position      = Vector3(0, 1.1, 0)
	qmark.billboard     = BaseMaterial3D.BILLBOARD_ENABLED
	qmark.no_depth_test = true
	add_child(qmark)

	# Floor ring
	var ring = MeshInstance3D.new()
	var torus = TorusMesh.new()
	torus.inner_radius = 0.30
	torus.outer_radius = 0.42
	ring.mesh     = torus
	ring.position = Vector3(0, 0.02, 0)
	var ring_mat = StandardMaterial3D.new()
	ring_mat.albedo_color               = col
	ring_mat.emission_enabled           = true
	ring_mat.emission                   = col
	ring_mat.emission_energy_multiplier = 1.5
	ring.set_surface_override_material(0, ring_mat)
	add_child(ring)
