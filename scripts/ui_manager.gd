extends CanvasLayer

class_name UIManager

# ── References (discovered in _ready via "players" group) ─────────────────────
var game_manager: GameManager
var player: Player         # local / authoritative player
var _opponents: Array = []
var _net: NetworkManager

# ── HUD labels ────────────────────────────────────────────────────────────────
var _kills_label:   Label
var _trap_label:    Label
var _gun_label:     Label
var _hint_label:    Label
var _effects_label: Label
var _ping_label:    Label

# ── HP bar (local player) ─────────────────────────────────────────────────────
var _hp_bg:    ColorRect
var _hp_fill:  ColorRect
var _hp_label: Label

# ── Player list panel (all players, right side) ───────────────────────────────
var _player_hud_panel: PanelContainer
var _player_hud_vbox:  VBoxContainer
# pid → { hp_fill, voice_lbl, hp_lbl, kills_lbl, lives_lbl, row_root }
var _player_rows: Dictionary = {}
var _speaking_pids: Dictionary = {}  # pid → bool

# ── Minimap ───────────────────────────────────────────────────────────────────
var _mm_rect:    TextureRect
var _mm_image:   Image
var _mm_texture: ImageTexture
const MM_CELL   = 4
const MM_MARGIN = 8

# ── Win overlay ───────────────────────────────────────────────────────────────
var _overlay_panel: Panel
var _overlay_label: Label
var _retry_btn:     Button

# ── Notifications ─────────────────────────────────────────────────────────────
var _notif_vbox: VBoxContainer

# ── Blind flash ───────────────────────────────────────────────────────────────
var _blind_overlay: ColorRect

# ── Mobile controls (phone / web) ─────────────────────────────────────────────
const _JOY_BASE := 170.0  # joystick ring diameter
const _JOY_KNOB := 70.0   # joystick knob diameter
const _JOY_R    := 70.0   # max knob travel from centre, in pixels
const _JOY_DEAD := 0.18   # normalised dead-zone
const _JOY_MG   := 28     # joystick distance from screen corner

var _joy_id:      int     = -1
var _joy_origin:  Vector2 = Vector2.ZERO
var _joy_base_nd: Panel   = null
var _joy_knob_nd: Panel   = null

var _look_id:     int     = -1
var _look_prev:   Vector2 = Vector2.ZERO

var _fire_nd:     Panel   = null   # visual-only circle for FIRE
var _trap_nd:     Panel   = null   # visual-only circle for TRAP
var _fire_id:     int     = -1
var _trap_id:     int     = -1

# ── Crosshair ─────────────────────────────────────────────────────────────────
var _crosshair_parts: Array = []

# ── Device detection ──────────────────────────────────────────────────────────
static func _is_mobile_device() -> bool:
	if OS.has_feature("android") or OS.has_feature("ios"):
		return true
	if OS.has_feature("web"):
		# Ask the browser whether a touch screen is present
		var result = JavaScriptBridge.eval("navigator.maxTouchPoints > 0 ? 1 : 0")
		return int(result) > 0
	return false

# ────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	var root     = get_parent()
	game_manager = root.get_node("GameManager")
	_net         = root.get_node_or_null("NetworkManager")

	for p in get_tree().get_nodes_in_group("players"):
		if p is Player and p.is_multiplayer_authority():
			player = p as Player
			break

	for p in get_tree().get_nodes_in_group("players"):
		if p != player:
			_opponents.append(p)

	_build_hud()
	_build_hp_bar()
	_build_crosshair()
	_build_minimap()
	_build_player_hud()
	_build_overlay()
	_build_blind_overlay()
	_build_mobile_buttons()
	_build_notifications()

	if player != null:
		player.set_blind_overlay(_blind_overlay)

	game_manager.player_damaged.connect(_on_player_damaged)
	var trap_mgr = root.get_node_or_null("TrapManager")
	if trap_mgr != null:
		trap_mgr.trap_triggered.connect(_on_trap_triggered)
	if _net != null:
		_net.peer_left.connect(_on_peer_disconnected_notif)

	# Connect voice speaking signal so we can show the 🔊 icon
	var vm = root.get_node_or_null("VoiceManager") as VoiceManager
	if vm:
		vm.player_speaking_changed.connect(_on_player_speaking_changed)

# ────────────────────────────────────────────────────────────────────────────
func _process(_delta: float) -> void:
	if player == null: return
	_update_hud()
	_update_player_hud()
	_update_minimap()
	_update_crosshair()
	# Keep the joystick knob parked at the ring centre while idle (also handles resize).
	if _joy_base_nd != null and _joy_id == -1:
		_recenter_knob()
	if not game_manager.is_playing:
		_show_overlay()

# ── HUD ───────────────────────────────────────────────────────────────────────
func _build_hud() -> void:
	_kills_label = _make_label("", 10, 10, 22, Color.YELLOW)
	add_child(_kills_label)

	_trap_label = _make_label("", 10, 44, 18, Color.WHITE)
	add_child(_trap_label)

	_gun_label = _make_label("", 10, 72, 17, Color(0.3, 1.0, 0.3))
	add_child(_gun_label)

	_effects_label = _make_label("", 10, 0, 17, Color(0.8, 1.0, 0.8))
	_effects_label.anchor_top    = 1.0; _effects_label.anchor_bottom = 1.0
	_effects_label.offset_top    = -80; _effects_label.offset_bottom = -10
	add_child(_effects_label)

	var is_mp     = multiplayer.has_multiplayer_peer()
	var voice_hint = "  V=Mute/Unmute" if is_mp else ""
	_hint_label = _make_label(
		"W/S=Move  Q/E=Turn  Walk over box=Pick up  SPACE=Throw Trap  LMB=Fire  R=Restart" + voice_hint,
		0, 0, 13, Color(0.8, 0.8, 0.8)
	)
	_hint_label.anchor_left   = 0.0; _hint_label.anchor_right = 1.0
	_hint_label.anchor_top    = 1.0; _hint_label.anchor_bottom = 1.0
	_hint_label.offset_top    = -24; _hint_label.offset_bottom = 0
	_hint_label.offset_left   = 10
	add_child(_hint_label)

	_ping_label = _make_label("", 0, 0, 14, Color(0.5, 1.0, 0.5))
	_ping_label.anchor_left   = 1.0; _ping_label.anchor_right  = 1.0
	_ping_label.anchor_top    = 1.0; _ping_label.anchor_bottom = 1.0
	_ping_label.offset_left   = -110; _ping_label.offset_right  = -8
	_ping_label.offset_top    = -48;  _ping_label.offset_bottom = -26
	_ping_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(_ping_label)

func _build_hp_bar() -> void:
	_hp_bg = ColorRect.new()
	_hp_bg.color        = Color(0.15, 0.05, 0.05, 0.88)
	_hp_bg.anchor_left  = 0.5; _hp_bg.anchor_right  = 0.5
	_hp_bg.anchor_top   = 0.0; _hp_bg.anchor_bottom = 0.0
	_hp_bg.offset_left  = -155; _hp_bg.offset_right  = 155
	_hp_bg.offset_top   = 8;    _hp_bg.offset_bottom = 38
	add_child(_hp_bg)

	_hp_fill = ColorRect.new()
	_hp_fill.color    = Color(0.15, 0.85, 0.20)
	_hp_fill.position = Vector2(3, 3); _hp_fill.size = Vector2(300, 24)
	_hp_bg.add_child(_hp_fill)

	_hp_label = Label.new()
	_hp_label.text = "HP 100"
	_hp_label.add_theme_font_size_override("font_size", 15)
	_hp_label.add_theme_color_override("font_color", Color.WHITE)
	_hp_label.add_theme_color_override("font_shadow_color", Color(0,0,0,0.9))
	_hp_label.add_theme_constant_override("shadow_offset_x", 1)
	_hp_label.add_theme_constant_override("shadow_offset_y", 1)
	_hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hp_label.position = Vector2(0, 4); _hp_label.size = Vector2(306, 24)
	_hp_bg.add_child(_hp_label)

# ── Player list panel ─────────────────────────────────────────────────────────
func _build_player_hud() -> void:
	if game_manager == null: return

	# Outer panel — right side, below the top bar
	_player_hud_panel = PanelContainer.new()
	var sb = StyleBoxFlat.new()
	sb.bg_color = Color(0.0, 0.0, 0.0, 0.60)
	sb.set_corner_radius_all(6)
	_player_hud_panel.add_theme_stylebox_override("panel", sb)
	_player_hud_panel.anchor_left   = 1.0; _player_hud_panel.anchor_right  = 1.0
	_player_hud_panel.anchor_top    = 0.0; _player_hud_panel.anchor_bottom = 0.0
	_player_hud_panel.offset_left   = -230; _player_hud_panel.offset_right  = -8
	_player_hud_panel.offset_top    = 8;    _player_hud_panel.offset_bottom = 8  # grows with content
	add_child(_player_hud_panel)

	_player_hud_vbox = VBoxContainer.new()
	_player_hud_vbox.add_theme_constant_override("separation", 4)
	_player_hud_panel.add_child(_player_hud_vbox)

	for pid in game_manager.player_ids:
		_ensure_player_row(pid)

## Called from _update_player_hud to create a row on demand (late joiners etc.)
func _ensure_player_row(pid: int) -> void:
	if _player_rows.has(pid): return
	if game_manager == null or _player_hud_vbox == null: return

	var idx    = game_manager.player_ids.find(pid)
	var col    = Config.PLAYER_COLORS[idx % Config.PLAYER_COLORS.size()] if idx >= 0 else Color.WHITE
	var is_me  = (player != null and pid == player.peer_id)

	var name_str: String
	if _net and _net.player_names.has(pid):
		name_str = _net.player_names[pid]
	elif is_me:
		name_str = "You"
	else:
		name_str = "P%d" % (idx + 1)

	# ── Row container ─────────────────────────────────────────────────────────
	var row_pc = PanelContainer.new()
	var rsb = StyleBoxFlat.new()
	rsb.bg_color = Color(col.r * 0.15, col.g * 0.15, col.b * 0.15, 0.5)
	rsb.border_color = Color(col.r, col.g, col.b, 0.45)
	rsb.set_border_width_all(1); rsb.set_corner_radius_all(4)
	row_pc.add_theme_stylebox_override("panel", rsb)
	row_pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_player_hud_vbox.add_child(row_pc)

	var col_v = VBoxContainer.new()
	col_v.add_theme_constant_override("separation", 2)
	row_pc.add_child(col_v)

	# ── Top line: dot · name · voice icon ─────────────────────────────────────
	var top_h = HBoxContainer.new()
	top_h.add_theme_constant_override("separation", 4)
	col_v.add_child(top_h)

	var dot = ColorRect.new()
	dot.color = col
	dot.custom_minimum_size = Vector2(10, 10)
	top_h.add_child(dot)

	var name_lbl = Label.new()
	name_lbl.text = name_str + (" ★" if is_me else "")
	name_lbl.add_theme_font_size_override("font_size", 12)
	name_lbl.add_theme_color_override("font_color",
		Color(1.0, 0.95, 0.5) if is_me else Color(0.9, 0.9, 0.9))
	name_lbl.clip_text = true
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_h.add_child(name_lbl)

	var voice_lbl = Label.new()
	voice_lbl.text = "🔊"
	voice_lbl.add_theme_font_size_override("font_size", 12)
	voice_lbl.visible = false
	top_h.add_child(voice_lbl)

	# ── HP bar ────────────────────────────────────────────────────────────────
	# Outer fixed-height control; inner fill uses anchors for percentage width.
	var bar_ctrl = Control.new()
	bar_ctrl.custom_minimum_size = Vector2(0, 6)
	bar_ctrl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col_v.add_child(bar_ctrl)

	var bar_bg = ColorRect.new()
	bar_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bar_bg.color = Color(0.12, 0.05, 0.05, 0.9)
	bar_ctrl.add_child(bar_bg)

	var hp_fill = ColorRect.new()
	hp_fill.color = col
	hp_fill.anchor_left   = 0.0; hp_fill.anchor_top    = 0.0
	hp_fill.anchor_right  = 1.0; hp_fill.anchor_bottom = 1.0
	hp_fill.offset_left   = 0;   hp_fill.offset_right  = 0
	hp_fill.offset_top    = 0;   hp_fill.offset_bottom = 0
	bar_ctrl.add_child(hp_fill)

	# ── Bottom line: HP · lives · kills ──────────────────────────────────────
	var bot_h = HBoxContainer.new()
	bot_h.add_theme_constant_override("separation", 6)
	col_v.add_child(bot_h)

	var hp_lbl = _make_label("100 HP", 0, 0, 10, Color(0.75, 0.75, 0.75))
	hp_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bot_h.add_child(hp_lbl)

	var lives_lbl = _make_label("♥♥♥", 0, 0, 10, Color(0.95, 0.35, 0.35))
	bot_h.add_child(lives_lbl)

	var kills_lbl = _make_label("K:0", 0, 0, 10, Color(0.55, 0.85, 1.0))
	bot_h.add_child(kills_lbl)

	_player_rows[pid] = {
		"hp_fill":   hp_fill,
		"voice_lbl": voice_lbl,
		"hp_lbl":    hp_lbl,
		"lives_lbl": lives_lbl,
		"kills_lbl": kills_lbl,
		"base_col":  col,
	}

func _update_player_hud() -> void:
	if game_manager == null or _player_hud_vbox == null: return

	for pid in game_manager.player_ids:
		_ensure_player_row(pid)   # handles late joiners

	for pid in _player_rows.keys():
		var row = _player_rows[pid]

		var hp    = game_manager.hp.get(pid, Config.MAX_HP)
		var ratio = float(hp) / float(Config.MAX_HP)

		# HP bar fill width
		var fill: ColorRect = row["hp_fill"]
		if is_instance_valid(fill):
			fill.anchor_right = ratio
			# Colour shifts red as health drops
			var base: Color = row["base_col"]
			if   ratio > 0.60: fill.color = base
			elif ratio > 0.30: fill.color = Color(0.92, 0.78, 0.08)
			else:              fill.color = Color(0.95, 0.18, 0.12)

		# HP text
		var hp_lbl: Label = row["hp_lbl"]
		if is_instance_valid(hp_lbl):
			hp_lbl.text = "%d HP" % hp

		# Lives hearts
		var lives: int = game_manager.lives.get(pid, Config.PLAYER_LIVES)
		var lives_lbl: Label = row["lives_lbl"]
		if is_instance_valid(lives_lbl):
			lives_lbl.text = "♥".repeat(max(lives, 0))

		# Kills
		var kills: int = game_manager.kills.get(pid, 0)
		var kills_lbl: Label = row["kills_lbl"]
		if is_instance_valid(kills_lbl):
			kills_lbl.text = "K:%d" % kills

		# Voice icon
		var voice_lbl: Label = row["voice_lbl"]
		if is_instance_valid(voice_lbl):
			voice_lbl.visible = _speaking_pids.get(pid, false)

func _on_player_speaking_changed(pid: int, speaking: bool) -> void:
	_speaking_pids[pid] = speaking

# ── Crosshair ─────────────────────────────────────────────────────────────────
func _build_crosshair() -> void:
	var root = Control.new()
	root.anchor_left  = 0.5; root.anchor_right  = 0.5
	root.anchor_top   = 0.5; root.anchor_bottom = 0.5
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	const GAP := 5; const LEN := 11; const TICK := 2
	var rects: Array[Dictionary] = [
		{ "pos": Vector2(-(GAP + LEN), -TICK / 2), "size": Vector2(LEN, TICK) },
		{ "pos": Vector2(GAP,          -TICK / 2), "size": Vector2(LEN, TICK) },
		{ "pos": Vector2(-TICK / 2, -(GAP + LEN)), "size": Vector2(TICK, LEN) },
		{ "pos": Vector2(-TICK / 2,  GAP),         "size": Vector2(TICK, LEN) },
		{ "pos": Vector2(-2, -2),                  "size": Vector2(4, 4) },
	]
	for r in rects:
		var cr = ColorRect.new()
		cr.position = r["pos"]; cr.size = r["size"]
		cr.color = Color(1, 1, 1, 0.88); cr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		root.add_child(cr); _crosshair_parts.append(cr)

func _update_crosshair() -> void:
	if _crosshair_parts.is_empty() or player == null: return

	var on_target := false
	if game_manager.is_playing:
		var fwd = Vector3(-sin(player.yaw), 0.0, -cos(player.yaw))
		for opp in get_tree().get_nodes_in_group("players"):
			if opp == player or not is_instance_valid(opp): continue
			var opid = opp.get("peer_id")
			if opid != null and game_manager.respawning.get(opid, false): continue
			var to_opp = opp.position - player.position
			var dist   = to_opp.length()
			var horiz  = Vector3(to_opp.x, 0.0, to_opp.z).normalized()
			if dist < 28.0 and fwd.dot(horiz) > 0.65:
				on_target = true; break

	var col: Color
	if not game_manager.is_playing:
		col = Color(1, 1, 1, 0.0)
	elif on_target:
		col = Color(1.0, 0.15, 0.15, 1.0)
	elif player._gun_cooldown > 0.0:
		col = Color(0.85, 0.55, 0.10, 0.85)
	else:
		col = Color(1.0, 1.0, 1.0, 0.88)
	for part in _crosshair_parts: part.color = col

func _update_hud() -> void:
	if player == null: return
	var pid     = player.peer_id
	var my_hp   = game_manager.hp.get(pid, Config.MAX_HP)
	var my_k    = game_manager.kills.get(pid, 0)
	var my_l    = game_manager.lives.get(pid, Config.PLAYER_LIVES)

	_kills_label.text = "Kills: %d  Lives: %s  (first to %d wins)" % [
		my_k, "♥ ".repeat(my_l).strip_edges(), Config.KILLS_TO_WIN
	]

	# HP bar
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
		_trap_label.text = "Trap: [%s]  (SPACE to throw)" % Config.TRAP_NAMES[player.held_trap]
		_trap_label.add_theme_color_override("font_color", Config.TRAP_COLORS[player.held_trap])
	else:
		_trap_label.text = "No trap  (walk over a glowing box to pick one up)"
		_trap_label.add_theme_color_override("font_color", Color.GRAY)

	if player._gun_cooldown > 0.0:
		_gun_label.text = "Gun: %.1fs" % player._gun_cooldown
		_gun_label.add_theme_color_override("font_color", Color(0.8, 0.5, 0.2))
	else:
		_gun_label.text = "Gun: READY  (LMB / TAB)"
		_gun_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3))

	var fx_text = ""
	for eff in game_manager.effects.get(pid, {}).keys():
		var remaining = snappedf(game_manager.effects[pid][eff], 0.1)
		fx_text += "  [%s %.1fs]" % [eff.to_upper(), remaining]
	_effects_label.text = fx_text

	if _net != null and not multiplayer.is_server():
		var ms = _net.ping_ms
		_ping_label.text = "● %d ms" % ms
		var col: Color
		if ms < 50:        col = Color(0.2, 1.0, 0.2)
		elif ms < 150:     col = Color(1.0, 0.85, 0.1)
		else:              col = Color(1.0, 0.25, 0.25)
		_ping_label.add_theme_color_override("font_color", col)

# ── Minimap ───────────────────────────────────────────────────────────────────
func _build_minimap() -> void:
	var grid = game_manager.grid
	var w    = grid[0].size() * MM_CELL
	var h    = grid.size()    * MM_CELL
	_mm_image   = Image.create(w, h, false, Image.FORMAT_RGB8)
	_mm_texture = ImageTexture.create_from_image(_mm_image)
	_mm_rect          = TextureRect.new()
	_mm_rect.position = Vector2(MM_MARGIN, MM_MARGIN + 110)
	_mm_rect.size     = Vector2(w, h)
	_mm_rect.texture  = _mm_texture
	add_child(_mm_rect)

func _update_minimap() -> void:
	if _mm_image == null: return
	var grid = game_manager.grid
	var w    = _mm_image.get_width()
	var h    = _mm_image.get_height()

	for r in range(grid.size()):
		for c in range(grid[r].size()):
			var col = Color(0.65, 0.65, 0.65) if grid[r][c] == 0 else Color(0.1, 0.1, 0.1)
			for dy in range(MM_CELL):
				for dx in range(MM_CELL):
					var px = c * MM_CELL + dx; var py = r * MM_CELL + dy
					if px < w and py < h: _mm_image.set_pixel(px, py, col)

	if player != null:
		var pg = player.get_grid_position()
		_mm_dot(pg[0], pg[1], Color.CYAN, 3)

	for opp in get_tree().get_nodes_in_group("players"):
		if opp == player or not is_instance_valid(opp): continue
		var idx = opp.get("player_index") if opp.get("player_index") != null else 1
		var col = Config.PLAYER_COLORS[idx % Config.PLAYER_COLORS.size()]
		if opp.has_method("get_grid_position"):
			var og = opp.get_grid_position()
			_mm_dot(og[0], og[1], col, 2)

	for box in get_tree().get_nodes_in_group("trap_boxes"):
		var bg = game_manager.world_to_grid(box.position)
		_mm_dot(bg[0], bg[1], Color.YELLOW, 2)

	_mm_texture = ImageTexture.create_from_image(_mm_image)
	_mm_rect.texture = _mm_texture

func _mm_dot(gx: int, gy: int, col: Color, radius: int) -> void:
	var w = _mm_image.get_width(); var h = _mm_image.get_height()
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var px = gx * MM_CELL + MM_CELL / 2 + dx
			var py = gy * MM_CELL + MM_CELL / 2 + dy
			if px >= 0 and px < w and py >= 0 and py < h:
				_mm_image.set_pixel(px, py, col)

# ── Win overlay ───────────────────────────────────────────────────────────────
func _build_overlay() -> void:
	_overlay_panel = Panel.new()
	_overlay_panel.anchor_left   = 0.5; _overlay_panel.anchor_top    = 0.5
	_overlay_panel.anchor_right  = 0.5; _overlay_panel.anchor_bottom = 0.5
	_overlay_panel.offset_left   = -240; _overlay_panel.offset_top    = -130
	_overlay_panel.offset_right  = 240;  _overlay_panel.offset_bottom = 150
	_overlay_panel.visible       = false
	var bg = StyleBoxFlat.new(); bg.bg_color = Color(0, 0, 0, 0.82)
	_overlay_panel.add_theme_stylebox_override("panel", bg)
	add_child(_overlay_panel)

	_overlay_label = Label.new()
	_overlay_label.anchor_left   = 0.5; _overlay_label.anchor_top    = 0.5
	_overlay_label.anchor_right  = 0.5; _overlay_label.anchor_bottom = 0.5
	_overlay_label.offset_left   = -210; _overlay_label.offset_top    = -110
	_overlay_label.offset_right  = 210;  _overlay_label.offset_bottom = 0
	_overlay_label.add_theme_font_size_override("font_size", 34)
	_overlay_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_overlay_label)

func _show_overlay() -> void:
	if _overlay_panel.visible: return
	_overlay_panel.visible = true

	var wpid = game_manager.winner_pid
	if wpid == player.peer_id:
		_overlay_label.text = "YOU WIN!\n\nKills: %d  Lives left: %d" % [
			game_manager.kills.get(wpid, 0), game_manager.lives.get(wpid, 0)
		]
		_overlay_label.add_theme_color_override("font_color", Color.GREEN)
	elif wpid == -1:
		_overlay_label.text = "DRAW!"
		_overlay_label.add_theme_color_override("font_color", Color.YELLOW)
	else:
		var idx = game_manager.player_ids.find(wpid)
		var pname = ("Robot AI" if wpid == 0 else "Player %d" % (idx + 1))
		_overlay_label.text = "%s WINS!" % pname
		_overlay_label.add_theme_color_override("font_color", Color.RED)

	if _retry_btn == null:
		_retry_btn = Button.new()
		_retry_btn.text = "PLAY AGAIN"
		_retry_btn.anchor_left   = 0.5; _retry_btn.anchor_top    = 0.5
		_retry_btn.anchor_right  = 0.5; _retry_btn.anchor_bottom = 0.5
		_retry_btn.offset_left   = -80; _retry_btn.offset_top    = 50
		_retry_btn.offset_right  = 80;  _retry_btn.offset_bottom = 100
		_retry_btn.add_theme_font_size_override("font_size", 24)
		_retry_btn.add_theme_color_override("font_color", Color.WHITE)
		_retry_btn.button_down.connect(func(): get_tree().reload_current_scene())
		add_child(_retry_btn)

# ── Blind overlay ─────────────────────────────────────────────────────────────
func _build_blind_overlay() -> void:
	_blind_overlay = ColorRect.new()
	_blind_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_blind_overlay.color   = Color(1.0, 1.0, 1.0, 0.92)
	_blind_overlay.visible = false
	add_child(_blind_overlay)

# ── Mobile controls (phone / web) ────────────────────────────────────────────
func _build_mobile_buttons() -> void:
	if player == null: return
	if not (_is_mobile_device() or OS.has_feature("web")): return

	const FSZ := 120.0   # fire button diameter
	const TSZ :=  90.0   # trap button diameter
	const MG  :=  20     # screen-edge margin

	# Joystick outer ring — fixed at bottom-left, always visible
	_joy_base_nd = _circle_panel(_JOY_BASE, Color(0.12, 0.14, 0.18, 0.42), Color(0.90, 0.90, 0.90, 0.55), 3)
	_joy_base_nd.anchor_left   = 0.0; _joy_base_nd.anchor_right  = 0.0
	_joy_base_nd.anchor_top    = 1.0; _joy_base_nd.anchor_bottom = 1.0
	_joy_base_nd.offset_left   = _JOY_MG;            _joy_base_nd.offset_right  = _JOY_MG + _JOY_BASE
	_joy_base_nd.offset_top    = -(_JOY_MG + _JOY_BASE); _joy_base_nd.offset_bottom = -_JOY_MG
	add_child(_joy_base_nd)

	# Joystick knob — positioned absolutely (recentred each idle frame)
	_joy_knob_nd = _circle_panel(_JOY_KNOB, Color(0.72, 0.74, 0.80, 0.72), Color(1.0, 1.0, 1.0, 0.88), 2)
	add_child(_joy_knob_nd)

	# FIRE button — gun icon, right side, ~72% down (PUBG-style)
	_fire_nd = _action_image_button(FSZ, "res://assets/icons/icon_gun.svg")
	_fire_nd.anchor_left   = 1.0; _fire_nd.anchor_right  = 1.0
	_fire_nd.anchor_top    = 0.72; _fire_nd.anchor_bottom = 0.72
	_fire_nd.offset_left   = -(FSZ + MG); _fire_nd.offset_right  = -MG
	_fire_nd.offset_top    = -FSZ * 0.5;  _fire_nd.offset_bottom = FSZ * 0.5
	add_child(_fire_nd)

	# TRAP button — bomb icon, above fire button, same right edge
	_trap_nd = _action_image_button(TSZ, "res://assets/icons/icon_bomb.svg")
	_trap_nd.anchor_left   = 1.0; _trap_nd.anchor_right  = 1.0
	_trap_nd.anchor_top    = 0.72; _trap_nd.anchor_bottom = 0.72
	_trap_nd.offset_left   = -(TSZ + MG); _trap_nd.offset_right  = -MG
	_trap_nd.offset_top    = -(FSZ * 0.5 + MG + TSZ); _trap_nd.offset_bottom = -(FSZ * 0.5 + MG)
	add_child(_trap_nd)

	# Voice button (multiplayer only) — above trap button, same right edge
	if multiplayer.has_multiplayer_peer():
		var vm = get_parent().get_node_or_null("VoiceManager") as VoiceManager
		if vm:
			const VSZ := 68.0
			# Trap top = -(FSZ*0.5 + MG + TSZ); voice sits 12px above that
			var v_bot := -(FSZ * 0.5 + MG + TSZ + 12)
			# (anchor_top = 0.72 matches fire/trap buttons)
			var btn_voice = Button.new()
			btn_voice.text = "🎤\nON"
			btn_voice.add_theme_font_size_override("font_size", 14)
			btn_voice.add_theme_color_override("font_color", Color.WHITE)
			var vsb = StyleBoxFlat.new()
			vsb.bg_color = Color(0.20, 0.68, 0.36, 0.85)
			vsb.border_color = Color(0.55, 1.0, 0.65, 0.90)
			vsb.set_border_width_all(2); vsb.set_corner_radius_all(int(VSZ * 0.5))
			btn_voice.add_theme_stylebox_override("normal", vsb)
			btn_voice.add_theme_stylebox_override("pressed", vsb)
			btn_voice.anchor_left   = 1.0; btn_voice.anchor_right  = 1.0
			btn_voice.anchor_top    = 0.72; btn_voice.anchor_bottom = 0.72
			btn_voice.offset_right  = -MG
			btn_voice.offset_left   = -(VSZ + MG)
			btn_voice.offset_top    = v_bot - VSZ
			btn_voice.offset_bottom = v_bot
			add_child(btn_voice)
			btn_voice.pressed.connect(func():
				if vm._transmitting: vm.mute()
				else:                vm.unmute()
			)
			vm.voice_button = btn_voice

# Transparent hit-area panel with a SVG image button. No background — icon
# floats directly on the HUD like a standard game action button.
func _action_image_button(size: float, tex_path: String) -> Panel:
	var p = Panel.new()
	p.custom_minimum_size = Vector2(size, size)
	var sb = StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	p.add_theme_stylebox_override("panel", sb)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tr = TextureRect.new()
	tr.texture = load(tex_path)
	tr.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.set_anchors_preset(Control.PRESET_FULL_RECT)
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(tr)
	return p

func _circle_panel(size: float, fill: Color, border: Color, bw: int) -> Panel:
	var p = Panel.new()
	p.custom_minimum_size = Vector2(size, size)
	var sb = StyleBoxFlat.new()
	sb.bg_color = fill; sb.border_color = border
	sb.set_border_width_all(bw); sb.set_corner_radius_all(int(size * 0.5))
	p.add_theme_stylebox_override("panel", sb)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p

# ── Helpers ───────────────────────────────────────────────────────────────────
func _make_label(txt: String, ox: int, oy: int, sz: int, col: Color) -> Label:
	var lbl = Label.new()
	lbl.text = txt; lbl.offset_left = ox; lbl.offset_top = oy
	lbl.add_theme_font_size_override("font_size", sz)
	lbl.add_theme_color_override("font_color", col)
	lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	lbl.add_theme_constant_override("shadow_offset_x", 2)
	lbl.add_theme_constant_override("shadow_offset_y", 2)
	return lbl

# ── Notifications ─────────────────────────────────────────────────────────────
func _build_notifications() -> void:
	_notif_vbox = VBoxContainer.new()
	_notif_vbox.anchor_left  = 0.5; _notif_vbox.anchor_right  = 0.5
	_notif_vbox.anchor_top   = 0.0; _notif_vbox.anchor_bottom = 0.0
	_notif_vbox.offset_left  = -220; _notif_vbox.offset_right  = 220
	_notif_vbox.offset_top   = 50
	_notif_vbox.add_theme_constant_override("separation", 4)
	add_child(_notif_vbox)

func show_notification(text: String, col: Color = Color.WHITE) -> void:
	var panel = PanelContainer.new()
	var sb = StyleBoxFlat.new()
	sb.bg_color = Color(0.0, 0.0, 0.0, 0.72)
	sb.set_corner_radius_all(5)
	panel.add_theme_stylebox_override("panel", sb)

	var lbl = Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", col)
	lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	lbl.add_theme_constant_override("shadow_offset_x", 1)
	lbl.add_theme_constant_override("shadow_offset_y", 1)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(lbl)
	_notif_vbox.add_child(panel)

	var tween = create_tween()
	tween.tween_property(panel, "modulate:a", 0.0, 0.5).set_delay(3.5)
	tween.tween_callback(panel.queue_free)

func _player_name(pid: int) -> String:
	if _net != null and _net.player_names.has(pid):
		return _net.player_names[pid]
	var idx = game_manager.player_ids.find(pid)
	return "Player %d" % (idx + 1) if idx >= 0 else "Player"

func _on_player_damaged(victim_pid: int, attacker_pid: int, _amount: int) -> void:
	if player == null or victim_pid != player.peer_id: return
	if attacker_pid == -1 or attacker_pid == victim_pid:
		show_notification("You were hit!", Color(1.0, 0.35, 0.35))
	else:
		show_notification("Hit by %s!" % _player_name(attacker_pid), Color(1.0, 0.35, 0.35))

func _on_trap_triggered(victim_pid: int, owner_pid: int, trap_type: int) -> void:
	if player == null or victim_pid != player.peer_id: return
	var trap_name = Config.TRAP_NAMES.get(trap_type, "trap")
	if owner_pid == -1:
		show_notification("You triggered a %s!" % trap_name, Color(1.0, 0.65, 0.15))
	else:
		show_notification("Caught in %s's %s!" % [_player_name(owner_pid), trap_name], Color(1.0, 0.65, 0.15))

func _on_peer_disconnected_notif(pid: int) -> void:
	if pid == -1: return
	show_notification("%s disconnected." % _player_name(pid), Color(0.6, 0.6, 0.6))

# ── Input ─────────────────────────────────────────────────────────────────────
func _input(event: InputEvent) -> void:
	# Keyboard shortcuts (always active)
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R:
			get_tree().reload_current_scene()
		elif event.keycode == KEY_ESCAPE and not OS.has_feature("web"):
			if multiplayer.has_multiplayer_peer():
				multiplayer.multiplayer_peer.close()
			get_tree().quit()

	# Touch controls
	if not (_is_mobile_device() or OS.has_feature("web")): return
	if player == null or not game_manager.is_playing: return

	var vp_hw: float = get_viewport().get_visible_rect().size.x * 0.5

	if event is InputEventScreenTouch:
		var pos: Vector2 = event.position
		if event.pressed:
			# Left half → joystick (origin is the fixed ring centre)
			if pos.x < vp_hw and _joy_id == -1:
				_joy_id = event.index
				_joy_update(pos)
				get_viewport().set_input_as_handled()
				return
			# Right half → check action buttons first, then look
			if pos.x >= vp_hw:
				if _fire_nd != null and _fire_nd.get_global_rect().has_point(pos) and _fire_id == -1:
					_fire_id = event.index
					_fire_nd.modulate = Color(1.5, 1.5, 1.5)
					player._fire_gun()
					get_viewport().set_input_as_handled()
					return
				if _trap_nd != null and _trap_nd.get_global_rect().has_point(pos) and _trap_id == -1:
					_trap_id = event.index
					_trap_nd.modulate = Color(1.5, 1.5, 1.5)
					player._try_place()
					get_viewport().set_input_as_handled()
					return
				if _look_id == -1:
					_look_id   = event.index
					_look_prev = pos
					get_viewport().set_input_as_handled()
					return
		else:
			if event.index == _joy_id:
				_joy_id = -1
				player.touch_move_x = 0.0
				player.touch_move_y = 0.0
				_recenter_knob()
				get_viewport().set_input_as_handled()
			elif event.index == _look_id:
				_look_id = -1
				get_viewport().set_input_as_handled()
			elif event.index == _fire_id:
				_fire_id = -1
				if _fire_nd: _fire_nd.modulate = Color(1, 1, 1)
				get_viewport().set_input_as_handled()
			elif event.index == _trap_id:
				_trap_id = -1
				if _trap_nd: _trap_nd.modulate = Color(1, 1, 1)
				get_viewport().set_input_as_handled()

	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		if event.index == _joy_id:
			_joy_update(drag.position)
			get_viewport().set_input_as_handled()
		elif event.index == _look_id:
			var sens: float = player.mouse_sensitivity * 1.8
			# Clamp a single (possibly browser-coalesced) drag delta so a frame
			# hitch near a wall can't deliver one huge lump that snaps the view.
			var dx := clampf(drag.relative.x, -45.0, 45.0)
			var dy := clampf(drag.relative.y, -45.0, 45.0)
			player._pending_yaw_delta -= dx * sens
			player.pitch = clamp(player.pitch - dy * sens, -PI / 3.0, PI / 3.0)
			if player.camera_node:
				player.camera_node.rotation.x = player.pitch
			get_viewport().set_input_as_handled()

# Move the knob toward `pos` (clamped to ring) and update the strafe vector.
func _joy_update(pos: Vector2) -> void:
	if _joy_base_nd == null or player == null: return
	var centre:  Vector2 = _joy_base_nd.get_global_rect().get_center()
	var delta_v: Vector2 = pos - centre
	var dist:    float   = delta_v.length()
	var norm:    Vector2 = delta_v / maxf(dist, 1.0)
	var clamped: float   = minf(dist, _JOY_R)
	_joy_knob_nd.position = centre + norm * clamped - Vector2(_JOY_KNOB * 0.5, _JOY_KNOB * 0.5)

	var strength: float = minf(dist / _JOY_R, 1.0)
	if strength > _JOY_DEAD:
		player.touch_move_x =  norm.x * strength   # +x = strafe right
		player.touch_move_y = -norm.y * strength   # screen y is down → invert for forward
	else:
		player.touch_move_x = 0.0
		player.touch_move_y = 0.0

# Snap the knob back to the centre of the ring.
func _recenter_knob() -> void:
	if _joy_base_nd == null or _joy_knob_nd == null: return
	var centre: Vector2 = _joy_base_nd.get_global_rect().get_center()
	_joy_knob_nd.position = centre - Vector2(_JOY_KNOB * 0.5, _JOY_KNOB * 0.5)
