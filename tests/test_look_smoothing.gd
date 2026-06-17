extends SceneTree

# Headless test for the mobile look-turn fix (Player.compute_look_step).
# Simulates the player buffering a large look swipe during a frame hitch and
# asserts the per-frame turn is bounded on touch (so the view can't snap, which
# read as "chaotic" movement when turning while moving), while desktop mouse
# stays uncapped.
#
# Run:
#   godot --headless --path <project> --script res://tests/test_look_smoothing.gd
# Result is printed and also written to C:/work/game/report/test_look_smoothing_result.txt
# (stdout capture is unreliable in some shells). Exit code is 0 on pass, 1 on fail.
const REPORT_PATH := "C:/work/game/report/test_look_smoothing_result.txt"

var _lines: PackedStringArray = []
var _failures := 0

func _check(ok: bool, msg: String) -> void:
	var tag := "PASS" if ok else "FAIL"
	if not ok:
		_failures += 1
	_lines.append("%s: %s" % [tag, msg])

func _init() -> void:
	var hitch_dt := 1.0      # a 1-second frame hitch (extreme)
	var huge_swipe := 100.0  # absurd buffered look delta
	# The blend uses a timestep clamped to 1/30 s, which also bounds the touch cap.
	var touch_cap: float = Player.TOUCH_MAX_LOOK_RATE * (1.0 / 30.0)

	# 1) Touch + huge buffer + frame hitch → step must stay within the turn cap.
	var touch_step: float = Player.compute_look_step(huge_swipe, hitch_dt, true)
	_check(absf(touch_step) <= touch_cap + 0.0001,
		"touch step %.4f <= cap %.4f" % [touch_step, touch_cap])

	# 2) Desktop mouse is intentionally uncapped → turns faster than the touch cap.
	var mouse_step: float = Player.compute_look_step(huge_swipe, hitch_dt, false)
	_check(absf(mouse_step) > touch_cap,
		"desktop step %.4f > touch cap %.4f" % [mouse_step, touch_cap])

	# 3) A normal small swipe still drains (responsive, correct sign, no overshoot).
	var small_step: float = Player.compute_look_step(0.05, 1.0 / 60.0, true)
	_check(small_step > 0.0 and small_step <= 0.05,
		"small swipe drains (%.5f)" % small_step)

	# 4) Repeated frames fully drain a max buffer (no lingering runaway spin).
	var pending := Player.MAX_PENDING_YAW
	var frames := 0
	while absf(pending) > 0.001 and frames < 600:
		pending = clampf(pending, -Player.MAX_PENDING_YAW, Player.MAX_PENDING_YAW)
		pending -= Player.compute_look_step(pending, 1.0 / 60.0, true)
		frames += 1
	_check(frames < 600, "buffer drained in %d frames" % frames)

	var summary := "ALL TESTS PASSED" if _failures == 0 else ("%d TEST(S) FAILED" % _failures)
	_lines.append(summary)
	var report := "\n".join(_lines)
	print(report)

	var f := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if f:
		f.store_string(report + "\n")
		f.close()

	quit(0 if _failures == 0 else 1)
