extends RefCounted
## How the room's surfaces look: each material drawn as what it is, in the room's own plain style (flat colours and
## clean lines, as the instruments are): planks, tiles and carpet on the floor; drywall with its skirting, plaster,
## brick, wood boards, curtain folds, foam wedges, fabric panels, diffuser wells and shelves of books on the walls; a
## suspended ceiling's tiles overhead. Drawn by one shader, in metres on the surface (so a brick is a brick's size
## whatever the wall's), its joints, folds and wells catching the light as relief, and the finest of it fading out
## where it is too small to see rather than shimmering.

## Each material's look: [pattern, the colour of its joints or second part (mortar, grout, a frame, a shelf), how
## rough it is (1 matt, 0 glossy)]. Its main colour is room.gd's MATERIALS'.
const LOOKS := {
	"drywall": [0, Color(0.13, 0.135, 0.16), 0.9],
	"plaster": [1, Color(0.2, 0.19, 0.17), 0.95],
	"brick": [2, Color(0.2, 0.19, 0.17), 0.95],
	"concrete": [3, Color(0.09, 0.09, 0.1), 0.85],
	"wood": [4, Color(0.07, 0.04, 0.025), 0.6],
	"glass": [5, Color(0.05, 0.055, 0.065), 0.05],
	"curtain": [6, Color(0.08, 0.01, 0.02), 1.0],
	"foam": [7, Color(0.012, 0.012, 0.014), 1.0],
	"acoustic_panel": [8, Color(0.02, 0.02, 0.025), 1.0],
	"ceiling_tile": [9, Color(0.19, 0.19, 0.2), 0.95],
	"diffuser": [10, Color(0.3, 0.2, 0.12), 0.7],
	"bookshelf": [11, Color(0.15, 0.09, 0.05), 0.8],
	"wood_floor": [12, Color(0.04, 0.025, 0.015), 0.6],
	"tile": [13, Color(0.1, 0.1, 0.11), 0.25],
	"rug": [14, Color(0.09, 0.03, 0.02), 1.0],
	"carpet": [15, Color(0.05, 0.04, 0.06), 1.0],
}

const SHADER := """
shader_type spatial;
render_mode cull_back;
uniform int pattern = 0;
uniform vec3 base_color : source_color = vec3(0.1);
uniform vec3 accent_color : source_color = vec3(0.2);
uniform float rough = 0.9;
uniform float alpha = 1.0;
varying vec3 world_pos;
varying vec3 local_pos;
varying vec3 local_normal;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	local_pos = VERTEX;
	local_normal = NORMAL;
}

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

// 1 on a line `width` wide at every multiple of `period` along x, smoothed over a pixel.
float groove(float x, float period, float width) {
	float d = abs(fract(x / period + 0.5) - 0.5) * period;
	return 1.0 - smoothstep(width * 0.5, width * 0.5 + fwidth(x), d);
}

// How much of detail `size` metres across can be seen here (fading it out before it shimmers).
float seen(vec2 p, float size) {
	return 1.0 - smoothstep(size * 0.3, size * 1.2, length(fwidth(p)));
}

// The normal, tilted as a height `h` (metres) across the surface would tilt it (Mikkelsen's surface gradient), but by
// MOST_TILT at most: a joint a pixel wide and millimetres deep would otherwise turn the surface on its side there,
// and catch the light as a mirror's edge does. (Called everywhere alike: its derivatives need every pixel's.)
const float MOST_TILT = 0.35;
vec3 bumped(vec3 n, vec3 pos, float h) {
	vec3 sx = dFdx(pos);
	vec3 sy = dFdy(pos);
	vec3 r1 = cross(sy, n);
	vec3 r2 = cross(n, sx);
	float det = dot(sx, r1);
	vec3 grad = sign(det) * (dFdx(h) * r1 + dFdy(h) * r2) / max(abs(det), 1e-12);
	float tilt = length(grad);
	if (tilt > MOST_TILT) {
		grad *= MOST_TILT / tilt;
	}
	return normalize(n - grad);
}

void fragment() {
	bool upright = abs(local_normal.y) < 0.5;
	// On the surface, in metres: along it, and up it from the floor (a floor or ceiling: across and along the room).
	vec2 p = !upright ? world_pos.xz : vec2(abs(local_normal.x) > 0.5 ? local_pos.z : local_pos.x, world_pos.y);
	vec3 color = base_color;
	float h = 0.0;
	float r = rough;
	float a = alpha;
	if (pattern == 0) {  // drywall: painted, its boards' seams just showing, a skirting board along the floor
		color *= 1.0 - 0.035 * groove(p.x, 1.2, 0.004) * seen(p, 0.01);
		color *= 0.97 + 0.06 * noise(p * 0.7);
		if (upright && p.y < 0.1) {
			color = accent_color;
			h = 0.012 - 0.004 * smoothstep(0.085, 0.1, p.y);
			r = 0.5;
		}
	} else if (pattern == 1) {  // plaster: smooth, trowelled, a little uneven in tone
		color *= 0.9 + 0.12 * noise(p * 1.3) + 0.06 * noise(p * 7.0) * seen(p, 0.05);
	} else if (pattern == 2) {  // brick: running bond, each brick its own shade, the mortar set back
		vec2 b = vec2(0.225, 0.075);
		float row = floor(p.y / b.y);
		float x = p.x + mod(row, 2.0) * b.x * 0.5;
		vec2 cell = vec2(floor(x / b.x), row);
		float mortar = max(groove(x, b.x, 0.012), groove(p.y, b.y, 0.012));
		float shade = 0.75 + 0.5 * hash(cell);
		vec3 brick = base_color * shade * (0.92 + 0.16 * noise(p * 40.0) * seen(p, 0.02));
		color = mix(brick, accent_color, mortar);
		h = (1.0 - mortar) * 0.006;
	} else if (pattern == 3) {  // concrete: mottled, pitted, cut into slabs
		color *= 0.85 + 0.2 * noise(p * 1.5) + 0.1 * noise(p * 9.0) * seen(p, 0.05);
		float pit = step(0.965, hash(floor(p / 0.012))) * seen(p, 0.012);
		color = mix(color, accent_color, max(pit * 0.8, groove(p.x, 2.4, 0.006) * 0.7));
		h = -0.004 * groove(p.x, 2.4, 0.006);
	} else if (pattern == 4) {  // wood panelling: upright tongue-and-groove boards, each its own tone, the grain running up them
		float board = floor(p.x / 0.12);
		float grain = noise(vec2(p.x * 90.0, p.y * 3.0)) * seen(p, 0.01);
		color *= (0.8 + 0.4 * hash(vec2(board, 7.0))) * (0.88 + 0.24 * grain);
		float joint = groove(p.x, 0.12, 0.005);
		color = mix(color, accent_color, joint);
		h = -0.003 * joint;
	} else if (pattern == 5) {  // glass: clear panes in dark frames
		float frame = max(groove(p.x, 1.2, 0.05), upright ? 1.0 - smoothstep(0.05, 0.05 + fwidth(p.y), p.y) : 0.0);
		color = mix(base_color, accent_color, frame);
		a = mix(alpha, 1.0, frame);
		r = mix(0.05, 0.6, frame);
	} else if (pattern == 6) {  // heavy curtain: hanging in folds, its velvet catching the light at their edges
		float phase = p.x / 0.17 + 0.6 * sin(p.x / 0.53) + 0.3 * sin(p.x / 1.7);
		float fold = sin(phase * 6.2832);
		color = mix(accent_color, base_color, 0.5 + 0.5 * fold);
		h = fold * 0.025;
		RIM = 0.5;
		RIM_TINT = 0.6;
	} else if (pattern == 7) {  // acoustic foam: wedges, each square's running the other way to its neighbours'
		vec2 tile = floor(p / 0.3);
		bool across = mod(tile.x + tile.y, 2.0) < 0.5;
		float t = (across ? p.x : p.y) / 0.05;
		float near = seen(p, 0.03);
		float wedge = mix(0.5, abs(fract(t) - 0.5) * 2.0, near);  // (far off, the wedges blur to an even tone)
		color = mix(accent_color, base_color * 3.4, wedge) * (0.95 + 0.1 * noise(p * 60.0) * seen(p, 0.01));
		h = (wedge - 0.5) * 0.03 * near;
		float seam = max(groove(p.x, 0.3, 0.004), groove(p.y, 0.3, 0.004));
		color = mix(color, accent_color, seam);
	} else if (pattern == 8) {  // acoustic panels: fabric-covered, 60 by 120 cm, with gaps between
		float gap = max(groove(p.x, 0.6, 0.02), groove(p.y, 1.2, 0.02));
		float weave = (noise(vec2(p.x * 400.0, p.y * 30.0)) + noise(vec2(p.x * 30.0, p.y * 400.0))) * 0.5 * seen(p, 0.004);
		color = mix(base_color * (0.9 + 0.2 * weave) * (0.95 + 0.1 * noise(p * 2.0)), accent_color, gap);
		h = (1.0 - gap) * 0.01;
	} else if (pattern == 9) {  // a suspended ceiling: tiles in a grid of T-bars, the tiles' surface fissured
		float bar = max(groove(p.x, 0.6, 0.024), groove(p.y, 0.6, 0.024));
		float fissure = step(0.86, hash(floor(p / 0.008))) * seen(p, 0.008);
		vec3 tile = base_color * (1.0 - 0.25 * fissure) * (0.95 + 0.1 * noise(p * 5.0));
		color = mix(tile, accent_color, bar);
		h = (1.0 - bar) * 0.006;
		r = mix(rough, 0.5, bar);
	} else if (pattern == 10) {  // diffuser: upright wells between wooden fins, of the depths a quadratic-residue sequence
		// gives (n² mod 7), in framed panels 60 cm square
		float well = floor(p.x / 0.06);
		float n = mod(well, 7.0);
		float depth = mod(n * n, 7.0) / 6.0;
		float near = seen(p, 0.03);
		float fin = max(groove(p.x, 0.06, 0.008), groove(p.y, 0.6, 0.03));
		color = mix(base_color * (1.0 - 0.7 * depth * near), accent_color, fin);
		h = mix(-depth * 0.06, 0.0, fin) * near;
	} else if (pattern == 11) {  // bookshelves: shelves 36 cm apart, full of books of every colour and height
		float shelf_gap = 0.36;
		float y = mod(p.y, shelf_gap);
		float row = floor(p.y / shelf_gap);
		float slot = floor(p.x / 0.035);
		float pick = hash(vec2(slot, row));
		float tall = (0.55 + 0.35 * hash(vec2(row, slot + 0.5))) * shelf_gap;
		vec3 spine = vec3(0.32, 0.08, 0.06);  // the books' colours: muted reds, greens, blues, creams, browns
		if (pick > 0.8) spine = vec3(0.08, 0.18, 0.1);
		else if (pick > 0.6) spine = vec3(0.07, 0.1, 0.22);
		else if (pick > 0.45) spine = vec3(0.36, 0.32, 0.22);
		else if (pick > 0.3) spine = vec3(0.22, 0.13, 0.07);
		spine *= 0.6 + 0.5 * hash(vec2(slot + 0.3, row));
		float band = groove(y - tall * 0.78, 1000.0, 0.01) * 0.5;
		float book = (1.0 - smoothstep(tall, tall + fwidth(y), y)) * step(0.06, hash(vec2(slot, row + 0.7)));
		float edge = groove(p.x, 0.035, 0.002) * book;
		vec3 back = base_color * 0.35;
		color = mix(back, mix(spine * (1.0 + band), back, edge * 0.6), book);
		float board = 1.0 - smoothstep(0.025, 0.025 + fwidth(y), y);
		color = mix(color, accent_color, board);
		h = book * 0.02 + board * 0.03;
	} else if (pattern == 12) {  // wooden floor: planks laid along the room, their ends staggered, the grain along them
		float row = floor(p.y / 0.14);
		float along = p.x + hash(vec2(row, 3.0)) * 1.6;
		vec2 plank = vec2(floor(along / 1.6), row);
		float grain = noise(vec2(p.x * 4.0, p.y * 120.0)) * seen(p, 0.008);
		color *= (0.75 + 0.5 * hash(plank)) * (0.85 + 0.3 * grain);
		float seam = max(groove(p.y, 0.14, 0.002), groove(along, 1.6, 0.002));
		color = mix(color, accent_color, seam);
		h = -0.002 * seam;
	} else if (pattern == 13) {  // tiles: 30 cm squares, grout between, glazed
		vec2 cell = floor(p / 0.3);
		float grout = max(groove(p.x, 0.3, 0.005), groove(p.y, 0.3, 0.005));
		color = mix(base_color * (0.92 + 0.16 * hash(cell)), accent_color, grout);
		h = (1.0 - grout) * 0.003;
		r = mix(rough, 0.9, grout);
	} else if (pattern == 14) {  // a rug: woven, in a lattice of diamonds with a border every couple of metres
		vec2 q = fract(p / 0.6) - 0.5;
		float diamond = groove(abs(q.x) + abs(q.y), 0.25, 0.03);
		float border = max(groove(p.x, 2.4, 0.12), groove(p.y, 2.4, 0.12));
		float weave = noise(vec2(p.x * 300.0, p.y * 300.0)) * seen(p, 0.004);
		color = mix(base_color, accent_color, max(diamond, border)) * (0.9 + 0.2 * weave);
	} else if (pattern == 15) {  // carpet: a fine, even pile, flecked
		float fleck = hash(floor(p / 0.004)) * seen(p, 0.004);
		color *= (0.9 + 0.2 * fleck) * (0.94 + 0.12 * noise(p * 3.0));
	}
	ALBEDO = color;
	ROUGHNESS = r;
	NORMAL = bumped(NORMAL, VERTEX, h * seen(p, 0.01));  // (relief too fine to see left out, as the colours' is)
	// (see-through)
}
"""

static var _shader: Shader
static var _clear: Shader  # (glass: seen through)


## A surface of `material`, its colours as `tint` makes them (the room's ceiling darker, as it is lit from below; a wall
## standing in the room lighter).
static func made_of(material: String, main_color: Color, tint: Callable = Callable()) -> ShaderMaterial:
	if _shader == null:
		_shader = Shader.new()
		_shader.code = SHADER
		_clear = Shader.new()
		_clear.code = SHADER.replace("render_mode cull_back;", "render_mode cull_back, depth_draw_always;").replace(
			"// (see-through)", "ALPHA = a;")  # (only glass writes ALPHA: anything that does is drawn as see-through)
	var look: Array = LOOKS.get(material, LOOKS.drywall)
	var surface := ShaderMaterial.new()
	var see_through: bool = look[0] == 5
	surface.shader = _clear if see_through else _shader
	surface.set_shader_parameter("pattern", look[0])
	surface.set_shader_parameter("base_color", tint.call(main_color) if tint.is_valid() else main_color)
	surface.set_shader_parameter("accent_color", tint.call(look[1]) if tint.is_valid() else look[1])
	surface.set_shader_parameter("rough", look[2])
	surface.set_shader_parameter("alpha", 0.3 if see_through else 1.0)
	return surface
