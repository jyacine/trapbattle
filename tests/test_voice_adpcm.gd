extends SceneTree

# Headless test for the voice relay optimisation (VoiceManager IMA-ADPCM codec).
# Asserts the encoder/decoder round-trip is faithful, that packets compress to
# ~half a byte per sample (vs the old 1 byte/sample 8-bit PCM), and that decoding
# is self-contained (each packet carries its own predictor/index header).
#
# Run:
#   godot --headless --path <project> --script res://tests/test_voice_adpcm.gd
# Exit code is 0 on pass, 1 on fail.

const REPORT_PATH := "C:/work/game/report/test_voice_adpcm_result.txt"

var _lines: PackedStringArray = []
var _failures := 0

func _check(ok: bool, msg: String) -> void:
	var tag := "PASS" if ok else "FAIL"
	if not ok:
		_failures += 1
	_lines.append("%s: %s" % [tag, msg])

func _make_sine(n: int, freq: float, rate: float, amp: float) -> PackedFloat32Array:
	var sig := PackedFloat32Array()
	sig.resize(n)
	for i in n:
		sig[i] = amp * sin(TAU * freq * float(i) / rate)
	return sig

func _init() -> void:
	var n := 800
	var rate := float(VoiceManager.VOICE_RATE)   # voice send/playback rate
	var sig := _make_sine(n, 220.0, rate, 0.5)

	var enc := VoiceManager.adpcm_encode(sig, 0, 0)
	var bytes: PackedByteArray = enc["bytes"]
	var dec := VoiceManager.adpcm_decode(bytes)

	# 1) Decoded length matches the input (packing is two samples per byte).
	_check(absi(dec.size() - n) <= 1, "decoded length %d ≈ input %d" % [dec.size(), n])

	# 2) Compression: ≤ ~0.5 byte/sample + a 3-byte header (was 1.0 byte/sample).
	var max_bytes := 3 + (n + 1) / 2
	_check(bytes.size() <= max_bytes, "packet %d bytes ≤ %d" % [bytes.size(), max_bytes])
	var bps := float(bytes.size()) / float(n)
	_check(bps <= 0.6, "%.3f bytes/sample (8-bit PCM was 1.0)" % bps)

	# 3) Fidelity: mean absolute round-trip error stays small.
	var err := 0.0
	var m: int = min(dec.size(), n)
	for i in m:
		err += absf(dec[i] - sig[i])
	err /= float(max(1, m))
	_check(err < 0.06, "mean abs round-trip error %.4f < 0.06" % err)

	# 4) Self-contained packets: decoding a second block on its own (fresh decode,
	#    no shared state) still tracks — i.e. the header seeds it correctly.
	var enc2 := VoiceManager.adpcm_encode(sig, enc["predictor"], enc["index"])
	var dec2 := VoiceManager.adpcm_decode(enc2["bytes"])
	var err2 := 0.0
	var m2: int = min(dec2.size(), n)
	for i in m2:
		err2 += absf(dec2[i] - sig[i])
	err2 /= float(max(1, m2))
	_check(err2 < 0.06, "second packet decodes standalone (err %.4f)" % err2)

	_test_resampler_continuity()

	var summary := "ALL TESTS PASSED" if _failures == 0 else ("%d TEST(S) FAILED" % _failures)
	_lines.append(summary)
	var report := "\n".join(_lines)
	print(report)

	var f := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if f:
		f.store_string(report + "\n")
		f.close()

	quit(0 if _failures == 0 else 1)

# Streaming resampler: feeding the source in 20 ms chunks (the live mic path) must
# produce the SAME output stream as resampling it all in one shot. This is the core
# guarantee that fixed the per-chunk discontinuity ("buzz"). Also checks the chunked
# output has no abrupt sample jumps a continuous resampler wouldn't make.
func _test_resampler_continuity() -> void:
	var src_rate := 44100.0
	var dst_rate := float(VoiceManager.VOICE_RATE)
	var sig := _make_sine(44100, 440.0, src_rate, 0.5)   # 1 s tone

	# One-shot reference.
	var one := VoiceManager.resample_stream(sig, src_rate, dst_rate, 0.0)
	var full: PackedFloat32Array = one["out"]

	# Chunked (simulate ~20 ms mic reads), carrying tail + cursor between calls.
	var chunked := PackedFloat32Array()
	var buf := PackedFloat32Array()
	var pos := 0.0
	var chunk := int(src_rate * 0.02)
	var off := 0
	while off < sig.size():
		var endi: int = min(off + chunk, sig.size())
		buf.append_array(sig.slice(off, endi))
		var r := VoiceManager.resample_stream(buf, src_rate, dst_rate, pos)
		chunked.append_array(r["out"])
		buf = r["tail"]
		pos = r["pos"]
		off = endi

	_check(absi(chunked.size() - full.size()) <= 1,
		"chunked resample len %d ≈ one-shot %d" % [chunked.size(), full.size()])

	var m: int = min(chunked.size(), full.size())
	var maxd := 0.0
	for i in m:
		maxd = maxf(maxd, absf(chunked[i] - full[i]))
	_check(maxd < 1e-5, "chunked == one-shot (max sample diff %.8f)" % maxd)

	# Continuity: a clean 440 Hz tone resampled to 24 kHz must not have per-sample
	# jumps anywhere near a discontinuity (well under the tone's own slew).
	var maxjump := 0.0
	for i in range(1, full.size()):
		maxjump = maxf(maxjump, absf(full[i] - full[i - 1]))
	_check(maxjump < 0.2, "no resample discontinuities (max step %.4f)" % maxjump)
