extends Node3D

class_name GunBox

const GUN_ICONS: Array = [
	"res://assets/icons/icon_gun.svg",        # 0 pistol
	"res://assets/icons/icon_shotgun.svg",    # 1 shotgun
	"res://assets/icons/icon_machinegun.svg", # 2 machinegun
]

# ── References ────────────────────────────────────────────────────────────────
var game_manager: GameManager

# ── State ─────────────────────────────────────────────────────────────────────
var gun_type: int = 0
var current_grid_pos: Array = [0, 0]

# ── Visuals ───────────────────────────────────────────────────────────────────
var _sprite: Sprite3D
var _light: OmniLight3D
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

	# Pulse brightness
	if _light:
		_light.light_energy = 1.8 + sin(_light_phase) * 0.6

	# Bob up/down
	var bob_y: float = sin(_light_phase * 1.2) * 0.08
	if _sprite:
		_sprite.position.y = 0.8 + bob_y
	if _light:
		_light.position.y = 1.3 + bob_y

	rotation.y += delta * 2.0

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
	_update_icon()
	visible = true
	add_to_group("gun_boxes")

func _assign_random_gun() -> void:
	gun_type = randi() % 3

func _update_icon() -> void:
	if _sprite:
		_sprite.texture = load(GUN_ICONS[gun_type])
		const PIXEL_SIZES: Array = [0.007, 0.012, 0.011]
		_sprite.pixel_size = PIXEL_SIZES[gun_type]

func _build_visual() -> void:
	# Gun icon sprite — always faces the player
	_sprite = Sprite3D.new()
	_sprite.texture = load(GUN_ICONS[gun_type])
	# Larger weapons get a bigger world-space icon so they read clearly from a distance
	const PIXEL_SIZES: Array = [0.007, 0.012, 0.011]   # pistol, shotgun, machinegun
	_sprite.pixel_size = PIXEL_SIZES[gun_type]
	_sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_sprite.no_depth_test = true
	_sprite.position = Vector3(0, 0.8, 0)
	add_child(_sprite)

	# Blue glow light
	_light = OmniLight3D.new()
	_light.light_color = Color(0.5, 0.8, 1.0)
	_light.light_energy = 2.0
	_light.omni_range = 4.5
	_light.position = Vector3(0, 1.3, 0)
	add_child(_light)

	# Floor ring
	var ring = MeshInstance3D.new()
	var torus = TorusMesh.new()
	torus.inner_radius = 0.30
	torus.outer_radius = 0.42
	ring.mesh = torus
	ring.position = Vector3(0, 0.02, 0)
	var ring_mat = StandardMaterial3D.new()
	var col = Color(0.5, 0.8, 1.0)
	ring_mat.albedo_color = col
	ring_mat.emission_enabled = true
	ring_mat.emission = col
	ring_mat.emission_energy_multiplier = 1.5
	ring.set_surface_override_material(0, ring_mat)
	add_child(ring)
