extends Node3D
class_name LobbyRoom

# Procedural lobby room for up to 10 players.
# Uses shader-based marble/stone/grid materials — no external texture URLs needed.

const NUM_SPOTS = 10
const RING_R    = 7.5
const ROOM_W    = 22.0
const ROOM_D    = 22.0
const ROOM_H    = 7.0

var _name_labels:      Array = []  # Label3D per spot
var _spot_lights:      Array = []  # OmniLight3D per spot
var _spot_ring_mats:   Array = []  # StandardMaterial3D per ring (for glow toggle)

var camera: Camera3D
var _orb_ring: MeshInstance3D
var _orb: CSGSphere3D

# ────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	_build_floor()
	_build_ceiling()
	_build_walls()
	_build_room_lights()
	_build_spots()
	_build_center()
	_build_camera()

func _process(delta: float) -> void:
	if is_instance_valid(_orb_ring):
		_orb_ring.rotation.y += delta * 0.65
	if is_instance_valid(_orb):
		_orb.position.y = 1.8 + sin(Time.get_ticks_msec() * 0.001) * 0.09

# ── Marble floor ─────────────────────────────────────────────────────────────
func _build_floor() -> void:
	var mi    = MeshInstance3D.new()
	var plane = PlaneMesh.new()
	plane.size = Vector2(ROOM_W, ROOM_D)
	mi.mesh = plane
	mi.set_surface_override_material(0, _marble_mat())
	add_child(mi)

func _marble_mat() -> ShaderMaterial:
	var s = Shader.new()
	s.code = """
shader_type spatial;
void fragment() {
    vec2 uv = UV * 10.0;
    float v1 = sin(uv.x * 2.5 + sin(uv.y * 5.0 + sin(uv.x * 1.8) * 2.2) * 1.8) * 0.5 + 0.5;
    float v2 = sin(uv.y * 3.0 + sin(uv.x * 4.5) * 1.5) * 0.5 + 0.5;
    float vein = smoothstep(0.42, 0.54, v1 * v2);
    float gv   = smoothstep(0.46, 0.50, sin(uv.x * 7.0 + uv.y * 2.8) * 0.5 + 0.5);
    vec3 base   = vec3(0.93, 0.91, 0.89);
    vec3 dark   = vec3(0.52, 0.50, 0.48);
    vec3 gold   = vec3(0.84, 0.70, 0.38);
    vec3 marble = mix(base, dark, vein * 0.40);
    marble = mix(marble, gold, gv * 0.28);
    ALBEDO    = marble;
    ROUGHNESS = 0.04;
    METALLIC  = 0.12;
    SPECULAR  = 0.95;
}
"""
	var m = ShaderMaterial.new()
	m.shader = s
	return m

# ── Grid ceiling ─────────────────────────────────────────────────────────────
func _build_ceiling() -> void:
	var mi    = MeshInstance3D.new()
	var plane = PlaneMesh.new()
	plane.size = Vector2(ROOM_W, ROOM_D)
	mi.mesh = plane
	mi.set_surface_override_material(0, _ceiling_mat())
	mi.position  = Vector3(0, ROOM_H, 0)
	mi.rotation.x = PI
	add_child(mi)

func _ceiling_mat() -> ShaderMaterial:
	var s = Shader.new()
	s.code = """
shader_type spatial;
void fragment() {
    vec2 uv   = UV * 14.0;
    float gx  = step(0.93, fract(uv.x));
    float gy  = step(0.93, fract(uv.y));
    float grid = max(gx, gy);
    vec3 panel = vec3(0.06, 0.08, 0.14);
    ALBEDO    = mix(panel, panel * 1.4, grid);
    EMISSION  = vec3(0.18, 0.38, 0.90) * grid * 0.85;
    ROUGHNESS = 0.85;
}
"""
	var m = ShaderMaterial.new()
	m.shader = s
	return m

# ── Stone-brick walls ─────────────────────────────────────────────────────────
func _build_walls() -> void:
	var wm = _wall_mat()
	# [position, rotation (euler), plane_size]
	for wd: Array in [
		[Vector3(0,         ROOM_H/2.0, -ROOM_D/2.0), Vector3(-PI/2.0,  0.0,    0.0), Vector2(ROOM_W, ROOM_H)],
		[Vector3(0,         ROOM_H/2.0,  ROOM_D/2.0), Vector3(-PI/2.0,  PI,     0.0), Vector2(ROOM_W, ROOM_H)],
		[Vector3(-ROOM_W/2.0, ROOM_H/2.0, 0.0),       Vector3(-PI/2.0, -PI/2.0, 0.0), Vector2(ROOM_D, ROOM_H)],
		[Vector3( ROOM_W/2.0, ROOM_H/2.0, 0.0),       Vector3(-PI/2.0,  PI/2.0, 0.0), Vector2(ROOM_D, ROOM_H)],
	]:
		var mi    = MeshInstance3D.new()
		var plane = PlaneMesh.new()
		plane.size = wd[2]
		mi.mesh     = plane
		mi.set_surface_override_material(0, wm)
		mi.position = wd[0]
		mi.rotation = wd[1]
		add_child(mi)

func _wall_mat() -> ShaderMaterial:
	var s = Shader.new()
	s.code = """
shader_type spatial;
render_mode cull_disabled;
void fragment() {
    vec2 uv   = UV * vec2(8.0, 3.5);
    float row = floor(uv.y);
    float off = mod(row, 2.0) * 0.5;
    vec2  buv = vec2(uv.x + off, uv.y);
    float mx  = abs(fract(buv.x) - 0.5) * 2.0;
    float my  = abs(fract(buv.y) - 0.5) * 2.0;
    float mortar = step(0.86, max(mx, my));
    float rnd    = fract(sin(floor(buv.x) * 17.31 + row * 31.07) * 4375.83);
    vec3 stone   = vec3(0.20, 0.22, 0.28) + rnd * 0.07;
    vec3 grout   = vec3(0.10, 0.11, 0.15);
    vec3 col     = mix(stone, grout, mortar);
    ALBEDO       = col;
    ROUGHNESS    = 0.88;
    METALLIC     = 0.04;
    // Subtle blue atmospheric glow at top of wall
    EMISSION     = vec3(0.03, 0.06, 0.18) * (UV.y * 0.6);
}
"""
	var m = ShaderMaterial.new()
	m.shader = s
	return m

# ── Room ambient & fill lights ────────────────────────────────────────────────
func _build_room_lights() -> void:
	var env_node = WorldEnvironment.new()
	var env      = Environment.new()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color  = Color(0.12, 0.18, 0.32)
	env.ambient_light_energy = 1.8
	env.background_mode      = Environment.BG_COLOR
	env.background_color     = Color(0.04, 0.05, 0.10)
	env_node.environment = env
	add_child(env_node)

	var top = OmniLight3D.new()
	top.light_color  = Color(0.65, 0.78, 1.00)
	top.light_energy = 3.0
	top.omni_range   = 24.0
	top.position     = Vector3(0, ROOM_H - 0.3, 0)
	add_child(top)

	for cp: Vector3 in [
		Vector3(-8, 4, -8), Vector3(8, 4, -8),
		Vector3(-8, 4,  8), Vector3(8, 4,  8),
	]:
		var corner = OmniLight3D.new()
		corner.light_color  = Color(0.72, 0.78, 1.00)
		corner.light_energy = 0.85
		corner.omni_range   = 14.0
		corner.position     = cp
		add_child(corner)

# ── 10 player spots in a ring ─────────────────────────────────────────────────
func _build_spots() -> void:
	for i: int in NUM_SPOTS:
		var angle = float(i) / float(NUM_SPOTS) * TAU
		var x = cos(angle) * RING_R
		var z = sin(angle) * RING_R
		var col: Color = Config.PLAYER_COLORS[i]

		# Outer glow ring
		var ring_mi   = MeshInstance3D.new()
		var ring_mesh = CylinderMesh.new()
		ring_mesh.top_radius      = 1.05
		ring_mesh.bottom_radius   = 1.05
		ring_mesh.height          = 0.04
		ring_mesh.radial_segments = 32
		ring_mi.mesh = ring_mesh
		var ring_mat = StandardMaterial3D.new()
		ring_mat.albedo_color               = col.darkened(0.25)
		ring_mat.emission_enabled           = true
		ring_mat.emission                   = col
		ring_mat.emission_energy_multiplier = 0.4
		ring_mat.metallic  = 0.95
		ring_mat.roughness = 0.08
		ring_mi.set_surface_override_material(0, ring_mat)
		ring_mi.position = Vector3(x, 0.02, z)
		add_child(ring_mi)
		_spot_ring_mats.append(ring_mat)

		# Platform disc
		var plat_mi   = MeshInstance3D.new()
		var plat_mesh = CylinderMesh.new()
		plat_mesh.top_radius      = 0.80
		plat_mesh.bottom_radius   = 0.80
		plat_mesh.height          = 0.12
		plat_mesh.radial_segments = 24
		plat_mi.mesh = plat_mesh
		var plat_mat = StandardMaterial3D.new()
		plat_mat.albedo_color = Color(0.10, 0.10, 0.14)
		plat_mat.metallic     = 0.92
		plat_mat.roughness    = 0.04
		plat_mi.set_surface_override_material(0, plat_mat)
		plat_mi.position = Vector3(x, 0.06, z)
		add_child(plat_mi)

		# Slot number on the disc
		var num_lbl       = Label3D.new()
		num_lbl.text      = str(i + 1)
		num_lbl.font_size = 24
		num_lbl.modulate  = col
		num_lbl.position  = Vector3(x, 0.22, z)
		num_lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		num_lbl.no_depth_test = true
		add_child(num_lbl)

		# Name label floating above platform
		var lbl = Label3D.new()
		lbl.text      = "— empty —"
		lbl.font_size = 24
		lbl.modulate  = Color(0.45, 0.45, 0.45, 0.70)
		lbl.position  = Vector3(x, 1.45, z)
		lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lbl.no_depth_test    = true
		lbl.outline_size     = 5
		lbl.outline_modulate = Color(0, 0, 0, 0.85)
		add_child(lbl)
		_name_labels.append(lbl)

		# Spot omni light (dim when empty, bright when occupied)
		var spot = OmniLight3D.new()
		spot.light_color  = col
		spot.light_energy = 0.35
		spot.omni_range   = 3.5
		spot.position     = Vector3(x, 0.5, z)
		add_child(spot)
		_spot_lights.append(spot)

# ── Central holographic orb + title ──────────────────────────────────────────
func _build_center() -> void:
	_orb = CSGSphere3D.new()
	_orb.radius = 0.52
	_orb.position = Vector3(0, 1.8, 0)
	var orb_mat = StandardMaterial3D.new()
	orb_mat.albedo_color               = Color(0.08, 0.35, 0.90, 0.35)
	orb_mat.emission_enabled           = true
	orb_mat.emission                   = Color(0.04, 0.22, 0.80)
	orb_mat.emission_energy_multiplier = 2.8
	orb_mat.transparency               = BaseMaterial3D.TRANSPARENCY_ALPHA
	orb_mat.metallic  = 0.4
	orb_mat.roughness = 0.0
	_orb.material = orb_mat
	add_child(_orb)

	_orb_ring = MeshInstance3D.new()
	var torus = TorusMesh.new()
	torus.inner_radius  = 0.68
	torus.outer_radius  = 0.86
	torus.rings         = 32
	torus.ring_segments = 16
	_orb_ring.mesh = torus
	var ring_mat = StandardMaterial3D.new()
	ring_mat.albedo_color               = Color(0.20, 0.55, 1.00)
	ring_mat.emission_enabled           = true
	ring_mat.emission                   = Color(0.10, 0.38, 0.95)
	ring_mat.emission_energy_multiplier = 3.5
	ring_mat.metallic  = 0.95
	ring_mat.roughness = 0.04
	_orb_ring.set_surface_override_material(0, ring_mat)
	_orb_ring.position = Vector3(0, 1.8, 0)
	add_child(_orb_ring)

	var center_light = OmniLight3D.new()
	center_light.light_color  = Color(0.3, 0.6, 1.0)
	center_light.light_energy = 2.2
	center_light.omni_range   = 9.0
	center_light.position     = Vector3(0, 1.8, 0)
	add_child(center_light)

	var title = Label3D.new()
	title.text           = "TRAPBATTLE"
	title.font_size      = 64
	title.modulate       = Color(1.0, 0.88, 0.12)
	title.position       = Vector3(0, 4.2, 0)
	title.billboard      = BaseMaterial3D.BILLBOARD_ENABLED
	title.no_depth_test  = true
	title.outline_size   = 10
	title.outline_modulate = Color(0, 0, 0, 1)
	add_child(title)

	var subtitle = Label3D.new()
	subtitle.text          = "First-person maze trap battle"
	subtitle.font_size     = 28
	subtitle.modulate      = Color(0.65, 0.75, 0.95)
	subtitle.position      = Vector3(0, 3.5, 0)
	subtitle.billboard     = BaseMaterial3D.BILLBOARD_ENABLED
	subtitle.no_depth_test = true
	add_child(subtitle)

# ── Static camera looking down at the ring ────────────────────────────────────
func _build_camera() -> void:
	camera = Camera3D.new()
	camera.position   = Vector3(0, 10.5, 14.5)
	camera.rotation.x = deg_to_rad(-34)
	add_child(camera)
	camera.make_current()

# ── Called by LobbyUI on each lobby_updated signal ───────────────────────────
func update_slots(peer_ids: Array, local_pid: int) -> void:
	for i: int in NUM_SPOTS:
		var occupied = i < peer_ids.size()
		var col: Color = Config.PLAYER_COLORS[i]
		if occupied:
			var pid = peer_ids[i]
			var txt = "Player %d" % (i + 1)
			if i == 0:    txt += "  [HOST]"
			if pid == local_pid: txt += "  (YOU)"
			_name_labels[i].text     = txt
			_name_labels[i].modulate = col
			_spot_lights[i].light_energy = 2.8
			_spot_ring_mats[i].emission_energy_multiplier = 2.2
		else:
			_name_labels[i].text     = "— empty —"
			_name_labels[i].modulate = Color(0.45, 0.45, 0.45, 0.70)
			_spot_lights[i].light_energy = 0.35
			_spot_ring_mats[i].emission_energy_multiplier = 0.4
