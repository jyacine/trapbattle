extends CharacterBody3D

class_name Player

# ── Identity ─────────────────────────────────────────────────────────────────
# peer_id:      actual Godot multiplayer peer ID (1 = host; 0 = robot AI sentinel)
# player_index: 0-9 slot — determines color and spawn point
var peer_id:      int = 0
var player_index: int = 0

# ── References ───────────────────────────────────────────────────────────────
var game_manager: GameManager
var trap_manager: Node
var sound_manager: SoundManager

# ── Movement ─────────────────────────────────────────────────────────────────
var move_speed:        float = Config.PLAYER_SPEED
var rotation_speed:    float = Config.PLAYER_ROTATION_SPEED
var mouse_sensitivity: float = Config.MOUSE_SENSITIVITY
var player_radius:     float = Config.PLAYER_RADIUS
var yaw:               float = 0.0
var pitch:             float = 0.0
var _pending_yaw_delta: float = 0.0

# ── Camera ───────────────────────────────────────────────────────────────────
var camera_node: Camera3D

# ── Trap inventory ────────────────────────────────────────────────────────────
var held_trap: int = -1
var _pickup_cooldown: float = 0.0

# ── Gun ───────────────────────────────────────────────────────────────────────
var _gun_cooldown: float = 0.0
const GUN_RANGE    := 28.0
const GUN_COOLDOWN := 1.5

# ── Blind overlay ────────────────────────────────────────────────────────────
var _blind_overlay: ColorRect

# ── Current grid pos ─────────────────────────────────────────────────────────
var current_grid_pos: Array = [0, 0]

# ── Footstep audio ────────────────────────────────────────────────────────────
var _footstep_timer:   float = 0.0
const FOOTSTEP_INTERVAL := 0.42   # seconds between steps

# ── Touch input ───────────────────────────────────────────────────────────────
var touch_forward:  bool  = false
var touch_backward: bool  = false
var touch_turn:     float = 0.0   # joystick X: -1 (left) .. +1 (right)

# ── Multiplayer ───────────────────────────────────────────────────────────────
var is_local: bool = true

# Remote-body HP bar (only built when is_local == false)
var _hp3_fill_mi: MeshInstance3D = null
var _hp3_fill_q:  QuadMesh       = null
var _hp3_label:   Label3D        = null

# ── Viewmodel (first-person gun) ─────────────────────────────────────────────
var _viewmodel_root: Node3D = null
var _vm_sway_time:   float  = 0.0
var _vm_recoil:      float  = 0.0

# ── Backward-compat alias (robot.gd / old callers) ───────────────────────────
var robot_ref: Node3D  # unused in N-player but kept so existing robot.gd compiles

# ────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	add_to_group("players")
	game_manager = get_parent().get_node("GameManager")
	is_local     = is_multiplayer_authority()   # true in SP (no peer) or on authority peer

	var col = CollisionShape3D.new()
	var cap = CapsuleShape3D.new()
	cap.radius = player_radius; cap.height = 1.8
	col.shape  = cap
	add_child(col)

	var spawn_cell = game_manager.get_spawn_for_index(player_index)

	if is_local:
		camera_node = Camera3D.new()
		camera_node.position = Vector3(0, 1.6, 0)
		add_child(camera_node)
		_build_viewmodel()
		_teleport_to(spawn_cell)
		if not OS.has_feature("web"):
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		_build_remote_body()
		_teleport_to(spawn_cell)

# ────────────────────────────────────────────────────────────────────────────
func _physics_process(delta: float) -> void:
	if not game_manager.is_playing:
		return

	if not is_local:
		_update_hp3_bar()
		return

	_pickup_cooldown = max(0.0, _pickup_cooldown - delta)
	_gun_cooldown    = max(0.0, _gun_cooldown    - delta)

	yaw += _pending_yaw_delta
	_pending_yaw_delta = 0.0

	if game_manager.respawning.get(peer_id, false):
		_teleport_to(game_manager.get_spawn_for_index(player_index))
		return

	var is_confused = game_manager.has_effect(peer_id, "confusion")
	var turn_dir = 0.0
	if Input.is_key_pressed(KEY_Q): turn_dir -= rotation_speed * delta
	if Input.is_key_pressed(KEY_E): turn_dir += rotation_speed * delta
	turn_dir += touch_turn * rotation_speed * delta
	if is_confused: turn_dir = -turn_dir
	yaw += turn_dir
	rotation.y = yaw

	var can_move = not (game_manager.has_effect(peer_id, "glue") or
	                    game_manager.has_effect(peer_id, "cage") or
	                    game_manager.has_effect(peer_id, "electric"))

	if can_move:
		var speed_mult = 0.25 if game_manager.has_effect(peer_id, "freeze") else 1.0
		var move = 0.0
		if Input.is_action_pressed("ui_up")  or Input.is_key_pressed(KEY_W) or touch_forward:  move += 1.0
		if Input.is_action_pressed("ui_down") or Input.is_key_pressed(KEY_S) or touch_backward: move -= 1.0
		if is_confused: move = -move
		if move != 0.0:
			# Footstep sound
			_footstep_timer -= delta
			if _footstep_timer <= 0.0:
				if sound_manager: sound_manager.play_footstep()
				_footstep_timer = FOOTSTEP_INTERVAL / speed_mult

			var forward  = Vector3(-sin(yaw), 0.0, -cos(yaw))
			var movement = forward * move * move_speed * speed_mult * delta
			var new_pos  = position + movement
			if _is_walkable(new_pos):
				position = new_pos
			else:
				var sx = position + Vector3(movement.x, 0, 0)
				var sz = position + Vector3(0, 0, movement.z)
				if   _is_walkable(sx): position = sx
				elif _is_walkable(sz): position = sz
		else:
			_footstep_timer = 0.0   # reset so first step after pause is immediate

	current_grid_pos = game_manager.world_to_grid(position)
	_try_pickup()

	if _blind_overlay:
		_blind_overlay.visible = game_manager.has_effect(peer_id, "blind")

	_update_viewmodel(delta)

	if multiplayer.has_multiplayer_peer():
		_net_pos.rpc(position, yaw)

# ────────────────────────────────────────────────────────────────────────────
func _input(event: InputEvent) -> void:
	if not is_local:
		return

	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED: _fire_gun()
			else: Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_pending_yaw_delta -= event.relative.x * mouse_sensitivity
		pitch -= event.relative.y * mouse_sensitivity
		pitch = clamp(pitch, -PI / 3.0, PI / 3.0)
		camera_node.rotation.x = pitch

	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_SPACE:  _try_place()
			KEY_TAB:    _fire_gun()
			KEY_ESCAPE:
				if OS.has_feature("web"): Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
				else: get_tree().quit()
			KEY_R: get_tree().reload_current_scene()

# ── Gun ───────────────────────────────────────────────────────────────────────
func _fire_gun() -> void:
	if _gun_cooldown > 0.0 or not game_manager.is_playing:
		return
	_gun_cooldown = GUN_COOLDOWN
	_vm_recoil    = 1.0
	if sound_manager: sound_manager.play_gun_fire()

	var spawn_pos = position + Vector3(0, 0.9, 0)
	var flash = OmniLight3D.new()
	flash.light_color = Color(1.0, 0.88, 0.45); flash.light_energy = 12.0; flash.omni_range = 5.0
	flash.position = spawn_pos; get_parent().add_child(flash)
	get_tree().create_timer(0.07).timeout.connect(func():
		if is_instance_valid(flash): flash.queue_free())

	var forward = -camera_node.global_transform.basis.z
	_spawn_bullet_local(spawn_pos, forward)

	if multiplayer.has_multiplayer_peer():
		game_manager.net_spawn_bullet.rpc(spawn_pos, forward, peer_id, player_index)

func _spawn_bullet_local(pos: Vector3, dir: Vector3) -> void:
	var b = Bullet.new()
	b.owner_peer_id = peer_id
	b.owner_index   = player_index
	b.direction     = dir
	b.local_only    = false
	b.game_manager  = game_manager
	b.sound_manager = sound_manager
	b.position      = pos
	get_parent().add_child(b)

# ── Trap placement ────────────────────────────────────────────────────────────
func _try_place() -> void:
	if held_trap < 0 or trap_manager == null:
		return
	var forward    = Vector3(-sin(yaw), 0.0, -cos(yaw))
	var throw_pos  = position + forward * Config.CELL_SIZE
	var throw_cell = game_manager.world_to_grid(throw_pos)
	var target_cell = throw_cell if game_manager.is_floor(throw_cell[0], throw_cell[1]) \
	                             else current_grid_pos
	if multiplayer.has_multiplayer_peer():
		trap_manager.net_place_trap.rpc(target_cell, peer_id, held_trap)
	else:
		trap_manager.place_trap(target_cell, peer_id, held_trap)
	held_trap = -1

# ── Auto pick-up ─────────────────────────────────────────────────────────────
func _try_pickup() -> void:
	if held_trap >= 0 or _pickup_cooldown > 0.0 or trap_manager == null:
		return
	var best_box = null; var best_dist = Config.CELL_SIZE * 0.75
	for box in get_tree().get_nodes_in_group("trap_boxes"):
		var d = position.distance_to(box.position)
		if d < best_dist: best_dist = d; best_box = box
	if best_box != null:
		held_trap = best_box.trap_type; best_box.respawn_box()
		_pickup_cooldown = 0.5
		if sound_manager: sound_manager.play_pickup()

# ── Multiplayer position sync ─────────────────────────────────────────────────
@rpc("authority", "unreliable")
func _net_pos(pos: Vector3, y: float) -> void:
	if is_multiplayer_authority(): return
	position         = pos
	yaw              = y
	rotation.y       = yaw
	current_grid_pos = game_manager.world_to_grid(pos)   # keep grid pos in sync

# ── Remote body ───────────────────────────────────────────────────────────────
func _build_remote_body() -> void:
	var pc  = Config.PLAYER_COLORS[player_index % Config.PLAYER_COLORS.size()]
	var bm  = StandardMaterial3D.new()
	bm.albedo_color = pc.darkened(0.35); bm.metallic = 0.8; bm.roughness = 0.3
	var am  = StandardMaterial3D.new()
	am.albedo_color = pc; am.emission_enabled = true
	am.emission = pc; am.emission_energy_multiplier = 0.8
	am.metallic = 1.0; am.roughness = 0.1

	var parts = [
		[Vector3(0.5,  0.6,  0.3 ), Vector3( 0,    0.70, 0   ), bm],
		[Vector3(0.18, 0.35, 0.18), Vector3(-0.12, 0.25, 0   ), bm],
		[Vector3(0.18, 0.35, 0.18), Vector3( 0.12, 0.25, 0   ), bm],
		[Vector3(0.12, 0.5,  0.12), Vector3(-0.32, 0.70, 0   ), bm],
		[Vector3(0.12, 0.5,  0.12), Vector3( 0.32, 0.70, 0   ), bm],
		[Vector3(0.42, 0.42, 0.42), Vector3( 0,    1.18, 0   ), bm],
		[Vector3(0.30, 0.08, 0.05), Vector3( 0,    1.20, 0.22), am],
	]
	for p in parts:
		var box = CSGBox3D.new()
		box.size = p[0]; box.position = p[1]; box.material = p[2]
		add_child(box)

	var eye = OmniLight3D.new()
	eye.position = Vector3(0, 1.4, 0); eye.light_color = pc
	eye.light_energy = 1.5; eye.omni_range = 3.0; add_child(eye)

	_build_hp3_bar()

func _build_hp3_bar() -> void:
	var root = Node3D.new(); root.position = Vector3(0, 1.72, 0); add_child(root)

	var bg_m = StandardMaterial3D.new()
	bg_m.albedo_color = Color(0.10, 0.04, 0.04, 0.90)
	bg_m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bg_m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	bg_m.billboard_keep_scale = true
	bg_m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var bg = MeshInstance3D.new()
	var bgq = QuadMesh.new(); bgq.size = Vector2(0.70, 0.10)
	bg.mesh = bgq; bg.set_surface_override_material(0, bg_m); root.add_child(bg)

	var fill_m = StandardMaterial3D.new()
	fill_m.albedo_color = Config.PLAYER_COLORS[player_index % Config.PLAYER_COLORS.size()]
	fill_m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fill_m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	fill_m.billboard_keep_scale = true
	_hp3_fill_q  = QuadMesh.new(); _hp3_fill_q.size = Vector2(0.66, 0.06)
	_hp3_fill_mi = MeshInstance3D.new()
	_hp3_fill_mi.mesh = _hp3_fill_q; _hp3_fill_mi.set_surface_override_material(0, fill_m)
	_hp3_fill_mi.position = Vector3(0, 0, 0.001); root.add_child(_hp3_fill_mi)

	_hp3_label = Label3D.new()
	_hp3_label.text = "100 HP"; _hp3_label.font_size = 18
	_hp3_label.modulate = Color(1,1,1,1); _hp3_label.outline_size = 6
	_hp3_label.outline_modulate = Color(0,0,0,1)
	_hp3_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_hp3_label.position = Vector3(0, 0.10, 0); root.add_child(_hp3_label)

func _update_hp3_bar() -> void:
	if _hp3_fill_mi == null: return
	var h     = game_manager.hp.get(peer_id, Config.MAX_HP)
	var ratio = float(h) / float(Config.MAX_HP)
	var fw    = 0.66
	_hp3_fill_q.size.x      = fw * ratio
	_hp3_fill_mi.position.x = -(fw - fw * ratio) / 2.0
	var m = _hp3_fill_mi.get_surface_override_material(0) as StandardMaterial3D
	if m:
		if   ratio > 0.60: m.albedo_color = Config.PLAYER_COLORS[player_index % Config.PLAYER_COLORS.size()]
		elif ratio > 0.30: m.albedo_color = Color(0.92, 0.50, 0.08)
		else:              m.albedo_color = Color(0.95, 0.80, 0.05)
	if _hp3_label: _hp3_label.text = "%d HP" % h

# ── Walkability ───────────────────────────────────────────────────────────────
func _is_walkable(pos: Vector3) -> bool:
	var cs = Config.CELL_SIZE; var r = player_radius; var grid = game_manager.grid
	for cz in range(int(floor((pos.z - r) / cs)), int(floor((pos.z + r) / cs)) + 1):
		for cx in range(int(floor((pos.x - r) / cs)), int(floor((pos.x + r) / cs)) + 1):
			if cx < 0 or cx >= grid[0].size() or cz < 0 or cz >= grid.size(): return false
			if grid[cz][cx] != 1: continue
			var clx = clamp(pos.x, cx*cs, (cx+1)*cs)
			var clz = clamp(pos.z, cz*cs, (cz+1)*cs)
			if (pos.x-clx)*(pos.x-clx) + (pos.z-clz)*(pos.z-clz) < r*r: return false

	# Player-player collision: block movement if too close to another body
	var combined_sq = (player_radius * 2.0) * (player_radius * 2.0)
	for other in get_tree().get_nodes_in_group("players"):
		if other == self or not is_instance_valid(other): continue
		# Skip players currently respawning (they are teleporting, not blocking)
		var other_pid = other.get("peer_id")
		if other_pid != null and game_manager.respawning.get(other_pid, false): continue
		var dx = pos.x - other.position.x
		var dz = pos.z - other.position.z
		if dx * dx + dz * dz < combined_sq: return false

	return true

# ── Utility ──────────────────────────────────────────────────────────────────
func _teleport_to(cell: Array) -> void:
	position = game_manager.grid_to_world(cell); current_grid_pos = cell.duplicate()

func get_grid_position() -> Array:
	# Compute from actual world position so remote players show correctly on the minimap.
	# current_grid_pos is still kept as a cached value for local-player trap detection.
	if game_manager != null:
		return game_manager.world_to_grid(position)
	return current_grid_pos

func set_blind_overlay(overlay: ColorRect) -> void:
	_blind_overlay = overlay

# ── Viewmodel ─────────────────────────────────────────────────────────────────
func _build_viewmodel() -> void:
	_viewmodel_root = Node3D.new()
	# Bottom-right of view, angled slightly inward
	_viewmodel_root.position        = Vector3(0.24, -0.20, -0.38)
	_viewmodel_root.rotation_degrees = Vector3(0.0, -10.0, 0.0)
	camera_node.add_child(_viewmodel_root)

	var grey = StandardMaterial3D.new()
	grey.albedo_color = Color(0.28, 0.31, 0.36)
	grey.metallic = 0.85; grey.roughness = 0.22

	var dark = StandardMaterial3D.new()
	dark.albedo_color = Color(0.15, 0.17, 0.20)
	dark.metallic = 0.90; dark.roughness = 0.18

	var red_mat = StandardMaterial3D.new()
	red_mat.albedo_color = Color(0.85, 0.05, 0.05)
	red_mat.emission_enabled = true
	red_mat.emission = Color(1.0, 0.08, 0.08)
	red_mat.emission_energy_multiplier = 2.5

	# Frame / lower receiver
	_vm_box(Vector3(0.068, 0.052, 0.220), Vector3( 0.000,  0.000,  0.000), grey)
	# Slide (upper, slightly narrower and taller)
	_vm_box(Vector3(0.050, 0.040, 0.195), Vector3( 0.000,  0.046, -0.008), dark)
	# Barrel extension past slide
	_vm_box(Vector3(0.024, 0.024, 0.085), Vector3( 0.000,  0.026, -0.148), dark)
	# Grip
	_vm_box(Vector3(0.056, 0.108, 0.052), Vector3( 0.003, -0.078,  0.062), grey)
	# Trigger guard
	_vm_box(Vector3(0.010, 0.006, 0.050), Vector3( 0.000, -0.025,  0.008), dark)
	# Red laser sight on left flank
	_vm_box(Vector3(0.018, 0.020, 0.034), Vector3(-0.044, -0.005, -0.055), red_mat)

func _vm_box(size: Vector3, pos: Vector3, mat: StandardMaterial3D) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.set_surface_override_material(0, mat)
	mi.position = pos
	_viewmodel_root.add_child(mi)

func _update_viewmodel(delta: float) -> void:
	if _viewmodel_root == null: return

	# Idle breath sway
	_vm_sway_time += delta
	var idle_y := sin(_vm_sway_time * 1.15) * 0.0025
	var idle_x := sin(_vm_sway_time * 0.70) * 0.0015

	# Recoil kick — gun slides back then returns
	_vm_recoil = max(0.0, _vm_recoil - delta * 9.0)
	var recoil_z   :=  _vm_recoil * 0.055
	var recoil_rot := -_vm_recoil * 6.0   # muzzle lifts on fire

	_viewmodel_root.position = Vector3(
		0.24  + idle_x,
		-0.20 + idle_y,
		-0.38 + recoil_z
	)
	_viewmodel_root.rotation_degrees = Vector3(recoil_rot, -10.0, 0.0)
