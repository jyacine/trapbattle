extends SceneTree

# Headless smoke test for the map system. Exercises the GDScript paths that the
# dummy headless renderer DOES run: material builders + _scatter_props prop
# generation for every map id, against a realistic maze grid. Catches indexing /
# Vector2i / MultiMesh bugs without needing a full networked game start.
#   Run: GODOT --headless --path <client> -s tests/map_check.gd

func _initialize() -> void:
	var main = load("res://scripts/main.gd").new()
	var holder := Node3D.new()
	get_root().add_child(holder)

	var rows := 27
	var cols := 27
	var grid: Array = []
	for r in range(rows):
		var row: Array = []
		for c in range(cols):
			var is_wall := (r == 0 or c == 0 or r == rows - 1 or c == cols - 1 \
				or ((r % 2 == 0) and (c % 3 == 0)))
			row.append(1 if is_wall else 0)
		grid.append(row)

	var names := ["", "Labyrinth", "Garage", "Forest", "Village", "Canyon"]
	var ok := true
	for id in [1, 2, 3, 4, 5]:
		var wm = main._make_wall_material(id)
		var fm = main._make_floor_material(id)
		var cm = main._make_ceiling_material(id)
		if wm == null or fm == null or cm == null:
			push_error("map %d: null material" % id); ok = false
		var before := holder.get_child_count()
		main._scatter_props(id, grid, rows, cols, 2.0, 3.0, holder)
		print("map %d (%s): materials ok, props added %d nodes" % [
			id, names[id], holder.get_child_count() - before])

	await process_frame
	print("MAP_CHECK_DONE ok=%s total_prop_nodes=%d" % [str(ok), holder.get_child_count()])
	quit(0 if ok else 1)
