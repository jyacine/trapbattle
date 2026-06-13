extends CanvasLayer
class_name LobbyUI

# seed_val=0 means random; is_mp=false = single-player (Robot AI)
signal start_game(seed_val: int, is_mp: bool)

var _net: NetworkManager
var _status: Label
var _ip_field: LineEdit

func _ready() -> void:
	_net = get_parent().get_node("NetworkManager")
	_net.lobby_ready.connect(_on_lobby_ready)
	_build_ui()

func _build_ui() -> void:
	var bg = ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.05, 0.05, 0.10, 1.0)
	add_child(bg)

	var title = Label.new()
	title.text = "TRAPBATTLE"
	title.add_theme_font_size_override("font_size", 60)
	title.add_theme_color_override("font_color", Color.YELLOW)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.anchor_left = 0.0; title.anchor_right = 1.0
	title.anchor_top = 0.5; title.anchor_bottom = 0.5
	title.offset_top = -240; title.offset_bottom = -150
	add_child(title)

	var sub = Label.new()
	sub.text = "First-person maze trap battle"
	sub.add_theme_font_size_override("font_size", 20)
	sub.add_theme_color_override("font_color", Color(0.7, 0.7, 0.8))
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.anchor_left = 0.0; sub.anchor_right = 1.0
	sub.anchor_top = 0.5; sub.anchor_bottom = 0.5
	sub.offset_top = -138; sub.offset_bottom = -98
	add_child(sub)

	# Single player
	var btn_sp = _mk_btn("SINGLE PLAYER  (vs Robot AI)", Color(0.2, 0.65, 0.2))
	btn_sp.anchor_left = 0.5; btn_sp.anchor_right = 0.5
	btn_sp.anchor_top = 0.5; btn_sp.anchor_bottom = 0.5
	btn_sp.offset_left = -210; btn_sp.offset_right = 210
	btn_sp.offset_top = -72; btn_sp.offset_bottom = -12
	btn_sp.pressed.connect(_on_single_player)
	add_child(btn_sp)

	# IP field
	_ip_field = LineEdit.new()
	_ip_field.placeholder_text = "Host IP  (e.g. 192.168.1.10)"
	_ip_field.text = "127.0.0.1"
	_ip_field.add_theme_font_size_override("font_size", 18)
	_ip_field.anchor_left = 0.5; _ip_field.anchor_right = 0.5
	_ip_field.anchor_top = 0.5; _ip_field.anchor_bottom = 0.5
	_ip_field.offset_left = -210; _ip_field.offset_right = 210
	_ip_field.offset_top = 8; _ip_field.offset_bottom = 52
	add_child(_ip_field)

	var btn_host = _mk_btn("HOST GAME", Color(0.15, 0.35, 0.85))
	btn_host.anchor_left = 0.5; btn_host.anchor_right = 0.5
	btn_host.anchor_top = 0.5; btn_host.anchor_bottom = 0.5
	btn_host.offset_left = -210; btn_host.offset_right = -8
	btn_host.offset_top = 62; btn_host.offset_bottom = 122
	btn_host.pressed.connect(_on_host)
	add_child(btn_host)

	var btn_join = _mk_btn("JOIN GAME", Color(0.75, 0.25, 0.10))
	btn_join.anchor_left = 0.5; btn_join.anchor_right = 0.5
	btn_join.anchor_top = 0.5; btn_join.anchor_bottom = 0.5
	btn_join.offset_left = 8; btn_join.offset_right = 210
	btn_join.offset_top = 62; btn_join.offset_bottom = 122
	btn_join.pressed.connect(_on_join)
	add_child(btn_join)

	_status = Label.new()
	_status.text = ""
	_status.add_theme_font_size_override("font_size", 18)
	_status.add_theme_color_override("font_color", Color(0.6, 1.0, 0.6))
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.anchor_left = 0.0; _status.anchor_right = 1.0
	_status.anchor_top = 0.5; _status.anchor_bottom = 0.5
	_status.offset_top = 134; _status.offset_bottom = 174
	add_child(_status)

	var hint = Label.new()
	hint.text = "Multiplayer: both players need to be on the same network (or use port-forwarding)"
	hint.add_theme_font_size_override("font_size", 14)
	hint.add_theme_color_override("font_color", Color(0.45, 0.45, 0.55))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.anchor_left = 0.0; hint.anchor_right = 1.0
	hint.anchor_top = 1.0; hint.anchor_bottom = 1.0
	hint.offset_top = -30; hint.offset_bottom = 0
	add_child(hint)

func _on_single_player() -> void:
	start_game.emit(0, false)
	queue_free()

func _on_host() -> void:
	_status.text = "Hosting on port %d — waiting for the other player..." % NetworkManager.PORT
	_net.host_game()

func _on_join() -> void:
	var ip = _ip_field.text.strip_edges()
	_status.text = "Connecting to %s:%d ..." % [ip, NetworkManager.PORT]
	_net.join_game(ip)

func _on_lobby_ready() -> void:
	_status.text = "Connected! Starting game..."
	if multiplayer.is_server():
		_rpc_start.rpc(randi())

@rpc("authority", "call_local", "reliable")
func _rpc_start(s: int) -> void:
	start_game.emit(s, true)
	queue_free()

func _mk_btn(txt: String, col: Color) -> Button:
	var btn = Button.new()
	btn.text = txt
	btn.add_theme_font_size_override("font_size", 20)
	btn.add_theme_color_override("font_color", Color.WHITE)
	var sb = StyleBoxFlat.new()
	sb.bg_color = col.darkened(0.35); sb.bg_color.a = 0.92
	sb.border_color = col
	sb.set_border_width_all(2); sb.set_corner_radius_all(6)
	btn.add_theme_stylebox_override("normal", sb)
	btn.add_theme_stylebox_override("pressed", sb)
	return btn
