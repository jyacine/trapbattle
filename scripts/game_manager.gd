extends Node

class_name GameManager

# ── Maze data ───────────────────────────────────────────────────────────────
var grid: Array
var spawns: Array        # Array of [col, row] — up to MAX_PLAYERS spawn points
var player_start: Array  # spawns[0] — backward compat
var robot_start: Array   # spawns[1] — backward compat
var box_spawns: Array

# ── Per-player state (keyed by peer_id) ─────────────────────────────────────
var player_ids: Array      = []   # ordered list, index = player_index
var hp:         Dictionary = {}
var lives:      Dictionary = {}
var kills:      Dictionary = {}
var effects:    Dictionary = {}   # peer_id -> {effect_name: timer}
var respawning: Dictionary = {}
var _respawn_timers: Dictionary = {}
var _last_damager:   Dictionary = {}   # victim_pid -> attacker_pid

const RESPAWN_DELAY = 2.0

# ── Game state ───────────────────────────────────────────────────────────────
var is_playing: bool = true
var winner_pid: int  = -1   # peer_id of winner; -1 = no winner yet

# ── Backward-compat read-only props (SP: player=pid 1, robot=pid 0) ──────────
var player_hp: int:
	get: return hp.get(1, Config.MAX_HP)
var robot_hp: int:
	get: return hp.get(0, Config.MAX_HP)
var player_lives: int:
	get: return lives.get(1, Config.PLAYER_LIVES)
var robot_lives: int:
	get: return lives.get(0, Config.PLAYER_LIVES)
var player_kills: int:
	get: return kills.get(1, 0)
var robot_kills: int:
	get: return kills.get(0, 0)
var player_respawning: bool:
	get: return respawning.get(1, false)
var robot_respawning: bool:
	get: return respawning.get(0, false)
var player_effects: Dictionary:
	get: return effects.get(1, {})
var robot_effects: Dictionary:
	get: return effects.get(0, {})
var winner: String:
	get:
		if winner_pid == 1:  return "player"
		if winner_pid == 0:  return "robot"
		if winner_pid != -1: return "player_%d" % winner_pid
		return ""

# ── Floor cells cache ────────────────────────────────────────────────────────
var _floor_cells: Array = []

# ────────────────────────────────────────────────────────────────────────────
func _init() -> void:
	if Config.maze_seed != 0:
		seed(Config.maze_seed)

	var gen  = MazeGenerator.new()
	grid     = gen.generate_maze(Config.MAZE_COLS, Config.MAZE_ROWS, Config.EXTRA_PASSAGES)
	var data = gen.pick_spawns(grid, Config.MAX_PLAYERS)
	spawns      = data["spawns"]
	player_start = spawns[0] if spawns.size() > 0 else [1, 1]
	robot_start  = spawns[1] if spawns.size() > 1 else player_start
	box_spawns   = data["boxes"]

	for r in range(grid.size()):
		for c in range(grid[r].size()):
			if grid[r][c] == 0:
				_floor_cells.append([c, r])

# ── Register a player (call once per peer after spawning) ────────────────────
func register_player(pid: int) -> void:
	if pid in player_ids:
		return
	player_ids.append(pid)
	hp[pid]              = Config.MAX_HP
	lives[pid]           = Config.PLAYER_LIVES
	kills[pid]           = 0
	effects[pid]         = {}
	respawning[pid]      = false
	_respawn_timers[pid] = 0.0

# ────────────────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	if not is_playing:
		return
	for pid in player_ids:
		_tick_effects(effects.get(pid, {}), delta)
		if respawning.get(pid, false):
			_respawn_timers[pid] -= delta
			if _respawn_timers[pid] <= 0.0:
				respawning[pid] = false

func _tick_effects(eff: Dictionary, delta: float) -> void:
	var to_remove: Array = []
	for key in eff.keys():
		eff[key] -= delta
		if eff[key] <= 0.0:
			to_remove.append(key)
	for key in to_remove:
		eff.erase(key)

# ── Damage ───────────────────────────────────────────────────────────────────
func damage_player(victim_pid: int, amount: int, attacker_pid: int = -1) -> void:
	if not hp.has(victim_pid): return
	if respawning.get(victim_pid, false): return
	if attacker_pid != -1:
		_last_damager[victim_pid] = attacker_pid
	hp[victim_pid] = max(0, hp[victim_pid] - amount)
	if hp[victim_pid] == 0:
		_player_died(victim_pid)

## Replicated damage — any peer calls; runs on all peers (call_local).
@rpc("any_peer", "call_local", "reliable")
func net_damage(victim_pid: int, amount: int, attacker_pid: int = -1) -> void:
	damage_player(victim_pid, amount, attacker_pid)

## Backward-compat for TrapManager and Robot which still use string targets.
func damage_target(target, amount: int) -> void:
	damage_player(_to_pid(target), amount)

## Spawn a visual-only bullet on the remote peers.
@rpc("any_peer", "call_remote", "reliable")
func net_spawn_bullet(pos: Vector3, dir: Vector3, owner_pid: int, owner_idx: int) -> void:
	var root = get_parent()
	var b = Bullet.new()
	b.local_only    = true
	b.owner_peer_id = owner_pid
	b.owner_index   = owner_idx
	b.direction     = dir
	b.game_manager  = self
	b.sound_manager = root.get_node_or_null("SoundManager")
	b.position      = pos
	root.add_child(b)

# ────────────────────────────────────────────────────────────────────────────
func _player_died(pid: int) -> void:
	lives[pid] = max(0, lives[pid] - 1)
	hp[pid]    = Config.MAX_HP
	effects[pid].clear()
	respawning[pid]      = true
	_respawn_timers[pid] = RESPAWN_DELAY

	var killer = _last_damager.get(pid, -1)
	if killer != -1 and kills.has(killer):
		kills[killer] += 1

	_check_win()

func _check_win() -> void:
	for pid in player_ids:
		if kills.get(pid, 0) >= Config.KILLS_TO_WIN:
			winner_pid = pid; is_playing = false; return

	var alive: Array = []
	for pid in player_ids:
		if lives.get(pid, 0) > 0:
			alive.append(pid)
	if alive.size() == 1:
		winner_pid = alive[0]; is_playing = false
	elif alive.size() == 0:
		is_playing = false

# ── Effects ──────────────────────────────────────────────────────────────────
func has_effect(target, effect: String) -> bool:
	return effects.get(_to_pid(target), {}).has(effect)

func add_effect(target, effect: String, duration: float) -> void:
	var pid = _to_pid(target)
	if effects.has(pid):
		effects[pid][effect] = duration

func _to_pid(target) -> int:
	if target is String:
		return 1 if target == "player" else 0
	return int(target)

# ── Helpers ──────────────────────────────────────────────────────────────────
func get_random_floor_cell() -> Array:
	return _floor_cells[randi() % _floor_cells.size()]

func get_random_far_floor_cell(from: Array, min_dist: float) -> Array:
	var cands: Array = []
	for cell in _floor_cells:
		var d = sqrt(float((cell[0]-from[0])*(cell[0]-from[0]) + (cell[1]-from[1])*(cell[1]-from[1])))
		if d >= min_dist:
			cands.append(cell)
	if cands.size() == 0:
		return get_random_floor_cell()
	return cands[randi() % cands.size()]

func get_spawn_for_index(idx: int) -> Array:
	if idx < spawns.size():
		return spawns[idx]
	return get_random_floor_cell()

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
