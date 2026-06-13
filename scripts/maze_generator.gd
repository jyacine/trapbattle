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

static func pick_spawns(grid: Array) -> Dictionary:
	var rows = grid.size()
	var cols = grid[0].size()
	var floors = _get_floor_cells(grid)

	# Player: top-left quadrant
	var tl = []
	for cell in floors:
		if cell[0] < cols / 3 and cell[1] < rows / 3:
			tl.append(cell)
	var player_cell = tl[randi() % tl.size()] if tl.size() > 0 else floors[randi() % floors.size()]

	# Robot: bottom-right quadrant (opposite corner)
	var br = []
	for cell in floors:
		if cell[0] > cols * 2 / 3 and cell[1] > rows * 2 / 3:
			br.append(cell)
	var robot_cell = br[randi() % br.size()] if br.size() > 0 else floors[randi() % floors.size()]

	# Trap box spawns: spread across the map
	var box_cells = []
	var used = [player_cell, robot_cell]
	var shuffled = floors.duplicate()
	shuffled.shuffle()
	for cell in shuffled:
		if cell not in used and _distance(cell, player_cell) > cols * 0.2:
			box_cells.append(cell)
			used.append(cell)
		if box_cells.size() >= Config.NUM_TRAP_BOXES:
			break

	return {
		"player": player_cell,
		"robot":  robot_cell,
		"boxes":  box_cells,
	}

static func _get_floor_cells(grid: Array) -> Array:
	var cells = []
	for r in range(grid.size()):
		for c in range(grid[r].size()):
			if grid[r][c] == 0:
				cells.append([c, r])
	return cells

static func _distance(a: Array, b: Array) -> float:
	return sqrt(float((a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1])))
