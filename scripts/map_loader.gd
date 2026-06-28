extends Node
class_name MapLoader

# Loads a black/white mask PNG into a gameplay grid.
# White (lum > 0.5) -> floor (0), dark -> wall (1).
# Returns [] on load failure so the caller can fall back to procedural generation.
static func load_mask_to_grid(path: String, cols: int, rows: int) -> Array:
	var img: Image = _load_image(path)
	if img == null:
		return []

	# Nearest-neighbour keeps sharp pixel edges when scaling to grid dimensions.
	img.resize(cols, rows, Image.INTERPOLATE_NEAREST)

	var grid: Array = []
	for r in range(rows):
		var row: Array = []
		for c in range(cols):
			var px: Color = img.get_pixel(c, r)
			var lum := (px.r + px.g + px.b) / 3.0
			row.append(0 if lum > 0.5 else 1)
		grid.append(row)

	# Outer border must be solid wall so players cannot walk out of bounds.
	for c in range(cols):
		grid[0][c] = 1
		grid[rows - 1][c] = 1
	for r in range(rows):
		grid[r][0] = 1
		grid[r][cols - 1] = 1

	# Discard isolated floor islands - keep only the largest connected component.
	_keep_largest_floor_component(grid, rows, cols)

	return grid


# Try texture-resource loading first (works in exported builds including web),
# then fall back to direct byte-level Image.load (works in the editor).
static func _load_image(path: String) -> Image:
	var res = load(path)
	if res is Texture2D:
		return (res as Texture2D).get_image()
	if res is Image:
		return res as Image
	var img := Image.new()
	if img.load(path) == OK:
		return img
	push_error("MapLoader: cannot load '%s'" % path)
	return null


static func _keep_largest_floor_component(grid: Array, rows: int, cols: int) -> void:
	var label: Array = []
	for r in range(rows):
		label.append([])
		for c in range(cols):
			label[r].append(-1)

	var comp_sizes: Array = []
	var comp_id := 0

	for start_r in range(rows):
		for start_c in range(cols):
			if grid[start_r][start_c] != 0 or label[start_r][start_c] != -1:
				continue
			var q: Array = [[start_r, start_c]]
			label[start_r][start_c] = comp_id
			var size := 0
			var qi := 0
			while qi < q.size():
				var cur = q[qi]
				qi += 1
				size += 1
				for d in [[-1, 0], [1, 0], [0, -1], [0, 1]]:
					var nr = cur[0] + d[0]
					var nc = cur[1] + d[1]
					if nr >= 0 and nr < rows and nc >= 0 and nc < cols:
						if grid[nr][nc] == 0 and label[nr][nc] == -1:
							label[nr][nc] = comp_id
							q.append([nr, nc])
			comp_sizes.append(size)
			comp_id += 1

	if comp_id == 0:
		return

	var best_id := 0
	for i in range(comp_sizes.size()):
		if comp_sizes[i] > comp_sizes[best_id]:
			best_id = i

	for r in range(rows):
		for c in range(cols):
			if grid[r][c] == 0 and label[r][c] != best_id:
				grid[r][c] = 1
