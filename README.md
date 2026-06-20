# TrapBattle — Client

A 3D multiplayer maze trap-combat game built with **Godot 4.6.3**.  
Set traps, kill the robot, survive. Play online at <https://jyacine.itch.io/battletrap>.

> **Architecture:** see [architecture.md](architecture.md) for the full system
> design (client + dedicated server, networking planes, voice pipeline/transport).

---

## Project structure

```
trapbattle/
├── project.godot          # Godot project config (mic input enabled)
├── export_presets.cfg     # Export preset: "Web" → export/index.html
├── scenes/
│   └── Main.tscn          # Root scene (autoloads Config)
└── scripts/
    ├── config.gd          # Autoload — global constants (server host, etc.)
    ├── main.gd            # Scene entry point, wires managers together
    ├── network_manager.gd # Multiplayer peer, WebSocket connect / RPC dispatch
    ├── lobby_ui.gd        # Lobby screen — host input, connect button, status
    ├── lobby_room.gd      # In-lobby state (waiting for second player)
    ├── game_manager.gd    # HP, lives, kills, respawn logic
    ├── trap_manager.gd    # Trap placement and activation
    ├── maze_generator.gd  # Procedural maze (seeded, same seed on all peers)
    ├── pathfinding.gd     # Robot A* navigation
    ├── player.gd          # Local player movement & actions
    ├── robot.gd           # AI robot controller
    ├── bullet.gd          # Projectile physics
    ├── trap_box.gd        # Individual trap node
    ├── sound_manager.gd   # SFX playback
    ├── ui_manager.gd      # HUD, voice icon, mute button
    └── voice_manager.gd   # Mic capture, VAD, ADPCM, jitter-buffered playback, relay
```

---

## Prerequisites

| Tool | Version / notes |
|------|----------------|
| Godot | 4.6.3 stable (`Godot_v4.6.3-stable_win64.exe`) |
| butler | itch.io uploader — `C:\work\tools\butler.exe` |

---

## How to export (Web)

1. Open the project in Godot, or use the CLI:

```powershell
$GODOT = "<path to Godot executable>"
& $GODOT --headless --path "<path to trapbattle>" --export-release "Web" "export/index.html"
```

The preset outputs to `export/index.html` (and companion `index.js`, `index.wasm`, etc.).  
The `export/` directory is git-ignored.

---

## How to deploy to itch.io

The live game is on the **`web`** channel (not `html5`) at <https://jyacine.itch.io/battletrap>.

```powershell
# Remove any stale TrapBattle.* files left from old naming
Remove-Item "C:\work\game\trapbattle\export\TrapBattle.*" -ErrorAction SilentlyContinue

# Push the web build
& "C:\work\tools\butler.exe" push "C:\work\game\trapbattle\export" jyacine/battletrap:web
```

After pushing, make sure the itch.io embed has:
- **SharedArrayBuffer** enabled (required for Godot web threading)
- `allow="microphone"` on the iframe (required for voice chat)

---

## How to run locally

Open `project.godot` in the Godot editor and press **F5** (or Run).

To test multiplayer locally, you need the dedicated server running — see [trapbattle-server](../trapbattle-server/README.md).  
The default lobby host is `172-174-208-254.nip.io` (the live Azure VM). Change it in `scripts/config.gd` or type a different address in the lobby UI.

---

## Networking

- Connects via `wss://172-174-208-254.nip.io` (port 443, TLS terminated by Caddy on the VM).
- Uses Godot High-Level Multiplayer API over WebSocketMultiplayerPeer.
- RPCs are routed by alphabetical index — client and server must declare **identical `@rpc` method sets** on each shared node or calls will be silently misrouted.

## Voice chat

- Press **V** or the on-screen button to toggle mute (mic is open by default).
- Voice Activity Detection (VAD) gates transmission — silence is never sent.
- Audio is anti-alias downsampled to **16 kHz wideband** and **IMA-ADPCM** (4-bit,
  ~64 kbps while speaking) before relay through the server.
- The mic bus is muted locally, so you never hear yourself. A per-speaker **jitter
  buffer** smooths bursty arrival on playback.
- **Transport:** WebSocket relay by default; an optional **WebRTC DataChannel** path
  (UDP, off the TCP plane) exists behind `const USE_WEBRTC` — see
  [architecture.md §6](architecture.md#6-voice-transport-two-options).
- Requires `audio/driver/enable_input=true` in `project.godot` (already set).
- Inside the itch.io iframe, mic access requires the `allow="microphone"` attribute. Use the fullscreen button if the browser blocks the prompt.

---

## E2E voice communication test

An automated end-to-end test that:
1. Generates a 12-second chirp audio file covering the speech band (100 Hz – 4 kHz).
2. Launches **two headless Godot processes** that connect to the live dedicated server
   as Player 1 (sender) and Player 2 (receiver).
3. Player 1 streams the audio through the server's voice relay for 10 seconds.
4. Player 2 captures all received voice packets and saves them to a WAV file.
5. The Python orchestrator compares original vs received audio and produces a
   quality report (SNR, Pearson correlation, optional PESQ MOS, packet-loss estimate).

Output goes to `test_report/<timestamp>/` (git-ignored):
- `voice_test.wav` — original test signal
- `voice_received.wav` — what Player 2 heard
- `report.md` — step-by-step log + quality metrics

### Prerequisites

| Item | Requirement |
|------|-------------|
| Python | 3.10+ |
| NumPy / SciPy | `pip install -r tests/requirements.txt` |
| Godot | `C:\Users\XDGT0500\Downloads\Godot_v4.6.3-stable_win64.exe` |
| Server | Live VM at `172.174.208.254` must be running; **no other players connected** |

Optional: `pip install pesq` for an ITU-T P.862 PESQ MOS score.

### Run

```powershell
# From the trapbattle project root:
cd C:\work\game\trapbattle
pip install -r tests/requirements.txt      # first time only
python tests/e2e_voice_test.py
```

The test takes approximately **40 seconds** to complete:

| Phase | Duration |
|-------|----------|
| Generate test audio | < 1 s |
| Receiver connects + waits in lobby | ~3 s |
| Sender connects, starts game, transmits 10 s | ~15 s |
| Receiver finishes collecting + saves WAV | ~3 s |
| Quality analysis + report | < 1 s |

### Pass/fail criteria

| Metric | Pass threshold |
|--------|----------------|
| SNR | > 10 dB |
| Pearson correlation | > 0.60 |
| Estimated packet loss | < 20 % |

### Interpreting results

- **SNR > 20 dB** → excellent; ADPCM codec is transparent at this level.
- **SNR 10–20 dB** → acceptable for voice; some quantisation noise audible.
- **SNR < 10 dB** → packet loss or network issues are dominating.
- **Low correlation with non-trivial SNR** → timing/delay misalignment (check server relay latency).
- **Large delay\_ms** → normal for the WebSocket-relay path (~50–200 ms); very large values (> 500 ms) indicate jitter or buffering issues.

### How it works internally

```
Python orchestrator
  │
  ├─ starts tests/voice_receiver.gd  (headless Godot, Player 2)
  │    └─ connects → lobby → waits for game start
  │
  └─ starts tests/voice_sender.gd    (headless Godot, Player 1)
       ├─ connects → lobby → sends start → transmits 10 s of ADPCM
       └─ server relays each packet to Player 2 via _rpc_play_voice

Player 2 receives → decodes ADPCM → saves 24 kHz mono WAV
Python measures SNR / correlation / PESQ and writes report.md
```

Both headless processes connect via `wss://172-174-208-254.nip.io` with default TLS
(the nip.io host has a valid Let's Encrypt cert provisioned by Caddy) — exactly the
same URL and TLS path the real game client uses. A bare-IP URL or `client_unsafe()`
fails the handshake because Caddy needs SNI to select the cert.
