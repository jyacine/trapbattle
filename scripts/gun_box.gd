extends Node3D

class_name GunBox

# ── References ────────────────────────────────────────────────────────────────
var game_manager: GameManager

# ── State ─────────────────────────────────────────────────────────────────────
var gun_type: int = 0
var current_grid_pos: Array = [0, 0]

# ── Visuals ───────────────────────────────────────────────────────────────────
var _box_mesh: MeshInstance3D
var _lid_mesh: MeshInstance3D
var _box_mat: StandardMaterial3D
var _lid_mat: StandardMaterial3D
var _light: OmniLight3D
var _billboard: Label3D

# ── Light cycling ─────────────────────────────────────────────────────────────
var _light_phase: float = 0.0

# ────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	game_manager = get_parent().get_node("GameManager")
	add_to_group("gun_boxes")
	_assign_random_gun()
	_build_visual()
	_snap_to_grid()

# ────────────────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	if not game_manager.is_playing or not visible:
		return

	_light_phase += delta * 1.8
	if _light:
		var gun_col = Color(0.5, 0.8, 1.0)  # light blue for guns
		_light.light_energy = 1.8 + sin(_light_phase) * 0.6
		var shimmer_r = gun_col.r + sin(_light_phase * 0.7) * 0.15
		var shimmer_g = gun_col.g + sin(_light_phase * 1.1) * 0.15
		var shimmer_b = gun_col.b + sin(_light_phase * 1.5) * 0.15
		_light.light_color = Color(
			clamp(shimmer_r, 0.0, 1.0),
			clamp(shimmer_g, 0.0, 1.0),
			clamp(shimmer_b, 0.0, 1.0)
		)

	var bob_y = sin(_light_phase * 1.2) * 0.08
	if _box_mesh:
		_box_mesh.position.y = 0.3 + bob_y
	if _lid_mesh:
		_lid_mesh.position.y = 0.62 + bob_y
	if _light:
		_light.position.y = 1.2 + bob_y

	rotation.y += delta * 2.0  # spin faster than trap boxes

func _snap_to_grid() -> void:
	var cs = Config.CELL_SIZE
	position = Vector3(
		(current_grid_pos[0] + 0.5) * cs,
		0.0,
		(current_grid_pos[1] + 0.5) * cs
	)

func respawn_box() -> void:
	visible = false
	remove_from_group("gun_boxes")
	get_tree().create_timer(30.0).timeout.connect(_do_respawn)

func _do_respawn() -> void:
	var new_cell = game_manager.get_random_floor_cell()
	current_grid_pos = new_cell
	_snap_to_grid()
	_assign_random_gun()
	_update_colors()
	visible = true
	add_to_group("gun_boxes")

func _assign_random_gun() -> void:
	gun_type = randi() % 3

func _update_colors() -> void:
	var col = Color(0.5, 0.8, 1.0)  # light blue
	if _box_mat:
		_box_mat.albedo_color = col.darkened(0.3)
		_box_mat.emission = col
		_box_mat.emission_energy_multiplier = 0.4
	if _lid_mat:
		_lid_mat.albedo_color = col
		_lid_mat.emission = col
		_lid_mat.emission_energy_multiplier = 0.6
	if _light:
		_light.light_color = col
	if _billboard:
		_billboard.text = Config.GUN_NAMES[gun_type]

func _build_visual() -> void:
	var col = Color(0.5, 0.8, 1.0)  # light blue

	_box_mat = StandardMaterial3D.new()
	_box_mat.albedo_color = col.darkened(0.3)
	_box_mat.emission_enabled = true
	_box_mat.emission = col
	_box_mat.emission_energy_multiplier = 0.4
	_box_mat.roughness = 0.7

	_box_mesh = MeshInstance3D.new()
	var box_bm = BoxMesh.new(); box_bm.size = Vector3(0.5, 0.45, 0.5)
	_box_mesh.mesh = box_bm
	_box_mesh.position = Vector3(0, 0.3, 0)
	_box_mesh.material_override = _box_mat
	add_child(_box_mesh)

	_lid_mat = StandardMaterial3D.new()
	_lid_mat.albedo_color = col
	_lid_mat.emission_enabled = true
	_lid_mat.emission = col
	_lid_mat.emission_energy_multiplier = 0.6
	_lid_mat.roughness = 0.5

	_lid_mesh = MeshInstance3D.new()
	var lid_bm = BoxMesh.new(); lid_bm.size = Vector3(0.54, 0.10, 0.54)
	_lid_mesh.mesh = lid_bm
	_lid_mesh.position = Vector3(0, 0.62, 0)
	_lid_mesh.material_override = _lid_mat
	add_child(_lid_mesh)

	_billboard = Label3D.new()
	_billboard.text = Config.GUN_NAMES[gun_type]
	_billboard.font_size = 24
	_billboard.modulate = Color.WHITE
	_billboard.position = Vector3(0, 1.5, 0)
	_billboard.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_billboard.no_depth_test = true
	add_child(_billboard)

	_light = OmniLight3D.new()
	_light.light_color = col
	_light.light_energy = 2.0
	_light.omni_range = 4.5
	_light.position = Vector3(0, 1.2, 0)
	add_child(_light)

	var icon = Label3D.new()
	icon.text = "🔫"
	icon.font_size = 48
	icon.modulate = Color.WHITE
	icon.position = Vector3(0, 1.1, 0)
	icon.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	icon.no_depth_test = true
	add_child(icon)

	var ring = MeshInstance3D.new()
	var torus = TorusMesh.new()
	torus.inner_radius = 0.30
	torus.outer_radius = 0.42
	ring.mesh = torus
	ring.position = Vector3(0, 0.02, 0)
	var ring_mat = StandardMaterial3D.new()
	ring_mat.albedo_color = col
	ring_mat.emission_enabled = true
	ring_mat.emission = col
	ring_mat.emission_energy_multiplier = 1.5
	ring.set_surface_override_material(0, ring_mat)
	add_child(ring)
