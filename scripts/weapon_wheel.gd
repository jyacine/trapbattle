extends Control

class_name WeaponWheel

# Emitted when user confirms a selection; consumer applies it to the player.
signal slot_selected(is_gun: bool, slot_index: int)

var player: Player = null

# ── Layout ────────────────────────────────────────────────────────────────────
const OUTER_R      := 205.0
const INNER_R      := 82.0
const MID_R        := 143.5   # (OUTER_R + INNER_R) * 0.5
const ICON_SZ      := 52.0
const ARC_STEPS    := 36      # polygon resolution per segment

# Segment centre angles (radians; 0 = right, positive = clockwise in screen coords)
# Guns  → right half:  upper-right, right, lower-right
# Traps → left half:   lower-left,  left,  upper-left
const GUN_ANGLES  : Array = [-PI / 3.0,       0.0,  PI / 3.0      ]
const TRAP_ANGLES : Array = [ PI * 2.0 / 3.0, PI,  -PI * 2.0 / 3.0]
const SEG_HALF    := PI / 3.0 * 0.88 / 2.0   # half-span; leaves ~12% gaps

const GUN_ICON_PATHS : Array = [
	"res://assets/icons/icon_gun.svg",
	"res://assets/icons/icon_shotgun.svg",
	"res://assets/icons/icon_machinegun.svg",
	"res://assets/icons/icon_stove.svg",
]

# ── State ─────────────────────────────────────────────────────────────────────
var _hovered  : int     = -1   # 0-2 = gun slots, 3-5 = trap slots, -1 = none
var _tex_cache: Dictionary = {}

# ── Children ──────────────────────────────────────────────────────────────────
var _lbl_center : Label = null
var _lbl_guns   : Label = null
var _lbl_traps  : Label = null

# ────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	get_tree().root.size_changed.connect(_on_viewport_resized)

func _on_viewport_resized() -> void:
	if visible:
		size = get_viewport().get_visible_rect().size
		queue_redraw()

	_lbl_center = _make_lbl(22, Color.WHITE)
	_lbl_center.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lbl_center.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	add_child(_lbl_center)

	_lbl_guns  = _make_lbl(13, Color(0.6, 0.85, 1.0))
	_lbl_guns.text = "GUNS"
	add_child(_lbl_guns)

	_lbl_traps = _make_lbl(13, Color(1.0, 0.75, 0.35))
	_lbl_traps.text = "TRAPS"
	add_child(_lbl_traps)

func _make_lbl(sz: int, col: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", sz)
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("shadow_offset_x", 2)
	l.add_theme_constant_override("shadow_offset_y", 2)
	return l

# ── Public API ────────────────────────────────────────────────────────────────
func open() -> void:
	# A Control added to a CanvasLayer doesn't inherit the viewport size
	# automatically until layout runs; force it here so size * 0.5 is the
	# actual screen centre when _draw() and _process() run immediately.
	var vp_size: Vector2 = get_viewport().get_visible_rect().size
	position = Vector2.ZERO
	size     = vp_size
	_hovered = -1
	visible  = true
	queue_redraw()

func close(apply: bool) -> void:
	if apply and _hovered >= 0:
		emit_signal("slot_selected", _hovered < 3, _hovered % 3)
	visible = false

# ── Per-frame ─────────────────────────────────────────────────────────────────
func _process(_dt: float) -> void:
	if not visible or player == null: return

	var c   : Vector2 = size * 0.5
	var mouse: Vector2 = get_local_mouse_position()
	var d   : Vector2 = mouse - c
	var dist: float   = d.length()
	var prev: int     = _hovered

	if dist >= INNER_R and dist <= OUTER_R:
		_hovered = _angle_to_slot(atan2(d.y, d.x))
	else:
		_hovered = -1

	# Position side labels
	_lbl_guns.position  = c + Vector2(OUTER_R * 0.55,  -OUTER_R * 0.92) - Vector2(20, 8)
	_lbl_traps.position = c + Vector2(-OUTER_R * 0.78, -OUTER_R * 0.92) - Vector2(20, 8)

	# Position + size centre label
	_lbl_center.position = c - Vector2(INNER_R * 0.9, INNER_R * 0.9)
	_lbl_center.size     = Vector2(INNER_R * 1.8, INNER_R * 1.8)

	if _hovered != prev:
		_update_center_label()
		queue_redraw()

func _input(event: InputEvent) -> void:
	if not visible: return
	if not (event is InputEventMouseButton) or not event.pressed: return
	if event.button_index == MOUSE_BUTTON_LEFT:
		# Re-derive the hovered slot from the exact click position so there is
		# no one-frame lag between mouse move and click.
		var mouse: Vector2 = get_viewport().get_mouse_position()
		var c    : Vector2 = size * 0.5
		var d    : Vector2 = mouse - c
		var dist : float   = d.length()
		if dist >= INNER_R and dist <= OUTER_R:
			_hovered = _angle_to_slot(atan2(d.y, d.x))
		else:
			_hovered = -1
		close(true)
	elif event.button_index == MOUSE_BUTTON_RIGHT:
		close(false)
	get_viewport().set_input_as_handled()

# ── Drawing ───────────────────────────────────────────────────────────────────
func _draw() -> void:
	if player == null: return
	var c: Vector2 = size * 0.5

	# Full-screen dim
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.50))

	for i in 6:
		var is_gun : bool  = (i < 3)
		var slot   : int   = i % 3
		var ang    : float = GUN_ANGLES[slot] if is_gun else TRAP_ANGLES[slot]

		var has_item  : bool = false
		var is_active : bool = false
		var icon_path : String = ""

		if is_gun:
			has_item  = slot < player.gun_inventory.size() and player.gun_inventory[slot] >= 0
			is_active = slot == player.active_gun_slot
			if has_item:
				var gtype: int = player.gun_inventory[slot]
				if gtype < GUN_ICON_PATHS.size():
					icon_path = GUN_ICON_PATHS[gtype]
		else:
			has_item  = player.trap_inventory[slot] >= 0
			is_active = slot == player.active_trap_slot

		# Segment colour
		var col: Color
		if i == _hovered:
			col = Color(0.85, 0.12, 0.10, 0.92)
		elif is_active and has_item:
			col = Color(0.15, 0.42, 0.82, 0.88)
		elif has_item:
			col = Color(0.16, 0.20, 0.27, 0.84)
		else:
			col = Color(0.09, 0.10, 0.13, 0.68)

		_draw_segment(c, INNER_R, OUTER_R, ang - SEG_HALF, ang + SEG_HALF, col)

		# Segment border highlight when active or hovered
		if i == _hovered or (is_active and has_item):
			var bcol := Color(1, 1, 1, 0.30) if (is_active and has_item) else Color(1, 0.25, 0.25, 0.55)
			_draw_segment(c, INNER_R + 2, INNER_R + 5, ang - SEG_HALF, ang + SEG_HALF, bcol)
			_draw_segment(c, OUTER_R - 5, OUTER_R - 2, ang - SEG_HALF, ang + SEG_HALF, bcol)

		# Gun icon
		if icon_path != "":
			var tex: Texture2D = _get_tex(icon_path)
			if tex:
				var ip: Vector2 = c + Vector2(cos(ang), sin(ang)) * MID_R
				draw_texture_rect(tex,
					Rect2(ip - Vector2(ICON_SZ, ICON_SZ) * 0.5, Vector2(ICON_SZ, ICON_SZ)),
					false, Color(1, 1, 1, 0.92))

		# Trap: coloured circle + slot number (no per-trap icons yet)
		elif not is_gun:
			var ip: Vector2 = c + Vector2(cos(ang), sin(ang)) * MID_R
			if has_item:
				var ttype: int  = player.trap_inventory[slot]
				var tcol : Color = Config.TRAP_COLORS.get(ttype, Color.WHITE)
				draw_circle(ip, 22, tcol.darkened(0.35))
				draw_arc(ip, 22, 0, TAU, 32, tcol, 2.5)
			else:
				draw_circle(ip, 22, Color(0.18, 0.18, 0.22, 0.6))
				draw_arc(ip, 22, 0, TAU, 32, Color(0.35, 0.35, 0.4, 0.5), 1.5)

	# Inner dark circle
	draw_circle(c, INNER_R, Color(0.04, 0.05, 0.08, 0.94))
	draw_arc(c, INNER_R, 0, TAU, 64, Color(0.30, 0.32, 0.40, 0.65), 2.0)

func _draw_segment(c: Vector2, r_in: float, r_out: float, a0: float, a1: float, col: Color) -> void:
	var pts: PackedVector2Array = PackedVector2Array()
	for i in range(ARC_STEPS + 1):
		var a: float = lerpf(a0, a1, float(i) / ARC_STEPS)
		pts.append(c + Vector2(cos(a), sin(a)) * r_out)
	for i in range(ARC_STEPS + 1):
		var a: float = lerpf(a1, a0, float(i) / ARC_STEPS)
		pts.append(c + Vector2(cos(a), sin(a)) * r_in)
	var cols: PackedColorArray = PackedColorArray()
	cols.resize(pts.size())
	cols.fill(col)
	draw_polygon(pts, cols)

func _angle_to_slot(a: float) -> int:
	for i in 3:
		if absf(angle_difference(a, GUN_ANGLES[i])) < PI / 3.0 * 0.52:
			return i
	for i in 3:
		if absf(angle_difference(a, TRAP_ANGLES[i])) < PI / 3.0 * 0.52:
			return i + 3
	return -1

func _update_center_label() -> void:
	if _lbl_center == null: return
	if _hovered < 0 or player == null:
		_lbl_center.text = ""
		return
	var is_gun : bool = _hovered < 3
	var slot   : int  = _hovered % 3
	if is_gun:
		if slot < player.gun_inventory.size() and player.gun_inventory[slot] >= 0:
			var gtype: int = player.gun_inventory[slot]
			var ammo : int = player.gun_ammo_inventory[slot]
			var ammo_str: String = str(ammo) if ammo >= 0 else "∞"
			_lbl_center.text = "%s\n%s ammo" % [Config.GUN_NAMES.get(gtype, "?"), ammo_str]
		else:
			_lbl_center.text = "Empty\ngun slot"
	else:
		if player.trap_inventory[slot] >= 0:
			_lbl_center.text = Config.TRAP_NAMES.get(player.trap_inventory[slot], "?")
		else:
			_lbl_center.text = "Empty\ntrap slot"

func _get_tex(path: String) -> Texture2D:
	if not _tex_cache.has(path):
		_tex_cache[path] = load(path)
	return _tex_cache[path]
