class_name RoomStatus
extends RefCounted

# Pure decision logic for the multi-lobby browser rows (no scene, no autoload
# references — headless-testable via tests/test_lobby_browser.gd; the Config
# autoload identifier is unavailable under `godot --script`, so map names are
# resolved through a preload of the config script instead).

const _CFG := preload("res://scripts/config.gd")

# Given a room number, the HTTP status code, and the parsed /status/<room>
# payload (Dictionary, or anything else on bad data), returns what the browser
# row must display: { text, color, btn, btn_color, disabled }
static func format_room_row(room: int, code: int, st: Variant) -> Dictionary:
	var grey := Color(0.5, 0.5, 0.55)
	if code != 200:
		return { "text": "Room %d — offline" % room, "color": grey,
			"btn": "—", "btn_color": Color(0.25, 0.28, 0.35), "disabled": true }
	if not st is Dictionary:
		return { "text": "Room %d — bad status" % room, "color": grey,
			"btn": "—", "btn_color": Color(0.25, 0.28, 0.35), "disabled": true }

	var players: int  = int(st.get("players", 0))
	var maxp:    int  = int(st.get("max", 10))
	var started: bool = bool(st.get("started", false))
	var map_id:  int  = int(st.get("map", 1))
	var elapsed: int  = int(st.get("elapsed", 0))
	var full: bool    = players >= maxp

	if players == 0:
		return { "text": "Room %d  —  Empty" % room,
			"color": Color(0.65, 0.95, 0.65),
			"btn": "CREATE", "btn_color": Color(0.20, 0.60, 0.25), "disabled": false }
	if not started:
		return { "text": "Room %d  —  In lobby  —  %d/%d players" % [room, players, maxp],
			"color": Color(0.85, 0.92, 1.0),
			"btn": "FULL" if full else "JOIN",
			"btn_color": Color(0.15, 0.40, 0.80), "disabled": full }
	var mins: int = int(float(elapsed) / 60.0)
	var secs: int = elapsed % 60
	return { "text": "Room %d  —  %s  —  %d/%d  —  playing %d:%02d" % [
			room, _CFG.map_name(map_id), players, maxp, mins, secs],
		"color": Color(1.0, 0.85, 0.45),
		"btn": "FULL" if full else "JOIN",
		"btn_color": Color(0.75, 0.45, 0.10), "disabled": full }
