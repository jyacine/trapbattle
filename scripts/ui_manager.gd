extends CanvasLayer

class_name UIManager

# ── References (discovered in _ready via "players" group) ─────────────────────
var game_manager: GameManager
var player: Player         # local / authoritative player
var _opponents: Array = []
var _net: NetworkManager

# Heart icon for lives — the ♥ glyph isn't in the default font (renders as a
# missing-glyph box on the web build), so lives are drawn as SVG textures instead.
const HEART_TEX := preload("res://assets/icons/icon_heart.svg")
const HEART_COLOR := Color(0.95, 0.35, 0.35)

# Voice icons (the emoji glyphs aren't in the default font, so use SVG textures).
const MIC_TEX     := preload("res://assets/icons/icon_mic.svg")      # 🎤 mic on
const MUTE_TEX    := preload("res://assets/icons/icon_mute.svg")     # 🔇 muted
const SPEAKER_TEX := preload("res://assets/icons/icon_speaker.svg")  # 🔊 speaking

# ── HUD labels ────────────────────────────────────────────────────────────────
var _kills_label:   Label
var _lives_box:     HBoxContainer   # heart icons for the local player's lives
var _wins_label:    Label
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
# pid → { hp_fill, voice_lbl, hp_lbl, kills_lbl, lives_box, row_root }
var _player_rows: Dictionary = {}
var _speaking_pids: Dictionary = {}  # pid → bool
var _voice_btn:     Button = null    # mic mute/unmute toggle (multiplayer only)
var _voice_icon:    TextureRect = null  # mic / mute icon shown on the button

# ── Minimap ───────────────────────────────────────────────────────────────────
var _mm_rect:    TextureRect
var _mm_image:   Image
var _mm_texture: ImageTexture
const MM_CELL   = 4
const MM_MARGIN = 8

# ── Exit / leave-match ─────────────────────────────────────────────────────────
var _exit_btn:     Button
var _exit_overlay: Control   # custom in-canvas confirm — reliable touch on mobile web

# ── Win overlay ───────────────────────────────────────────────────────────────
var _overlay_panel: Panel
var _overlay_label: Label
var _retry_btn:     Button

# ── Notifications ─────────────────────────────────────────────────────────────
var _notif_vbox: VBoxContainer

# ── Blind flash ───────────────────────────────────────────────────────────────
var _blind_overlay: ColorRect

# ── Trap inventory bar (bottom centre) ───────────────────────────────────────
var _inv_bar:   Control = null
var _inv_slots: Array   = []   # Array of {panel, sb_normal, sb_active, label}

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

var _look_id:          int     = -1
var _look_prev:        Vector2 = Vector2.ZERO
var _look_prev_fire:   Vector2 = Vector2.ZERO   # track fire-drag position for turn-while-firing
var _look_prev_trap:   Vector2 = Vector2.ZERO   # track trap-drag position for aim-while-holding

var _fire_nd:       Panel = null
var _trap_nd:       Panel = null
var _switch_gun_nd: Panel = null
var _jump_nd:       Panel = null
var _fire_id:       int   = -1
var _trap_id:       int   = -1
var _switch_gun_id: int   = -1
var _jump_id:       int   = -1

# ── Crosshair ─────────────────────────────────────────────────────────────────
var _crosshair_parts: Array = []

# ── Gun icons (index matches Config.GunType) ──────────────────────────────────
const GUN_ICONS: Array = [
	"res://assets/icons/icon_gun.svg",
	"res://assets/icons/icon_shotgun.svg",
	"res://assets/icons/icon_machinegun.svg",
]

# ── Device detection ──────────────────────────────────────────────────────────
static func _is_mobile_device() -> bool:
	return _is_touch_device()

static func _is_touch_device() -> bool:
	if OS.has_feature("android") or OS.has_feature("ios"):
		return true
	if OS.has_feature("web"):
		var result = JavaScriptBridge.eval("navigator.maxTouchPoints > 0 ? 1 : 0")
		return int(result) > 0
	return DisplayServer.is_touchscreen_available()

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
	_build_exit_button()
	_build_inventory_bar()
	_build_voice_button()
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
	# Mobile hold-to-fire: while touch is on the fire button, fire every cooldown cycle
	if _fire_id != -1 and player != null and player._gun_cooldown <= 0.0:
		player._fire_gun()
	_update_inventory_bar()
	if not game_manager.is_playing:
		_show_overlay()

# ── HUD ───────────────────────────────────────────────────────────────────────
func _build_hud() -> void:
	# Top line: "Kills: N" + heart icons + "(first to M wins)" laid out in a row so
	# the lives can be real heart textures (the ♥ glyph is missing from the font).
	var top_line = HBoxContainer.new()
	top_line.offset_left = 10; top_line.offset_top = 10
	top_line.add_theme_constant_override("separation", 8)
	add_child(top_line)

	_kills_label = _make_label("", 0, 0, 22, Color.YELLOW)
	top_line.add_child(_kills_label)

	_lives_box = HBoxContainer.new()
	_lives_box.add_theme_constant_override("separation", 3)
	_lives_box.alignment = BoxContainer.ALIGNMENT_CENTER
	top_line.add_child(_lives_box)

	_wins_label = _make_label("", 0, 0, 22, Color.YELLOW)
	top_line.add_child(_wins_label)

	_trap_label = _make_label("", 10, 44, 18, Color.WHITE)
	add_child(_trap_label)
	# _gun_label intentionally omitted — active weapon shown on the Select button

	_effects_label = _make_label("", 10, 0, 17, Color(0.8, 1.0, 0.8))
	_effects_label.anchor_top    = 1.0; _effects_label.anchor_bottom = 1.0
	_effects_label.offset_top    = -80; _effects_label.offset_bottom = -10
	add_child(_effects_label)

	var is_mp     = multiplayer.has_multiplayer_peer()
	var voice_hint = "  M=Mute/Unmute" if is_mp else ""
	_hint_label = _make_label(
		"W/S=Move  ←/→=Strafe  Q/E=Turn  C/SPACE=Cycle trap  N=Throw  RMB=Aim+Throw  V/B=Cycle gun  LMB/TAB=Fire  R=Restart" + voice_hint,
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
	# Sits below the Exit button (top-right corner).
	_player_hud_panel.offset_top    = 56;   _player_hud_panel.offset_bottom = 56  # grows with content
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
	name_lbl.text = name_str + ("  (you)" if is_me else "")
	name_lbl.add_theme_font_size_override("font_size", 12)
	name_lbl.add_theme_color_override("font_color",
		Color(1.0, 0.95, 0.5) if is_me else Color(0.9, 0.9, 0.9))
	name_lbl.clip_text = true
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_h.add_child(name_lbl)

	# Speaking indicator — a 🔊 speaker icon (SVG; the emoji glyph isn't in the
	# default font), shown only while this peer is transmitting.
	var voice_icon = TextureRect.new()
	voice_icon.texture      = SPEAKER_TEX
	voice_icon.custom_minimum_size = Vector2(15, 15)
	voice_icon.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
	voice_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	voice_icon.modulate     = Color(0.45, 1.0, 0.55)
	voice_icon.visible      = false
	top_h.add_child(voice_icon)

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

	var lives_box = HBoxContainer.new()
	lives_box.add_theme_constant_override("separation", 2)
	bot_h.add_child(lives_box)

	var kills_lbl = _make_label("K:0", 0, 0, 10, Color(0.55, 0.85, 1.0))
	bot_h.add_child(kills_lbl)

	_player_rows[pid] = {
		"hp_fill":   hp_fill,
		"voice_lbl": voice_icon,
		"hp_lbl":    hp_lbl,
		"lives_box": lives_box,
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
		var lives_box: HBoxContainer = row["lives_box"]
		if is_instance_valid(lives_box):
			_set_hearts(lives_box, max(lives, 0), 11.0)

		# Kills
		var kills: int = game_manager.kills.get(pid, 0)
		var kills_lbl: Label = row["kills_lbl"]
		if is_instance_valid(kills_lbl):
			kills_lbl.text = "K:%d" % kills

		# Voice icon
		var voice_icon: TextureRect = row["voice_lbl"]
		if is_instance_valid(voice_icon):
			voice_icon.visible = _speaking_pids.get(pid, false)

func _on_player_speaking_changed(pid: int, speaking: bool) -> void:
	_speaking_pids[pid] = speaking
	# Brighten the local player's mic button while transmitting — an always-visible
	# speaking indicator (the scoreboard speaker icon covers remote peers).
	if player != null and pid == player.peer_id and is_instance_valid(_voice_btn):
		_voice_btn.modulate = Color(1.4, 1.4, 1.4) if speaking else Color(1, 1, 1)

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

	_kills_label.text = "Kills: %d   Lives:" % my_k
	_set_hearts(_lives_box, my_l, 20.0)
	_wins_label.text  = "(first to %d wins)" % Config.KILLS_TO_WIN

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
		if _trap_nd != null:
			_trap_nd.modulate = Config.TRAP_COLORS[player.held_trap]
	else:
		_trap_label.text = "No trap  (walk over a glowing box to pick one up)"
		_trap_label.add_theme_color_override("font_color", Color.GRAY)
		if _trap_nd != null:
			_trap_nd.modulate = Color(1, 1, 1, 0.40)

	# (gun state now shown on the Select button instead of a HUD label)

	var fx_text = ""
	for eff in game_manager.effects.get(pid, {}).keys():
		var remaining = snappedf(game_manager.effects[pid][eff], 0.1)
		fx_text += "  [%s %.1fs]" % [eff.to_upper(), remaining]
	_effects_label.text = fx_text

	if _net != null and not multiplayer.is_server():
		var ms = _net.ping_ms
		_ping_label.text = "• %d ms" % ms
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

	# Other players first, then the local player on top.
	for opp in get_tree().get_nodes_in_group("players"):
		if opp == player or not is_instance_valid(opp): continue
		var idx = opp.get("player_index") if opp.get("player_index") != null else 1
		var col = Config.PLAYER_COLORS[idx % Config.PLAYER_COLORS.size()]
		var oyaw: float = opp.get("yaw") if opp.get("yaw") != null else 0.0
		_mm_arrow(opp.position, oyaw, col, 5.0)

	if player != null:
		_mm_arrow(player.position, player.yaw, Color.CYAN, 6.5)

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

# Draw a player as a triangle pointing in their facing direction. Position comes
# from the world transform (sub-cell precision); facing from yaw. Player forward
# in world is (-sin(yaw), -cos(yaw)) on the (x, z) plane, which maps directly to
# the minimap's (x, y) axes.
func _mm_arrow(wpos: Vector3, yaw: float, col: Color, size: float) -> void:
	var w := _mm_image.get_width(); var h := _mm_image.get_height()
	var cs: float = Config.CELL_SIZE
	var c  := Vector2((wpos.x / cs) * MM_CELL, (wpos.z / cs) * MM_CELL)
	var d  := Vector2(-sin(yaw), -cos(yaw))
	if d.length() < 0.001: d = Vector2(0, -1)
	d = d.normalized()
	var perp  := Vector2(-d.y, d.x)
	var tip   := c + d * size
	var back  := c - d * (size * 0.55)
	var left  := back + perp * (size * 0.62)
	var right := back - perp * (size * 0.62)
	var minx := int(floor(min(tip.x, min(left.x, right.x))))
	var maxx := int(ceil( max(tip.x, max(left.x, right.x))))
	var miny := int(floor(min(tip.y, min(left.y, right.y))))
	var maxy := int(ceil( max(tip.y, max(left.y, right.y))))
	for py in range(miny, maxy + 1):
		for px in range(minx, maxx + 1):
			if px < 0 or px >= w or py < 0 or py >= h: continue
			if _point_in_tri(Vector2(px + 0.5, py + 0.5), tip, left, right):
				_mm_image.set_pixel(px, py, col)

func _point_in_tri(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> bool:
	var d1: float = (p.x - b.x) * (a.y - b.y) - (a.x - b.x) * (p.y - b.y)
	var d2: float = (p.x - c.x) * (b.y - c.y) - (b.x - c.x) * (p.y - c.y)
	var d3: float = (p.x - a.x) * (c.y - a.y) - (c.x - a.x) * (p.y - a.y)
	var has_neg: bool = d1 < 0.0 or d2 < 0.0 or d3 < 0.0
	var has_pos: bool = d1 > 0.0 or d2 > 0.0 or d3 > 0.0
	return not (has_neg and has_pos)

# ── Exit / leave-match ─────────────────────────────────────────────────────────
func _build_exit_button() -> void:
	_exit_btn = Button.new()
	_exit_btn.text = "X Exit"
	_exit_btn.add_theme_font_size_override("font_size", 16)
	_exit_btn.add_theme_color_override("font_color", Color.WHITE)
	var sb = StyleBoxFlat.new()
	sb.bg_color      = Color(0.55, 0.12, 0.12, 0.85)
	sb.border_color  = Color(1.0, 0.45, 0.45, 0.90)
	sb.set_border_width_all(2); sb.set_corner_radius_all(6)
	_exit_btn.add_theme_stylebox_override("normal",  sb)
	_exit_btn.add_theme_stylebox_override("hover",   sb)
	_exit_btn.add_theme_stylebox_override("pressed", sb)
	_exit_btn.anchor_left   = 1.0; _exit_btn.anchor_right  = 1.0
	_exit_btn.anchor_top    = 0.0; _exit_btn.anchor_bottom = 0.0
	_exit_btn.offset_left   = -96; _exit_btn.offset_right  = -8
	_exit_btn.offset_top    = 8;   _exit_btn.offset_bottom = 48
	_exit_btn.pressed.connect(_on_exit_pressed)
	add_child(_exit_btn)

	_build_exit_overlay()

# In-canvas confirmation built from Control nodes (NOT a ConfirmationDialog, whose
# embedded-subwindow buttons don't reliably receive touch / emulated-mouse input on
# mobile web — tapping Stay/Leave did nothing). Plain Buttons in the CanvasLayer get
# input exactly like the on-screen action buttons, so their `pressed` always fires.
func _build_exit_overlay() -> void:
	_exit_overlay = Control.new()
	_exit_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_exit_overlay.mouse_filter = Control.MOUSE_FILTER_STOP   # absorb taps outside the panel
	_exit_overlay.visible = false
	add_child(_exit_overlay)

	var dim = ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.62)
	_exit_overlay.add_child(dim)

	var panel = Panel.new()
	panel.anchor_left = 0.5; panel.anchor_right  = 0.5
	panel.anchor_top  = 0.5; panel.anchor_bottom = 0.5
	panel.offset_left = -210; panel.offset_right  = 210
	panel.offset_top  = -115; panel.offset_bottom = 115
	var psb = StyleBoxFlat.new()
	psb.bg_color     = Color(0.10, 0.11, 0.15, 0.98)
	psb.border_color = Color(1.0, 0.45, 0.45, 0.90)
	psb.set_border_width_all(2); psb.set_corner_radius_all(10)
	panel.add_theme_stylebox_override("panel", psb)
	_exit_overlay.add_child(panel)

	var msg = Label.new()
	msg.text = "Leave the match and return to the menu?"
	msg.add_theme_font_size_override("font_size", 20)
	msg.add_theme_color_override("font_color", Color.WHITE)
	msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	msg.anchor_left = 0.0; msg.anchor_right  = 1.0
	msg.offset_left = 20;  msg.offset_right  = -20
	msg.offset_top  = 26;  msg.offset_bottom = 120
	panel.add_child(msg)

	var stay_btn = _mk_confirm_btn("Stay", Color(0.20, 0.40, 0.72))
	stay_btn.anchor_left = 0.0; stay_btn.anchor_right  = 0.5
	stay_btn.anchor_top  = 1.0; stay_btn.anchor_bottom = 1.0
	stay_btn.offset_left = 22; stay_btn.offset_right  = -11
	stay_btn.offset_top  = -74; stay_btn.offset_bottom = -22
	stay_btn.pressed.connect(_on_exit_stay)
	panel.add_child(stay_btn)

	var leave_btn = _mk_confirm_btn("Leave", Color(0.68, 0.18, 0.18))
	leave_btn.anchor_left = 0.5; leave_btn.anchor_right  = 1.0
	leave_btn.anchor_top  = 1.0; leave_btn.anchor_bottom = 1.0
	leave_btn.offset_left = 11; leave_btn.offset_right  = -22
	leave_btn.offset_top  = -74; leave_btn.offset_bottom = -22
	leave_btn.pressed.connect(_do_exit)
	panel.add_child(leave_btn)

func _mk_confirm_btn(txt: String, col: Color) -> Button:
	var b = Button.new()
	b.text = txt
	b.add_theme_font_size_override("font_size", 22)
	b.add_theme_color_override("font_color", Color.WHITE)
	var sb = StyleBoxFlat.new()
	sb.bg_color     = col
	sb.border_color = col.lightened(0.25)
	sb.set_border_width_all(2); sb.set_corner_radius_all(8)
	b.add_theme_stylebox_override("normal",  sb)
	b.add_theme_stylebox_override("hover",   sb)
	b.add_theme_stylebox_override("pressed", sb.duplicate())
	return b

func _on_exit_pressed() -> void:
	if _exit_overlay == null: return
	# Free the cursor so the buttons are clickable on desktop (mouse is captured
	# during play); on web/mobile the cursor is already free.
	if not OS.has_feature("web"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_exit_overlay.visible = true

func _on_exit_stay() -> void:
	if _exit_overlay: _exit_overlay.visible = false
	if not OS.has_feature("web"):
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _do_exit() -> void:
	if multiplayer.has_multiplayer_peer():
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null  # stop peer_left(-1) from double-reloading
	get_tree().paused = false
	# change_scene_to_file deferred: gives signal handlers a frame to finish before
	# the scene tree is torn down, and is more reliable than reload_current_scene()
	# on mobile web where the current-scene path can be stale in the web runner.
	get_tree().call_deferred("change_scene_to_file", "res://scenes/Main.tscn")

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
		var idx: int = game_manager.player_ids.find(wpid)
		var wname: String
		if _net != null and _net.player_names.has(wpid):
			wname = _net.player_names[wpid]
		elif wpid == 0:
			wname = "Robot AI"
		else:
			wname = "Player %d" % (idx + 1)
		_overlay_label.text = "YOU LOSE!\n\n%s wins" % wname
		_overlay_label.add_theme_color_override("font_color", Color(0.95, 0.15, 0.15))

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
	if not _is_mobile_device(): return

	# On touch-capable laptops the device reports as "touch" (so player.gd ignores
	# the mouse), yet the user may still drive the on-screen controls with a mouse
	# or trackpad. Emulating touch from the mouse lets a click+drag on the fire
	# button both fire AND turn — exactly the same code path as a real finger.
	Input.set_emulate_touch_from_mouse(true)

	const FSZ := 92.0    # fire button diameter (smaller — less screen clutter)
	const TSZ :=  68.0   # trap button diameter
	const MG  :=  20     # screen-edge margin
	const ACT_ANCHOR := 0.66   # vertical anchor for action buttons (raised a bit)

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

	# FIRE button — bullet icon, centred at 75% from left
	_fire_nd = _action_image_button(FSZ, "res://assets/icons/icon_bullet.svg")
	_fire_nd.anchor_left   = 0.75; _fire_nd.anchor_right  = 0.75
	_fire_nd.anchor_top    = ACT_ANCHOR; _fire_nd.anchor_bottom = ACT_ANCHOR
	_fire_nd.offset_left   = -FSZ * 0.5; _fire_nd.offset_right  = FSZ * 0.5
	_fire_nd.offset_top    = -FSZ * 0.5; _fire_nd.offset_bottom = FSZ * 0.5
	add_child(_fire_nd)

	# JUMP button — right column, at fire level (bottom of the action stack)
	# Tap to jump; positioned beside the fire button so it's easy to reach.
	const JZ := 60.0
	_jump_nd = _action_image_button(JZ, "res://assets/icons/icon_jump.svg")
	_jump_nd.anchor_left   = 1.0; _jump_nd.anchor_right  = 1.0
	_jump_nd.anchor_top    = ACT_ANCHOR; _jump_nd.anchor_bottom = ACT_ANCHOR
	_jump_nd.offset_left   = -(JZ + MG); _jump_nd.offset_right  = -MG
	_jump_nd.offset_top    = -(JZ * 0.5); _jump_nd.offset_bottom = JZ * 0.5
	add_child(_jump_nd)

	# TRAP button — above jump button, right column
	_trap_nd = _action_image_button(TSZ, "res://assets/icons/icon_bomb.svg")
	_trap_nd.anchor_left   = 1.0; _trap_nd.anchor_right  = 1.0
	_trap_nd.anchor_top    = ACT_ANCHOR; _trap_nd.anchor_bottom = ACT_ANCHOR
	_trap_nd.offset_left   = -(TSZ + MG); _trap_nd.offset_right  = -MG
	_trap_nd.offset_top    = -(JZ * 0.5 + MG + TSZ); _trap_nd.offset_bottom = -(JZ * 0.5 + MG)
	add_child(_trap_nd)


# Mic mute/unmute toggle. Built for every multiplayer client (desktop + mobile
# web), not just touch — on desktop you can also press V. Placed on the mid-left
# edge so it never overlaps the top-right scoreboard or the bottom-right action
# cluster. The button brightens while you are actually transmitting (VAD), so it
# doubles as your own speaking indicator.
func _build_voice_button() -> void:
	if not multiplayer.has_multiplayer_peer(): return
	var vm = get_parent().get_node_or_null("VoiceManager") as VoiceManager
	if vm == null: return

	const VSZ := 60.0
	const VMG := 14.0
	_voice_btn = Button.new()
	var vsb = StyleBoxFlat.new()
	vsb.bg_color     = Color(0.20, 0.68, 0.36, 0.85)
	vsb.border_color = Color(0.55, 1.0, 0.65, 0.90)
	vsb.set_border_width_all(2); vsb.set_corner_radius_all(int(VSZ * 0.5))
	_voice_btn.add_theme_stylebox_override("normal",  vsb)
	_voice_btn.add_theme_stylebox_override("hover",   vsb)
	_voice_btn.add_theme_stylebox_override("pressed", vsb.duplicate())
	# Mid-right edge, vertically centred a little above middle.
	_voice_btn.anchor_left  = 1.0; _voice_btn.anchor_right  = 1.0
	_voice_btn.anchor_top   = 0.42; _voice_btn.anchor_bottom = 0.42
	_voice_btn.offset_left  = -(VMG + VSZ); _voice_btn.offset_right  = -VMG
	_voice_btn.offset_top   = -VSZ * 0.5;   _voice_btn.offset_bottom = VSZ * 0.5
	add_child(_voice_btn)

	# Mic / mute icon centred on the button (swapped by VoiceManager on toggle).
	_voice_icon = TextureRect.new()
	_voice_icon.texture      = MIC_TEX
	_voice_icon.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
	_voice_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_voice_icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	_voice_icon.offset_left = 15; _voice_icon.offset_top    = 15
	_voice_icon.offset_right = -15; _voice_icon.offset_bottom = -15
	_voice_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_voice_btn.add_child(_voice_icon)

	_voice_btn.pressed.connect(func():
		if vm._transmitting: vm.mute()
		else:                vm.unmute())
	vm.voice_button      = _voice_btn
	vm.voice_button_icon = _voice_icon

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

# Build/refresh a row of heart icons to match `count`. Lives are drawn as SVG
# textures because the ♥ glyph is absent from the default font (it renders as a
# missing-glyph box on the web build). Only rebuilds when the count changes.
func _set_hearts(box: HBoxContainer, count: int, px: float) -> void:
	if box == null: return
	var cur: int = int(box.get_meta("hearts", -1))
	if cur == count: return
	box.set_meta("hearts", count)
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()
	for i in count:
		var tr = TextureRect.new()
		tr.texture = HEART_TEX
		tr.custom_minimum_size = Vector2(px, px)
		tr.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.modulate     = HEART_COLOR
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(tr)

# ── Inventory bar (bottom centre, always visible) ────────────────────────────
var _select_btn:      Button      = null
var _active_icon:     TextureRect = null   # gun icon (right half of preview)
var _active_label:    Label       = null   # trap name (left half of preview)
var _active_trap_dot: ColorRect   = null   # trap colour dot (left half)
var _weapon_wheel:    WeaponWheel = null
var _wheel_open_by_key: bool      = false

func _build_inventory_bar() -> void:
	if player == null: return

	const BTN_SIZE := 90.0
	const MG := 30.0   # bottom margin (above hint label)

	_inv_bar = Control.new()
	_inv_bar.anchor_left   = 0.5; _inv_bar.anchor_right  = 0.5
	_inv_bar.anchor_top    = 1.0; _inv_bar.anchor_bottom = 1.0
	_inv_bar.offset_left   = -BTN_SIZE * 0.5
	_inv_bar.offset_right  =  BTN_SIZE * 0.5
	_inv_bar.offset_top    = -(BTN_SIZE + MG)
	_inv_bar.offset_bottom = -MG
	add_child(_inv_bar)

	_select_btn = Button.new()
	_select_btn.text = "Select"
	_select_btn.position = Vector2(0, 0)
	_select_btn.size     = Vector2(BTN_SIZE, BTN_SIZE)
	_select_btn.pressed.connect(_open_wheel)
	_build_button_style(_select_btn)
	_inv_bar.add_child(_select_btn)

	# Active-item preview above button: left = trap, right = gun.
	# No boxed background — the icon + trap dot/name float directly on the HUD
	# (like the action buttons) so the equipped items read at a glance.
	const PREVIEW_H := 52.0
	const HALF      := BTN_SIZE * 0.5
	var preview_panel := Control.new()
	preview_panel.position = Vector2(0, -(PREVIEW_H + 6))
	preview_panel.size     = Vector2(BTN_SIZE, PREVIEW_H)
	preview_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_inv_bar.add_child(preview_panel)

	# Trap section – left half: coloured dot + name
	_active_trap_dot = ColorRect.new()
	_active_trap_dot.size = Vector2(10, 10)
	_active_trap_dot.position = Vector2(6, 8)
	_active_trap_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_active_trap_dot.visible = false
	preview_panel.add_child(_active_trap_dot)

	_active_label = Label.new()
	_active_label.position = Vector2(2, 20)
	_active_label.size = Vector2(HALF - 4, PREVIEW_H - 22)
	_active_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_active_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_active_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_active_label.add_theme_font_size_override("font_size", 11)
	_active_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_active_label.add_theme_constant_override("shadow_offset_x", 1)
	_active_label.add_theme_constant_override("shadow_offset_y", 1)
	_active_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_active_label.visible = false
	preview_panel.add_child(_active_label)

	# Gun section – right half: gun icon
	_active_icon = TextureRect.new()
	_active_icon.expand_mode  = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	_active_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_active_icon.position = Vector2(HALF + 2, 4)
	_active_icon.size = Vector2(HALF - 6, PREVIEW_H - 8)
	_active_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_active_icon.visible = false
	preview_panel.add_child(_active_icon)

	# Weapon wheel overlay
	_weapon_wheel = WeaponWheel.new()
	_weapon_wheel.player = player
	_weapon_wheel.slot_selected.connect(_on_wheel_slot_selected)
	add_child(_weapon_wheel)

func _build_button_style(btn: Button) -> void:
	btn.flat = false
	var sb = StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.05, 0.10, 0.80)
	sb.border_color = Color(0.4, 0.4, 0.4, 0.80)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	btn.add_theme_stylebox_override("normal", sb)
	btn.add_theme_stylebox_override("hover", sb)
	btn.add_theme_stylebox_override("pressed", sb)
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	btn.add_theme_font_size_override("font_size", 16)

func _open_wheel() -> void:
	if _weapon_wheel == null or not game_manager.is_playing: return
	if _weapon_wheel.visible:
		_weapon_wheel.close(false)
	else:
		_weapon_wheel.open()

func _on_wheel_slot_selected(is_gun: bool, slot_idx: int) -> void:
	if player == null: return
	if is_gun:
		player.active_gun_slot = slot_idx
		player._rebuild_viewmodel()
	else:
		player.active_trap_slot = slot_idx

func _update_inventory_bar() -> void:
	if _select_btn == null or player == null:
		return
	if _weapon_wheel != null and _weapon_wheel.visible and not game_manager.is_playing:
		_weapon_wheel.close(false)

	# Active-item preview: gun (right) and trap (left) shown simultaneously
	if _active_icon != null and _active_label != null and _active_trap_dot != null:
		var gtype: int = player.gun_type
		var htrap: int = player.held_trap
		# Gun side (right half)
		if gtype >= 0 and gtype < GUN_ICONS.size():
			_active_icon.texture = load(GUN_ICONS[gtype])
			_active_icon.visible = true
		else:
			_active_icon.texture = null
			_active_icon.visible = false
		# Trap side (left half)
		if htrap >= 0:
			var tcol: Color = Config.TRAP_COLORS.get(htrap, Color.WHITE)
			_active_trap_dot.color = tcol
			_active_trap_dot.visible = true
			_active_label.text = Config.TRAP_NAMES.get(htrap, "?")
			_active_label.add_theme_color_override("font_color", tcol.lightened(0.4))
			_active_label.visible = true
		else:
			_active_trap_dot.visible = false
			_active_label.visible = false


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
	if event is InputEventKey and not event.echo:
		if event.keycode == KEY_R and event.pressed:
			get_tree().reload_current_scene()
		elif event.keycode == KEY_ESCAPE and event.pressed:
			_on_exit_pressed()
		elif event.keycode == KEY_G:
			# Hold G to open wheel, release to close & apply
			if event.pressed and _weapon_wheel != null and not _weapon_wheel.visible:
				_wheel_open_by_key = true
				_open_wheel()
			elif not event.pressed and _wheel_open_by_key:
				_wheel_open_by_key = false
				if _weapon_wheel != null and _weapon_wheel.visible:
					_weapon_wheel.close(true)

	# Touch controls
	if not _is_mobile_device(): return
	if player == null or not game_manager.is_playing: return

	# While the leave-match confirm is open, let touches reach its Stay/Leave
	# buttons instead of being captured for look / joystick / fire.
	if _exit_overlay != null and _exit_overlay.visible:
		return

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
					_look_prev_fire = pos   # seed drag tracking for turn-while-firing
					_fire_nd.modulate = Color(1.5, 1.5, 1.5)
					player._fire_gun()
					get_viewport().set_input_as_handled()
					return
				if _trap_nd != null and _trap_nd.get_global_rect().has_point(pos) and _trap_id == -1:
					_trap_id = event.index
					_look_prev_trap = pos
					_trap_nd.modulate = Color(1.5, 1.5, 1.5)
					player._begin_trap_aim()   # show arc; drag to aim, release to throw
					get_viewport().set_input_as_handled()
					return
				if _jump_nd != null and _jump_nd.get_global_rect().has_point(pos) and _jump_id == -1:
					_jump_id = event.index
					_jump_nd.modulate = Color(1.5, 1.5, 1.5)
					player.do_jump()
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
				player._release_trap_aim()   # throws at the aimed cell
				get_viewport().set_input_as_handled()
			elif event.index == _jump_id:
				_jump_id = -1
				if _jump_nd: _jump_nd.modulate = Color(1, 1, 1)
				get_viewport().set_input_as_handled()

	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		var dpos: Vector2 = drag.position
		# Button-anchored turn/aim drags stay keyed to their own finger index.
		if event.index == _fire_id:
			_apply_turn(dpos - _look_prev_fire)
			_look_prev_fire = dpos
			get_viewport().set_input_as_handled()
		elif event.index == _trap_id:
			_apply_turn(dpos - _look_prev_trap)
			_look_prev_trap = dpos
			get_viewport().set_input_as_handled()
		# Joystick (move) and look (turn) are routed by SCREEN REGION, not by the
		# touch index. Godot HTML5 multi-touch can deliver a drag under the OTHER
		# finger index when two fingers are down (godot #94346 / #33470), so a
		# left-side joystick drag could arrive tagged with the look index and spin
		# the camera -- the chaotic movement when you hold look (right) then drag to
		# move (left). Routing by position is immune to that index swap.
		elif _joy_id != -1 and dpos.x < vp_hw:
			_joy_update(dpos)
			get_viewport().set_input_as_handled()
		elif _look_id != -1 and dpos.x >= vp_hw:
			_apply_turn(dpos - _look_prev)
			_look_prev = dpos
			get_viewport().set_input_as_handled()

func _apply_turn(delta: Vector2) -> void:
	if player == null:
		return
	# Gain 2.6: a short swipe turns a useful amount without feeling twitchy.
	# Delta comes from tracked positions (never drag.relative, which Godot
	# inflates with a second finger down); clamp guards a coalesced lump.
	var sens: float = player.mouse_sensitivity * 2.6
	var dx := clampf(delta.x, -60.0, 60.0)
	var dy := clampf(delta.y, -60.0, 60.0)
	player._pending_yaw_delta -= dx * sens
	player.pitch = clamp(player.pitch - dy * sens, -PI / 3.0, PI / 3.0)
	if player.camera_node:
		player.camera_node.rotation.x = player.pitch


# Move the knob toward `pos` (clamped to ring) and update the strafe vector.
func _joy_update(pos: Vector2) -> void:
	if _joy_base_nd == null or player == null: return
	# Guard: Godot multi-touch can fire a drag event with the joystick's index but
	# with the look-drag position (right side of screen). Clamping to the left half
	# prevents that wrong-position from driving touch_move_x all the way to +1.
	var vp_hw: float = get_viewport().get_visible_rect().size.x * 0.5
	if pos.x > vp_hw:
		return
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
