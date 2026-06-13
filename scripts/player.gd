extends CharacterBody3D

class_name Player

# ── References ───────────────────────────────────────────────────────────────
var game_manager: GameManager
var trap_manager: Node    # TrapManager (set by main.gd)

# ── Movement ─────────────────────────────────────────────────────────────────
var move_speed: float         = Config.PLAYER_SPEED
var rotation_speed: float     = Config.PLAYER_ROTATION_SPEED
var mouse_sensitivity: float  = Config.MOUSE_SENSITIVITY
var player_radius: float      = Config.PLAYER_RADIUS
var yaw: float                = 0.0
var pitch: float              = 0.0
var _pending_yaw_delta: float = 0.0

# ── Camera ───────────────────────────────────────────────────────────────────
var camera_node: Camera3D

# ── Trap inventory ────────────────────────────────────────────────────────────
var held_trap: int = -1   # -1 = none; otherwise Config.TrapType value
var _pickup_cooldown: float = 0.0

# ── Gun ───────────────────────────────────────────────────────────────────────
var robot_ref: Node3D
var sound_manager: SoundManager
var _gun_cooldown: float = 0.0
const GUN_RANGE    := 28.0
const GUN_COOLDOWN := 1.5

# ── Blind overlay ────────────────────────────────────────────────────────────
var _blind_overlay: ColorRect  # full-screen white panel

# ── Current grid pos ─────────────────────────────────────────────────────────
var current_grid_pos: Array = [0, 0]

# ── Touch input ───────────────────────────────────────────────────────────────
var touch_forward: bool  = false
var touch_backward: bool = false
var _touch_turn_id: int   = -1
var _touch_turn_prev: Vector2 = Vector2.ZERO

# ────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	game_manager = get_parent().get_node("GameManager")

	# Collision capsule
	var col = CollisionShape3D.new()
	var cap = CapsuleShape3D.new()
	cap.radius = player_radius
	cap.height = 1.8
	col.shape  = cap
	add_child(col)

	# Camera
	camera_node = Camera3D.new()
	camera_node.position = Vector3(0, 1.6, 0)
	add_child(camera_node)

	# Respawn to start
	_teleport_to(game_manager.player_start)

	if not OS.has_feature("web"):
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

# ────────────────────────────────────────────────────────────────────────────
func _physics_process(delta: float) -> void:
	if not game_manager.is_playing:
		return

	# Handle respawn
	if game_manager.player_respawning:
		_teleport_to(game_manager.player_start)
		return

	_pickup_cooldown = max(0.0, _pickup_cooldown - delta)
	_gun_cooldown    = max(0.0, _gun_cooldown    - delta)

	# Apply yaw (buffered from input events)
	yaw += _pending_yaw_delta
	_pending_yaw_delta = 0.0

	# ── Turn keys ────────────────────────────────────────────────────────────
	var is_confused = game_manager.has_effect("player", "confusion")
	var turn_dir = 0.0
	if Input.is_key_pressed(KEY_Q):
		turn_dir -= rotation_speed * delta
	if Input.is_key_pressed(KEY_E):
		turn_dir += rotation_speed * delta
	if is_confused:
		turn_dir = -turn_dir
	yaw += turn_dir
	rotation.y = yaw

	# ── Move ─────────────────────────────────────────────────────────────────
	var can_move = not (game_manager.has_effect("player", "glue") or
	                    game_manager.has_effect("player", "cage") or
	                    game_manager.has_effect("player", "electric"))

	if can_move:
		var speed_mult = 1.0
		if game_manager.has_effect("player", "freeze"):
			speed_mult = 0.25
		var effective_speed = move_speed * speed_mult

		var move = 0.0
		if Input.is_action_pressed("ui_up") or Input.is_key_pressed(KEY_W) or touch_forward:
			move += 1.0
		if Input.is_action_pressed("ui_down") or Input.is_key_pressed(KEY_S) or touch_backward:
			move -= 1.0
		if is_confused:
			move = -move

		if move != 0.0:
			var forward = Vector3(-sin(yaw), 0.0, -cos(yaw))
			var movement = forward * move * effective_speed * delta
			var new_pos = position + movement
			if _is_walkable(new_pos):
				position = new_pos
			else:
				var sx = position + Vector3(movement.x, 0, 0)
				var sz = position + Vector3(0, 0, movement.z)
				if _is_walkable(sx):
					position = sx
				elif _is_walkable(sz):
					position = sz

	current_grid_pos = game_manager.world_to_grid(position)

	# Auto-pickup: walking over a glowing box grabs its trap
	_try_pickup()

	# ── Blind overlay ─────────────────────────────────────────────────────────
	if _blind_overlay:
		_blind_overlay.visible = game_manager.has_effect("player", "blind")

# ────────────────────────────────────────────────────────────────────────────
func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
				_fire_gun()
			else:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_pending_yaw_delta -= event.relative.x * mouse_sensitivity
		pitch -= event.relative.y * mouse_sensitivity
		pitch = clamp(pitch, -PI / 3.0, PI / 3.0)
		camera_node.rotation.x = pitch

	# Touch turning
	if event is InputEventScreenTouch:
		var half_w = get_viewport().get_visible_rect().size.x / 2.0
		if event.position.x < half_w:
			if event.pressed:
				_touch_turn_id   = event.index
				_touch_turn_prev = event.position
			elif event.index == _touch_turn_id:
				_touch_turn_id = -1

	if event is InputEventScreenDrag and event.index == _touch_turn_id:
		var half_w = get_viewport().get_visible_rect().size.x / 2.0
		if event.position.x < half_w:
			var dx = (event.position.x - _touch_turn_prev.x) * mouse_sensitivity * 2.0
			_touch_turn_prev = event.position
			_pending_yaw_delta -= dx

	# ── Trap interactions ─────────────────────────────────────────────────────
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_SPACE:
				_try_place()
			KEY_TAB:
				_fire_gun()
			KEY_ESCAPE:
				if OS.has_feature("web"):
					Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
				else:
					get_tree().quit()
			KEY_R:
				get_tree().reload_current_scene()

# ── Gun ───────────────────────────────────────────────────────────────────────
func _fire_gun() -> void:
	if _gun_cooldown > 0.0 or not game_manager.is_playing:
		return
	_gun_cooldown = GUN_COOLDOWN

	if sound_manager:
		sound_manager.play_gun_fire()

	# Muzzle flash at chest height
	var spawn_pos = position + Vector3(0, 0.9, 0)
	var flash = OmniLight3D.new()
	flash.light_color  = Color(1.0, 0.88, 0.45)
	flash.light_energy = 12.0
	flash.omni_range   = 5.0
	flash.position     = spawn_pos
	get_parent().add_child(flash)
	get_tree().create_timer(0.07).timeout.connect(func():
		if is_instance_valid(flash): flash.queue_free()
	)

	# Spawn bullet at body centre so it travels at target height
	var forward = Vector3(-sin(yaw), 0.0, -cos(yaw))
	var b = Bullet.new()
	b.owner_tag     = "player"
	b.direction     = forward
	b.game_manager  = game_manager
	b.robot_ref     = robot_ref
	b.player_ref    = self
	b.sound_manager = sound_manager
	b.position      = spawn_pos
	get_parent().add_child(b)

# ── Auto pick-up: grab the trap from a box the player walks over ─────────────
func _try_pickup() -> void:
	if held_trap >= 0:
		return  # already carrying a trap
	if _pickup_cooldown > 0.0:
		return
	if trap_manager == null:
		return

	var best_box = null
	var best_dist = Config.CELL_SIZE * 0.75  # must walk over the box
	for box in get_tree().get_nodes_in_group("trap_boxes"):
		var d = position.distance_to(box.position)
		if d < best_dist:
			best_dist = d
			best_box  = box

	if best_box != null:
		held_trap = best_box.trap_type
		best_box.respawn_box()
		_pickup_cooldown = 0.5
		if sound_manager:
			sound_manager.play_pickup()

# ── Place held trap at current position ──────────────────────────────────────
# -- Place held trap one cell in front of the player
func _try_place() -> void:
	if held_trap < 0 or trap_manager == null:
		return
	var forward    = Vector3(-sin(yaw), 0.0, -cos(yaw))
	var throw_pos  = position + forward * Config.CELL_SIZE
	var throw_cell = game_manager.world_to_grid(throw_pos)
	var target_cell = throw_cell if game_manager.is_floor(throw_cell[0], throw_cell[1]) \
	                             else current_grid_pos
	trap_manager.place_trap(target_cell, "player", held_trap)
	held_trap = -1


# ── Walkability check (same circle-vs-cell as original) ─────────────────────
func _is_walkable(pos: Vector3) -> bool:
	var cs = Config.CELL_SIZE
	var r  = player_radius
	var grid = game_manager.grid

	var min_cx = int(floor((pos.x - r) / cs))
	var max_cx = int(floor((pos.x + r) / cs))
	var min_cz = int(floor((pos.z - r) / cs))
	var max_cz = int(floor((pos.z + r) / cs))

	for cz in range(min_cz, max_cz + 1):
		for cx in range(min_cx, max_cx + 1):
			if cx < 0 or cx >= grid[0].size() or cz < 0 or cz >= grid.size():
				return false
			if grid[cz][cx] != 1:
				continue
			var closest_x = clamp(pos.x, cx * cs, (cx + 1) * cs)
			var closest_z = clamp(pos.z, cz * cs, (cz + 1) * cs)
			var dx = pos.x - closest_x
			var dz = pos.z - closest_z
			if dx * dx + dz * dz < r * r:
				return false
	return true

# ── Utility ──────────────────────────────────────────────────────────────────
func _teleport_to(cell: Array) -> void:
	position = game_manager.grid_to_world(cell)
	current_grid_pos = cell.duplicate()

func get_grid_position() -> Array:
	return current_grid_pos

## Called by UIManager to attach the blind overlay after Camera is ready
func set_blind_overlay(overlay: ColorRect) -> void:
	_blind_overlay = overlay
