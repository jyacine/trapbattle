extends Node

class_name Pathfinding

static func astar(grid: Array, start: Array, goal: Array) -> Array:
	if start == goal:
		return [start]

	var rows = grid.size()
	var cols = grid[0].size()

	var open_set = []
	var came_from = {}
	var g_score = {}
	var f_score = {}

	var h = _heuristic(start, goal)
	open_set.append({"f": h, "g": 0, "cell": start})
	came_from[_key(start)] = null
	g_score[_key(start)] = 0
	f_score[_key(start)] = h

	while open_set.size() > 0:
		open_set.sort_custom(func(a, b): return a["f"] < b["f"])
		var current = open_set.pop_front()["cell"]

		if current == goal:
			var path = [current]
			var node = current
			while came_from[_key(node)] != null:
				node = came_from[_key(node)]
				path.push_front(node)
			return path

		for neighbor in _neighbors(grid, current):
			var tentative_g = g_score[_key(current)] + 1
			var nk = _key(neighbor)
			if nk not in g_score or tentative_g < g_score[nk]:
				came_from[nk] = current
				g_score[nk] = tentative_g
				var f = tentative_g + _heuristic(neighbor, goal)
				f_score[nk] = f
				open_set.append({"f": f, "g": tentative_g, "cell": neighbor})

	return []

static func _neighbors(grid: Array, cell: Array) -> Array:
	var c = cell[0]
	var r = cell[1]
	var rows = grid.size()
	var cols = grid[0].size()
	var result = []
	for dc in [-1, 1]:
		var nc = c + dc
		if nc >= 0 and nc < cols and grid[r][nc] == 0:
			result.append([nc, r])
	for dr in [-1, 1]:
		var nr = r + dr
		if nr >= 0 and nr < rows and grid[nr][c] == 0:
			result.append([c, nr])
	return result

static func _heuristic(a: Array, b: Array) -> int:
	return abs(a[0] - b[0]) + abs(a[1] - b[1])

static func _key(arr: Array) -> String:
	return "%d,%d" % [arr[0], arr[1]]
