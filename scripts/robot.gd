extends CharacterBody3D

class_name Robot

# ── Identity (used by bullet hit-detection via "players" group) ───────────────
var peer_id:      int = 0   # sentinel: 0 = robot AI in SP
var player_index: int = 1

# ── References ────────────────────────────────────────────────────────────────
var game_manager: GameManager
var player: Player
var trap_manager: Node

# ── Navigation ────────────────────────────────────────────────────────────────
var current_path: Array   = []
var path_timer: float     = 0.0
const PATH_INTERVAL       = 0.4

# ── State machine ─────────────────────────────────────────────────────────────
# States: "seek_box" | "hunt" | "place" | "dead" | "avoid"
var state: String         = "seek_box"
var current_grid_pos: Array = [0, 0]

# ── Trap inventory ─────────────────────────────────────────────────────────────
var held_trap: int        = -1   # -1 = none
var _place_cooldown: float = 0.0
var _place_radius_cells: float = 3.0  # place trap when within this many cells

# ── Visual ────────────────────────────────────────────────────────────────────
var _body_mat: StandardMaterial3D
var _eye_light: OmniLight3D

# 3-D HP bar (floats above head)
var _hp3_fill_mi: MeshInstance3D
var _hp3_fill_q:  QuadMesh
var _hp3_label:   Label3D

# ── Gun ───────────────────────────────────────────────────────────────────────
var sound_manager: SoundManager
var _gun_timer: float = 4.0

# ── Constants ─────────────────────────────────────────────────────────────────
const ROBOT_RADIUS  = 0.28
const ROBOT_GUN_RANGE = 20.0

# ────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	add_to_group("players")
	var root  = get_parent()
	game_manager = root.get_node("GameManager")
	player       = root.get_node("Player")
	# TrapManager is added after Robot; resolved lazily in _physics_process
	trap_manager = root.get_node_or_null("TrapManager")

	# Collision capsule
	var col = CollisionShape3D.new()
	var cap = CapsuleShape3D.new()
	cap.radius = ROBOT_RADIUS
	cap.height = 1.8
	col.shape  = cap
	add_child(col)

	_build_visual()
	_teleport_to(game_manager.robot_start)

# ────────────────────────────────────────────────────────────────────────────
func _physics_process(delta: float) -> void:
	if not game_manager.is_playing:
		return

	# Resolve TrapManager lazily if it wasn't ready during _ready()
	if trap_manager == null:
		trap_manager = get_parent().get_node_or_null("TrapManager")

	# Handle respawn
	if game_manager.robot_respawning:
		_teleport_to(game_manager.robot_start)
		state = "seek_box"
		held_trap = -1
		return

	# Robot is affected by traps too
	if game_manager.has_effect("robot", "glue") or \
	   game_manager.has_effect("robot", "cage") or \
	   game_manager.has_effect("robot", "electric"):
		return

	var speed_mult = 1.0
	if game_manager.has_effect("robot", "freeze"):
		speed_mult = 0.25
	if game_manager.has_effect("robot", "confusion"):
		speed_mult *= 0.5  # confused robot stumbles

	current_grid_pos = game_manager.world_to_grid(position)
	_place_cooldown = max(0.0, _place_cooldown - delta)

	# ── State transitions ──────────────────────────────────────────────────
	var dist_to_player = position.distance_to(player.position)

	if held_trap < 0:
		state = "seek_box"
	elif dist_to_player <= _place_radius_cells * Config.CELL_SIZE:
		state = "place"
	else:
		state = "hunt"

	# Safety: stay away from player when no trap
	if state == "seek_box" and dist_to_player < 4.0:
		state = "avoid"

	# ── Pathfinding ────────────────────────────────────────────────────────
	path_timer -= delta
	if path_timer <= 0.0:
		path_timer = PATH_INTERVAL
		match state:
			"seek_box":
				var target_box = _find_nearest_box()
				if target_box:
					var box_cell = game_manager.world_to_grid(target_box.position)
					current_path = Pathfinding.astar(game_manager.grid, current_grid_pos, box_cell)
				else:
					current_path = []
			"hunt", "place":
				current_path = Pathfinding.astar(game_manager.grid, current_grid_pos, player.get_grid_position())
			"avoid":
				# Move to robot start (far from player)
				current_path = Pathfinding.astar(game_manager.grid, current_grid_pos, game_manager.robot_start)

	# ── Move along path ────────────────────────────────────────────────────
	var speed = Config.ROBOT_SPEED * speed_mult
	if current_path.size() > 1:
		var target_cell = current_path[1]
		var cs          = Config.CELL_SIZE
		var target_pos  = Vector3((target_cell[0] + 0.5) * cs, position.y, (target_cell[1] + 0.5) * cs)
		var dir         = (target_pos - position).normalized()
		var new_pos     = position + dir * speed * delta
		if _is_valid_pos(new_pos):
			position = new_pos
		# Face direction of travel
		if dir.length() > 0.01:
			rotation.y = atan2(dir.x, dir.z)

	# ── Pick up box if adjacent ────────────────────────────────────────────
	if state == "seek_box" and held_trap < 0:
		for box in get_tree().get_nodes_in_group("trap_boxes"):
			if position.distance_to(box.position) < 2.5:
				held_trap = box.trap_type
				box.respawn_box()
				break

	# ── Place trap ────────────────────────────────────────────────────────
	if state == "place" and held_trap >= 0 and _place_cooldown <= 0.0:
		# Place slightly ahead of player's path
		trap_manager.place_trap(current_grid_pos, peer_id, held_trap)
		held_trap = -1
		_place_cooldown = 3.0

	# ── Pulse eye light ────────────────────────────────────────────────────
	# Gun: fire at player periodically when hunting
	_gun_timer -= delta
	if _gun_timer <= 0.0 and state == "hunt":
		_gun_timer = randf_range(3.5, 5.5)
		if position.distance_to(player.position) < ROBOT_GUN_RANGE:
			_fire_at_player()

	_update_hp3_bar()

	if _eye_light:
		var t = float(Time.get_ticks_msec()) / 1000.0
		if held_trap >= 0:
			# Glow the trap color when carrying one
			_eye_light.light_color  = Config.TRAP_COLORS[held_trap]
			_eye_light.light_energy = 1.5 + sin(t * 4.0) * 0.5
		else:
			_eye_light.light_color  = Color(1.0, 0.1, 0.1)
			_eye_light.light_energy = 1.0 + sin(t * 2.0) * 0.3

# ── Robot gun ────────────────────────────────────────────────────────────────
func _fire_at_player() -> void:
	if sound_manager:
		sound_manager.play_gun_fire()

	var flash = OmniLight3D.new()
	flash.light_color  = Color(1.0, 0.25, 0.25)
	flash.light_energy = 8.0
	flash.omni_range   = 4.0
	flash.position     = position + Vector3(0, 0.9, 0)
	get_parent().add_child(flash)
	get_tree().create_timer(0.06).timeout.connect(func():
		if is_instance_valid(flash): flash.queue_free()
	)

	# Aim from body centre to player body centre so bullet travels at hit height
	var spawn_pos = position + Vector3(0, 0.9, 0)
	var target_pos = player.position + Vector3(0, 0.9, 0)
	var dir = (target_pos - spawn_pos).normalized()
	var b = Bullet.new()
	b.owner_peer_id = peer_id         # 0 = robot AI
	b.owner_index   = player_index    # 1 = second color slot
	b.direction     = dir
	b.game_manager  = game_manager
	b.sound_manager = sound_manager
	b.position      = spawn_pos
	get_parent().add_child(b)

# ── Find nearest trap box ─────────────────────────────────────────────────────
func _find_nearest_box() -> Node:
	var best: Node = null
	var best_d = INF
	for box in get_tree().get_nodes_in_group("trap_boxes"):
		var d = position.distance_to(box.position)
		if d < best_d:
			best_d = d
			best   = box
	return best

# ── Collision guard ────────────────────────────────────────────────────────────
func _is_valid_pos(pos: Vector3) -> bool:
	var cs = Config.CELL_SIZE
	var gx = int(pos.x / cs)
	var gz = int(pos.z / cs)
	if not game_manager.is_floor(gx, gz): return false

	# Collision with other bodies (players and other robots)
	var combined_sq = (ROBOT_RADIUS + Config.PLAYER_RADIUS) * (ROBOT_RADIUS + Config.PLAYER_RADIUS)
	for other in get_tree().get_nodes_in_group("players"):
		if other == self or not is_instance_valid(other): continue
		var other_pid = other.get("peer_id")
		if other_pid != null and game_manager.respawning.get(other_pid, false): continue
		var dx = pos.x - other.position.x
		var dz = pos.z - other.position.z
		if dx * dx + dz * dz < combined_sq: return false

	return true

func _teleport_to(cell: Array) -> void:
	position = game_manager.grid_to_world(cell)
	current_grid_pos = cell.duplicate()

func get_grid_position() -> Array:
	return current_grid_pos

# ── Robot visual: blocky android body ─────────────────────────────────────────
func _build_visual() -> void:
	_body_mat = StandardMaterial3D.new()
	_body_mat.albedo_color = Color(0.2, 0.2, 0.3)
	_body_mat.metallic     = 0.8
	_body_mat.roughness    = 0.3

	var accent_mat = StandardMaterial3D.new()
	accent_mat.albedo_color = Color(0.05, 0.5, 0.8)
	accent_mat.metallic     = 1.0
	accent_mat.roughness    = 0.1

	# Torso
	var torso = CSGBox3D.new()
	torso.size     = Vector3(0.5, 0.6, 0.3)
	torso.position = Vector3(0, 0.7, 0)
	torso.material = _body_mat
	add_child(torso)

	# Legs
	for lp in [Vector3(-0.12, 0.25, 0.0), Vector3(0.12, 0.25, 0.0)]:
		var leg = CSGBox3D.new()
		leg.size     = Vector3(0.18, 0.35, 0.18)
		leg.position = lp
		leg.material = _body_mat
		add_child(leg)

	# Arms
	for ap in [Vector3(-0.32, 0.7, 0.0), Vector3(0.32, 0.7, 0.0)]:
		var arm = CSGBox3D.new()
		arm.size     = Vector3(0.12, 0.5, 0.12)
		arm.position = ap
		arm.material = _body_mat
		add_child(arm)

	# Head (cube)
	var head = CSGBox3D.new()
	head.size     = Vector3(0.42, 0.42, 0.42)
	head.position = Vector3(0, 1.18, 0)
	head.material = _body_mat
	add_child(head)

	# Visor (glowing strip)
	var visor = CSGBox3D.new()
	visor.size     = Vector3(0.30, 0.08, 0.05)
	visor.position = Vector3(0, 1.20, 0.22)
	visor.material = accent_mat
	add_child(visor)

	# Eye light
	_eye_light = OmniLight3D.new()
	_eye_light.position     = Vector3(0, 1.4, 0)
	_eye_light.light_color  = Color(1.0, 0.1, 0.1)
	_eye_light.light_energy = 1.0
	_eye_light.omni_range   = 3.0
	add_child(_eye_light)

	_build_hp3_bar()

# -- 3-D HP bar build ---------------------------------------------------------
func _build_hp3_bar() -> void:
	var root = Node3D.new()
	root.position = Vector3(0, 1.72, 0)
	add_child(root)

	var bg_mat = StandardMaterial3D.new()
	bg_mat.albedo_color    = Color(0.10, 0.04, 0.04, 0.90)
	bg_mat.shading_mode    = BaseMaterial3D.SHADING_MODE_UNSHADED
	bg_mat.billboard_mode  = BaseMaterial3D.BILLBOARD_ENABLED
	bg_mat.billboard_keep_scale = true
	bg_mat.transparency    = BaseMaterial3D.TRANSPARENCY_ALPHA
	var bg_mi = MeshInstance3D.new()
	var bg_q  = QuadMesh.new(); bg_q.size = Vector2(0.70, 0.10)
	bg_mi.mesh = bg_q
	bg_mi.set_surface_override_material(0, bg_mat)
	root.add_child(bg_mi)

	var fill_mat = StandardMaterial3D.new()
	fill_mat.albedo_color   = Color(0.88, 0.12, 0.12)
	fill_mat.shading_mode   = BaseMaterial3D.SHADING_MODE_UNSHADED
	fill_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	fill_mat.billboard_keep_scale = true
	_hp3_fill_q  = QuadMesh.new(); _hp3_fill_q.size = Vector2(0.66, 0.06)
	_hp3_fill_mi = MeshInstance3D.new()
	_hp3_fill_mi.mesh = _hp3_fill_q
	_hp3_fill_mi.set_surface_override_material(0, fill_mat)
	_hp3_fill_mi.position = Vector3(0, 0, 0.001)
	root.add_child(_hp3_fill_mi)

	_hp3_label = Label3D.new()
	_hp3_label.text          = "100 HP"
	_hp3_label.font_size     = 18
	_hp3_label.modulate      = Color(1, 1, 1, 1)
	_hp3_label.outline_size  = 6
	_hp3_label.outline_modulate = Color(0, 0, 0, 1)
	_hp3_label.billboard     = BaseMaterial3D.BILLBOARD_ENABLED
	_hp3_label.position      = Vector3(0, 0.10, 0)
	root.add_child(_hp3_label)

func _update_hp3_bar() -> void:
	if _hp3_fill_mi == null or _hp3_fill_q == null:
		return
	var ratio = float(game_manager.robot_hp) / float(Config.MAX_HP)
	var full_w = 0.66
	var new_w  = full_w * ratio
	_hp3_fill_q.size.x    = new_w
	_hp3_fill_mi.position.x = -(full_w - new_w) / 2.0

	var mat = _hp3_fill_mi.get_surface_override_material(0) as StandardMaterial3D
	if mat:
		if ratio > 0.60:
			mat.albedo_color = Color(0.88, 0.12, 0.12)
		elif ratio > 0.30:
			mat.albedo_color = Color(0.92, 0.50, 0.08)
		else:
			mat.albedo_color = Color(0.95, 0.80, 0.05)

	if _hp3_label:
		_hp3_label.text = "%d HP" % game_manager.robot_hp
