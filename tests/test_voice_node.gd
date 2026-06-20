# Minimal voice RPC stub used by the E2E voice test.
# Placed at /root/Main/VoiceManager so Godot's RPC router maps to the same path
# as the real VoiceManager on every peer. The @rpc methods are declared in
# ALPHABETICAL ORDER (case-sensitive) so their positional indices match
# voice_relay.gd on the server — a mismatch would silently misroute packets.
class_name TestVoiceNode
extends Node

const VOICE_FMT_ADPCM := 0
const VOICE_FMT_PCM16 := 1

# Set to true in the receiver process so _rpc_play_voice saves instead of discards.
var is_receiver: bool = false

# Receiver accumulates decoded PCM samples here.
var received_pcm: PackedFloat32Array = PackedFloat32Array()

# ── RPCs — alphabetical order MUST match voice_relay.gd on the server ─────────

@rpc("authority", "call_remote", "unreliable")
func _rpc_play_voice(audio_bytes: PackedByteArray, _sender_id: int) -> void:
	if not is_receiver:
		return
	if audio_bytes.size() < 2:
		return
	var fmt := int(audio_bytes[0])
	var body := audio_bytes.slice(1)
	var samples: PackedFloat32Array
	if fmt == VOICE_FMT_PCM16:
		samples = _unpack_pcm16(body)
	else:
		samples = VoiceManager.adpcm_decode(body)
	received_pcm.append_array(samples)

@rpc("any_peer", "call_remote", "unreliable")
func _rpc_voice(_audio_bytes: PackedByteArray, _sender_id: int) -> void:
	pass  # handled by the server; client stub is only needed for RPC index alignment

@rpc("authority", "call_remote", "reliable")
func _rpc_voice_answer(_sdp: String) -> void:
	pass

@rpc("any_peer", "call_remote", "reliable")
func _rpc_voice_ice(_media: String, _index: int, _name: String) -> void:
	pass

@rpc("any_peer", "call_remote", "reliable")
func _rpc_voice_offer(_sdp: String) -> void:
	pass

# ── Helpers ────────────────────────────────────────────────────────────────────

static func _unpack_pcm16(body: PackedByteArray) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var n := body.size() / 2
	out.resize(n)
	for i in n:
		var lo := int(body[i * 2])
		var hi := int(body[i * 2 + 1])
		var v: int = lo | (hi << 8)
		if v >= 32768: v -= 65536
		out[i] = float(v) / 32768.0
	return out

func save_wav(path: String, sample_rate: int = VoiceManager.VOICE_RATE) -> bool:
	if received_pcm.is_empty():
		printerr("[TestVoiceNode] No audio received — nothing to save")
		return false
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		printerr("[TestVoiceNode] Cannot write WAV: %s" % path)
		return false

	var n := received_pcm.size()
	var data_bytes := n * 2  # int16
	# RIFF/WAV header
	f.store_buffer("RIFF".to_utf8_buffer())
	f.store_32(36 + data_bytes)
	f.store_buffer("WAVE".to_utf8_buffer())
	f.store_buffer("fmt ".to_utf8_buffer())
	f.store_32(16)           # subchunk1 size
	f.store_16(1)            # PCM
	f.store_16(1)            # mono
	f.store_32(sample_rate)
	f.store_32(sample_rate * 2)  # byte rate
	f.store_16(2)            # block align
	f.store_16(16)           # bits per sample
	f.store_buffer("data".to_utf8_buffer())
	f.store_32(data_bytes)
	for s in received_pcm:
		var v: int = int(clampf(s, -1.0, 1.0) * 32767.0)
		f.store_16(v & 0xFFFF)
	f.close()
	print("[TestVoiceNode] Saved %d samples → %s" % [n, path])
	return true
