extends Node3D

class_name Bullet

var direction:    Vector3 = Vector3.FORWARD
var speed:        float   = 24.0
var max_range:    float   = 28.0
var local_only:   bool    = false   # true = visual only, no hit detection
var owner_peer_id: int    = 0       # peer_id of the player who fired
var owner_index:  int     = 0       # player_index for color
var game_manager: GameManager
var sound_manager: SoundManager

var _traveled: float = 0.0

# ────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	var pc  = Config.PLAYER_COLORS[owner_index % Config.PLAYER_COLORS.size()]
	var mat = StandardMaterial3D.new()
	mat.emission_enabled           = true
	mat.emission_energy_multiplier = 4.0
	mat.albedo_color = pc
	mat.emission     = pc
	mat.roughness    = 0.1
	mat.metallic     = 0.5

	var mesh = MeshInstance3D.new()
	var sphere = SphereMesh.new()
	sphere.radius = 0.07; sphere.height = 0.14
	mesh.mesh = sphere; mesh.set_surface_override_material(0, mat)
	add_child(mesh)

	var light = OmniLight3D.new()
	light.light_color  = pc
	light.light_energy = 4.0
	light.omni_range   = 2.5
	add_child(light)

# ────────────────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	var step = direction * speed * delta
	position  += step
	_traveled += step.length()

	if _is_in_wall():
		queue_free(); return
	if _traveled >= max_range:
		queue_free(); return
	if local_only:
		return

	# Check all players in group except the shooter.
	# Body is treated as a vertical capsule (feet→head) so shots fired along the
	# eye/crosshair ray connect anywhere on the body, not just at chest height.
	const HIT_RADIUS := 0.55
	const BODY_MIN_Y := 0.20   # above the feet
	const BODY_MAX_Y := 1.80   # head height
	for target in get_tree().get_nodes_in_group("players"):
		if not is_instance_valid(target): continue
		var target_pid = target.get("peer_id")
		if target_pid == null or target_pid == owner_peer_id: continue
		if game_manager.respawning.get(target_pid, false): continue
		var dx: float = position.x - target.position.x
		var dz: float = position.z - target.position.z
		var y_rel: float = position.y - target.position.y
		if dx * dx + dz * dz < HIT_RADIUS * HIT_RADIUS \
				and y_rel > BODY_MIN_Y and y_rel < BODY_MAX_Y:
			if multiplayer.has_multiplayer_peer():
				game_manager.net_damage.rpc(target_pid, Config.HIT_DAMAGE, owner_peer_id)
			else:
				game_manager.damage_player(target_pid, Config.HIT_DAMAGE, owner_peer_id)
			if sound_manager: sound_manager.play_gun_hit()
			queue_free()
			return

# ── Grid-based wall check ──────────────────────────────────────────────────
func _is_in_wall() -> bool:
	if game_manager == null: return false
	var cs   = Config.CELL_SIZE
	var grid = game_manager.grid
	var col  = int(position.x / cs)
	var row  = int(position.z / cs)
	if row < 0 or row >= grid.size() or col < 0 or col >= grid[0].size():
		return true
	return grid[row][col] == 1
