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
# Higher = snappier/more responsive look, lower = smoother but laggier.
# ~25 drains a spike over ~3-4 physics frames while staying responsive.
const LOOK_SMOOTH_RATE := 25.0
# Touch only: hard cap on how fast the view may turn (rad/s). A finger swipe can
# buffer a large yaw delta and a mobile-web frame hitch can otherwise dump it all
# in one physics step, snapping the view mid-turn — which feels chaotic when also
# moving. Bounding the per-frame turn keeps it smooth. Generous enough that normal
# swipes are unaffected. Desktop mouse is left uncapped (its deltas are tiny).
const TOUCH_MAX_LOOK_RATE := 13.0
# Largest buffered look delta we keep; anything beyond ~half a turn is a spurious
# burst and is discarded so it can't accumulate into a runaway spin.
const MAX_PENDING_YAW := PI

# ── Camera ───────────────────────────────────────────────────────────────────
var camera_node: Camera3D

# ── Trap inventory (3 slots) ──────────────────────────────────────────────────
var trap_inventory: Array = [-1, -1, -1]
var active_trap_slot: int = 0
var held_trap: int:                   # read alias used by UI / place code
	get: return trap_inventory[active_trap_slot]
var _pickup_cooldown: float = 0.0

# ── Trap throw aiming (desktop: hold RMB to aim a lobbed arc, release to throw) ─
# A ballistic preview arc + landing ring let the player pick exactly where the
# trap lands, instead of the old fixed one-cell-ahead drop. Local/visual only —
# the arc and marker exist on this client and are never networked.
var _aiming_trap:      bool           = false
var _traj_line:        MeshInstance3D = null   # ImmediateMesh arc preview
var _traj_im:          ImmediateMesh  = null
var _traj_marker:      MeshInstance3D = null   # landing-spot ring on the floor
var _traj_target_cell: Array          = [0, 0]
const THROW_SPEED     := 11.0   # initial throw velocity (m/s) along the aim ray
const THROW_GRAVITY   := 17.0   # arc gravity (game-y, snappier than 9.8)
const THROW_DT        := 0.03   # arc integration step (s)
const THROW_MAX_STEPS := 70     # ~2.1 s max flight before giving up
var _traj_target_pos: Vector3   = Vector3.ZERO   # exact arc-landing world position

# ── Gun system (2 slots) ─────────────────────────────────────────────────────
var _gun_cooldown: float = 0.0
var gun_inventory:      Array = [-1, -1, -1]   # gun type per slot (-1 = empty)
var gun_ammo_inventory: Array = [0,  0,  0 ]   # ammo per slot
var active_gun_slot: int = 0
var _fire_held: bool = false   # true while LMB / touch fire is held

var gun_type: int:   # alias for the active slot's type
	get: return gun_inventory[active_gun_slot]
	set(v): gun_inventory[active_gun_slot] = v

var gun_ammo: int:   # alias for the active slot's ammo
	get: return gun_ammo_inventory[active_gun_slot]
	set(v): gun_ammo_inventory[active_gun_slot] = v

const GUN_RANGE := 28.0

# ── Blind overlay ────────────────────────────────────────────────────────────
var _blind_overlay: ColorRect

# ── Death / respawn animation ─────────────────────────────────────────────────
var _death_overlay:    ColorRect = null
var _replay_banner:    Label     = null
var _letterbox_top:    ColorRect = null
var _letterbox_bot:    ColorRect = null
var _prev_respawning:  bool      = false
var _respawn_drop_t:   float     = -1.0   # -1 = inactive; 0..1 = falling
var _respawn_y_from:   float     = 0.0
var _respawn_y_to:     float     = 0.0
const RESPAWN_DROP_HEIGHT    := 9.0
const RESPAWN_DROP_DURATION  := 1.4

# ── Death replay (top-down killcam + opponent POV) ───────────────────────────
const REPLAY_SECONDS         := 5.0   # phase 1: player POV top-down length
const OPPONENT_VIEW_SECONDS  := 3.0   # phase 2: live opponent first-person length
var _replay_buf_pos: Array = []        # ring buffer of recent positions (Vector3)
var _replay_buf_yaw: Array = []        # ring buffer of recent yaw (float)
var _replaying:       bool  = false
var _replay_t:        float = 0.0     # raw seconds elapsed in current replay
var _replay_phase:    int   = 1       # 1 = player POV, 2 = opponent POV
var _replay_path_pos: Array = []       # snapshot played back on death
var _replay_path_yaw: Array = []
var _replay_cam:      Camera3D = null
var _replay_avatar:   Node3D   = null
var _killer_node:     Node3D   = null  # live reference to the opponent who killed us
var _opponent_view_banner: Label = null

# ── Current grid pos ─────────────────────────────────────────────────────────
var current_grid_pos: Array = [0, 0]

# ── Footstep audio ────────────────────────────────────────────────────────────
var _footstep_timer:   float = 0.0
const FOOTSTEP_INTERVAL := 0.42   # seconds between steps
const SPRINT_SPEED_MULT := 1.7    # velocity multiplier while sprinting
const DOUBLE_TAP_WINDOW := 0.35   # seconds within which a second forward press triggers sprint

# ── Touch input (left joystick = strafe/move, relative to facing) ─────────────
var touch_move_x: float = 0.0   # strafe: -1 (left)  .. +1 (right)
var touch_move_y: float = 0.0   # drive:  -1 (back)  .. +1 (forward)

# ── Sprint state ───────────────────────────────────────────────────────────────
var _sprinting:        bool  = false
var _fwd_tap_t:        float = -1.0   # time (s) of last forward press, -1 = none
var _fwd_was_active:   bool  = false  # forward was active last frame (for edge detect)

# ── Multiplayer ───────────────────────────────────────────────────────────────
var is_local: bool = true

# Interpolation targets — remote players lerp toward these each physics frame
# instead of snapping to the received position.  Avoids the teleporting/jitter
# caused by WebSocket relay latency (~25-75 ms one-way on the live server).
var _net_pos_target: Vector3 = Vector3.ZERO
var _net_yaw_target: float   = 0.0

# True on phones/tablets — pointer input is owned by UIManager's on-screen pads,
# so we ignore (emulated) mouse events here to avoid double-turning the camera.
var _is_touch: bool = false

# Remote-body HP bar (only built when is_local == false)
var _hp3_fill_mi:      MeshInstance3D = null
var _hp3_fill_q:       QuadMesh       = null
var _hp3_label:        Label3D        = null
var _remote_body_root: Node3D         = null   # parent of CSG body parts — hidden when dead
var _remote_gun_mi:    MeshInstance3D = null   # gun mesh shown when opponent is armed
var _last_synced_gun_type: int        = -2     # -2 = never synced (sentinel)

# ── Viewmodel (first-person gun) ─────────────────────────────────────────────
var _viewmodel_root: Node3D = null
var _vm_sway_time:   float  = 0.0
var _vm_recoil:      float  = 0.0

# ── Jump ─────────────────────────────────────────────────────────────────────
var _jump_vel: float = 0.0
const JUMP_SPEED   := 7.0    # peak height ≈ 1.75 m — clears 0.9 m fence and lands on 0.75 m crates
const JUMP_GRAVITY := 14.0

# ── Debug overlay (toggle with F3; on by default so it shows on mobile) ────────
var _dbg_label:       Label = null
var _dbg_yaw_step:    float = 0.0   # yaw applied this physics frame (rad)
var _dbg_last_yaw:    float = 0.0
var _dbg_slides:      int   = 0     # slide-collision count from last move_and_slide
var _dbg_real_speed:  float = 0.0   # actual speed after sliding
var _dbg_worst_ft:    float = 0.0   # worst frame time in current 1s window (ms)
var _dbg_shown_worst: float = 0.0
var _dbg_window:      float = 1.0

# ── Backward-compat alias (robot.gd / old callers) ───────────────────────────
var robot_ref: Node3D  # unused in N-player but kept so existing robot.gd compiles

# ────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	add_to_group("players")
	game_manager = get_parent().get_node("GameManager")
	is_local     = is_multiplayer_authority()   # true in SP (no peer) or on authority peer
	_is_touch    = UIManager._is_mobile_device()

	var col = CollisionShape3D.new()
	var cap = CapsuleShape3D.new()
	cap.radius = player_radius; cap.height = 1.8
	cap.margin = 0.04   # wider depenetration margin → more forgiving wall sliding
	col.shape  = cap
	add_child(col)

	var spawn_cell = game_manager.get_spawn_for_index(player_index)

	if is_local:
		# Free-floating physics movement (zero gravity, no floor) — let the engine
		# slide us smoothly along wall colliders instead of grid axis-separation.
		motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
		wall_min_slide_angle = deg_to_rad(15.0)   # ignore near-perpendicular ghost normals
		camera_node = Camera3D.new()
		camera_node.position = Vector3(0, 1.6, 0)
		add_child(camera_node)
		_build_viewmodel()
		_build_debug_overlay()
		_teleport_to(spawn_cell)
		# Death / replay overlay layer (above all gameplay layers)
		var death_layer := CanvasLayer.new()
		death_layer.layer = 110
		add_child(death_layer)
		# Full-screen black — only used for the quick cut-fade into the respawn drop.
		_death_overlay = ColorRect.new()
		_death_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
		_death_overlay.color = Color(0, 0, 0, 0)
		_death_overlay.visible = false
		_death_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		death_layer.add_child(_death_overlay)
		# Cinematic letterbox bars + REPLAY banner, shown during the death killcam.
		_letterbox_top = ColorRect.new()
		_letterbox_top.color = Color(0, 0, 0, 0.9)
		_letterbox_top.anchor_right = 1.0
		_letterbox_top.anchor_bottom = 0.0
		_letterbox_top.offset_bottom = 64
		_letterbox_top.visible = false
		_letterbox_top.mouse_filter = Control.MOUSE_FILTER_IGNORE
		death_layer.add_child(_letterbox_top)
		_letterbox_bot = ColorRect.new()
		_letterbox_bot.color = Color(0, 0, 0, 0.9)
		_letterbox_bot.anchor_top = 1.0; _letterbox_bot.anchor_right = 1.0; _letterbox_bot.anchor_bottom = 1.0
		_letterbox_bot.offset_top = -64
		_letterbox_bot.visible = false
		_letterbox_bot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		death_layer.add_child(_letterbox_bot)
		_replay_banner = Label.new()
		_replay_banner.text = "▶  REPLAY"
		_replay_banner.add_theme_font_size_override("font_size", 28)
		_replay_banner.add_theme_color_override("font_color", Color(1.0, 0.35, 0.30))
		_replay_banner.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
		_replay_banner.add_theme_constant_override("shadow_offset_x", 2)
		_replay_banner.add_theme_constant_override("shadow_offset_y", 2)
		_replay_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_replay_banner.anchor_right = 1.0
		_replay_banner.offset_top = 78
		_replay_banner.visible = false
		_replay_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
		death_layer.add_child(_replay_banner)
		_opponent_view_banner = Label.new()
		_opponent_view_banner.text = "OPPONENT VIEW"
		_opponent_view_banner.add_theme_font_size_override("font_size", 28)
		_opponent_view_banner.add_theme_color_override("font_color", Color(1.0, 0.80, 0.20))
		_opponent_view_banner.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
		_opponent_view_banner.add_theme_constant_override("shadow_offset_x", 2)
		_opponent_view_banner.add_theme_constant_override("shadow_offset_y", 2)
		_opponent_view_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_opponent_view_banner.anchor_right = 1.0
		_opponent_view_banner.offset_top = 78
		_opponent_view_banner.visible = false
		_opponent_view_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
		death_layer.add_child(_opponent_view_banner)
		if not OS.has_feature("web"):
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		_build_remote_body()
		_teleport_to(spawn_cell)
		_net_pos_target = position
		_net_yaw_target = yaw

# ────────────────────────────────────────────────────────────────────────────
func _physics_process(delta: float) -> void:
	if not game_manager.is_playing:
		if _replaying:
			_end_death_replay()   # match ended mid-respawn — restore the normal camera
		return

	if not is_local:
		_update_hp3_bar()
		# Smooth the remote player toward the last received network position.
		# Distances > 2 m are respawns/teleports — snap so we don't glide across the map.
		var dist := (_net_pos_target - position).length()
		if dist > 2.0:
			position = _net_pos_target
			reset_physics_interpolation()
		else:
			position = position.lerp(_net_pos_target, minf(delta * 15.0, 1.0))
		yaw = lerp_angle(yaw, _net_yaw_target, minf(delta * 12.0, 1.0))
		rotation.y = yaw
		return

	_pickup_cooldown = max(0.0, _pickup_cooldown - delta)
	_gun_cooldown    = max(0.0, _gun_cooldown    - delta)

	# Smooth look-turn: apply a fraction of the accumulated delta each physics
	# frame and carry the rest, so a single large (coalesced) touch drag near a
	# wall decays over a few frames instead of snapping the view in one step.
	# Frame-rate aware so the feel is the same at any FPS.
	# Discard absurdly large buffered deltas (spurious touch bursts) so they can't
	# accumulate into a runaway spin, then apply a bounded, frame-hitch-safe step.
	_pending_yaw_delta = clampf(_pending_yaw_delta, -MAX_PENDING_YAW, MAX_PENDING_YAW)
	var look_step := compute_look_step(_pending_yaw_delta, delta, _is_touch)
	yaw += look_step
	_pending_yaw_delta -= look_step
	if absf(_pending_yaw_delta) < 0.0001:
		_pending_yaw_delta = 0.0   # snap-drain the tail to avoid lingering drift

	# ── Respawn state machine ────────────────────────────────────────────────
	# On death: play a top-down replay of the last moments (instead of a fade).
	# When the respawn timer ends: cut back, teleport to the spawn point high in
	# the air, and drop down to the ground.
	var is_respawning: bool = game_manager.respawning.get(peer_id, false)
	if is_respawning and not _prev_respawning:
		# Just died → start the killcam replay (stay where we died, frozen).
		_respawn_drop_t = -1.0
		_start_death_replay()
	elif not is_respawning and _prev_respawning:
		# Just respawned → stop replay, teleport to spawn, lift up, drop + fade in.
		_end_death_replay()
		_teleport_to(game_manager.get_spawn_for_index(player_index))
		_respawn_y_to   = position.y
		_respawn_y_from = position.y + RESPAWN_DROP_HEIGHT
		position.y      = _respawn_y_from
		reset_physics_interpolation()   # don't smear the camera from ground → sky
		_respawn_drop_t = 0.0
		velocity        = Vector3.ZERO
		if _death_overlay:
			# Black at the cut, then fade back to gameplay over the start of the drop.
			_death_overlay.visible = true
			_death_overlay.color = Color(0, 0, 0, 1.0)
			var tw_in := create_tween()
			tw_in.tween_property(_death_overlay, "color", Color(0, 0, 0, 0), 0.5)
			tw_in.tween_callback(func(): if _death_overlay: _death_overlay.visible = false)
	_prev_respawning = is_respawning
	if is_respawning:
		if _replaying:
			_update_death_replay(delta)
		return

	# While dropping in from the sky, the player free-falls (no steering) — animate
	# Y here and skip the normal movement block below.
	if _respawn_drop_t >= 0.0:
		_respawn_drop_t = minf(_respawn_drop_t + delta / RESPAWN_DROP_DURATION, 1.0)
		var drop_e: float = _respawn_drop_t * _respawn_drop_t   # ease-in: accelerating fall
		position.y = lerpf(_respawn_y_from, _respawn_y_to, drop_e)
		velocity   = Vector3.ZERO
		if _respawn_drop_t >= 1.0:
			_respawn_drop_t = -1.0
			position.y = _respawn_y_to
		current_grid_pos = game_manager.world_to_grid(position)
		_update_viewmodel(delta)
		if multiplayer.has_multiplayer_peer():
			_net_pos.rpc(position, yaw, pitch)
		return

	var is_confused = game_manager.has_effect(peer_id, "confusion")
	# Turning is keyboard (Q/E) + right-screen look-drag only — never the joystick.
	var turn_dir = 0.0
	if Input.is_key_pressed(KEY_Q): turn_dir -= rotation_speed * delta
	if Input.is_key_pressed(KEY_E): turn_dir += rotation_speed * delta
	if is_confused: turn_dir = -turn_dir
	yaw += turn_dir
	rotation.y = yaw

	# Debug: how much yaw was applied this single physics frame (deg shown later).
	_dbg_yaw_step = wrapf(yaw - _dbg_last_yaw, -PI, PI)
	_dbg_last_yaw = yaw

	var can_move = not (game_manager.has_effect(peer_id, "glue") or
						game_manager.has_effect(peer_id, "cage") or
						game_manager.has_effect(peer_id, "electric"))

	if can_move:
		var speed_mult = 0.25 if game_manager.has_effect(peer_id, "freeze") else 1.0

		# Build a move vector relative to facing: Y = forward/back, X = strafe.
		var drive  := 0.0
		var strafe := 0.0
		if Input.is_action_pressed("ui_up")   or Input.is_key_pressed(KEY_W): drive  += 1.0
		if Input.is_action_pressed("ui_down") or Input.is_key_pressed(KEY_S): drive  -= 1.0
		if Input.is_key_pressed(KEY_LEFT):  strafe -= 1.0
		if Input.is_key_pressed(KEY_RIGHT): strafe += 1.0
		drive  += touch_move_y
		strafe += touch_move_x
		if is_confused:
			drive  = -drive
			strafe = -strafe

		# Sprint: double-tap forward (W/↑ key or joystick push).
		# Detect the rising edge of forward input; second tap within DOUBLE_TAP_WINDOW
		# activates sprint.  Sprint stops as soon as forward is released.
		var fwd_active: bool = drive > 0.3
		if fwd_active and not _fwd_was_active:
			var now: float = Time.get_ticks_msec() * 0.001
			if _fwd_tap_t >= 0.0 and (now - _fwd_tap_t) < DOUBLE_TAP_WINDOW:
				_sprinting  = true
				_fwd_tap_t  = -1.0
			else:
				_fwd_tap_t = now
		if not fwd_active:
			_sprinting = false
		_fwd_was_active = fwd_active

		var sprint_mult: float = SPRINT_SPEED_MULT if (_sprinting and drive > 0.0) else 1.0

		var forward := Vector3(-sin(yaw), 0.0, -cos(yaw))
		var right   := Vector3( cos(yaw), 0.0, -sin(yaw))
		var dir     := forward * drive + right * strafe
		if dir.length() > 1.0:
			dir = dir.normalized()

		# Physics-driven movement: wall sliding (XZ) + jump arc gravity (Y).
		# Gravity runs here so the player falls correctly when walking off a prop.
		if _jump_vel != 0.0 or position.y > 0.01:
			_jump_vel -= JUMP_GRAVITY * delta
		velocity = dir * move_speed * speed_mult * sprint_mult
		velocity.y = _jump_vel
		move_and_slide()
		_jump_vel = velocity.y   # zeroed by move_and_slide when landing on a prop surface
		if position.y < 0.0:    # floor snap — no StaticBody3D at y = 0
			position.y = 0.0
			if _jump_vel < 0.0: _jump_vel = 0.0
		_dbg_slides     = get_slide_collision_count()
		_dbg_real_speed = velocity.length()

		if dir.length_squared() > 0.0001:
			# Footstep sound (faster cadence when sprinting)
			_footstep_timer -= delta
			if _footstep_timer <= 0.0:
				if sound_manager: sound_manager.play_footstep()
				_footstep_timer = FOOTSTEP_INTERVAL / (speed_mult * sprint_mult)
		else:
			_footstep_timer = 0.0   # reset so first step after pause is immediate

	current_grid_pos = game_manager.world_to_grid(position)
	_try_pickup()
	_record_replay_frame()

	if _blind_overlay:
		_blind_overlay.visible = game_manager.has_effect(peer_id, "blind")

	# Continuous fire: fire every cooldown cycle while button held
	if _fire_held and _gun_cooldown <= 0.0:
		_fire_gun()

	_update_viewmodel(delta)

	# Live trap-aim preview (RMB held): refresh the arc, or cancel if the trap is
	# gone / the round ended.
	if _aiming_trap:
		if not game_manager.is_playing or held_trap < 0:
			_cancel_trap_aim()
		else:
			_update_trap_aim()

	if multiplayer.has_multiplayer_peer():
		_net_pos.rpc(position, yaw, pitch)
		if gun_type != _last_synced_gun_type:
			_last_synced_gun_type = gun_type
			_net_gun_type.rpc(gun_type)

# Pure look-smoothing math (static so it can be unit-tested headless without a
# full Player node — see tests/test_look_smoothing.gd). Returns how much to add
# to `yaw` this frame given the buffered delta, the frame time, and whether the
# input came from touch.
static func compute_look_step(pending: float, delta: float, is_touch: bool) -> float:
	var p  := clampf(pending, -MAX_PENDING_YAW, MAX_PENDING_YAW)
	var dt := minf(delta, 1.0 / 30.0)          # ignore frame hitches when blending
	var step := p * (1.0 - exp(-LOOK_SMOOTH_RATE * dt))
	if is_touch:
		# Bound the per-frame turn so a buffered swipe can never snap the view.
		step = clampf(step, -TOUCH_MAX_LOOK_RATE * dt, TOUCH_MAX_LOOK_RATE * dt)
	return step

# ────────────────────────────────────────────────────────────────────────────
func _input(event: InputEvent) -> void:
	if not is_local:
		return

	# Mouse-look / click-to-fire only on non-touch devices. On phones the joystick
	# and look pads (UIManager) handle pointing; processing the emulated mouse here
	# would let joystick drags also turn the camera and make movement go haywire.
	if not _is_touch:
		if event is InputEventMouseButton:
			match event.button_index:
				MOUSE_BUTTON_LEFT:
					if event.pressed:
						if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
							if gun_type >= 0:
								_fire_held = true
								_fire_gun()
							else:
								_try_place()   # throw trap when unarmed
						else:
							Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
					else:
						_fire_held = false
				MOUSE_BUTTON_RIGHT:
					# Hold to aim a lobbed trap throw (shows the arc), release to throw.
					if event.pressed:
						if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
							_begin_trap_aim()
					else:
						_release_trap_aim()
				MOUSE_BUTTON_WHEEL_UP:
					if event.pressed: _cycle_slot(-1)
				MOUSE_BUTTON_WHEEL_DOWN:
					if event.pressed: _cycle_slot(1)
				_:
					if event.pressed: Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

		if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			_pending_yaw_delta -= event.relative.x * mouse_sensitivity
			pitch -= event.relative.y * mouse_sensitivity
			pitch = clamp(pitch, -PI / 3.0, PI / 3.0)
			camera_node.rotation.x = pitch

	# Space = jump. Use is_action so it works regardless of OS key repeat settings.
	if event.is_action_pressed("ui_accept") and not event.is_echo():
		do_jump()
		get_viewport().set_input_as_handled()
		return

	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_N:      _try_place()
			KEY_C:      _cycle_trap_slot()    # cycle trap
			KEY_V:      _cycle_gun_slot()     # cycle gun  (also: B)
			KEY_TAB:    _fire_gun()
			KEY_B:      _cycle_gun_slot()     # kept for backward compat
			KEY_1:      active_trap_slot = 0
			KEY_2:      active_trap_slot = 1
			KEY_3:      active_trap_slot = 2
			KEY_ESCAPE:
				if OS.has_feature("web"): Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
				else: get_tree().quit()
			KEY_R: get_tree().reload_current_scene()
			KEY_F3:
				if _dbg_label: _dbg_label.visible = not _dbg_label.visible

# ── Slot cycling ─────────────────────────────────────────────────────────────
func _cycle_slot(dir: int) -> void:
	active_trap_slot = (active_trap_slot + dir + 3) % 3

func _cycle_trap_slot() -> void:
	for i in 3:
		var s := (active_trap_slot + i + 1) % 3
		if trap_inventory[s] >= 0:
			active_trap_slot = s
			return
	# all empty — still advance so player sees the slot change
	active_trap_slot = (active_trap_slot + 1) % 3

func _cycle_gun_slot() -> void:
	active_gun_slot = (active_gun_slot + 1) % 3
	_rebuild_viewmodel()

func do_jump() -> void:
	if not is_local or not game_manager.is_playing: return
	if _jump_vel == 0.0 and position.y <= 0.05:
		_jump_vel = JUMP_SPEED

# ── Gun ───────────────────────────────────────────────────────────────────────
func _fire_gun() -> void:
	if gun_type < 0 or _gun_cooldown > 0.0 or not game_manager.is_playing:
		return
	# Check ammo
	if gun_ammo == 0:
		return

	var cooldown = Config.GUN_COOLDOWN[gun_type]
	_gun_cooldown = cooldown
	_vm_recoil    = 1.0
	if sound_manager: sound_manager.play_gun_fire()

	# Fire straight along the camera (crosshair) ray so the shot lands exactly where
	# the player is aiming. Spawning from the eye — nudged forward past the body —
	# keeps the bullet path identical to the aim ray at every distance.
	var cam_origin = camera_node.global_position
	var forward    = -camera_node.global_transform.basis.z
	var spawn_pos  = cam_origin + forward * 0.6

	var flash = OmniLight3D.new()
	flash.light_color = Color(1.0, 0.88, 0.45); flash.light_energy = 12.0; flash.omni_range = 5.0
	flash.position = spawn_pos; get_parent().add_child(flash)
	get_tree().create_timer(0.07).timeout.connect(func():
		if is_instance_valid(flash): flash.queue_free())

	_spawn_bullet_local(spawn_pos, forward)

	if multiplayer.has_multiplayer_peer():
		game_manager.net_spawn_bullet.rpc(spawn_pos, forward, peer_id, player_index, gun_type)

	# Consume ammo (unlimited ammo stays at -1)
	if gun_ammo > 0:
		gun_ammo -= 1
		if gun_ammo == 0:
			gun_inventory[active_gun_slot] = -1
			# Auto-switch to the next occupied slot so the player keeps firing
			for i in 3:
				var s := (active_gun_slot + i + 1) % 3
				if gun_inventory[s] >= 0:
					active_gun_slot = s
					break
			_rebuild_viewmodel()

func _spawn_bullet_local(pos: Vector3, dir: Vector3) -> void:
	var b = Bullet.new()
	b.owner_peer_id = peer_id
	b.owner_index   = player_index
	b.direction     = dir
	b.local_only    = false
	b.game_manager  = game_manager
	b.sound_manager = sound_manager
	b.position      = pos
	b.damage        = Config.GUN_DAMAGE[gun_type]
	get_parent().add_child(b)

# ── Trap placement ────────────────────────────────────────────────────────────
# Quick throw: drop the trap one cell ahead (keyboard N / unarmed LMB).
func _try_place() -> void:
	if trap_inventory[active_trap_slot] < 0 or trap_manager == null:
		return
	var forward    = Vector3(-sin(yaw), 0.0, -cos(yaw))
	var throw_pos  = position + forward * Config.CELL_SIZE
	var throw_cell = game_manager.world_to_grid(throw_pos)
	_place_trap_at(throw_cell)

# Place the active trap at a specific grid cell (used by both the quick throw and
# the aimed RMB throw). Falls back to the player's own cell if the target isn't a
# floor cell. Consumes the trap and auto-advances to the next occupied slot.
func _place_trap_at(target_cell: Array) -> void:
	var trap_type: int = trap_inventory[active_trap_slot]
	if trap_type < 0 or trap_manager == null:
		return
	if not game_manager.is_floor(target_cell[0], target_cell[1]):
		target_cell = current_grid_pos
	if multiplayer.has_multiplayer_peer():
		trap_manager.net_place_trap.rpc(target_cell, peer_id, trap_type)
	else:
		trap_manager.place_trap(target_cell, peer_id, trap_type)
	trap_inventory[active_trap_slot] = -1
	# Auto-advance to next occupied slot so the next throw is ready
	for i in 3:
		var s := (active_trap_slot + i + 1) % 3
		if trap_inventory[s] >= 0:
			active_trap_slot = s; break

# ── Aimed trap throw (RMB) ────────────────────────────────────────────────────
func _begin_trap_aim() -> void:
	if game_manager == null or not game_manager.is_playing: return
	if held_trap < 0: return            # nothing to throw
	_aiming_trap = true
	_ensure_traj_nodes()
	_update_trap_aim()

func _release_trap_aim() -> void:
	if not _aiming_trap: return
	_aiming_trap = false
	_hide_traj_nodes()
	_place_trap_at(_traj_target_cell)

# Abort aiming WITHOUT throwing (game ended / trap lost mid-aim).
func _cancel_trap_aim() -> void:
	_aiming_trap = false
	_hide_traj_nodes()

func _ensure_traj_nodes() -> void:
	if _traj_line == null:
		_traj_im = ImmediateMesh.new()
		_traj_line = MeshInstance3D.new()
		_traj_line.mesh = _traj_im
		_traj_line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var lm := StandardMaterial3D.new()
		lm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		lm.vertex_color_use_as_albedo = true
		lm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		lm.no_depth_test = true
		_traj_line.material_override = lm
		get_parent().add_child(_traj_line)
	if _traj_marker == null:
		var ring := TorusMesh.new()
		ring.inner_radius = 0.32
		ring.outer_radius = 0.58
		_traj_marker = MeshInstance3D.new()
		_traj_marker.mesh = ring
		_traj_marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var mm := StandardMaterial3D.new()
		mm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_traj_marker.material_override = mm
		get_parent().add_child(_traj_marker)
	_traj_line.visible = true
	_traj_marker.visible = true

func _hide_traj_nodes() -> void:
	if _traj_line:   _traj_line.visible = false
	if _traj_marker: _traj_marker.visible = false

# Rebuild the preview arc + landing ring from the current aim each physics frame.
func _update_trap_aim() -> void:
	if camera_node == null or game_manager == null or _traj_im == null: return
	var arc := _compute_throw_arc()
	var pts: PackedVector3Array = arc["points"]
	_traj_target_cell = arc["cell"]
	_traj_target_pos  = arc.get("landing_pos", game_manager.grid_to_world(_traj_target_cell))
	var col: Color = Config.TRAP_COLORS.get(held_trap, Color(1.0, 0.9, 0.2))

	_traj_im.clear_surfaces()
	if pts.size() >= 2:
		_traj_im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
		for i in pts.size():
			var fade := 1.0 - float(i) / float(pts.size())
			_traj_im.surface_set_color(Color(col.r, col.g, col.b, 0.40 + 0.60 * fade))
			_traj_im.surface_add_vertex(pts[i])
		_traj_im.surface_end()

	_traj_marker.position = Vector3(_traj_target_pos.x, 0.06, _traj_target_pos.z)
	var mat := _traj_marker.material_override as StandardMaterial3D
	if mat: mat.albedo_color = Color(col.r, col.g, col.b, 0.85)

# Integrate a simple ballistic arc from the eye along the aim ray.
# Walls do not block the arc — traps can be thrown over or behind walls.
# Returns {points, cell: landing grid cell, landing_pos: exact world Vector3}.
func _compute_throw_arc() -> Dictionary:
	var origin: Vector3 = camera_node.global_position
	var fwd: Vector3 = -camera_node.global_transform.basis.z
	var v0: Vector3 = fwd * THROW_SPEED
	var pts := PackedVector3Array()
	pts.append(origin)
	var landing: Array = current_grid_pos
	var landing_pos := origin
	var last_floor: Array = current_grid_pos
	var last_floor_pos := origin
	var p := origin
	var t := 0.0
	for i in THROW_MAX_STEPS:
		t += THROW_DT
		p = origin + v0 * t + Vector3(0.0, -0.5 * THROW_GRAVITY * t * t, 0.0)
		var cell := game_manager.world_to_grid(p)
		if game_manager.is_floor(cell[0], cell[1]) and p.y > 0.06:
			last_floor     = cell
			last_floor_pos = Vector3(p.x, 0.06, p.z)
		if p.y <= 0.06:
			p.y = 0.06
			pts.append(p)
			if game_manager.is_floor(cell[0], cell[1]):
				landing     = cell
				landing_pos = p
			else:
				landing     = last_floor
				landing_pos = last_floor_pos
			return {"points": pts, "cell": landing, "landing_pos": landing_pos}
		pts.append(p)
	landing = game_manager.world_to_grid(p)
	if not game_manager.is_floor(landing[0], landing[1]):
		landing     = last_floor
		landing_pos = last_floor_pos
	else:
		landing_pos = Vector3(p.x, 0.06, p.z)
	return {"points": pts, "cell": landing, "landing_pos": landing_pos}

# ── Auto pick-up ─────────────────────────────────────────────────────────────
func _try_pickup() -> void:
	if _pickup_cooldown > 0.0 or trap_manager == null:
		return
	var pickup_dist = Config.CELL_SIZE * 0.75

	# Try to pick up gun first (prioritize guns)
	var best_gun_box = null
	var best_gun_dist = pickup_dist
	for box in get_tree().get_nodes_in_group("gun_boxes"):
		var d = position.distance_to(box.position)
		if d < best_gun_dist: best_gun_dist = d; best_gun_box = box

	if best_gun_box != null:
		# Find a free gun slot; if all filled, overwrite the active slot
		var fill_slot := -1
		for s in 3:
			if gun_inventory[s] < 0: fill_slot = s; break
		if fill_slot < 0: fill_slot = active_gun_slot
		gun_inventory[fill_slot]      = best_gun_box.gun_type
		gun_ammo_inventory[fill_slot] = Config.GUN_AMMO_MAX[best_gun_box.gun_type]
		active_gun_slot = fill_slot
		best_gun_box.respawn_box()
		_rebuild_viewmodel()
		_pickup_cooldown = 0.5
		if sound_manager: sound_manager.play_pickup()
		return

	# Try to pick up trap (if no gun nearby)
	var slot := -1
	for i in 3:
		if trap_inventory[i] < 0: slot = i; break
	if slot < 0: return
	var best_box = null
	var best_dist = pickup_dist
	for box in get_tree().get_nodes_in_group("trap_boxes"):
		var d = position.distance_to(box.position)
		if d < best_dist: best_dist = d; best_box = box
	if best_box != null:
		trap_inventory[slot] = best_box.trap_type
		best_box.respawn_box()
		_pickup_cooldown = 0.5
		if sound_manager: sound_manager.play_pickup()

# ── Multiplayer position sync ─────────────────────────────────────────────────
@rpc("authority", "unreliable")
func _net_pos(pos: Vector3, y: float, p: float = 0.0) -> void:
	if is_multiplayer_authority(): return
	_net_pos_target  = pos
	_net_yaw_target  = y
	pitch            = p                                  # used in death-replay opponent view
	current_grid_pos = game_manager.world_to_grid(pos)   # authoritative grid cell (not interpolated)

# Syncs which gun type (if any) the local player is currently holding.
# Received by all remote peers so they can show/hide the gun on the remote body.
@rpc("authority", "unreliable")
func _net_gun_type(gtype: int) -> void:
	if is_multiplayer_authority(): return
	if _remote_gun_mi:
		_remote_gun_mi.visible = (gtype >= 0)

# ── Remote body ───────────────────────────────────────────────────────────────
func _build_player_mesh_body(parent: Node3D) -> void:
	var pc = Config.PLAYER_COLORS[player_index % Config.PLAYER_COLORS.size()]
	var bm = StandardMaterial3D.new()
	bm.albedo_color = pc.darkened(0.35); bm.metallic = 0.8; bm.roughness = 0.3
	var am = StandardMaterial3D.new()
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
		parent.add_child(box)

func _build_remote_body() -> void:
	_remote_body_root = Node3D.new()
	add_child(_remote_body_root)

	var pc = Config.PLAYER_COLORS[player_index % Config.PLAYER_COLORS.size()]
	_build_player_mesh_body(_remote_body_root)

	# Gun held in right hand — hidden until opponent picks one up.
	var gm = StandardMaterial3D.new()
	gm.albedo_color = Color(0.12, 0.12, 0.12); gm.metallic = 0.9; gm.roughness = 0.2
	_remote_gun_mi = MeshInstance3D.new()
	var gun_box := BoxMesh.new(); gun_box.size = Vector3(0.06, 0.06, 0.30)
	_remote_gun_mi.mesh = gun_box
	_remote_gun_mi.set_surface_override_material(0, gm)
	_remote_gun_mi.position  = Vector3(0.30, 0.72, 0.22)
	_remote_gun_mi.visible   = false
	_remote_body_root.add_child(_remote_gun_mi)

	var eye = OmniLight3D.new()
	eye.position = Vector3(0, 1.4, 0); eye.light_color = pc
	eye.light_energy = 1.5; eye.omni_range = 3.0
	_remote_body_root.add_child(eye)

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
	var is_dead: bool = game_manager.respawning.get(peer_id, false)
	if _remote_body_root:
		_remote_body_root.visible = not is_dead
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

# ── Utility ──────────────────────────────────────────────────────────────────
func _teleport_to(cell: Array) -> void:
	position = game_manager.grid_to_world(cell); current_grid_pos = cell.duplicate()
	# With physics interpolation on, a direct position set would smear the camera
	# across the map for one frame — reset so spawns/respawns snap cleanly.
	reset_physics_interpolation()

func get_grid_position() -> Array:
	# Compute from actual world position so remote players show correctly on the minimap.
	# current_grid_pos is still kept as a cached value for local-player trap detection.
	if game_manager != null:
		return game_manager.world_to_grid(position)
	return current_grid_pos

func set_blind_overlay(overlay: ColorRect) -> void:
	_blind_overlay = overlay

# ── Death replay (top-down killcam) ───────────────────────────────────────────
# Record one position+yaw sample per physics frame into a rolling buffer that
# keeps the last REPLAY_SECONDS of movement.
func _record_replay_frame() -> void:
	_replay_buf_pos.append(position)
	_replay_buf_yaw.append(yaw)
	var cap: int = int(REPLAY_SECONDS * float(Engine.physics_ticks_per_second))
	while _replay_buf_pos.size() > cap:
		_replay_buf_pos.pop_front()
		_replay_buf_yaw.pop_front()

func _start_death_replay() -> void:
	if _replay_buf_pos.size() < 2:
		# Not enough footage (died right after spawn) → just black out the screen.
		if _death_overlay:
			_death_overlay.visible = true
			_death_overlay.color = Color(0, 0, 0, 0.85)
		return
	_replay_path_pos = _replay_buf_pos.duplicate()
	_replay_path_yaw = _replay_buf_yaw.duplicate()
	_replaying    = true
	_replay_t     = 0.0
	_replay_phase = 1
	_killer_node  = null

	if _viewmodel_root: _viewmodel_root.visible = false

	# Visible stand-in for the (otherwise body-less, first-person) local player.
	_replay_avatar = _make_replay_avatar()
	get_parent().add_child(_replay_avatar)

	# Dedicated top-down camera that overrides the first-person view.
	_replay_cam = Camera3D.new()
	get_parent().add_child(_replay_cam)
	_replay_cam.current = true

	if _letterbox_top: _letterbox_top.visible = true
	if _letterbox_bot: _letterbox_bot.visible = true
	if _replay_banner: _replay_banner.visible = true

func _update_death_replay(delta: float) -> void:
	if _replay_cam == null or not is_instance_valid(_replay_cam):
		return
	_replay_t += delta

	if _replay_phase == 1:
		# Phase 1 (first REPLAY_SECONDS): top-down replay of the player's last moments.
		var n: int = _replay_path_pos.size()
		if n >= 2 and _replay_avatar != null and is_instance_valid(_replay_avatar):
			var t_norm := minf(_replay_t / REPLAY_SECONDS, 1.0)
			var f: float    = t_norm * float(n - 1)
			var i: int      = int(f)
			var i2: int     = mini(i + 1, n - 1)
			var frac: float = f - float(i)
			var pos: Vector3 = (_replay_path_pos[i] as Vector3).lerp(_replay_path_pos[i2] as Vector3, frac)
			var yw: float    = lerp_angle(_replay_path_yaw[i] as float, _replay_path_yaw[i2] as float, frac)
			_replay_avatar.position   = pos
			_replay_avatar.rotation.y = yw
			_replay_cam.position = pos + Vector3(0.0, 3.8, 3.2)
			_replay_cam.look_at(pos + Vector3(0.0, 0.9, 0.0), Vector3.UP)
		if _replay_t >= REPLAY_SECONDS:
			_begin_opponent_view()

	elif _replay_phase == 2:
		# Phase 2 (next OPPONENT_VIEW_SECONDS): live first-person view from the killer.
		if _killer_node != null and is_instance_valid(_killer_node):
			var k: Player = _killer_node as Player
			_replay_cam.position = k.position + Vector3(0.0, 1.6, 0.0)
			# pitch is only known for the local player; remote opponents report 0 (not synced)
			_replay_cam.rotation = Vector3(k.pitch if k.is_local else 0.0, k.yaw, 0.0)

func _begin_opponent_view() -> void:
	if _replay_phase == 2:
		return   # guard: already switched
	# Find the opponent who killed us.
	var killer_pid: int = game_manager._last_damager.get(peer_id, -1)
	_killer_node = null
	if killer_pid >= 0 and killer_pid != peer_id:
		for p in get_tree().get_nodes_in_group("players"):
			if p is Player and (p as Player).peer_id == killer_pid:
				_killer_node = p as Player
				break
	if _killer_node == null:
		return   # self-kill or no killer found — hold the last phase-1 frame
	_replay_phase = 2
	if _replay_avatar != null and is_instance_valid(_replay_avatar):
		_replay_avatar.queue_free()
		_replay_avatar = null
	if _replay_banner:        _replay_banner.visible        = false
	if _opponent_view_banner: _opponent_view_banner.visible = true

func _end_death_replay() -> void:
	_replaying    = false
	_replay_phase = 1
	_killer_node  = null
	if is_instance_valid(_replay_cam):    _replay_cam.queue_free()
	if is_instance_valid(_replay_avatar): _replay_avatar.queue_free()
	_replay_cam    = null
	_replay_avatar = null
	if camera_node: camera_node.current = true
	if _viewmodel_root: _viewmodel_root.visible = (gun_type >= 0)
	if _letterbox_top:         _letterbox_top.visible         = false
	if _letterbox_bot:         _letterbox_bot.visible         = false
	if _replay_banner:         _replay_banner.visible         = false
	if _opponent_view_banner:  _opponent_view_banner.visible  = false
	_replay_path_pos.clear()
	_replay_path_yaw.clear()
	# Start recording fresh from the new spawn so a quick re-death never replays
	# across the teleport jump.
	_replay_buf_pos.clear()
	_replay_buf_yaw.clear()

func _make_replay_avatar() -> Node3D:
	var root := Node3D.new()
	_build_player_mesh_body(root)
	return root

# ── Viewmodel ─────────────────────────────────────────────────────────────────
func _build_viewmodel() -> void:
	_viewmodel_root = Node3D.new()
	_viewmodel_root.position         = Vector3(0.20, -0.26, -0.42)
	_viewmodel_root.rotation_degrees = Vector3(-4.0, -6.0, 0.0)
	_viewmodel_root.visible          = false   # hidden until a gun is picked up
	camera_node.add_child(_viewmodel_root)

func _rebuild_viewmodel() -> void:
	if _viewmodel_root == null: return
	for c in _viewmodel_root.get_children():
		c.queue_free()
	_viewmodel_root.visible = (gun_type >= 0)
	if   gun_type == Config.GunType.PISTOL:     _build_vm_pistol()
	elif gun_type == Config.GunType.SHOTGUN:    _build_vm_shotgun()
	elif gun_type == Config.GunType.MACHINEGUN: _build_vm_machinegun()
	elif gun_type == Config.GunType.STOVE:      _build_vm_stove()

func _build_vm_pistol() -> void:
	var white = StandardMaterial3D.new()
	white.albedo_color = Color(0.93, 0.93, 0.95); white.metallic = 0.30; white.roughness = 0.35
	var black = StandardMaterial3D.new()
	black.albedo_color = Color(0.09, 0.09, 0.11); black.metallic = 0.55; black.roughness = 0.30
	var skin = StandardMaterial3D.new()
	skin.albedo_color = Color(0.95, 0.78, 0.62); skin.metallic = 0.0; skin.roughness = 0.85

	_vm_box(Vector3(0.070, 0.056, 0.240), Vector3( 0.000,  0.000,  0.000), white)
	_vm_box(Vector3(0.054, 0.046, 0.210), Vector3( 0.000,  0.050, -0.006), black)
	_vm_box(Vector3(0.050, 0.040, 0.050), Vector3( 0.000,  0.030, -0.150), white)
	_vm_box(Vector3(0.022, 0.022, 0.040), Vector3( 0.000,  0.030, -0.190), black)
	_vm_box(Vector3(0.030, 0.014, 0.022), Vector3( 0.000,  0.078,  0.090), black)
	var grip = _vm_box(Vector3(0.060, 0.140, 0.060), Vector3( 0.004, -0.096,  0.080), white)
	grip.rotation_degrees = Vector3(18.0, 0.0, 0.0)
	_vm_box(Vector3(0.012, 0.008, 0.058), Vector3( 0.000, -0.030,  0.014), black)
	var hand = _vm_box(Vector3(0.090, 0.110, 0.090), Vector3( 0.010, -0.110,  0.090), skin)
	hand.rotation_degrees = Vector3(18.0, 0.0, 0.0)
	_vm_box(Vector3(0.024, 0.030, 0.080), Vector3(-0.040, -0.060,  0.060), skin)
	var arm = _vm_box(Vector3(0.130, 0.130, 0.300), Vector3( 0.060, -0.230,  0.230), skin)
	arm.rotation_degrees = Vector3(28.0, -10.0, 6.0)

func _build_vm_shotgun() -> void:
	var black = StandardMaterial3D.new()
	black.albedo_color = Color(0.09, 0.09, 0.11); black.metallic = 0.55; black.roughness = 0.30
	var brown_wood = StandardMaterial3D.new()
	brown_wood.albedo_color = Color(0.45, 0.28, 0.12); brown_wood.metallic = 0.0; brown_wood.roughness = 0.90
	var skin = StandardMaterial3D.new()
	skin.albedo_color = Color(0.95, 0.78, 0.62); skin.metallic = 0.0; skin.roughness = 0.85

	# Barrel (wide, long)
	_vm_box(Vector3(0.040, 0.040, 0.380), Vector3( 0.000,  0.040, -0.200), black)
	# Pump slide below barrel
	_vm_box(Vector3(0.060, 0.030, 0.100), Vector3( 0.000, -0.010, -0.150), brown_wood)
	# Receiver body
	_vm_box(Vector3(0.060, 0.060, 0.120), Vector3( 0.000,  0.010,  0.020), black)
	# Stock
	var stock = _vm_box(Vector3(0.055, 0.095, 0.200), Vector3( 0.005, -0.055,  0.110), brown_wood)
	stock.rotation_degrees = Vector3(6.0, 0.0, 0.0)
	# Stock butt
	_vm_box(Vector3(0.065, 0.115, 0.035), Vector3( 0.008, -0.080,  0.195), brown_wood)
	# Trigger guard
	_vm_box(Vector3(0.012, 0.008, 0.055), Vector3( 0.000, -0.032,  0.020), black)
	# Trigger hand
	var hand = _vm_box(Vector3(0.085, 0.105, 0.085), Vector3( 0.012, -0.105,  0.055), skin)
	hand.rotation_degrees = Vector3(14.0, 0.0, 0.0)
	# Pump forehand
	var pump_hand = _vm_box(Vector3(0.080, 0.075, 0.095), Vector3(-0.008, -0.040, -0.150), skin)
	pump_hand.rotation_degrees = Vector3(0.0, 0.0, 0.0)
	# Forearm
	var arm = _vm_box(Vector3(0.130, 0.130, 0.290), Vector3( 0.058, -0.220,  0.220), skin)
	arm.rotation_degrees = Vector3(26.0, -10.0, 6.0)

func _build_vm_machinegun() -> void:
	var black = StandardMaterial3D.new()
	black.albedo_color = Color(0.09, 0.09, 0.11); black.metallic = 0.55; black.roughness = 0.30
	var dark_metal = StandardMaterial3D.new()
	dark_metal.albedo_color = Color(0.18, 0.18, 0.20); dark_metal.metallic = 0.70; dark_metal.roughness = 0.30
	var skin = StandardMaterial3D.new()
	skin.albedo_color = Color(0.95, 0.78, 0.62); skin.metallic = 0.0; skin.roughness = 0.85

	# Boxy receiver
	_vm_box(Vector3(0.080, 0.080, 0.300), Vector3( 0.000,  0.000,  0.000), dark_metal)
	# Long barrel
	_vm_box(Vector3(0.026, 0.026, 0.200), Vector3( 0.000,  0.027, -0.250), black)
	# Muzzle brake
	_vm_box(Vector3(0.042, 0.042, 0.022), Vector3( 0.000,  0.027, -0.360), black)
	# Carry handle / sight rail on top
	_vm_box(Vector3(0.020, 0.032, 0.180), Vector3( 0.000,  0.058, -0.040), dark_metal)
	# Box magazine (hangs below)
	_vm_box(Vector3(0.055, 0.160, 0.045), Vector3( 0.000, -0.120,  0.040), dark_metal)
	# Pistol grip
	var grip = _vm_box(Vector3(0.055, 0.130, 0.055), Vector3( 0.004, -0.100,  0.090), dark_metal)
	grip.rotation_degrees = Vector3(16.0, 0.0, 0.0)
	# Trigger guard
	_vm_box(Vector3(0.012, 0.008, 0.058), Vector3( 0.000, -0.030,  0.020), black)
	# Trigger hand
	var hand = _vm_box(Vector3(0.090, 0.110, 0.090), Vector3( 0.010, -0.108,  0.090), skin)
	hand.rotation_degrees = Vector3(16.0, 0.0, 0.0)
	_vm_box(Vector3(0.024, 0.030, 0.080), Vector3(-0.040, -0.058,  0.060), skin)
	# Forearm
	var arm = _vm_box(Vector3(0.130, 0.130, 0.300), Vector3( 0.060, -0.230,  0.230), skin)
	arm.rotation_degrees = Vector3(28.0, -10.0, 6.0)

func _build_vm_stove() -> void:
	var metal = StandardMaterial3D.new()
	metal.albedo_color = Color(0.55, 0.56, 0.60); metal.metallic = 0.70; metal.roughness = 0.30
	var red_tank = StandardMaterial3D.new()
	red_tank.albedo_color = Color(0.75, 0.15, 0.05); red_tank.metallic = 0.40; red_tank.roughness = 0.45
	var dark = StandardMaterial3D.new()
	dark.albedo_color = Color(0.14, 0.14, 0.16); dark.metallic = 0.55; dark.roughness = 0.40
	var skin = StandardMaterial3D.new()
	skin.albedo_color = Color(0.95, 0.78, 0.62); skin.metallic = 0.0; skin.roughness = 0.85
	# Gas cylinder / tank (rear)
	var tank = _vm_box(Vector3(0.060, 0.130, 0.060), Vector3(0.005, -0.010, 0.130), red_tank)
	tank.rotation_degrees = Vector3(8.0, 0.0, 0.0)
	# Valve / connector
	_vm_box(Vector3(0.028, 0.022, 0.036), Vector3(0.000, -0.010, 0.072), dark)
	# Main body / pump housing
	_vm_box(Vector3(0.085, 0.070, 0.180), Vector3(0.000,  0.010, -0.050), metal)
	# Pressure gauge (small bump on top)
	_vm_box(Vector3(0.024, 0.024, 0.024), Vector3(0.000,  0.050, -0.010), dark)
	# Hose / nozzle tube
	_vm_box(Vector3(0.022, 0.022, 0.160), Vector3(0.000,  0.010, -0.220), dark)
	# Nozzle flare tip
	_vm_box(Vector3(0.036, 0.036, 0.024), Vector3(0.000,  0.010, -0.308), dark)
	# Grip
	var grip = _vm_box(Vector3(0.058, 0.120, 0.055), Vector3(0.004, -0.090, 0.060), dark)
	grip.rotation_degrees = Vector3(14.0, 0.0, 0.0)
	# Trigger guard
	_vm_box(Vector3(0.012, 0.008, 0.050), Vector3(0.000, -0.028, 0.012), dark)
	# Hand
	var hand = _vm_box(Vector3(0.088, 0.108, 0.088), Vector3(0.010, -0.108, 0.060), skin)
	hand.rotation_degrees = Vector3(14.0, 0.0, 0.0)
	# Forearm
	var arm = _vm_box(Vector3(0.130, 0.130, 0.300), Vector3(0.058, -0.225, 0.230), skin)
	arm.rotation_degrees = Vector3(26.0, -10.0, 6.0)

# ── Debug overlay ─────────────────────────────────────────────────────────────
func _build_debug_overlay() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 128
	add_child(layer)
	_dbg_label = Label.new()
	_dbg_label.position = Vector2(12, 12)
	_dbg_label.add_theme_font_size_override("font_size", 18)
	_dbg_label.add_theme_color_override("font_color", Color(0.4, 1.0, 0.4))
	_dbg_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_dbg_label.add_theme_constant_override("outline_size", 6)
	_dbg_label.visible = false
	layer.add_child(_dbg_label)

func _process(delta: float) -> void:
	if _dbg_label == null or not _dbg_label.visible:
		return
	var ft := delta * 1000.0
	if ft > _dbg_worst_ft: _dbg_worst_ft = ft
	_dbg_window -= delta
	if _dbg_window <= 0.0:
		_dbg_shown_worst = _dbg_worst_ft
		_dbg_worst_ft = 0.0
		_dbg_window = 1.0
	_dbg_label.text = "FPS %d   dt %.1fms   worst %.1fms\nturn/frame %.2f deg   slides %d   spd %.2f\npos %.1f, %.1f" % [
		Engine.get_frames_per_second(), ft, _dbg_shown_worst,
		rad_to_deg(_dbg_yaw_step), _dbg_slides, _dbg_real_speed,
		position.x, position.z]

func _vm_box(size: Vector3, pos: Vector3, mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.set_surface_override_material(0, mat)
	mi.position = pos
	_viewmodel_root.add_child(mi)
	return mi

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
		0.20  + idle_x,
		-0.26 + idle_y,
		-0.42 + recoil_z
	)
	_viewmodel_root.rotation_degrees = Vector3(-4.0 + recoil_rot, -6.0, 0.0)
