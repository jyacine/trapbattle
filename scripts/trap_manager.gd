extends Node

class_name TrapManager

signal trap_triggered(victim_pid: int, owner_pid: int, trap_type: int)

# ── References ────────────────────────────────────────────────────────────────
var game_manager: GameManager
var sound_manager: SoundManager

# ── Placed traps on the floor ─────────────────────────────────────────────────
# Each entry: { "cell": [col,row], "owner": peer_id(int),
#               "type": int, "timer": float, "lifetime": float,
#               "node": Node3D, "active": bool }
var _traps: Array = []

# ── Active special entities ───────────────────────────────────────────────────
# Turrets: { "node": Node3D, "owner": peer_id, "timer": float, "shoot_timer": float }
var _turrets: Array    = []
# Fire zones: { "node": Node3D, "pos": Vector3, "timer": float }
var _fire_zones: Array = []
# Cages: { "node": Node3D, "target_pid": int, "timer": float }
var _cages: Array      = []
# Lures: { "node": Node3D, "cell": [c,r], "timer": float, "owner": peer_id }
var _lures: Array      = []

# ── Mirror shields: peer_id -> bool ──────────────────────────────────────────
var _mirror_shields: Dictionary = {}

const TRAP_TRIGGER_RADIUS = 0.8

# ────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	game_manager = get_parent().get_node("GameManager")

# ── Helpers: get all player nodes from group ──────────────────────────────────
func _get_players() -> Array:
	return get_tree().get_nodes_in_group("players")

func _get_player_by_pid(pid: int) -> Node3D:
	for p in _get_players():
		if p.get("peer_id") == pid:
			return p as Node3D
	return null

# ────────────────────────────────────────────────────────────────────────────
func _physics_process(delta: float) -> void:
	if not game_manager.is_playing:
		return
	_check_floor_traps(delta)
	_tick_turrets(delta)
	_tick_fire_zones(delta)
	_tick_cages(delta)
	_tick_lures(delta)

# ── Place a trap ──────────────────────────────────────────────────────────────
func place_trap(cell: Array, owner_pid: int, trap_type: int) -> void:
	if not game_manager.is_floor(cell[0], cell[1]):
		return

	if trap_type == Config.TrapType.MIRROR:
		_mirror_shields[owner_pid] = true
		_show_effect_flash(game_manager.grid_to_world(cell), Config.TRAP_COLORS[Config.TrapType.MIRROR])
		return

	var pos = game_manager.grid_to_world(cell)

	if trap_type == Config.TrapType.TURRET:
		_spawn_turret(pos, owner_pid)
		return

	var trap_node = _make_trap_visual(pos, trap_type)
	get_parent().add_child(trap_node)

	var entry = {
		"cell":     cell,
		"owner":    owner_pid,
		"type":     trap_type,
		"timer":    0.0,
		"lifetime": 60.0,
		"node":     trap_node,
		"active":   true,
	}
	_traps.append(entry)

	if trap_type == Config.TrapType.BOMB:
		entry["timer"] = 2.5

	if trap_type == Config.TrapType.LURE:
		_lures.append({ "node": trap_node, "cell": cell, "timer": 10.0, "owner": owner_pid })

# ── Check floor traps against every player in the group ──────────────────────
func _check_floor_traps(delta: float) -> void:
	var to_remove: Array = []

	for entry in _traps:
		if not entry["active"]:
			to_remove.append(entry); continue

		var trap_type  = entry["type"]
		var owner_pid  = entry["owner"]
		var trap_world = game_manager.grid_to_world(entry["cell"])

		entry["lifetime"] -= delta
		if entry["lifetime"] <= 0.0:
			to_remove.append(entry); continue

		if trap_type == Config.TrapType.BOMB:
			entry["timer"] -= delta
			if entry["timer"] <= 0.0:
				_explode_bomb(entry); to_remove.append(entry)
			continue

		var triggered = false
		for pnode in _get_players():
			var pid = pnode.get("peer_id")
			if pid == null: continue
			if game_manager.respawning.get(pid, false): continue
			if pnode.position.distance_to(trap_world) < TRAP_TRIGGER_RADIUS:
				if not _check_mirror(pid, owner_pid, entry):
					if sound_manager: sound_manager.play_trap_trigger()
					_apply_effect(pid, trap_type, trap_world, owner_pid)
					to_remove.append(entry)
					triggered = true
					break
		if triggered:
			continue

	for entry in to_remove:
		_remove_trap(entry)

# ── Mirror check ──────────────────────────────────────────────────────────────
func _check_mirror(victim_pid: int, owner_pid: int, entry: Dictionary) -> bool:
	if not _mirror_shields.get(victim_pid, false):
		return false
	_mirror_shields[victim_pid] = false
	# Reflect trap back: owner becomes the new victim, reflected by victim_pid
	_apply_effect(owner_pid, entry["type"], game_manager.grid_to_world(entry["cell"]), victim_pid)
	return true

# ── Apply effect to a peer_id ─────────────────────────────────────────────────
func _apply_effect(target_pid: int, trap_type: int, trap_pos: Vector3, owner_pid: int = -1) -> void:
	_show_effect_flash(trap_pos, Config.TRAP_COLORS[trap_type])

	if trap_type == Config.TrapType.MIRROR or trap_type == Config.TrapType.LURE:
		return

	trap_triggered.emit(target_pid, owner_pid, trap_type)

	match trap_type:
		Config.TrapType.FREEZE:
			game_manager.add_effect(target_pid, "freeze", 5.0)

		Config.TrapType.TELEPORT:
			_teleport_target(target_pid)

		Config.TrapType.CONFUSION:
			game_manager.add_effect(target_pid, "confusion", 5.0)

		Config.TrapType.ELECTRIC_NET:
			game_manager.add_effect(target_pid, "electric", 3.0)
			_spawn_net_visual(trap_pos, Config.TRAP_COLORS[Config.TrapType.ELECTRIC_NET])

		Config.TrapType.GLUE:
			game_manager.add_effect(target_pid, "glue", 3.0)

		Config.TrapType.POISON:
			game_manager.add_effect(target_pid, "poison", 4.0)
			var ct = target_pid
			get_tree().create_timer(4.0).timeout.connect(func():
				if game_manager.has_effect(ct, "poison"):
					game_manager.damage_player(ct, Config.HIT_DAMAGE, owner_pid)
			)

		Config.TrapType.BLIND:
			game_manager.add_effect(target_pid, "blind", 3.0)

		Config.TrapType.CAGE:
			game_manager.add_effect(target_pid, "cage", 5.0)
			_spawn_cage(target_pid)

		Config.TrapType.FIRE_BURST:
			_spawn_fire_zone(trap_pos)

		Config.TrapType.TURRET:
			pass   # spawned at place_trap time

	game_manager.damage_player(target_pid, Config.HIT_DAMAGE, owner_pid)

# ── Teleport ─────────────────────────────────────────────────────────────────
func _teleport_target(target_pid: int) -> void:
	var pnode = _get_player_by_pid(target_pid)
	if pnode == null: return
	var current_cell = pnode.get_grid_position() if pnode.has_method("get_grid_position") \
	                   else game_manager.world_to_grid(pnode.position)
	var dest      = game_manager.get_random_far_floor_cell(current_cell, 10.0)
	pnode.position = game_manager.grid_to_world(dest)

# ── Bomb explosion ────────────────────────────────────────────────────────────
func _explode_bomb(entry: Dictionary) -> void:
	var bomb_pos  = game_manager.grid_to_world(entry["cell"])
	var owner_pid = entry["owner"]
	_show_effect_flash(bomb_pos, Color(1.0, 0.5, 0.0))

	var flash = OmniLight3D.new()
	flash.light_color  = Color(1.0, 0.6, 0.0)
	flash.light_energy = 8.0; flash.omni_range = 6.0
	flash.position = bomb_pos + Vector3(0, 1.0, 0)
	get_parent().add_child(flash)
	get_tree().create_timer(0.4).timeout.connect(func(): flash.queue_free())

	var radius = Config.CELL_SIZE * 2.2
	for pnode in _get_players():
		var pid = pnode.get("peer_id")
		if pid == null or pid == owner_pid: continue   # don't damage bomb owner
		if pnode.position.distance_to(bomb_pos) < radius:
			game_manager.damage_player(pid, Config.HIT_DAMAGE, owner_pid)

# ── Turret ────────────────────────────────────────────────────────────────────
func _spawn_turret(pos: Vector3, owner_pid: int) -> void:
	var node = Node3D.new(); node.position = pos

	var mat = StandardMaterial3D.new()
	mat.albedo_color               = Color(0.7, 0.1, 0.7)
	mat.emission_enabled           = true
	mat.emission                   = Color(0.8, 0.0, 0.8)
	mat.emission_energy_multiplier = 1.0

	var body = CSGBox3D.new()
	body.size = Vector3(0.25, 0.4, 0.25); body.position = Vector3(0, 0.25, 0); body.material = mat
	node.add_child(body)

	var barrel = CSGCylinder3D.new()
	barrel.radius = 0.04; barrel.height = 0.35
	barrel.position = Vector3(0, 0.45, 0.18); barrel.rotation.x = PI / 2.0; barrel.material = mat
	node.add_child(barrel)

	var light = OmniLight3D.new()
	light.light_color = Color(0.8, 0.0, 0.8); light.light_energy = 1.5
	light.omni_range = 3.0; light.position = Vector3(0, 0.6, 0)
	node.add_child(light)

	get_parent().add_child(node)
	_turrets.append({ "node": node, "owner": owner_pid, "timer": 6.0, "shoot_timer": 0.8 })

# ── Fire zone ─────────────────────────────────────────────────────────────────
func _spawn_fire_zone(pos: Vector3) -> void:
	var fire_node = Node3D.new(); fire_node.position = pos + Vector3(0, 0.1, 0)

	var cyl = CSGCylinder3D.new()
	cyl.radius = Config.CELL_SIZE * 0.7; cyl.height = 0.3
	var mat = StandardMaterial3D.new()
	mat.albedo_color               = Color(1.0, 0.3, 0.0, 0.7)
	mat.emission_enabled           = true
	mat.emission                   = Color(1.0, 0.2, 0.0)
	mat.emission_energy_multiplier = 2.0
	mat.transparency               = BaseMaterial3D.TRANSPARENCY_ALPHA
	cyl.material = mat; fire_node.add_child(cyl)

	var light = OmniLight3D.new()
	light.light_color = Color(1.0, 0.4, 0.0); light.light_energy = 3.0
	light.omni_range = 4.0; fire_node.add_child(light)

	get_parent().add_child(fire_node)
	_fire_zones.append({ "node": fire_node, "pos": pos, "timer": 3.0 })

# ── Electric net ──────────────────────────────────────────────────────────────
func _spawn_net_visual(pos: Vector3, col: Color) -> void:
	var net = MeshInstance3D.new()
	var plane = PlaneMesh.new(); plane.size = Vector2(Config.CELL_SIZE * 3.0, 0.2)
	net.mesh = plane
	var mat = StandardMaterial3D.new()
	mat.albedo_color               = col
	mat.emission_enabled           = true
	mat.emission                   = col
	mat.emission_energy_multiplier = 3.0
	net.set_surface_override_material(0, mat)
	net.position = pos + Vector3(0, 0.05, 0)
	get_parent().add_child(net)
	get_tree().create_timer(3.0).timeout.connect(func(): net.queue_free())

# ── Cage ──────────────────────────────────────────────────────────────────────
func _spawn_cage(target_pid: int) -> void:
	var pnode = _get_player_by_pid(target_pid)
	if pnode == null: return
	var pos = pnode.position

	var cage_node = Node3D.new(); cage_node.position = pos
	var bar_mat = StandardMaterial3D.new()
	bar_mat.albedo_color               = Color(0.5, 0.5, 0.5)
	bar_mat.emission_enabled           = true
	bar_mat.emission                   = Color(0.4, 0.4, 0.4)
	bar_mat.emission_energy_multiplier = 0.8

	for bp in [Vector3(-0.7, 0.9, 0), Vector3(0.7, 0.9, 0),
	           Vector3(0, 0.9, -0.7), Vector3(0, 0.9, 0.7)]:
		var bar = CSGBox3D.new()
		bar.size = Vector3(0.08, 1.8, 0.08); bar.position = bp; bar.material = bar_mat
		cage_node.add_child(bar)

	get_parent().add_child(cage_node)
	_cages.append({ "node": cage_node, "target_pid": target_pid, "timer": 5.0 })

# ── Tick systems ──────────────────────────────────────────────────────────────
func _tick_turrets(delta: float) -> void:
	var to_remove: Array = []
	for t in _turrets:
		t["timer"] -= delta
		if t["timer"] <= 0.0:
			t["node"].queue_free(); to_remove.append(t); continue

		t["shoot_timer"] -= delta
		if t["shoot_timer"] > 0.0: continue
		t["shoot_timer"] = 1.2

		var owner_pid   = t["owner"]
		var turret_pos  = t["node"].position
		# Find nearest non-owner player in range
		var hit_range = Config.CELL_SIZE * 3.5
		for pnode in _get_players():
			var pid = pnode.get("peer_id")
			if pid == null or pid == owner_pid: continue
			if turret_pos.distance_to(pnode.position) < hit_range:
				game_manager.damage_player(pid, Config.HIT_DAMAGE, owner_pid)
				t["node"].queue_free(); to_remove.append(t)
				break
	for t in to_remove: _turrets.erase(t)

func _tick_fire_zones(delta: float) -> void:
	var to_remove: Array = []
	for f in _fire_zones:
		f["timer"] -= delta
		if f["timer"] <= 0.0:
			f["node"].queue_free(); to_remove.append(f); continue
		var fire_pos = f["pos"]
		var radius   = Config.CELL_SIZE * 0.7
		for pnode in _get_players():
			var pid = pnode.get("peer_id")
			if pid == null: continue
			if pnode.position.distance_to(fire_pos) < radius:
				game_manager.damage_player(pid, Config.HIT_DAMAGE)
				f["node"].queue_free(); to_remove.append(f)
				break
	for f in to_remove: _fire_zones.erase(f)

func _tick_cages(delta: float) -> void:
	var to_remove: Array = []
	for c in _cages:
		c["timer"] -= delta
		var pnode = _get_player_by_pid(c["target_pid"])
		if pnode != null:
			c["node"].position = pnode.position
		if c["timer"] <= 0.0:
			c["node"].queue_free(); to_remove.append(c)
	for c in to_remove: _cages.erase(c)

func _tick_lures(delta: float) -> void:
	var to_remove: Array = []
	for l in _lures:
		l["timer"] -= delta
		if l["timer"] <= 0.0:
			if is_instance_valid(l["node"]): l["node"].queue_free()
			to_remove.append(l); continue
		var lure_world = game_manager.grid_to_world(l["cell"])
		# Trigger on any non-owner player that comes close
		for pnode in _get_players():
			var pid = pnode.get("peer_id")
			if pid == null or pid == l["owner"]: continue
			if pnode.position.distance_to(lure_world) < Config.CELL_SIZE:
				game_manager.damage_player(pid, Config.HIT_DAMAGE, l["owner"])
				if is_instance_valid(l["node"]): l["node"].queue_free()
				to_remove.append(l)
				break
	for l in to_remove: _lures.erase(l)

# ── Visual helpers ────────────────────────────────────────────────────────────
func _make_trap_visual(pos: Vector3, trap_type: int) -> Node3D:
	var node = Node3D.new(); node.position = pos + Vector3(0, 0.02, 0)
	var col  = Config.TRAP_COLORS[trap_type]

	var ring = MeshInstance3D.new()
	var disc = CylinderMesh.new()
	disc.top_radius    = Config.CELL_SIZE * 0.30
	disc.bottom_radius = Config.CELL_SIZE * 0.30
	disc.height        = 0.03
	ring.mesh = disc
	var disc_mat = StandardMaterial3D.new()
	disc_mat.albedo_color               = col
	disc_mat.emission_enabled           = true
	disc_mat.emission                   = col
	disc_mat.emission_energy_multiplier = 0.8
	disc_mat.transparency               = BaseMaterial3D.TRANSPARENCY_ALPHA
	disc_mat.albedo_color.a             = 0.55
	ring.set_surface_override_material(0, disc_mat)
	node.add_child(ring)
	node.add_child(_make_trap_icon(trap_type, col))

	var lbl = Label3D.new()
	lbl.text = Config.TRAP_NAMES[trap_type]; lbl.font_size = 14
	lbl.modulate = col; lbl.position = Vector3(0, 0.65, 0)
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED; lbl.no_depth_test = true
	node.add_child(lbl)
	return node

func _mat(col: Color, emit_mult: float = 1.0) -> StandardMaterial3D:
	var m = StandardMaterial3D.new()
	m.albedo_color               = col
	m.emission_enabled           = true
	m.emission                   = col
	m.emission_energy_multiplier = emit_mult
	m.roughness = 0.4
	return m

func _make_trap_icon(trap_type: int, col: Color) -> Node3D:
	var icon = Node3D.new()

	match trap_type:
		Config.TrapType.PITFALL:
			var pit = CSGCylinder3D.new()
			pit.radius = 0.19; pit.height = 0.05; pit.position = Vector3(0, 0.03, 0)
			pit.material = _mat(Color(0.04, 0.02, 0.02), 0.15); icon.add_child(pit)
			var warn = MeshInstance3D.new()
			var wtorus = TorusMesh.new(); wtorus.inner_radius = 0.19; wtorus.outer_radius = 0.30
			warn.mesh = wtorus; warn.position = Vector3(0, 0.03, 0)
			warn.set_surface_override_material(0, _mat(Color(1.0, 0.82, 0.0), 2.0)); icon.add_child(warn)
			var spike = CSGCylinder3D.new()
			spike.radius = 0.06; spike.height = 0.26; spike.position = Vector3(0, 0.16, 0)
			spike.material = _mat(col.darkened(0.35), 0.7); icon.add_child(spike)

		Config.TrapType.BOMB:
			var body = CSGSphere3D.new()
			body.radius = 0.22; body.position = Vector3(0, 0.24, 0)
			body.material = _mat(Color(0.08, 0.08, 0.10), 0.15); icon.add_child(body)
			var fuse = CSGCylinder3D.new()
			fuse.radius = 0.022; fuse.height = 0.24
			fuse.position = Vector3(0.07, 0.50, 0); fuse.rotation.z = -0.55
			fuse.material = _mat(Color(0.48, 0.32, 0.08), 0.3); icon.add_child(fuse)
			var spark = CSGSphere3D.new()
			spark.radius = 0.06; spark.position = Vector3(0.14, 0.62, 0)
			spark.material = _mat(Color(1.0, 0.65, 0.05), 5.0); icon.add_child(spark)

		Config.TrapType.SPIKE:
			var sm = _mat(Color(0.70, 0.72, 0.78), 0.5); sm.metallic = 0.85; sm.roughness = 0.15
			for sp in [Vector3(0,0,0), Vector3(0.16,0,0.10), Vector3(-0.16,0,0.10),
			           Vector3(0.10,0,-0.15), Vector3(-0.10,0,-0.15)]:
				var cone = CSGCylinder3D.new()
				cone.radius = 0.044; cone.height = 0.44
				cone.position = sp + Vector3(0, 0.22, 0); cone.material = sm; icon.add_child(cone)

		Config.TrapType.FREEZE:
			var im = _mat(Color(0.55, 0.82, 1.0), 2.0); im.metallic = 0.2; im.roughness = 0.05
			for i in 3:
				var ry = i * PI / 3.0
				var arm = CSGBox3D.new()
				arm.size = Vector3(0.06, 0.48, 0.06); arm.position = Vector3(0, 0.25, 0)
				arm.rotation.y = ry; arm.material = im; icon.add_child(arm)
				for offset in [-0.12, 0.12]:
					var cross = CSGBox3D.new()
					cross.size = Vector3(0.22, 0.05, 0.05)
					cross.position = Vector3(0, 0.25 + offset, 0)
					cross.rotation.y = ry; cross.material = im; icon.add_child(cross)

		Config.TrapType.TELEPORT:
			var pm = _mat(col, 2.5)
			for rx in [0.0, PI / 2.0]:
				var r = MeshInstance3D.new()
				var torus = TorusMesh.new(); torus.inner_radius = 0.11; torus.outer_radius = 0.24
				r.mesh = torus; r.position = Vector3(0, 0.27, 0); r.rotation.x = rx
				r.set_surface_override_material(0, pm); icon.add_child(r)
			var core = CSGSphere3D.new()
			core.radius = 0.08; core.position = Vector3(0, 0.27, 0)
			core.material = _mat(col.lightened(0.55), 4.0); icon.add_child(core)

		Config.TrapType.CONFUSION:
			for i in 6:
				var t  = float(i) / 6.0; var a = t * TAU
				var rs = 0.10 + t * 0.06; var ys = 0.06 + t * 0.38
				var orb = CSGSphere3D.new()
				orb.radius = 0.065 - t * 0.01
				orb.position = Vector3(cos(a) * rs, ys, sin(a) * rs)
				orb.material = _mat(col.lerp(col.lightened(0.5), t), 1.6 + t * 0.8); icon.add_child(orb)

		Config.TrapType.FIRE_BURST:
			var flame_pos = [Vector3(0,0,0), Vector3(0.14,0,0.06),
			                 Vector3(-0.12,0,0.08), Vector3(0.06,0,0.16), Vector3(-0.08,0,0.15)]
			var flame_h   = [0.40, 0.35, 0.42, 0.34, 0.38]
			for i in flame_pos.size():
				var fc    = col.lerp(Color(1.0, 0.38, 0.0), float(i) / 4.0)
				var flame = CSGCylinder3D.new()
				flame.radius = 0.058; flame.height = flame_h[i]
				flame.position = flame_pos[i] + Vector3(0, flame_h[i] / 2.0, 0)
				flame.material = _mat(fc, 2.8); icon.add_child(flame)

		Config.TrapType.ELECTRIC_NET:
			var em = _mat(col, 3.5)
			var segs = [
				[Vector3( 0.06, 0.44, 0), -0.55, Vector2(0.28, 0.10)],
				[Vector3(-0.02, 0.30, 0),  0.50, Vector2(0.26, 0.10)],
				[Vector3( 0.06, 0.18, 0), -0.55, Vector2(0.24, 0.10)],
				[Vector3(-0.01, 0.06, 0),  0.45, Vector2(0.22, 0.10)],
			]
			for seg in segs:
				var b = CSGBox3D.new()
				b.size = Vector3(seg[2].x, seg[2].y, 0.06)
				b.position = seg[0]; b.rotation.z = seg[1]; b.material = em; icon.add_child(b)

		Config.TrapType.GLUE:
			var gm = _mat(col, 1.3)
			var puddle = CSGCylinder3D.new()
			puddle.radius = 0.28; puddle.height = 0.07
			puddle.position = Vector3(0, 0.04, 0); puddle.material = gm; icon.add_child(puddle)
			for bp in [Vector3(0, 0.17, 0), Vector3(0.13, 0.23, 0.09), Vector3(-0.11, 0.19, 0.11)]:
				var blob = CSGSphere3D.new()
				blob.radius = 0.085; blob.position = bp; blob.material = gm; icon.add_child(blob)

		Config.TrapType.POISON:
			var bone_col = Color(0.86, 0.90, 0.78)
			var skull_m  = _mat(bone_col, 0.6)
			var head = CSGSphere3D.new()
			head.radius = 0.21; head.position = Vector3(0, 0.29, 0); head.material = skull_m; icon.add_child(head)
			var dark = _mat(Color(0.0, 0.0, 0.0), 0.05)
			for ep in [Vector3(-0.09, 0.31, 0.19), Vector3(0.09, 0.31, 0.19)]:
				var eye = CSGSphere3D.new()
				eye.radius = 0.065; eye.position = ep; eye.material = dark; icon.add_child(eye)
			var nose = CSGBox3D.new()
			nose.size = Vector3(0.06, 0.05, 0.04); nose.position = Vector3(0, 0.21, 0.20)
			nose.material = dark; icon.add_child(nose)
			for rz in [PI / 4.0, -PI / 4.0]:
				var bone = CSGCylinder3D.new()
				bone.radius = 0.036; bone.height = 0.40
				bone.position = Vector3(0, 0.06, 0); bone.rotation.z = rz; bone.material = skull_m; icon.add_child(bone)

		Config.TrapType.BLIND:
			var eye_body = CSGSphere3D.new()
			eye_body.radius = 0.20; eye_body.position = Vector3(0, 0.22, 0)
			eye_body.material = _mat(Color(0.96, 0.95, 0.92), 0.7); icon.add_child(eye_body)
			var iris = CSGSphere3D.new()
			iris.radius = 0.11; iris.position = Vector3(0, 0.22, 0.16)
			iris.material = _mat(Color(0.1, 0.15, 0.85), 1.0); icon.add_child(iris)
			var pupil = CSGSphere3D.new()
			pupil.radius = 0.06; pupil.position = Vector3(0, 0.22, 0.21)
			pupil.material = _mat(Color(0, 0, 0), 0.05); icon.add_child(pupil)
			var slash_m = _mat(Color(1.0, 0.1, 0.1), 2.5)
			for rz in [PI / 4.0, -PI / 4.0]:
				var sl = CSGBox3D.new()
				sl.size = Vector3(0.40, 0.045, 0.045)
				sl.position = Vector3(0, 0.22, 0.22); sl.rotation.z = rz; sl.material = slash_m; icon.add_child(sl)

		Config.TrapType.CAGE:
			var bar_m = _mat(Color(0.60, 0.62, 0.68), 0.55); bar_m.metallic = 0.75; bar_m.roughness = 0.25
			for bp in [Vector3( 0.16, 0.25,  0.16), Vector3(-0.16, 0.25,  0.16),
			           Vector3( 0.16, 0.25, -0.16), Vector3(-0.16, 0.25, -0.16)]:
				var bar = CSGCylinder3D.new()
				bar.radius = 0.032; bar.height = 0.50; bar.position = bp; bar.material = bar_m; icon.add_child(bar)
			for ry in [0.0, 0.50]:
				var ring = MeshInstance3D.new()
				var torus = TorusMesh.new(); torus.inner_radius = 0.12; torus.outer_radius = 0.22
				ring.mesh = torus; ring.position = Vector3(0, ry, 0)
				ring.set_surface_override_material(0, bar_m); icon.add_child(ring)

		Config.TrapType.LURE:
			var box_m = _mat(col, 1.1)
			var box = CSGBox3D.new()
			box.size = Vector3(0.32, 0.26, 0.32); box.position = Vector3(0, 0.13, 0); box.material = box_m; icon.add_child(box)
			var rib_m = _mat(col.lightened(0.45), 1.6)
			for rv in [Vector3(0.32, 0.04, 0.09), Vector3(0.09, 0.04, 0.32)]:
				var rib = CSGBox3D.new()
				rib.size = rv; rib.position = Vector3(0, 0.28, 0); rib.material = rib_m; icon.add_child(rib)
			for bp in [Vector3(-0.09, 0.37, 0), Vector3(0.09, 0.37, 0)]:
				var bow = CSGSphere3D.new()
				bow.radius = 0.09; bow.position = bp; bow.material = rib_m; icon.add_child(bow)

		Config.TrapType.TURRET:
			var tm = _mat(col, 1.0); tm.metallic = 0.72; tm.roughness = 0.28
			var base = CSGCylinder3D.new()
			base.radius = 0.20; base.height = 0.07; base.position = Vector3(0, 0.04, 0); base.material = tm; icon.add_child(base)
			var body = CSGBox3D.new()
			body.size = Vector3(0.25, 0.24, 0.25); body.position = Vector3(0, 0.20, 0); body.material = tm; icon.add_child(body)
			var barrel = CSGCylinder3D.new()
			barrel.radius = 0.055; barrel.height = 0.44
			barrel.position = Vector3(0, 0.28, 0.30); barrel.rotation.x = PI / 2.0; barrel.material = tm; icon.add_child(barrel)
			var muzzle = CSGSphere3D.new()
			muzzle.radius = 0.07; muzzle.position = Vector3(0, 0.28, 0.54)
			muzzle.material = _mat(col.lightened(0.6), 4.0); icon.add_child(muzzle)

		Config.TrapType.MIRROR:
			var face_m = StandardMaterial3D.new()
			face_m.albedo_color = col.lightened(0.35); face_m.metallic = 0.98; face_m.roughness = 0.02
			face_m.emission_enabled = true; face_m.emission = col; face_m.emission_energy_multiplier = 0.7
			var face = CSGCylinder3D.new()
			face.radius = 0.22; face.height = 0.03
			face.position = Vector3(0, 0.30, 0); face.rotation.x = PI / 2.0; face.material = face_m; icon.add_child(face)
			var frame_m = StandardMaterial3D.new()
			frame_m.albedo_color = Color(0.85, 0.72, 0.25); frame_m.metallic = 0.92; frame_m.roughness = 0.08
			frame_m.emission_enabled = true; frame_m.emission = Color(0.55, 0.42, 0.05); frame_m.emission_energy_multiplier = 0.8
			var frame = MeshInstance3D.new()
			var ftorus = TorusMesh.new(); ftorus.inner_radius = 0.20; ftorus.outer_radius = 0.30
			frame.mesh = ftorus; frame.position = Vector3(0, 0.30, 0); frame.rotation.x = PI / 2.0
			frame.set_surface_override_material(0, frame_m); icon.add_child(frame)
			var handle = CSGCylinder3D.new()
			handle.radius = 0.040; handle.height = 0.22
			handle.position = Vector3(0, 0.11, 0); handle.material = frame_m; icon.add_child(handle)

	return icon

func _show_effect_flash(pos: Vector3, col: Color) -> void:
	var light = OmniLight3D.new()
	light.position     = pos + Vector3(0, 0.8, 0)
	light.light_color  = col
	light.light_energy = 6.0; light.omni_range = 5.0
	get_parent().add_child(light)
	get_tree().create_timer(0.3).timeout.connect(func(): light.queue_free())

func _remove_trap(entry: Dictionary) -> void:
	if entry.has("node") and entry["node"] != null and is_instance_valid(entry["node"]):
		entry["node"].queue_free()
	_traps.erase(entry)

# ── Multiplayer: replicate trap placement on all peers ────────────────────────
@rpc("any_peer", "call_local", "reliable")
func net_place_trap(cell: Array, owner_pid: int, trap_type: int) -> void:
	place_trap(cell, owner_pid, trap_type)
