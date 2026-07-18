extends SceneTree

# Headless test for the multi-lobby browser row logic (RoomStatusScript.format_room_row)
# and the room URL scheme. Validates every server-state the browser must render:
# offline, bad payload, empty (CREATE), waiting lobby (JOIN), running match
# (JOIN + map + elapsed), and full rooms (disabled).
#
# Run:
#   godot --headless --path <project> --script res://tests/test_lobby_browser.gd
# Exit code 0 on pass, 1 on fail.

const ConfigScript := preload("res://scripts/config.gd")
const RoomStatusScript := preload("res://scripts/room_status.gd")

var _failures := 0

func _check(ok: bool, msg: String) -> void:
	print("%s: %s" % ["PASS" if ok else "FAIL", msg])
	if not ok:
		_failures += 1

func _init() -> void:
	# 1) Offline room (HTTP error / unreachable) â†’ disabled row.
	var r1: Dictionary = RoomStatusScript.format_room_row(2, 0, null)
	_check(r1["disabled"] and r1["text"].contains("offline"),
		"offline room disabled: '%s'" % r1["text"])

	# 2) HTTP 200 but non-JSON payload â†’ disabled row.
	var r2: Dictionary = RoomStatusScript.format_room_row(1, 200, "garbage")
	_check(r2["disabled"] and r2["text"].contains("bad status"),
		"bad payload disabled: '%s'" % r2["text"])

	# 3) Empty room â†’ CREATE, enabled.
	var r3: Dictionary = RoomStatusScript.format_room_row(1, 200,
		{ "map": 1, "players": 0, "max": 10, "started": false, "elapsed": 0 })
	_check(r3["btn"] == "CREATE" and not r3["disabled"],
		"empty room offers CREATE: '%s'" % r3["text"])

	# 4) Waiting lobby â†’ JOIN, shows player count.
	var r4: Dictionary = RoomStatusScript.format_room_row(2, 200,
		{ "map": 1, "players": 3, "max": 10, "started": false, "elapsed": 0 })
	_check(r4["btn"] == "JOIN" and not r4["disabled"] and r4["text"].contains("3/10"),
		"waiting lobby: '%s'" % r4["text"])

	# 5) Running match â†’ JOIN (late join), shows map name + elapsed mm:ss.
	var r5: Dictionary = RoomStatusScript.format_room_row(3, 200,
		{ "map": 1, "players": 2, "max": 10, "started": true, "elapsed": 754 })
	_check(r5["btn"] == "JOIN" and not r5["disabled"],
		"running match joinable (late join): '%s'" % r5["text"])
	_check(r5["text"].contains("12:34"),
		"elapsed 754 s renders 12:34: '%s'" % r5["text"])
	_check(r5["text"].contains(ConfigScript.map_name(1)),
		"map name shown: '%s'" % r5["text"])

	# 6) Full running match â†’ disabled FULL.
	var r6: Dictionary = RoomStatusScript.format_room_row(4, 200,
		{ "map": 2, "players": 10, "max": 10, "started": true, "elapsed": 60 })
	_check(r6["btn"] == "FULL" and r6["disabled"],
		"full match disabled: '%s'" % r6["text"])

	# 7) Full waiting lobby â†’ also disabled.
	var r7: Dictionary = RoomStatusScript.format_room_row(1, 200,
		{ "map": 1, "players": 10, "max": 10, "started": false, "elapsed": 0 })
	_check(r7["disabled"], "full lobby disabled: '%s'" % r7["text"])

	# 8) Missing fields fall back to safe defaults (server version skew).
	var r8: Dictionary = RoomStatusScript.format_room_row(1, 200, {})
	_check(r8["btn"] == "CREATE" and not r8["disabled"],
		"empty dict treated as empty room: '%s'" % r8["text"])

	print("---")
	print("test_lobby_browser: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	quit(0 if _failures == 0 else 1)
