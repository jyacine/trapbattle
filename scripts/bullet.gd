extends Node3D

class_name Bullet

var direction: Vector3   = Vector3.FORWARD
var speed: float         = 24.0
var max_range: float     = 28.0
var local_only: bool     = false  # if true: visual only, no hit detection (MP remote peer)
var owner_tag: String    = "player"   # "player" | "robot"
var game_manager: GameManager
var player_ref: Node3D
var robot_ref: Node3D
var sound_manager: SoundManager

var _traveled: float = 0.0

# ────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	var mat = StandardMaterial3D.new()
	mat.emission_enabled           = true
	mat.emission_energy_multiplier = 4.0
	if owner_tag == "player":
		mat.albedo_color = Color(1.0, 0.95, 0.3)
		mat.emission     = Color(1.0, 0.85, 0.1)
	else:
		mat.albedo_color = Color(1.0, 0.25, 0.25)
		mat.emission     = Color(1.0, 0.05, 0.05)
	mat.roughness = 0.1
	mat.metallic  = 0.5

	var mesh = MeshInstance3D.new()
	var sphere = SphereMesh.new()
	sphere.radius = 0.07
	sphere.height = 0.14
	mesh.mesh = sphere
	mesh.set_surface_override_material(0, mat)
	add_child(mesh)

	var light = OmniLight3D.new()
	light.light_color  = mat.emission
	light.light_energy = 4.0
	light.omni_range   = 2.5
	add_child(light)

# ────────────────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	var step = direction * speed * delta
	position += step
	_traveled += step.length()

	# Wall collision — stop as soon as bullet enters a wall cell
	if _is_in_wall():
		queue_free()
		return

	if _traveled >= max_range:
		queue_free()
		return

	# Target hit checks (skipped on remote peers in multiplayer)
	if local_only:
		return
 (each bullet only damages the opposing side)
	if owner_tag == "player" and is_instance_valid(robot_ref):
		if not game_manager.robot_respawning:
			if position.distance_to(robot_ref.position + Vector3(0, 0.9, 0)) < 0.55:
				game_manager.damage_target("robot", 5)
				if sound_manager:
					sound_manager.play_gun_hit()
				queue_free()

	elif owner_tag == "robot" and is_instance_valid(player_ref):
		if not game_manager.player_respawning:
			if position.distance_to(player_ref.position + Vector3(0, 0.9, 0)) < 0.55:
				game_manager.damage_target("player", 5)
				if sound_manager:
					sound_manager.play_gun_hit()
				queue_free()

# ── Grid-based wall check ──────────────────────────────────────────────────
func _is_in_wall() -> bool:
	if game_manager == null:
		return false
	var cs   = Config.CELL_SIZE
	var grid = game_manager.grid
	var col  = int(position.x / cs)
	var row  = int(position.z / cs)
	if row < 0 or row >= grid.size() or col < 0 or col >= grid[0].size():
		return true   # out of bounds counts as wall
	return grid[row][col] == 1
