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

# Map picker — buttons live in both the menu (drives single-player + captain's
# pre-pick) and the lobby overlay (captain only). All map buttons are tracked
# here so the highlight stays in sync across both rows.
var _selected_map:    int   = 1
var _map_btns:        Array = []   # [{ "btn": Button, "id": int }, …]
var _lobby_map_row:   HBoxContainer = null
var _lobby_map_label: Label = null

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
var _last_prompt_ms: int = 0   # debounce duplicate tap â†’ prompt (touch + emulated mouse)
var _pending_name_field: LineEdit = null  # field awaiting DOM-input result
var _rejected: bool = false           # set when server rejects us (game in progress)

# â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
func _ready() -> void:
	_net = get_parent().get_node("NetworkManager")
	_net.lobby_ready.connect(_on_lobby_ready)
	_net.lobby_updated.connect(_on_lobby_updated)
	_net.connected.connect(_on_connected)
	_net.game_in_progress.connect(_on_game_in_progress)
	_mobile_web = OS.has_feature("web") and UIManager._is_mobile_device()
	_build_menu()

func _process(delta: float) -> void:
	if _ping_label and _ping_label.visible:
		var ms = _net.ping_ms
		_ping_label.text = "• %d ms" % ms
		var col: Color
		if ms < 50:
			col = Color(0.2, 1.0, 0.2)
		elif ms < 150:
			col = Color(1.0, 0.85, 0.1)
		else:
			col = Color(1.0, 0.25, 0.25)
		_ping_label.add_theme_color_override("font_color", col)

	# Poll JS name-input overlay result (mobile web).
	if _pending_name_field != null and OS.has_feature("web"):
		var done = JavaScriptBridge.eval("typeof window._gdNameDone!='undefined'&&window._gdNameDone===true")
		if done:
			var val = JavaScriptBridge.eval("typeof window._gdNameVal!='undefined'?String(window._gdNameVal):''")
			if val != null:
				var s: String = str(val).strip_edges()
				if s != "":
					_pending_name_field.text = s
					_pending_name_field.caret_column = s.length()
			_pending_name_field = null
			JavaScriptBridge.eval("window._gdNameDone=false")

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
			_net.request_start(_selected_map)

# â”€â”€ Initial menu screen â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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
	sub.text = "First-person maze trap battle  â€”  up to 10 players"
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
	_ip_field.placeholder_text = "Server host  (e.g. 34-155-132-207.nip.io)"
	_ip_field.text = "34-155-132-207.nip.io"
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

	# Map picker (single-player uses this directly; in multiplayer the captain's
	# pick is sent on START). Tap a map to select it.
	var map_row = _make_map_row(152, 186)
	add_child(map_row)
	_menu_nodes.append(map_row)

	var btn_host = _mk_btn("HOST GAME", Color(0.15, 0.35, 0.85))
	btn_host.anchor_left = 0.5;  btn_host.anchor_right  = 0.5
	btn_host.anchor_top  = 0.5;  btn_host.anchor_bottom = 0.5
	btn_host.offset_left = -210; btn_host.offset_right  = -8
	btn_host.offset_top  = 198;  btn_host.offset_bottom = 250
	btn_host.pressed.connect(_on_host)
	btn_host.visible = not is_web
	add_child(btn_host)
	_menu_nodes.append(btn_host)

	var join_left = 8 if not is_web else -210
	var btn_join = _mk_btn("JOIN GAME", Color(0.75, 0.25, 0.10))
	btn_join.anchor_left = 0.5;   btn_join.anchor_right  = 0.5
	btn_join.anchor_top  = 0.5;   btn_join.anchor_bottom = 0.5
	btn_join.offset_left = join_left; btn_join.offset_right = 210
	btn_join.offset_top  = 198;   btn_join.offset_bottom = 250
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
	_status.offset_top  = 262; _status.offset_bottom = 300
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

# â”€â”€ Lobby overlay (2D HUD on top of the 3D room) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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
	_countdown_label.text = "Waiting for more playersâ€¦"
	_countdown_label.add_theme_font_size_override("font_size", 22)
	_countdown_label.add_theme_color_override("font_color", Color(0.7, 0.88, 1.0))
	_countdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_countdown_label.anchor_left   = 0.0;  _countdown_label.anchor_right  = 1.0
	_countdown_label.anchor_top    = 0.0;  _countdown_label.anchor_bottom = 0.0
	_countdown_label.offset_top    = 24;   _countdown_label.offset_bottom = 66
	add_child(_countdown_label)

	# Left panel â€” player list
	var left_bg = ColorRect.new()
	left_bg.color = Color(0, 0, 0, 0.45)
	left_bg.anchor_left   = 0.0; left_bg.anchor_right  = 0.0
	left_bg.anchor_top    = 0.0; left_bg.anchor_bottom = 1.0
	left_bg.offset_left   = 0;   left_bg.offset_right  = 280
	left_bg.offset_top    = 82;  left_bg.offset_bottom = 0
	add_child(left_bg)

	_player_list = Label.new()
	_player_list.text = "Waiting for playersâ€¦"
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

	# EXIT / LEAVE button — bottom-left, always visible
	var exit_btn = _mk_btn("Leave", Color(0.55, 0.08, 0.08))
	exit_btn.anchor_left   = 0.0;  exit_btn.anchor_right  = 0.0
	exit_btn.anchor_top    = 1.0;  exit_btn.anchor_bottom = 1.0
	exit_btn.offset_left   = 16;   exit_btn.offset_right  = 160
	exit_btn.offset_top    = -78;  exit_btn.offset_bottom = -18
	exit_btn.pressed.connect(func(): get_tree().reload_current_scene())
	add_child(exit_btn)

	# START GAME button (captain only, bottom-centre)
	_start_btn = _mk_btn("â–¶  START GAME", Color(0.0, 0.55, 0.10))
	_start_btn.anchor_left   = 0.5;  _start_btn.anchor_right  = 0.5
	_start_btn.anchor_top    = 1.0;  _start_btn.anchor_bottom = 1.0
	_start_btn.offset_left   = -160; _start_btn.offset_right  = 160
	_start_btn.offset_top    = -78;  _start_btn.offset_bottom = -18
	_start_btn.visible       = false
	_start_btn.pressed.connect(_on_start_pressed)
	add_child(_start_btn)

	# Captain-only map picker, just above START. The choice is synced to every
	# player when the game starts.
	_lobby_map_label = Label.new()
	_lobby_map_label.text = "Map:  %s" % Config.map_name(_selected_map)
	_lobby_map_label.add_theme_font_size_override("font_size", 16)
	_lobby_map_label.add_theme_color_override("font_color", Color(0.85, 0.92, 1.0))
	_lobby_map_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lobby_map_label.anchor_left = 0.0; _lobby_map_label.anchor_right = 1.0
	_lobby_map_label.anchor_top  = 1.0; _lobby_map_label.anchor_bottom = 1.0
	_lobby_map_label.offset_top  = -152; _lobby_map_label.offset_bottom = -128
	_lobby_map_label.visible = false
	add_child(_lobby_map_label)

	_lobby_map_row = _make_map_row(0, 0)
	_lobby_map_row.anchor_top = 1.0; _lobby_map_row.anchor_bottom = 1.0
	_lobby_map_row.offset_top = -122; _lobby_map_row.offset_bottom = -88
	_lobby_map_row.visible = false
	add_child(_lobby_map_row)

# â”€â”€ Transition from menu â†’ 3-D lobby room â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
func _enter_lobby_room() -> void:
	for c: Node in _menu_nodes:
		if is_instance_valid(c) and c is CanvasItem:
			c.visible = false

	_lobby_room = LobbyRoom.new()
	_lobby_room.name = "LobbyRoom"
	get_parent().add_child(_lobby_room)

	_build_lobby_overlay()

# â”€â”€ Button callbacks â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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

# ── Map picker ────────────────────────────────────────────────────────────────
# Build a centred row of map buttons. Selecting one sets Config.selected_map; in
# multiplayer the captain's choice is sent on START and synced to every client.
func _make_map_row(top: float, bottom: float) -> HBoxContainer:
	var row = HBoxContainer.new()
	row.anchor_left = 0.5; row.anchor_right = 0.5
	row.anchor_top  = 0.5; row.anchor_bottom = 0.5
	row.offset_left = -210; row.offset_right = 210
	row.offset_top  = top;  row.offset_bottom = bottom
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 4)
	# Buttons sized so the full map roster fits the ~420 px row (currently 5 maps).
	for m in Config.MAPS:
		var mid: int = m["id"]
		var b = Button.new()
		b.text = m["name"]
		b.custom_minimum_size = Vector2(80, 34)
		b.tooltip_text = m["desc"]
		b.add_theme_font_size_override("font_size", 12)
		b.pressed.connect(func(): _on_map_selected(mid))
		_style_map_button(b, mid == _selected_map)
		row.add_child(b)
		_map_btns.append({ "btn": b, "id": mid })
	return row

func _style_map_button(b: Button, selected: bool) -> void:
	var sb = StyleBoxFlat.new()
	sb.bg_color     = Color(0.18, 0.32, 0.16, 0.95) if selected else Color(0.11, 0.13, 0.18, 0.92)
	sb.border_color = Color(0.40, 1.00, 0.45)       if selected else Color(0.38, 0.42, 0.50)
	sb.set_border_width_all(3 if selected else 2)
	sb.set_corner_radius_all(6)
	b.add_theme_stylebox_override("normal",  sb)
	b.add_theme_stylebox_override("hover",   sb)
	b.add_theme_stylebox_override("pressed", sb)
	b.add_theme_color_override("font_color", Color.WHITE)

func _on_map_selected(map_id: int) -> void:
	_selected_map = map_id
	Config.selected_map = map_id
	for entry in _map_btns:
		if is_instance_valid(entry["btn"]):
			_style_map_button(entry["btn"], entry["id"] == map_id)
	if _lobby_map_label:
		_lobby_map_label.text = "Map:  %s" % Config.map_name(map_id)

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
	_open_lobby_browser()

# ── Lobby browser (multi-room) ────────────────────────────────────────────────
# Lists every server room with its live status (map, players, time playing) so
# the player can join a running/waiting game or create a fresh one by taking an
# empty room. Status comes from GET https://<host>/status/<N> (Caddy → the
# room's StatusServer).
const NUM_ROOMS := 4
var _browser_nodes:  Array = []      # everything to remove on BACK
var _room_rows:      Array = []      # per room: { "label": Label, "btn": Button }
var _browser_status: Label = null
var _refresh_timer:  Timer = null
var _joining_room:   int   = 0

func _open_lobby_browser() -> void:
	if not _browser_nodes.is_empty():
		return
	# Hide the main menu FIRST — browser nodes are appended to _menu_nodes as
	# they are created (via _track_browser), so hiding afterwards would hide the
	# freshly built browser too (the "no room selection" black-screen bug).
	for c: Node in _menu_nodes:
		if is_instance_valid(c) and c is CanvasItem: c.visible = false
	var bg = ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.05, 0.05, 0.10, 1.0)
	add_child(bg)
	_track_browser(bg)

	var title = Label.new()
	title.text = "GAME LOBBIES"
	title.add_theme_font_size_override("font_size", 36)
	title.add_theme_color_override("font_color", Color.YELLOW)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.anchor_left = 0.0; title.anchor_right = 1.0
	title.anchor_top  = 0.5; title.anchor_bottom = 0.5
	title.offset_top  = -252; title.offset_bottom = -200
	add_child(title)
	_track_browser(title)

	_room_rows.clear()
	for i in NUM_ROOMS:
		var room := i + 1
		var y: float = -170.0 + float(i) * 74.0

		var row_bg = ColorRect.new()
		row_bg.color = Color(0.10, 0.12, 0.18, 0.95)
		row_bg.anchor_left = 0.5; row_bg.anchor_right  = 0.5
		row_bg.anchor_top  = 0.5; row_bg.anchor_bottom = 0.5
		row_bg.offset_left = -280; row_bg.offset_right = 280
		row_bg.offset_top  = y;    row_bg.offset_bottom = y + 62
		add_child(row_bg)
		_track_browser(row_bg)

		var lbl = Label.new()
		lbl.text = "Room %d — checking…" % room
		lbl.add_theme_font_size_override("font_size", 17)
		lbl.add_theme_color_override("font_color", Color(0.8, 0.85, 0.95))
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lbl.anchor_left = 0.5; lbl.anchor_right  = 0.5
		lbl.anchor_top  = 0.5; lbl.anchor_bottom = 0.5
		lbl.offset_left = -266; lbl.offset_right = 130
		lbl.offset_top  = y;    lbl.offset_bottom = y + 62
		add_child(lbl)
		_track_browser(lbl)

		var btn = _mk_btn("…", Color(0.25, 0.28, 0.35))
		btn.disabled = true
		btn.anchor_left = 0.5; btn.anchor_right  = 0.5
		btn.anchor_top  = 0.5; btn.anchor_bottom = 0.5
		btn.offset_left = 142;  btn.offset_right = 272
		btn.offset_top  = y + 7; btn.offset_bottom = y + 55
		var r := room
		btn.pressed.connect(func(): _join_room(r))
		add_child(btn)
		_track_browser(btn)

		_room_rows.append({ "label": lbl, "btn": btn })

	_browser_status = Label.new()
	_browser_status.text = "Fetching room list from %s …" % _ip_field.text.strip_edges()
	_browser_status.add_theme_font_size_override("font_size", 16)
	_browser_status.add_theme_color_override("font_color", Color(0.6, 1.0, 0.6))
	_browser_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_browser_status.anchor_left = 0.0; _browser_status.anchor_right = 1.0
	_browser_status.anchor_top  = 0.5; _browser_status.anchor_bottom = 0.5
	_browser_status.offset_top  = 140; _browser_status.offset_bottom = 172
	add_child(_browser_status)
	_track_browser(_browser_status)

	var back = _mk_btn("BACK", Color(0.45, 0.20, 0.20))
	back.anchor_left = 0.5; back.anchor_right  = 0.5
	back.anchor_top  = 0.5; back.anchor_bottom = 0.5
	back.offset_left = -280; back.offset_right = -40
	back.offset_top  = 186;  back.offset_bottom = 238
	back.pressed.connect(_close_lobby_browser)
	add_child(back)
	_track_browser(back)

	var refresh = _mk_btn("REFRESH", Color(0.15, 0.40, 0.60))
	refresh.anchor_left = 0.5; refresh.anchor_right  = 0.5
	refresh.anchor_top  = 0.5; refresh.anchor_bottom = 0.5
	refresh.offset_left = 40;  refresh.offset_right = 280
	refresh.offset_top  = 186; refresh.offset_bottom = 238
	refresh.pressed.connect(_refresh_rooms)
	add_child(refresh)
	_track_browser(refresh)

	_refresh_timer = Timer.new()
	_refresh_timer.wait_time = 3.0
	_refresh_timer.timeout.connect(_refresh_rooms)
	add_child(_refresh_timer)
	_refresh_timer.start()
	# Cleanup list ONLY — a Timer has no `visible` property, so putting it in
	# _menu_nodes made every hide/show loop crash with "Invalid assignment of
	# property or key 'visible' ... on a base object of type 'Timer'".
	_browser_nodes.append(_refresh_timer)

	_refresh_rooms()

# Track a browser node in BOTH lists: _browser_nodes so BACK can free it, and
# _menu_nodes so entering the 3-D lobby room / rejection screens hide it too.
func _track_browser(n: Node) -> void:
	_browser_nodes.append(n)
	_menu_nodes.append(n)

func _close_lobby_browser() -> void:
	_joining_room = 0
	for n: Node in _browser_nodes:
		if is_instance_valid(n):
			_menu_nodes.erase(n)
			n.queue_free()
	_browser_nodes.clear()
	_room_rows.clear()
	_browser_status = null
	_refresh_timer  = null
	for c: Node in _menu_nodes:
		if is_instance_valid(c) and c is CanvasItem: c.visible = true

func _refresh_rooms() -> void:
	if _joining_room > 0:
		return   # freeze the list while connecting
	var host := _ip_field.text.strip_edges()
	for i in NUM_ROOMS:
		var room := i + 1
		var req := HTTPRequest.new()
		req.timeout = 4.0
		add_child(req)
		var r := room
		req.request_completed.connect(
			func(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray):
				req.queue_free()
				_on_room_status(r, code, body))
		if req.request("https://%s/status/%d" % [host, room]) != OK:
			req.queue_free()
			_on_room_status(room, 0, PackedByteArray())

func _on_room_status(room: int, code: int, body: PackedByteArray) -> void:
	if _room_rows.size() < room or _joining_room > 0:
		return
	var row: Dictionary = _room_rows[room - 1]
	var lbl: Label  = row["label"]
	var btn: Button = row["btn"]
	if not is_instance_valid(lbl) or not is_instance_valid(btn):
		return
	var st = JSON.parse_string(body.get_string_from_utf8()) if code == 200 else null
	# Row content decided by RoomStatus.format_room_row (pure static — covered
	# by tests/test_lobby_browser.gd).
	var r: Dictionary = RoomStatus.format_room_row(room, code, st)
	lbl.text = r["text"]
	lbl.add_theme_color_override("font_color", r["color"])
	btn.text     = r["btn"]
	btn.disabled = r["disabled"]
	_style_browser_btn(btn, r["btn_color"])

func _style_browser_btn(b: Button, col: Color) -> void:
	var sb = StyleBoxFlat.new()
	sb.bg_color = col
	sb.set_corner_radius_all(8)
	b.add_theme_stylebox_override("normal", sb)

func _join_room(room: int) -> void:
	if _joining_room > 0:
		return
	_joining_room = room
	if _refresh_timer and is_instance_valid(_refresh_timer):
		_refresh_timer.stop()
	var ip = _ip_field.text.strip_edges()
	if _browser_status:
		_browser_status.text = "Connecting to room %d on %s …" % [room, ip]
	_net.join_game(ip, room)

func _on_connected() -> void:
	# Defer building the 3-D lobby room by ~400 ms.  When a player joins a
	# game that is already in progress the server sends _rpc_late_join within
	# that window, lobby_ready fires, and queue_free() runs — so the lobby room
	# is never built and the player goes straight into the game.
	get_tree().create_timer(0.40).timeout.connect(_enter_lobby_room_deferred)

# â”€â”€ Lobby update from NetworkManager â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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
			var txt   = "  â— %s" % pname
			if multiplayer.has_multiplayer_peer() and pid == multiplayer.get_unique_id():
				txt += "  (you)"
			if i == 0:
				txt += "  [host]"
			lines.append(txt)
		_player_list.text = (
			"Players  %d / %d\n" % [peer_ids.size(), Config.MAX_PLAYERS]
			+ "\n".join(lines)
		)

	# Countdown: start (15 s) when â‰¥ 2 players are in the lobby
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
			_countdown_label.text = "Waiting for %d more player%sâ€¦" % \
				[waiting_for, "s" if waiting_for != 1 else ""]
			_countdown_label.add_theme_color_override("font_color", Color(0.7, 0.88, 1.0))

	# START button: captain only, requires â‰¥ 2 players
	if _start_btn:
		_start_btn.visible  = _net.is_captain and peer_ids.size() >= 2
		_start_btn.disabled = false

	# Map picker is the captain's call — only they see/choose it.
	if _lobby_map_row:
		_lobby_map_row.visible = _net.is_captain
	if _lobby_map_label:
		_lobby_map_label.visible = _net.is_captain

func _on_start_pressed() -> void:
	if _start_btn:
		_start_btn.disabled = true
	_counting = false
	_net.request_start(_selected_map)

func _enter_lobby_room_deferred() -> void:
	# Only build the room if lobby_ready hasn't already fired (we'd be freed by now).
	if not is_instance_valid(self): return
	if _lobby_room != null: return
	if _rejected: return   # server told us game is in progress — don't build a lobby
	_enter_lobby_room()
	if _countdown_label:
		_countdown_label.text = "Connected - waiting for host..."

func _on_game_in_progress() -> void:
	_rejected = true
	for c: Node in _menu_nodes:
		if is_instance_valid(c) and c is CanvasItem: c.visible = false

	var bg = ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.05, 0.05, 0.10, 0.96)
	add_child(bg)

	var msg = Label.new()
	msg.text = "Match is full\nPlease wait for a player slot to free up, then reconnect."
	msg.add_theme_font_size_override("font_size", 26)
	msg.add_theme_color_override("font_color", Color(1.0, 0.75, 0.2))
	msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	msg.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	msg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(msg)

	get_tree().create_timer(4.0).timeout.connect(func():
		get_tree().reload_current_scene())

func _on_lobby_ready(seed_val: int, map_id: int) -> void:
	Config.selected_map = map_id
	if _lobby_room and is_instance_valid(_lobby_room):
		_lobby_room.queue_free()
	start_game.emit(seed_val, true)
	queue_free()

# â”€â”€ Helper â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
# Make a LineEdit usable on a phone: tall enough to tap reliably, the OS virtual
# keyboard enabled (for native Android builds), and a clear (âœ•) button.
#
# On the WEB build the Godot canvas can't bring up the mobile browser's soft
# keyboard for a LineEdit â€” there is no real DOM <input> to focus â€” so on a touch
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
			var tapped: bool = (ev is InputEventScreenTouch and ev.pressed) \
				or (ev is InputEventMouseButton and ev.pressed)
			if tapped:
				_prompt_edit(field, label))

# Edit a field via the browser's native window.prompt() â€” opens the mobile soft
# keyboard, then writes the typed value back. Debounced so a single tap delivered
# as both a touch and an emulated-mouse event can't pop two prompts.
func _prompt_edit(field: LineEdit, label: String) -> void:
	if not OS.has_feature("web"):
		return
	var now := Time.get_ticks_msec()
	if now - _last_prompt_ms < 400:
		return
	_last_prompt_ms = Time.get_ticks_msec()
	_pending_name_field = field
	var le := _js_escape(label)
	var ve := _js_escape(field.text)
	var js := "(function(){"
	js += "window._gdNameDone=false;window._gdNameVal='';"
	js += "var ov=document.getElementById('_gd_prompt');if(ov)ov.remove();"
	js += "ov=document.createElement('div');ov.id='_gd_prompt';"
	js += "ov.style='position:fixed;inset:0;background:rgba(0,0,0,.72);display:flex;align-items:center;justify-content:center;z-index:9999';"
	js += "var box=document.createElement('div');"
	js += "box.style='background:#1a1a2e;border:2px solid #4a9eff;border-radius:12px;padding:24px;width:80%;max-width:380px';"
	js += "var lbl=document.createElement('p');lbl.textContent='" + le + "';"
	js += "lbl.style='color:#fff;font-size:18px;margin:0 0 12px;text-align:center';"
	js += "var inp=document.createElement('input');inp.type='text';inp.value='" + ve + "';"
	js += "inp.style='width:100%;box-sizing:border-box;padding:10px;font-size:18px;border-radius:8px;border:none;background:#2a2a4a;color:#fff';"
	js += "var row=document.createElement('div');row.style='display:flex;gap:12px;margin-top:16px';"
	js += "function ok(){window._gdNameVal=inp.value;window._gdNameDone=true;ov.remove();}"
	js += "function no(){window._gdNameDone=true;ov.remove();}"
	js += "var okb=document.createElement('button');okb.textContent='OK';"
	js += "okb.style='flex:1;padding:10px;font-size:16px;background:#2a6aad;color:#fff;border:none;border-radius:8px';okb.onclick=ok;"
	js += "var cxb=document.createElement('button');cxb.textContent='Cancel';"
	js += "cxb.style='flex:1;padding:10px;font-size:16px;background:#555;color:#fff;border:none;border-radius:8px';cxb.onclick=no;"
	js += "inp.onkeydown=function(e){if(e.key==='Enter')ok();else if(e.key==='Escape')no();};"
	js += "row.appendChild(okb);row.appendChild(cxb);box.appendChild(lbl);box.appendChild(inp);box.appendChild(row);"
	js += "ov.appendChild(box);document.body.appendChild(ov);"
	js += "setTimeout(function(){inp.focus();inp.select();},50);"
	js += "})();"
	JavaScriptBridge.eval(js)

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
