extends SceneTree

# Headless test for the mobile-web name-input fix (LobbyUI._js_escape).
# The fix edits LineEdit fields through a native window.prompt() on touch phones
# (the Godot canvas can't raise the browser soft keyboard). The current field text
# is interpolated into a single-quoted JS string literal, so it must be escaped or
# a name containing ' or \ would break the prompt call. This asserts that escaping.
#
# Run:
#   godot --headless --path <project> --script res://tests/test_name_input.gd
# Result is printed and written to C:/work/game/report/test_name_input_result.txt.
# Exit code is 0 on pass, 1 on fail.
const REPORT_PATH := "C:/work/game/report/test_name_input_result.txt"

var _lines: PackedStringArray = []
var _failures := 0

func _check(ok: bool, msg: String) -> void:
	var tag := "PASS" if ok else "FAIL"
	if not ok:
		_failures += 1
	_lines.append("%s: %s" % [tag, msg])

func _init() -> void:
	# 1) A single quote (e.g. O'Brien) is backslash-escaped so it can't terminate
	#    the JS string literal early.
	var q := LobbyUI._js_escape("O'Brien")
	_check(q == "O\\'Brien", "single quote escaped (%s)" % q)

	# 2) A backslash is doubled (and done before quotes so it can't double-escape).
	var b := LobbyUI._js_escape("a\\b")
	_check(b == "a\\\\b", "backslash doubled (%s)" % b)

	# 3) Backslash followed by quote: \ → \\ and ' → \', i.e. \' becomes \\\'.
	var bq := LobbyUI._js_escape("\\'")
	_check(bq == "\\\\\\'", "backslash+quote escaped (%s)" % bq)

	# 4) Newlines/carriage returns are flattened to spaces (a prompt label is one line).
	var nl := LobbyUI._js_escape("line1\nline2\r")
	_check(nl == "line1 line2 ", "newlines flattened (%s)" % nl)

	# 5) Ordinary text is returned unchanged.
	var plain := LobbyUI._js_escape("Player_1234")
	_check(plain == "Player_1234", "plain text unchanged (%s)" % plain)

	var summary := "ALL TESTS PASSED" if _failures == 0 else ("%d TEST(S) FAILED" % _failures)
	_lines.append(summary)
	var report := "\n".join(_lines)
	print(report)

	var f := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if f:
		f.store_string(report + "\n")
		f.close()

	quit(0 if _failures == 0 else 1)
