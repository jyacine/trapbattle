extends CanvasLayer

class_name UIManager

# ── References ────────────────────────────────────────────────────────────────
var game_manager: GameManager
var player: Player
var robot: Node3D
var local_role: String = "player"  # which role the local player has

# ── HUD labels ────────────────────────────────────────────────────────────────
var _kills_label: Label
var _lives_label: Label
var _trap_label:  Label
var _gun_label:   Label
var _hint_label:  Label
var _effects_label: Label

# ── HP bars ───────────────────────────────────────────────────────────────────
var _hp_bg:    ColorRect
var _hp_fill:  ColorRect
var _hp_label: Label

# ── Minimap ───────────────────────────────────────────────────────────────────
var _mm_rect: TextureRect
var _mm_image: Image
var _mm_texture: ImageTexture
const MM_CELL = 4
const MM_MARGIN = 8

# ── Overlay ───────────────────────────────────────────────────────────────────
var _overlay_panel: Panel
var _overlay_label: Label
var _retry_btn: Button

# ── Blind flash ───────────────────────────────────────────────────────────────
var _blind_overlay: ColorRect

# ── Mobile buttons ────────────────────────────────────────────────────────────
var _btn_fwd: Button
var _btn_bwd: Button
var _btn_place: Button
var _btn_fire: Button

# ── Crosshair ─────────────────────────────────────────────────────────────────
var _crosshair_parts: Array = []

# ────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	var root     = get_parent()
	game_manager = root.get_node("GameManager")
	player       = root.get_node("Player")
	robot        = root.get_node("Robot")

	_build_hud()
	_build_hp_bar()
	_build_crosshair()
	_build_minimap()
	_build_overlay()
	_build_blind_overlay()
	_build_mobile_buttons()

	# Give player a reference to the blind overlay
	player.set_blind_overlay(_blind_overlay)

# ── Process ───────────────────────────────────────────────────────────────────
func _process(_delta: float) -> void:
	_update_hud()
	_update_minimap()
	_update_crosshair()

	if not game_manager.is_playing:
		_show_overlay()

# ── HUD ───────────────────────────────────────────────────────────────────────
func _build_hud() -> void:
	# Kills: "You: 0 | Robot: 0"
	_kills_label = _make_label("", 10, 10, 28, Color.YELLOW)
	add_child(_kills_label)

	# Lives
	_lives_label = _make_label("", 10, 46, 22, Color(1.0, 0.5, 0.5))
	add_child(_lives_label)

	# Held trap
	_trap_label = _make_label("", 10, 76, 20, Color.WHITE)
	add_child(_trap_label)

	# Gun status
	_gun_label = _make_label("", 10, 104, 18, Color(0.3, 1.0, 0.3))
	add_child(_gun_label)

	# Active effects (bottom-left)
	_effects_label = _make_label("", 10, 0, 18, Color(0.8, 1.0, 0.8))
	_effects_label.anchor_top    = 1.0
	_effects_label.anchor_bottom = 1.0
	_effects_label.offset_top    = -80
	_effects_label.offset_bottom = -10
	add_child(_effects_label)

	# Hint (bottom right)
	_hint_label = _make_label(
		"W/S=Move  Q/E=Turn  Walk over box=Pick up  SPACE=Throw Trap  LMB=Fire Gun  R=Restart",
		0, 0, 14, Color(0.8, 0.8, 0.8)
	)
	_hint_label.anchor_left   = 0.0
	_hint_label.anchor_right  = 1.0
	_hint_label.anchor_top    = 1.0
	_hint_label.anchor_bottom = 1.0
	_hint_label.offset_top    = -26
	_hint_label.offset_bottom = 0
	_hint_label.offset_left   = 10
	add_child(_hint_label)

func _build_hp_bar() -> void:
	# Background
	_hp_bg = ColorRect.new()
	_hp_bg.color        = Color(0.15, 0.05, 0.05, 0.88)
	_hp_bg.anchor_left  = 0.5; _hp_bg.anchor_right  = 0.5
	_hp_bg.anchor_top   = 0.0; _hp_bg.anchor_bottom = 0.0
	_hp_bg.offset_left  = -155; _hp_bg.offset_right  = 155
	_hp_bg.offset_top   = 8;    _hp_bg.offset_bottom = 38
	add_child(_hp_bg)

	# Fill
	_hp_fill = ColorRect.new()
	_hp_fill.color = Color(0.15, 0.85, 0.20)
	_hp_fill.position = Vector2(3, 3)
	_hp_fill.size     = Vector2(300, 24)
	_hp_bg.add_child(_hp_fill)

	# Label on top of bar
	_hp_label = Label.new()
	_hp_label.text = "HP 100"
	_hp_label.add_theme_font_size_override("font_size", 15)
	_hp_label.add_theme_color_override("font_color", Color.WHITE)
	_hp_label.add_theme_color_override("font_shadow_color", Color(0,0,0,0.9))
	_hp_label.add_theme_constant_override("shadow_offset_x", 1)
	_hp_label.add_theme_constant_override("shadow_offset_y", 1)
	_hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hp_label.position = Vector2(0, 4)
	_hp_label.size     = Vector2(306, 24)
	_hp_bg.add_child(_hp_label)

func _build_crosshair() -> void:
	var root = Control.new()
	root.anchor_left   = 0.5; root.anchor_right  = 0.5
	root.anchor_top    = 0.5; root.anchor_bottom = 0.5
	root.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	# Four lines radiating from centre with a small gap
	const GAP  := 5
	const LEN  := 11
	const TICK := 2

	var rects: Array[Dictionary] = [
		{ "pos": Vector2(-(GAP + LEN), -TICK / 2), "size": Vector2(LEN, TICK) },   # left
		{ "pos": Vector2(GAP,          -TICK / 2), "size": Vector2(LEN, TICK) },   # right
		{ "pos": Vector2(-TICK / 2, -(GAP + LEN)), "size": Vector2(TICK, LEN) },   # up
		{ "pos": Vector2(-TICK / 2,  GAP),         "size": Vector2(TICK, LEN) },   # down
		{ "pos": Vector2(-2, -2),                  "size": Vector2(4, 4) },         # dot
	]

	for r in rects:
		var cr = ColorRect.new()
		cr.position     = r["pos"]
		cr.size         = r["size"]
		cr.color        = Color(1, 1, 1, 0.88)
		cr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		root.add_child(cr)
		_crosshair_parts.append(cr)

func _update_crosshair() -> void:
	if _crosshair_parts.is_empty():
		return

	# Aim-on-target: same cone the bullet uses (dot > 0.65, range < 28)
	var on_target := false
	if game_manager.is_playing and not game_manager.robot_respawning:
		var fwd     = Vector3(-sin(player.yaw), 0.0, -cos(player.yaw))
		var to_rob  = robot.position - player.position
		var dist    = to_rob.length()
		var horiz   = Vector3(to_rob.x, 0.0, to_rob.z).normalized()
		on_target   = dist < 28.0 and fwd.dot(horiz) > 0.65

	var col: Color
	if not game_manager.is_playing:
		col = Color(1, 1, 1, 0.0)   # hide on game-over screen
	elif on_target:
		col = Color(1.0, 0.15, 0.15, 1.0)   # red: locked on
	elif player._gun_cooldown > 0.0:
		col = Color(0.85, 0.55, 0.10, 0.85) # orange: reloading
	else:
		col = Color(1.0, 1.0, 1.0, 0.88)    # white: ready

	for part in _crosshair_parts:
		part.color = col

func _update_hud() -> void:
	_kills_label.text = "Kills — You: %d  |  Robot: %d  (first to %d wins)" % [
		game_manager.player_kills, game_manager.robot_kills, Config.KILLS_TO_WIN
	]

	_lives_label.text = "Lives — You: %s  |  Robot: %s" % [
		"♥ ".repeat(game_manager.player_lives).strip_edges(),
		"♥ ".repeat(game_manager.robot_lives).strip_edges(),
	]

	# HP bar
	var my_hp = game_manager.player_hp if local_role == "player" else game_manager.robot_hp
	var ratio = float(my_hp) / float(Config.MAX_HP)
	_hp_fill.size.x = 300.0 * ratio
	if ratio > 0.60:
		_hp_fill.color = Color(0.15, 0.85, 0.20)
	elif ratio > 0.30:
		_hp_fill.color = Color(0.92, 0.78, 0.08)
	else:
		_hp_fill.color = Color(0.90, 0.15, 0.12)
	_hp_label.text = "YOU  HP  %d / %d" % [my_hp, Config.MAX_HP]

	if player.held_trap >= 0:
		var trap_col = Config.TRAP_COLORS[player.held_trap]
		_trap_label.text = "Trap: [%s]  (SPACE to throw)" % Config.TRAP_NAMES[player.held_trap]
		_trap_label.add_theme_color_override("font_color", trap_col)
	else:
		_trap_label.text = "No trap  (walk over a glowing box to pick one up)"
		_trap_label.add_theme_color_override("font_color", Color.GRAY)

	if player._gun_cooldown > 0.0:
		_gun_label.text = "Gun: %.1fs" % player._gun_cooldown
		_gun_label.add_theme_color_override("font_color", Color(0.8, 0.5, 0.2))
	else:
		_gun_label.text = "Gun: READY  (LMB / TAB)"
		_gun_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3))

	# Active effects
	var fx_text = ""
	for eff in game_manager.player_effects.keys():
		var remaining = snappedf(game_manager.player_effects[eff], 0.1)
		fx_text += "  [%s %.1fs]" % [eff.to_upper(), remaining]
	_effects_label.text = fx_text if fx_text != "" else ""

# ── Minimap ───────────────────────────────────────────────────────────────────
func _build_minimap() -> void:
	var grid = game_manager.grid
	var w    = grid[0].size() * MM_CELL
	var h    = grid.size()    * MM_CELL

	_mm_image   = Image.create(w, h, false, Image.FORMAT_RGB8)
	_mm_texture = ImageTexture.create_from_image(_mm_image)

	_mm_rect          = TextureRect.new()
	_mm_rect.position = Vector2(MM_MARGIN, MM_MARGIN + 110)  # below HUD
	_mm_rect.size     = Vector2(w, h)
	_mm_rect.texture  = _mm_texture
	add_child(_mm_rect)

func _update_minimap() -> void:
	if _mm_image == null:
		return

	var grid = game_manager.grid
	var w    = _mm_image.get_width()
	var h    = _mm_image.get_height()

	# Maze
	for r in range(grid.size()):
		for c in range(grid[r].size()):
			var col = Color(0.65, 0.65, 0.65) if grid[r][c] == 0 else Color(0.1, 0.1, 0.1)
			for dy in range(MM_CELL):
				for dx in range(MM_CELL):
					var px = c * MM_CELL + dx
					var py = r * MM_CELL + dy
					if px < w and py < h:
						_mm_image.set_pixel(px, py, col)

	# Player (cyan)
	var pg = player.get_grid_position()
	_mm_dot(pg[0], pg[1], Color.CYAN, 3)

	# Robot (red)
	var rg = robot.get_grid_position()
	_mm_dot(rg[0], rg[1], Color.RED, 3)

	# Trap boxes (yellow)
	for box in get_tree().get_nodes_in_group("trap_boxes"):
		var bg = game_manager.world_to_grid(box.position)
		_mm_dot(bg[0], bg[1], Color.YELLOW, 2)

	_mm_texture = ImageTexture.create_from_image(_mm_image)
	_mm_rect.texture = _mm_texture

func _mm_dot(gx: int, gy: int, col: Color, radius: int) -> void:
	var w = _mm_image.get_width()
	var h = _mm_image.get_height()
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var px = gx * MM_CELL + MM_CELL / 2 + dx
			var py = gy * MM_CELL + MM_CELL / 2 + dy
			if px >= 0 and px < w and py >= 0 and py < h:
				_mm_image.set_pixel(px, py, col)

# ── Win/lose overlay ──────────────────────────────────────────────────────────
func _build_overlay() -> void:
	_overlay_panel = Panel.new()
	_overlay_panel.anchor_left   = 0.5
	_overlay_panel.anchor_top    = 0.5
	_overlay_panel.anchor_right  = 0.5
	_overlay_panel.anchor_bottom = 0.5
	_overlay_panel.offset_left   = -220
	_overlay_panel.offset_top    = -120
	_overlay_panel.offset_right  = 220
	_overlay_panel.offset_bottom = 140
	_overlay_panel.visible       = false
	var bg = StyleBoxFlat.new()
	bg.bg_color = Color(0, 0, 0, 0.82)
	_overlay_panel.add_theme_stylebox_override("panel", bg)
	add_child(_overlay_panel)

	_overlay_label = Label.new()
	_overlay_label.anchor_left   = 0.5
	_overlay_label.anchor_top    = 0.5
	_overlay_label.anchor_right  = 0.5
	_overlay_label.anchor_bottom = 0.5
	_overlay_label.offset_left   = -200
	_overlay_label.offset_top    = -100
	_overlay_label.offset_right  = 200
	_overlay_label.offset_bottom = -10
	_overlay_label.add_theme_font_size_override("font_size", 36)
	_overlay_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_overlay_label)

func _show_overlay() -> void:
	if _overlay_panel.visible:
		return
	_overlay_panel.visible = true

	if game_manager.winner == "player":
		_overlay_label.text = "YOU WIN!\n\n%d kills — %d lives left" % [
			game_manager.player_kills, game_manager.player_lives
		]
		_overlay_label.add_theme_color_override("font_color", Color.GREEN)
	else:
		_overlay_label.text = "ROBOT WINS!\n\nBetter luck next time…"
		_overlay_label.add_theme_color_override("font_color", Color.RED)

	if _retry_btn == null:
		_retry_btn = Button.new()
		_retry_btn.text          = "PLAY AGAIN"
		_retry_btn.anchor_left   = 0.5
		_retry_btn.anchor_top    = 0.5
		_retry_btn.anchor_right  = 0.5
		_retry_btn.anchor_bottom = 0.5
		_retry_btn.offset_left   = -70
		_retry_btn.offset_top    = 50
		_retry_btn.offset_right  = 70
		_retry_btn.offset_bottom = 100
		_retry_btn.add_theme_font_size_override("font_size", 24)
		_retry_btn.add_theme_color_override("font_color", Color.WHITE)
		_retry_btn.button_down.connect(func(): get_tree().reload_current_scene())
		add_child(_retry_btn)

# ── Blind overlay (full-screen white flash) ───────────────────────────────────
func _build_blind_overlay() -> void:
	_blind_overlay = ColorRect.new()
	_blind_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_blind_overlay.color   = Color(1.0, 1.0, 1.0, 0.92)
	_blind_overlay.visible = false
	add_child(_blind_overlay)

# ── Mobile buttons ────────────────────────────────────────────────────────────
func _build_mobile_buttons() -> void:
	var sz = 100
	var mg = 16

	_btn_fwd = _mk_btn("FWD", Color(0.2, 0.6, 1.0))
	_btn_fwd.anchor_left   = 1.0; _btn_fwd.anchor_right  = 1.0
	_btn_fwd.anchor_top    = 1.0; _btn_fwd.anchor_bottom = 1.0
	_btn_fwd.offset_left   = -(sz + mg); _btn_fwd.offset_right  = -mg
	_btn_fwd.offset_top    = -350;       _btn_fwd.offset_bottom = -250
	add_child(_btn_fwd)

	_btn_bwd = _mk_btn("BACK", Color(0.2, 0.6, 1.0))
	_btn_bwd.anchor_left   = 1.0; _btn_bwd.anchor_right  = 1.0
	_btn_bwd.anchor_top    = 1.0; _btn_bwd.anchor_bottom = 1.0
	_btn_bwd.offset_left   = -(sz + mg); _btn_bwd.offset_right  = -mg
	_btn_bwd.offset_top    = -230;       _btn_bwd.offset_bottom = -130
	add_child(_btn_bwd)

	_btn_place = _mk_btn("THROW\nTRAP", Color(1.0, 0.3, 0.3))
	_btn_place.anchor_left   = 0.0; _btn_place.anchor_right  = 0.0
	_btn_place.anchor_top    = 1.0; _btn_place.anchor_bottom = 1.0
	_btn_place.offset_left   = mg;         _btn_place.offset_right  = mg + sz
	_btn_place.offset_top    = -350;       _btn_place.offset_bottom = -250
	add_child(_btn_place)

	_btn_fire = _mk_btn("FIRE\nGUN", Color(1.0, 0.6, 0.0))
	_btn_fire.anchor_left   = 0.0; _btn_fire.anchor_right  = 0.0
	_btn_fire.anchor_top    = 1.0; _btn_fire.anchor_bottom = 1.0
	_btn_fire.offset_left   = mg;          _btn_fire.offset_right  = mg + sz
	_btn_fire.offset_top    = -230;        _btn_fire.offset_bottom = -130
	add_child(_btn_fire)

	_btn_fwd.button_down.connect(func():    player.touch_forward  = true)
	_btn_fwd.button_up.connect(func():      player.touch_forward  = false)
	_btn_bwd.button_down.connect(func():    player.touch_backward = true)
	_btn_bwd.button_up.connect(func():      player.touch_backward = false)
	_btn_place.button_down.connect(func():  player._try_place())
	_btn_fire.button_down.connect(func():   player._fire_gun())

func _mk_btn(txt: String, col: Color) -> Button:
	var btn = Button.new()
	btn.text = txt
	btn.add_theme_font_size_override("font_size", 16)
	btn.add_theme_color_override("font_color", Color.WHITE)
	var s = StyleBoxFlat.new()
	s.bg_color = col.darkened(0.5)
	s.bg_color.a = 0.8
	s.border_color = col
	s.set_border_width_all(2)
	s.set_corner_radius_all(6)
	btn.add_theme_stylebox_override("normal", s)
	btn.add_theme_stylebox_override("pressed", s)
	return btn

# ── Helpers ───────────────────────────────────────────────────────────────────
func _make_label(txt: String, ox: int, oy: int, sz: int, col: Color) -> Label:
	var lbl = Label.new()
	lbl.text         = txt
	lbl.offset_left  = ox
	lbl.offset_top   = oy
	lbl.add_theme_font_size_override("font_size", sz)
	lbl.add_theme_color_override("font_color", col)
	# Drop shadow for readability
	lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	lbl.add_theme_constant_override("shadow_offset_x", 2)
	lbl.add_theme_constant_override("shadow_offset_y", 2)
	return lbl

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R:
			get_tree().reload_current_scene()
		elif event.keycode == KEY_ESCAPE and not OS.has_feature("web"):
			get_tree().quit()

# -- Multiplayer: override which node is "local" vs "remote". ─────────────────
# Called from main.gd after UIManager is added, only in multiplayer mode.
func setup_players(local_p: Node3D, remote_p: Node3D, role: String) -> void:
	player     = local_p as Player
	robot      = remote_p
	local_role = role
