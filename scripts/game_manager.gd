extends Node

class_name GameManager

# ── Maze data ───────────────────────────────────────────────────────────────
var grid: Array          # 2D array: 0=floor 1=wall
var player_start: Array  # [col, row]
var robot_start: Array
var box_spawns: Array    # Array of [col, row]

# ── Score / lives ────────────────────────────────────────────────────────────
var player_kills: int = 0
var robot_kills:  int = 0
var player_lives: int = Config.PLAYER_LIVES
var robot_lives:  int = Config.ROBOT_LIVES

# ── HP ───────────────────────────────────────────────────────────────────────
var player_hp: int = Config.MAX_HP
var robot_hp:  int = Config.MAX_HP

# ── State ────────────────────────────────────────────────────────────────────
var is_playing: bool = true
var winner: String = ""   # "player" | "robot" | ""

# ── Active effects on player / robot ────────────────────────────────────────
var player_effects: Dictionary = {}
var robot_effects:  Dictionary = {}

# ── Respawn flags ────────────────────────────────────────────────────────────
var player_respawning: bool = false
var robot_respawning:  bool = false
var player_respawn_timer: float = 0.0
var robot_respawn_timer:  float = 0.0
const RESPAWN_DELAY = 2.0

# ── Floor cells cache ────────────────────────────────────────────────────────
var _floor_cells: Array = []

# ────────────────────────────────────────────────────────────────────────────
func _init() -> void:
	# Use shared seed in multiplayer so both peers generate the same maze
	if Config.maze_seed != 0:
		seed(Config.maze_seed)

	var gen = MazeGenerator.new()
	grid = gen.generate_maze(Config.MAZE_COLS, Config.MAZE_ROWS, Config.EXTRA_PASSAGES)
	var spawns = gen.pick_spawns(grid)
	player_start = spawns["player"]
	robot_start  = spawns["robot"]
	box_spawns   = spawns["boxes"]

	for r in range(grid.size()):
		for c in range(grid[r].size()):
			if grid[r][c] == 0:
				_floor_cells.append([c, r])

# ────────────────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	if not is_playing:
		return

	_tick_effects(player_effects, delta)
	_tick_effects(robot_effects, delta)

	if player_respawning:
		player_respawn_timer -= delta
		if player_respawn_timer <= 0.0:
			player_respawning = false

	if robot_respawning:
		robot_respawn_timer -= delta
		if robot_respawn_timer <= 0.0:
			robot_respawning = false

# ────────────────────────────────────────────────────────────────────────────
func _tick_effects(effects: Dictionary, delta: float) -> void:
	var to_remove = []
	for key in effects.keys():
		effects[key] -= delta
		if effects[key] <= 0.0:
			to_remove.append(key)
	for key in to_remove:
		effects.erase(key)

# ── Damage ───────────────────────────────────────────────────────────────────
## Local damage call (single-player or already replicated).
func damage_target(target: String, amount: int) -> void:
	if target == "player":
		if player_respawning: return
		player_hp = max(0, player_hp - amount)
		if player_hp == 0:
			player_hp = Config.MAX_HP
			player_died()
	else:
		if robot_respawning: return
		robot_hp = max(0, robot_hp - amount)
		if robot_hp == 0:
			robot_hp = Config.MAX_HP
			robot_died()

## Multiplayer: any peer calls this; it runs on ALL peers (call_local) so
## HP stays in sync without a server-authoritative round-trip.
@rpc("any_peer", "call_local", "reliable")
func net_damage(target: String, amount: int) -> void:
	damage_target(target, amount)

## Multiplayer: spawn a visual-only bullet on the remote peer.
## Called by the firing player with call_remote so only the OTHER peer runs it.
@rpc("any_peer", "call_remote", "reliable")
func net_spawn_bullet(pos: Vector3, dir: Vector3, owner_tag: String) -> void:
	var root = get_parent()
	var b = Bullet.new()
	b.local_only    = true   # visual only — no hit detection on this peer
	b.owner_tag     = owner_tag
	b.direction     = dir
	b.game_manager  = self
	b.player_ref    = root.get_node_or_null("Player")
	b.robot_ref     = root.get_node_or_null("Robot")
	b.sound_manager = root.get_node_or_null("SoundManager")
	b.position      = pos
	root.add_child(b)

# ────────────────────────────────────────────────────────────────────────────
func player_died() -> void:
	player_lives -= 1
	robot_kills  += 1
	player_hp    = Config.MAX_HP
	player_effects.clear()
	player_respawning    = true
	player_respawn_timer = RESPAWN_DELAY
	_check_win()

func robot_died() -> void:
	robot_lives  -= 1
	player_kills += 1
	robot_hp     = Config.MAX_HP
	robot_effects.clear()
	robot_respawning    = true
	robot_respawn_timer = RESPAWN_DELAY
	_check_win()

func _check_win() -> void:
	if player_kills >= Config.KILLS_TO_WIN:
		winner = "player"; is_playing = false
	elif robot_kills >= Config.KILLS_TO_WIN:
		winner = "robot";  is_playing = false
	elif player_lives <= 0:
		winner = "robot";  is_playing = false
	elif robot_lives <= 0:
		winner = "player"; is_playing = false

# ── Helpers ──────────────────────────────────────────────────────────────────
func get_random_floor_cell() -> Array:
	return _floor_cells[randi() % _floor_cells.size()]

func get_random_far_floor_cell(from: Array, min_dist: float) -> Array:
	var cands = []
	for cell in _floor_cells:
		var d = sqrt(float((cell[0]-from[0])*(cell[0]-from[0]) + (cell[1]-from[1])*(cell[1]-from[1])))
		if d >= min_dist:
			cands.append(cell)
	if cands.size() == 0:
		return get_random_floor_cell()
	return cands[randi() % cands.size()]

func has_effect(target: String, effect: String) -> bool:
	if target == "player":
		return player_effects.has(effect)
	return robot_effects.has(effect)

func add_effect(target: String, effect: String, duration: float) -> void:
	if target == "player":
		player_effects[effect] = duration
	else:
		robot_effects[effect] = duration

func grid_to_world(cell: Array) -> Vector3:
	var cs = Config.CELL_SIZE
	return Vector3((cell[0] + 0.5) * cs, 0.0, (cell[1] + 0.5) * cs)

func world_to_grid(pos: Vector3) -> Array:
	var cs = Config.CELL_SIZE
	return [int(pos.x / cs), int(pos.z / cs)]

func is_floor(col: int, row: int) -> bool:
	if row < 0 or row >= grid.size() or col < 0 or col >= grid[0].size():
		return false
	return grid[row][col] == 0
