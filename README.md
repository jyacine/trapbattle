# TrapBattle — Client

A 3D multiplayer maze trap-combat game built with **Godot 4.6.3**.  
Set traps, kill the robot, survive. Play online at <https://jyacine.itch.io/battletrap>.

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
    └── voice_manager.gd   # Mic capture, VAD, PCM relay, playback
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
- Audio is downsampled to 11 025 Hz / 8-bit before relay, keeping bandwidth low.
- Requires `audio/driver/enable_input=true` in `project.godot` (already set).
- Inside the itch.io iframe, mic access requires the `allow="microphone"` attribute. Use the fullscreen button if the browser blocks the prompt.
