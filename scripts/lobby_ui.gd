extends CanvasLayer
class_name LobbyUI

signal start_game(seed_val: int, is_mp: bool)

var _net: NetworkManager

# Menu controls (hidden when entering lobby)
var _status:          Label
var _ip_field:        LineEdit
var _name_field:      LineEdit
var _color_btns:      Array = []
var _selected_color:  int   = 0
var _default_name:    String = ""
var _menu_nodes:      Array = []

# Lobby overlay controls (shown after connecting)
var _player_list:      Label = null
var _countdown_label:  Label = null
var _ping_label:       Label = null
var _start_btn:        Button = null

# 3-D lobby room added to parent scene
var _lobby_room: LobbyRoom = null

# Countdown state (each client tracks locally; host triggers the actual start)
var _countdown: float = 15.0
var _counting:  bool  = false

# True on a touch phone/tablet running the web build. There the Godot canvas can't
# raise the browser soft keyboard for a LineEdit, so text fields are edited through
# a native window.prompt() instead (see _prompt_edit).
var _mobile_web: bool = false
var _last_prompt_ms: int = 0   # debounce duplicate tap → prompt (touch + emulated mouse)

# ────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	_net = get_parent().get_node("NetworkManager")
	_net.lobby_ready.connect(_on_lobby_ready)
	_net.lobby_updated.connect(_on_lobby_updated)
	_net.connected.connect(_on_connected)
	_mobile_web = OS.has_feature("web") and UIManager._is_mobile_device()
	_build_menu()

func _process(delta: float) -> void:
	if _ping_label and _ping_label.visible:
		var ms = _net.ping_ms
		_ping_label.text = "● %d ms" % ms
		var col: Color
		if ms < 50:
			col = Color(0.2, 1.0, 0.2)
		elif ms < 150:
			col = Color(1.0, 0.85, 0.1)
		else:
			col = Color(1.0, 0.25, 0.25)
		_ping_label.add_theme_color_override("font_color", col)

	if not _counting:
		return
	_countdown -= delta
	if _countdown_label:
		var secs = int(ceil(_countdown))
		_countdown_label.text = "Game starts in  %d s" % secs
		var urgent = secs <= 10
		_countdown_label.add_theme_color_override(
			"font_color",
			Color(1.0, 0.28, 0.28) if urgent else Color(0.7, 0.88, 1.0)
		)
	if _countdown <= 0.0:
		_counting = false
		if _net.is_captain:
			_net.request_start()

# ── Initial menu screen ──────────────────────────────────────────────────────
func _build_menu() -> void:
	var bg = ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.05, 0.05, 0.10, 1.0)
	add_child(bg)
	_menu_nodes.append(bg)

	var title = Label.new()
	title.text = "TRAPBATTLE"
	title.add_theme_font_size_override("font_size", 60)
	title.add_theme_color_override("font_color", Color.YELLOW)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.anchor_left = 0.0; title.anchor_right = 1.0
	title.anchor_top = 0.5;  title.anchor_bottom = 0.5
	title.offset_top = -250; title.offset_bottom = -160
	add_child(title)
	_menu_nodes.append(title)

	var sub = Label.new()
	sub.text = "First-person maze trap battle  —  up to 10 players"
	sub.add_theme_font_size_override("font_size", 18)
	sub.add_theme_color_override("font_color", Color(0.7, 0.7, 0.8))
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.anchor_left = 0.0; sub.anchor_right = 1.0
	sub.anchor_top = 0.5;  sub.anchor_bottom = 0.5
	sub.offset_top = -148; sub.offset_bottom = -110
	add_child(sub)
	_menu_nodes.append(sub)

	var btn_sp = _mk_btn("SINGLE PLAYER  (vs Robot AI)", Color(0.2, 0.65, 0.2))
	btn_sp.anchor_left = 0.5;  btn_sp.anchor_right  = 0.5
	btn_sp.anchor_top  = 0.5;  btn_sp.anchor_bottom = 0.5
	btn_sp.offset_left = -210; btn_sp.offset_right  = 210
	btn_sp.offset_top  = -88;  btn_sp.offset_bottom = -30
	btn_sp.pressed.connect(_on_single_player)
	add_child(btn_sp)
	_menu_nodes.append(btn_sp)

	_ip_field = LineEdit.new()
	_ip_field.placeholder_text = "Server host  (e.g. 172-174-208-254.nip.io)"
	_ip_field.text = "172-174-208-254.nip.io"
	_ip_field.add_theme_font_size_override("font_size", 18)
	_ip_field.anchor_left = 0.5;  _ip_field.anchor_right  = 0.5
	_ip_field.anchor_top  = 0.5;  _ip_field.anchor_bottom = 0.5
	_ip_field.offset_left = -210; _ip_field.offset_right  = 210
	_ip_field.offset_top  = -10;  _ip_field.offset_bottom = 34
	_make_field_mobile_friendly(_ip_field)
	add_child(_ip_field)
	_menu_nodes.append(_ip_field)

	var is_web = OS.has_feature("web")

	# Player name field
	_default_name = "Player_%04d" % randi_range(1000, 9999)
	_name_field = LineEdit.new()
	_name_field.placeholder_text = "Your name"
	_name_field.text = _default_name
	_name_field.add_theme_font_size_override("font_size", 18)
	_name_field.anchor_left = 0.5;  _name_field.anchor_right  = 0.5
	_name_field.anchor_top  = 0.5;  _name_field.anchor_bottom = 0.5
	_name_field.offset_left = -210; _name_field.offset_right  = 210
	_name_field.offset_top  = 46;   _name_field.offset_bottom = 90
	_make_field_mobile_friendly(_name_field)
	# On the first tap the default name is auto-selected, so the player can simply
	# start typing to replace it instead of having to clear it character by character
	# (which is awkward on a phone keyboard).
	_name_field.focus_entered.connect(func():
		if _name_field.text == _default_name:
			_name_field.select_all())
	add_child(_name_field)
	_menu_nodes.append(_name_field)

	# Color swatches
	var color_row = HBoxContainer.new()
	color_row.anchor_left  = 0.5; color_row.anchor_right  = 0.5
	color_row.anchor_top   = 0.5; color_row.anchor_bottom = 0.5
	color_row.offset_left  = -210; color_row.offset_right  = 210
	color_row.offset_top   = 102;  color_row.offset_bottom = 144
	color_row.add_theme_constant_override("separation", 4)
	add_child(color_row)
	_menu_nodes.append(color_row)

	for ci: int in Config.PLAYER_COLORS.size():
		var cb = Button.new()
		cb.custom_minimum_size = Vector2(38, 38)
		var sb_normal = StyleBoxFlat.new()
		sb_normal.bg_color = Config.PLAYER_COLORS[ci]
		sb_normal.set_corner_radius_all(4)
		var sb_selected = StyleBoxFlat.new()
		sb_selected.bg_color   = Config.PLAYER_COLORS[ci]
		sb_selected.border_color = Color.WHITE
		sb_selected.set_border_width_all(3)
		sb_selected.set_corner_radius_all(4)
		cb.add_theme_stylebox_override("normal",  sb_normal if ci != 0 else sb_selected)
		cb.add_theme_stylebox_override("pressed", sb_selected)
		cb.add_theme_stylebox_override("hover",   sb_selected)
		var idx = ci
		cb.pressed.connect(func(): _on_color_selected(idx))
		color_row.add_child(cb)
		_color_btns.append(cb)

	var btn_host = _mk_btn("HOST GAME", Color(0.15, 0.35, 0.85))
	btn_host.anchor_left = 0.5;  btn_host.anchor_right  = 0.5
	btn_host.anchor_top  = 0.5;  btn_host.anchor_bottom = 0.5
	btn_host.offset_left = -210; btn_host.offset_right  = -8
	btn_host.offset_top  = 156;  btn_host.offset_bottom = 212
	btn_host.pressed.connect(_on_host)
	btn_host.visible = not is_web
	add_child(btn_host)
	_menu_nodes.append(btn_host)

	var join_left = 8 if not is_web else -210
	var btn_join = _mk_btn("JOIN GAME", Color(0.75, 0.25, 0.10))
	btn_join.anchor_left = 0.5;   btn_join.anchor_right  = 0.5
	btn_join.anchor_top  = 0.5;   btn_join.anchor_bottom = 0.5
	btn_join.offset_left = join_left; btn_join.offset_right = 210
	btn_join.offset_top  = 156;   btn_join.offset_bottom = 212
	btn_join.pressed.connect(_on_join)
	add_child(btn_join)
	_menu_nodes.append(btn_join)

	_status = Label.new()
	_status.text = ""
	_status.add_theme_font_size_override("font_size", 18)
	_status.add_theme_color_override("font_color", Color(0.6, 1.0, 0.6))
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.anchor_left = 0.0; _status.anchor_right = 1.0
	_status.anchor_top  = 0.5; _status.anchor_bottom = 0.5
	_status.offset_top  = 228; _status.offset_bottom = 268
	add_child(_status)
	_menu_nodes.append(_status)

	var hint = Label.new()
	hint.text = "Multiplayer: all players must be on the same network (or use port-forwarding)"
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Color(0.45, 0.45, 0.55))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.anchor_left = 0.0; hint.anchor_right = 1.0
	hint.anchor_top  = 1.0; hint.anchor_bottom = 1.0
	hint.offset_top  = -28; hint.offset_bottom = 0
	add_child(hint)
	_menu_nodes.append(hint)

# ── Lobby overlay (2D HUD on top of the 3D room) ─────────────────────────────
func _build_lobby_overlay() -> void:
	# Top bar
	var top_bar = ColorRect.new()
	top_bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top_bar.color = Color(0, 0, 0, 0.58)
	top_bar.offset_bottom = 82
	add_child(top_bar)

	var lbl_title = Label.new()
	lbl_title.text = "LOBBY"
	lbl_title.add_theme_font_size_override("font_size", 34)
	lbl_title.add_theme_color_override("font_color", Color(1.0, 0.88, 0.12))
	lbl_title.anchor_left   = 0.0; lbl_title.anchor_right  = 0.5
	lbl_title.anchor_top    = 0.0; lbl_title.anchor_bottom = 0.0
	lbl_title.offset_left   = 22;  lbl_title.offset_top    = 16
	lbl_title.offset_bottom = 64
	add_child(lbl_title)

	# Countdown / status centred in the top bar
	_countdown_label = Label.new()
	_countdown_label.text = "Waiting for more players…"
	_countdown_label.add_theme_font_size_override("font_size", 22)
	_countdown_label.add_theme_color_override("font_color", Color(0.7, 0.88, 1.0))
	_countdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_countdown_label.anchor_left   = 0.0;  _countdown_label.anchor_right  = 1.0
	_countdown_label.anchor_top    = 0.0;  _countdown_label.anchor_bottom = 0.0
	_countdown_label.offset_top    = 24;   _countdown_label.offset_bottom = 66
	add_child(_countdown_label)

	# Left panel — player list
	var left_bg = ColorRect.new()
	left_bg.color = Color(0, 0, 0, 0.45)
	left_bg.anchor_left   = 0.0; left_bg.anchor_right  = 0.0
	left_bg.anchor_top    = 0.0; left_bg.anchor_bottom = 1.0
	left_bg.offset_left   = 0;   left_bg.offset_right  = 280
	left_bg.offset_top    = 82;  left_bg.offset_bottom = 0
	add_child(left_bg)

	_player_list = Label.new()
	_player_list.text = "Waiting for players…"
	_player_list.add_theme_font_size_override("font_size", 15)
	_player_list.add_theme_color_override("font_color", Color(0.82, 0.92, 1.0))
	_player_list.anchor_left   = 0.0; _player_list.anchor_right  = 0.0
	_player_list.anchor_top    = 0.0; _player_list.anchor_bottom = 0.0
	_player_list.offset_left   = 14;  _player_list.offset_right  = 268
	_player_list.offset_top    = 98;  _player_list.offset_bottom = 580
	add_child(_player_list)

	# Ping indicator (top-right of top bar, clients only)
	_ping_label = Label.new()
	_ping_label.text = ""
	_ping_label.add_theme_font_size_override("font_size", 15)
	_ping_label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5))
	_ping_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_ping_label.anchor_left   = 1.0; _ping_label.anchor_right  = 1.0
	_ping_label.anchor_top    = 0.0; _ping_label.anchor_bottom = 0.0
	_ping_label.offset_left   = -160; _ping_label.offset_right  = -14
	_ping_label.offset_top    = 28;   _ping_label.offset_bottom = 72
	_ping_label.visible = not _net.is_captain and multiplayer.has_multiplayer_peer()
	add_child(_ping_label)

	# START GAME button (captain only, bottom-centre)
	_start_btn = _mk_btn("▶  START GAME", Color(0.0, 0.55, 0.10))
	_start_btn.anchor_left   = 0.5;  _start_btn.anchor_right  = 0.5
	_start_btn.anchor_top    = 1.0;  _start_btn.anchor_bottom = 1.0
	_start_btn.offset_left   = -160; _start_btn.offset_right  = 160
	_start_btn.offset_top    = -78;  _start_btn.offset_bottom = -18
	_start_btn.visible       = false
	_start_btn.pressed.connect(_on_start_pressed)
	add_child(_start_btn)

# ── Transition from menu → 3-D lobby room ────────────────────────────────────
func _enter_lobby_room() -> void:
	for c: Node in _menu_nodes:
		if is_instance_valid(c):
			c.visible = false

	_lobby_room = LobbyRoom.new()
	_lobby_room.name = "LobbyRoom"
	get_parent().add_child(_lobby_room)

	_build_lobby_overlay()

# ── Button callbacks ──────────────────────────────────────────────────────────
func _on_single_player() -> void:
	start_game.emit(0, false)
	queue_free()

func _on_color_selected(idx: int) -> void:
	_selected_color = idx
	for i: int in _color_btns.size():
		var sb = StyleBoxFlat.new()
		sb.bg_color = Config.PLAYER_COLORS[i]
		sb.set_corner_radius_all(4)
		if i == idx:
			sb.border_color = Color.WHITE
			sb.set_border_width_all(3)
		_color_btns[i].add_theme_stylebox_override("normal", sb)

func _apply_identity() -> void:
	var name = _name_field.text.strip_edges() if _name_field else ""
	_net.my_name      = name if name != "" else _default_name
	_net.my_color_idx = _selected_color

func _on_host() -> void:
	_apply_identity()
	_net.host_game()        # sets _peers=[1], emits lobby_updated([1])
	_enter_lobby_room()
	_on_lobby_updated([1])

func _on_join() -> void:
	_apply_identity()
	var ip = _ip_field.text.strip_edges()
	_status.text = "Connecting to %s …" % ip
	_net.join_game(ip)

func _on_connected() -> void:
	_enter_lobby_room()
	if _countdown_label:
		_countdown_label.text = "Connected — waiting for host…"

# ── Lobby update from NetworkManager ─────────────────────────────────────────
func _on_lobby_updated(peer_ids: Array) -> void:
	var names      = _net.player_names
	var color_idxs = _net.player_color_indices

	# Update 3-D slot labels
	if _lobby_room and is_instance_valid(_lobby_room):
		var local_pid = multiplayer.get_unique_id() if multiplayer.has_multiplayer_peer() else 1
		_lobby_room.update_slots(peer_ids, local_pid, names, color_idxs)

	# Update text player list
	if _player_list:
		var lines: Array = []
		for i: int in peer_ids.size():
			var pid = peer_ids[i]
			var pname = names.get(pid, "Player %d" % (i + 1))
			var txt   = "  ● %s" % pname
			if multiplayer.has_multiplayer_peer() and pid == multiplayer.get_unique_id():
				txt += "  (you)"
			if i == 0:
				txt += "  [host]"
			lines.append(txt)
		_player_list.text = (
			"Players  %d / %d\n" % [peer_ids.size(), Config.MAX_PLAYERS]
			+ "\n".join(lines)
		)

	# Countdown: start (15 s) when ≥ 2 players are in the lobby
	if peer_ids.size() >= 2:
		if not _counting:
			_counting  = true
			_countdown = 15.0
			if _countdown_label:
				_countdown_label.add_theme_color_override("font_color", Color(0.7, 0.88, 1.0))
	else:
		_counting = false
		if _countdown_label:
			var waiting_for = 2 - peer_ids.size()
			_countdown_label.text = "Waiting for %d more player%s…" % \
				[waiting_for, "s" if waiting_for != 1 else ""]
			_countdown_label.add_theme_color_override("font_color", Color(0.7, 0.88, 1.0))

	# START button: captain only, requires ≥ 2 players
	if _start_btn:
		_start_btn.visible  = _net.is_captain and peer_ids.size() >= 2
		_start_btn.disabled = false

func _on_start_pressed() -> void:
	if _start_btn:
		_start_btn.disabled = true
	_counting = false
	_net.request_start()

func _on_lobby_ready(seed_val: int) -> void:
	if _lobby_room and is_instance_valid(_lobby_room):
		_lobby_room.queue_free()
	start_game.emit(seed_val, true)
	queue_free()

# ── Helper ────────────────────────────────────────────────────────────────────
# Make a LineEdit usable on a phone: tall enough to tap reliably, the OS virtual
# keyboard enabled (for native Android builds), and a clear (✕) button.
#
# On the WEB build the Godot canvas can't bring up the mobile browser's soft
# keyboard for a LineEdit — there is no real DOM <input> to focus — so on a touch
# phone tapping the field did nothing and the name couldn't be edited. There we
# route editing through a native window.prompt() (which DOES open the keyboard) and
# write the entered text back into the field.
func _make_field_mobile_friendly(field: LineEdit) -> void:
	field.custom_minimum_size = Vector2(0, 52)
	field.virtual_keyboard_enabled = true
	field.virtual_keyboard_type    = LineEdit.KEYBOARD_TYPE_DEFAULT
	field.clear_button_enabled     = true
	field.context_menu_enabled     = true
	field.selecting_enabled        = true
	field.editable                 = true
	# A taller field needs a wider tap target; grow the box downward so it does not
	# collide with the control below it.
	field.offset_bottom = field.offset_top + 52

	if _mobile_web:
		# Tapping the field opens the native browser prompt (the only reliable way
		# to get the soft keyboard in a web canvas on a phone).
		var label := field.placeholder_text if field.placeholder_text != "" else "Enter value"
		field.gui_input.connect(func(ev: InputEvent):
			var tapped := (ev is InputEventScreenTouch and ev.pressed) \
				or (ev is InputEventMouseButton and ev.pressed)
			if tapped:
				_prompt_edit(field, label))

# Edit a field via the browser's native window.prompt() — opens the mobile soft
# keyboard, then writes the typed value back. Debounced so a single tap delivered
# as both a touch and an emulated-mouse event can't pop two prompts.
func _prompt_edit(field: LineEdit, label: String) -> void:
	if not OS.has_feature("web"):
		return
	var now := Time.get_ticks_msec()
	if now - _last_prompt_ms < 400:
		return
	var js := "window.prompt('%s', '%s')" % [_js_escape(label), _js_escape(field.text)]
	var res = JavaScriptBridge.eval(js, true)
	if res != null:                       # null = the user cancelled → keep current text
		var s := str(res).strip_edges()
		field.text = s
		field.caret_column = s.length()
	_last_prompt_ms = Time.get_ticks_msec()

# Escape a string for embedding inside a single-quoted JavaScript string literal.
# Static + pure so it can be unit-tested headless (see tests/test_name_input.gd).
static func _js_escape(s: String) -> String:
	return s.replace("\\", "\\\\").replace("'", "\\'").replace("\n", " ").replace("\r", " ")

func _mk_btn(txt: String, col: Color) -> Button:
	var btn = Button.new()
	btn.text = txt
	btn.add_theme_font_size_override("font_size", 20)
	btn.add_theme_color_override("font_color", Color.WHITE)
	var sb = StyleBoxFlat.new()
	sb.bg_color = col.darkened(0.35)
	sb.bg_color.a = 0.92
	sb.border_color = col
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	btn.add_theme_stylebox_override("normal",  sb)
	btn.add_theme_stylebox_override("pressed", sb)
	return btn
