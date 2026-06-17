# TrapBattle — Architecture

System overview for the TrapBattle multiplayer maze game. Covers both repos
(`trapbattle` client + `trapbattle-server` dedicated server), the two networking
planes, and the voice subsystem. Keep this file in sync when the architecture
changes (see [CLAUDE.md](CLAUDE.md)).

---

## 1. Repos & deployment

| Repo | Role | Runtime | Deploy |
|------|------|---------|--------|
| `trapbattle` | Game client | Godot 4.6.3 **Web** export | itch.io (`jyacine/battletrap:web`) via `publish.ps1` |
| `trapbattle-server` | Dedicated authoritative server | Godot 4.6.3 **headless Linux** | Azure VM, behind **Caddy** (TLS on :443 → plain ws :9998) |

The client connects over `wss://<host>:443`; Caddy terminates TLS and reverse-proxies
to the headless server's loopback `ws://127.0.0.1:9998` (Godot's own mbedTLS server
resets browser connections, so TLS is handled by Caddy, not Godot).

---

## 2. Runtime startup flow

`main.gd` (root of `Main.tscn`) → instantiates `NetworkManager` + `LobbyUI` →
on the `start_game` signal it builds the maze, spawns players, and instantiates
`TrapManager`, `SoundManager`, **`VoiceManager` (multiplayer only)**, then `UIManager`.

> **Ordering invariant:** `VoiceManager` must be created **before** `UIManager`,
> because `UIManager._ready()` looks up the `VoiceManager` node to build the mic
> button and wire the speaking indicator. (Regression fixed in PR #13.)

`Config` (`scripts/config.gd`) is the **only autoload** — global constants plus
runtime state (`maze_seed`, `selected_map`, …). Available everywhere without a ref.

---

## 3. Networking planes (kept separate)

```
GAMEPLAY PLANE : WebSocketMultiplayerPeer (TCP/wss) — positions, HP, traps, lobby, RPCs
VOICE CONTROL  : the same RPC channel (reliable)    — voice signaling only
VOICE MEDIA    : WebSocket relay (default)  OR  WebRTC DataChannel (optional, see §6)
```

Player **positions for any spatial audio come from the gameplay plane**, never the
voice plane — the voice plane carries audio only. This keeps the two concerns
decoupled and means proximity/spatialization costs no extra voice bandwidth.

### Multiplayer topology
- **Listen-server** — one client calls `NetworkManager.host_game()`, peers
  `join_game(ip)`. Host peer ID is always `1`.
- **Dedicated server** — `trapbattle-server` runs headless; clients always
  `join_game()` over `wss://`. This is the production path.

`NetworkManager` owns the peer lifecycle, lobby handshake, peer-index assignment,
late-join RPCs, and ping/pong.

### RPC alignment rule (critical)
Client and server must declare the **identical `@rpc` method set + decorators** on
every shared node (`NetworkManager`, `GameManager`, `VoiceManager`, …). Godot routes
RPCs by the method's position in the sorted list, **not by name** — a mismatch
silently misroutes every call. When adding an `@rpc` to a shared script, add it in
**both repos**. (Name-extending an existing method, e.g. `_rpc_voice` →
`_rpc_voice_offer`, sorts after it and preserves existing indices.)

---

## 4. Gameplay subsystems (brief)

| System | Notes |
|--------|-------|
| **Maze** | 27×27 seeded grid (`maze_generator.gd`); walls drawn with one `MultiMeshInstance3D`; collision uses greedy-merged `StaticBody3D` rectangles to avoid ghost-collision jitter. |
| **Movement** | `CharacterBody3D`, `MOTION_MODE_FLOATING`, `move_and_slide()`. Yaw is buffered in `_pending_yaw_delta` (set in input) and drained in `_physics_process` so it only changes once per physics frame. |
| **Touch look** | Mobile look-drag computes its delta from `position - prev`, **not** `event.relative` — Godot inflates `relative` (~2× with two fingers, [#94346]/[#33470]), which snapped the view when moving+turning. (PR #16.) |
| **Gun/bullets** | `_fire_gun()` spawns a `Bullet` on the camera ray; per-frame capsule hit-detection vs the `"players"` group. |
| **Traps** | 15 `Config.TrapType` enum types; `TrapManager` owns placement/activation RPCs; `TrapBox` pickups set `Player.held_trap`. |

[#94346]: https://github.com/godotengine/godot/issues/94346
[#33470]: https://github.com/godotengine/godot/issues/33470

---

## 5. Voice pipeline

```
mic → AudioEffectCapture (bus MUTED, no self-monitoring)
    → VAD (RMS gate, silence not sent)
    → resample 44.1/48k → 16 kHz  (anti-aliased: average input window per output sample)
    → IMA-ADPCM encode (4-bit, ~0.5 byte/sample ≈ 64 kbps while speaking)
    → TRANSPORT (§6)
    ── server relays to other peers ──
    → IMA-ADPCM decode
    → per-speaker JITTER BUFFER (prebuffer ~120 ms, steady fill, re-buffer on underrun)
    → AudioStreamGenerator → AudioStreamPlayer
```

Key decisions:
- **Mic bus muted** so you never hear yourself (the capture effect taps the chain
  before the mute stage, so capture still works). (PR #18.)
- **16 kHz wideband + anti-aliased downsample** for clarity (was 8 kHz with aliasing). (PR #18.)
- **Jitter buffer** smooths bursty arrival; without it the generator underran →
  choppy. (PR #19.)
- The server **relays bytes opaquely** (no decode), so codec/rate are a client-only
  concern — tuning them needs no server change.

UI (`ui_manager.gd`): mic mute/unmute button + per-speaker speaking icon
(`VoiceManager` swaps the mic/mute SVG; speaking icon shown via the
`player_speaking_changed` signal). Glyph icons are SVG textures, not font glyphs
(the default font lacks ♥ ● mic/speaker emoji). (PRs #11, #14.)

---

## 6. Voice transport (two options)

| Transport | Status | Plane | Pros / cons |
|-----------|--------|-------|-------------|
| **WebSocket relay** | **Fallback** | rides the gameplay TCP/wss channel | Simple, no extra infra; but TCP head-of-line blocking causes jitter (masked by the jitter buffer). |
| **WebRTC DataChannel** | **Enabled (`const USE_WEBRTC = true`)** — implemented on both client (`voice_manager.gd`) and server (`voice_relay.gd`). **Activation also requires the `webrtc-native` GDExtension on the deployed server** (below). | separate unreliable/unordered UDP DataChannel | No TCP HOL blocking; STAR relay through the server (not P2P mesh, no IP exposure). |

**WebRTC path details (when enabled):**
- Topology: **star** — each client ↔ server DataChannel; server forwards each
  speaker's audio to the others (`[sender_id i32][ADPCM]`). Not a P2P mesh.
- Signaling (SDP offer/answer + trickle ICE) rides the **existing reliable RPC
  channel** via `_rpc_voice_offer` / `_rpc_voice_answer` / `_rpc_voice_ice`.
- Negotiated DataChannel `id=1`, `ordered=false`, `maxRetransmits=0`.
- Automatic fallback: until the channel is `STATE_OPEN`, voice uses the WebSocket
  relay, so enabling the flag without a WebRTC-capable server is harmless.

> **Hard requirement to enable:** the headless server build must include the
> **`webrtc-native` GDExtension** — `WebRTCPeerConnection` is a non-functional stub
> on native/headless without it (the **web client has WebRTC built in**, so no
> client addon is needed). Set `USE_WEBRTC = true` in **both** repos and deploy
> them together (RPC alignment).

---

## 7. Pitfalls / invariants

- **RPC alignment** across repos (§3) — the most common silent breakage.
- **GDScript `:=` type inference** on untyped `Node`/`Array`/`Dictionary` access
  infers `Variant` → warning-as-error. Use explicit `var x: Type = …`.
- **Tabs, not spaces** in GDScript (getter blocks especially) or the whole class
  fails to parse.
- **Headless export must pass (exit 0)** before any commit/deploy — the required gate.
