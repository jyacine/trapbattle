extends Node

# Multiplayer: maze seed shared by host; 0 = random
var maze_seed: int = 0



# ── Map / Level selection (set from menu or directly) ──────────────────────
# selected_map: 1 = Dungeon (brick/stone), 2 = Ice Cave (ice/frost)
var selected_map: int = 1
var selected_level: String = "medium"   # "easy" | "medium" | "hard"

# ── Grid / Maze ─────────────────────────────────────────────────────────────
const MAZE_COLS       = 27
const MAZE_ROWS       = 27
const EXTRA_PASSAGES  = 60
const CELL_SIZE       = 2.0   # world units per grid cell

# ── Multiplayer ─────────────────────────────────────────────────────────────
const MAX_PLAYERS = 10

const PLAYER_COLORS: Array = [
	Color(0.20, 0.85, 1.00),   # 0 cyan
	Color(1.00, 0.30, 0.30),   # 1 red
	Color(0.30, 1.00, 0.35),   # 2 green
	Color(1.00, 0.90, 0.15),   # 3 yellow
	Color(0.75, 0.30, 1.00),   # 4 purple
	Color(1.00, 0.50, 0.05),   # 5 orange
	Color(0.00, 0.95, 0.75),   # 6 teal
	Color(1.00, 0.40, 0.85),   # 7 pink
	Color(0.55, 0.95, 0.05),   # 8 lime
	Color(0.95, 0.78, 0.55),   # 9 sand
]

# ── HP ──────────────────────────────────────────────────────────────────────
const MAX_HP     = 100
const HIT_DAMAGE = 15

# ── Player ──────────────────────────────────────────────────────────────────
const PLAYER_SPEED            = 3.2
const PLAYER_ROTATION_SPEED   = 2.3
const PLAYER_RADIUS           = 0.28
const MOUSE_SENSITIVITY       = 0.003

# ── Robot AI ────────────────────────────────────────────────────────────────
const ROBOT_SPEED             = 2.2   # always a bit slower than player
const ROBOT_DETECTION_RADIUS  = 14.0  # how far it "sees" the player
const ROBOT_CATCH_DISTANCE    = 1.2   # too close = dangerous

# ── Game rules ──────────────────────────────────────────────────────────────
const KILLS_TO_WIN  = 3   # first to 3 kills wins
const PLAYER_LIVES  = 3
const ROBOT_LIVES   = 3

# ── Trap boxes ──────────────────────────────────────────────────────────────
const NUM_TRAP_BOXES     = 6
const BOX_MOVE_INTERVAL  = 4.0   # seconds between box moves

# ── Trap types enum ─────────────────────────────────────────────────────────
# Used as int keys everywhere; string names shown in HUD
enum TrapType {
	PITFALL        = 0,   # instant death / lose a life
	BOMB           = 1,   # 2-second fuse, then area kill
	SPIKE          = 2,   # instant kill (like pitfall, no telegraph)
	FREEZE         = 3,   # move speed * 0.25 for 5 s
	TELEPORT       = 4,   # warp to random far floor cell
	CONFUSION      = 5,   # invert movement for 5 s
	FIRE_BURST     = 6,   # fire zone for 3 s, kills on contact
	ELECTRIC_NET   = 7,   # 3-tile stun line for 3 s
	GLUE           = 8,   # stop movement for 3 s
	POISON         = 9,   # die after 4 s delay
	BLIND          = 10,  # white-screen flash for 3 s (player only)
	CAGE           = 11,  # locked in place for 5 s
	LURE           = 12,  # fake box that explodes when robot approaches
	TURRET         = 13,  # auto-shooter turret, fires for 6 s
	MIRROR         = 14,  # reflect next trap back at its owner
}

const TRAP_NAMES: Dictionary = {
	0:  "Pitfall",
	1:  "Bomb",
	2:  "Spike Floor",
	3:  "Freeze",
	4:  "Teleport",
	5:  "Confusion",
	6:  "Fire Burst",
	7:  "Electric Net",
	8:  "Glue",
	9:  "Poison",
	10: "Blind Flash",
	11: "Cage",
	12: "Lure Decoy",
	13: "Turret",
	14: "Mirror Shield",
}

const TRAP_COLORS: Dictionary = {
	0:  Color(0.3, 0.2, 0.1),   # Pitfall    – dark brown
	1:  Color(1.0, 0.4, 0.0),   # Bomb       – orange
	2:  Color(0.6, 0.0, 0.0),   # Spike      – blood red
	3:  Color(0.2, 0.6, 1.0),   # Freeze     – ice blue
	4:  Color(0.6, 0.0, 0.8),   # Teleport   – purple
	5:  Color(0.0, 0.8, 0.4),   # Confusion  – teal
	6:  Color(1.0, 0.2, 0.0),   # Fire Burst – red-orange
	7:  Color(1.0, 1.0, 0.0),   # E-Net      – yellow
	8:  Color(0.5, 0.4, 0.0),   # Glue       – amber
	9:  Color(0.2, 0.7, 0.1),   # Poison     – green
	10: Color(1.0, 1.0, 1.0),   # Blind      – white
	11: Color(0.4, 0.4, 0.4),   # Cage       – grey
	12: Color(0.9, 0.7, 0.1),   # Lure       – gold
	13: Color(0.8, 0.1, 0.8),   # Turret     – magenta
	14: Color(0.0, 0.9, 0.9),   # Mirror     – cyan
}
