extends Node

class_name MazeGenerator

static func generate_maze(cols: int, rows: int, extra: int) -> Array:
	cols = _odd(cols)
	rows = _odd(rows)

	var grid = []
	for r in range(rows):
		grid.append([])
		for c in range(cols):
			grid[r].append(1)

	_carve(grid, rows, cols, 1, 1)
	_add_loops(grid, rows, cols, extra)

	return grid

static func _odd(n: int) -> int:
	return n if n % 2 == 1 else n - 1

static func _carve(grid: Array, rows: int, cols: int, start_r: int, start_c: int) -> void:
	var stack = [[start_r, start_c]]
	grid[start_r][start_c] = 0

	while stack.size() > 0:
		var cr = stack[-1][0]
		var cc = stack[-1][1]
		var dirs = [[-2, 0], [2, 0], [0, -2], [0, 2]]
		dirs.shuffle()

		var moved = false
		for dir in dirs:
			var dr = dir[0]
			var dc = dir[1]
			var nr = cr + dr
			var nc = cc + dc

			if nr > 0 and nr < rows - 1 and nc > 0 and nc < cols - 1 and grid[nr][nc] == 1:
				grid[cr + dr/2][cc + dc/2] = 0
				grid[nr][nc] = 0
				stack.append([nr, nc])
				moved = true
				break

		if not moved:
			stack.pop_back()

static func _add_loops(grid: Array, rows: int, cols: int, count: int) -> void:
	var candidates = []
	for r in range(1, rows - 1):
		for c in range(1, cols - 1):
			if grid[r][c] == 1:
				if (grid[r][c-1] == 0 and grid[r][c+1] == 0) or \
				   (grid[r-1][c] == 0 and grid[r+1][c] == 0):
					candidates.append([r, c])

	candidates.shuffle()
	for i in range(min(count, candidates.size())):
		var cell = candidates[i]
		grid[cell[0]][cell[1]] = 0

static func pick_spawns(grid: Array, count: int = 2) -> Dictionary:
	var rows   = grid.size()
	var cols   = grid[0].size()
	var floors = _get_floor_cells(grid)

	# Up to 10 well-spread target positions across the maze
	var targets: Array = [
		[cols / 6,       rows / 6      ],   # top-left
		[cols * 5 / 6,   rows * 5 / 6  ],   # bottom-right
		[cols * 5 / 6,   rows / 6      ],   # top-right
		[cols / 6,       rows * 5 / 6  ],   # bottom-left
		[cols / 2,       rows / 6      ],   # top-center
		[cols / 2,       rows * 5 / 6  ],   # bottom-center
		[cols / 6,       rows / 2      ],   # mid-left
		[cols * 5 / 6,   rows / 2      ],   # mid-right
		[cols / 3,       rows / 3      ],   # inner TL
		[cols * 2 / 3,   rows * 2 / 3  ],   # inner BR
	]

	var spawn_cells: Array = []
	var used: Array = []
	for i in range(min(count, targets.size())):
		var t   = targets[i]
		var best: Array = []
		var bd  = 999999.0
		for cell in floors:
			var d = _distance(cell, t)
			if d < bd and cell not in used:
				bd = d; best = cell
		if best.size() > 0:
			spawn_cells.append(best)
			used.append(best)

	# Fill remaining if needed (shouldn't happen with MAX_PLAYERS ≤ 10)
	if spawn_cells.size() < count:
		var shuffled = floors.duplicate(); shuffled.shuffle()
		for cell in shuffled:
			if spawn_cells.size() >= count: break
			if cell not in used:
				spawn_cells.append(cell); used.append(cell)

	# Trap box spawns: spread across remaining floor cells
	var box_cells: Array = []
	var shuffled2 = floors.duplicate(); shuffled2.shuffle()
	for cell in shuffled2:
		if box_cells.size() >= Config.NUM_TRAP_BOXES: break
		if cell not in used and _min_dist(cell, spawn_cells) > cols * 0.15:
			box_cells.append(cell); used.append(cell)

	return { "spawns": spawn_cells, "boxes": box_cells }

static func _min_dist(cell: Array, others: Array) -> float:
	var md = 999999.0
	for o in others:
		md = min(md, _distance(cell, o))
	return md

static func _get_floor_cells(grid: Array) -> Array:
	var cells = []
	for r in range(grid.size()):
		for c in range(grid[r].size()):
			if grid[r][c] == 0:
				cells.append([c, r])
	return cells

static func _distance(a: Array, b: Array) -> float:
	return sqrt(float((a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1])))
