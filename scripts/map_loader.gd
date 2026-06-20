extends Node
class_name MapLoader

# Loads a black/white mask into gameplay grid:
# black  -> wall  (1)
# white  -> floor (0)
# Any load error returns [] so caller can fallback to procedural generation.
static func load_mask_to_grid(path: String, cols: int, rows: int) -> Array:
	var img := Image.new()
	var err := img.load(path)
	if err != OK:
		push_error("MapLoader: failed to load %s (err=%d)" % [path, err])
		return []

	# Ensure the mask matches gameplay grid dimensions
	img.resize(cols, rows, Image.INTERPOLATE_NEAREST)

	var grid: Array = []
	for r in range(rows):
		var row: Array = []
		for c in range(cols):
			var px: Color = img.get_pixel(c, r)
			var lum := (px.r + px.g + px.b) / 3.0
			# White-ish -> floor, dark -> wall
			row.append(0 if lum > 0.5 else 1)
		grid.append(row)

	return grid
