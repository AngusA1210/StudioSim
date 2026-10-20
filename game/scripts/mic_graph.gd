extends Control
## A microphone's character, drawn as makers draw it: its frequency response on axis, from 20 Hz to 20 kHz (as the
## audio core has its filters), and beside it its pickup pattern, seen from above, how much it hears from each way
## round (the middle band bright, the lows and highs fainter, so it shows where it widens and narrows; a figure-8's back
## lobe, opposite in polarity, drawn dashed).

const LOW_HZ := 20.0
const HIGH_HZ := 20000.0
const RANGE_DB := 15.0
const DIM := Color(0.62, 0.65, 0.74)
const POINTS := 96

var app
var model := ""
var pattern := {}  # {name, pressure: [3], gradient: [3]}
var ink := Color(0.55, 0.78, 1.0)
var _response := PackedFloat32Array()
var _shown := ""


func _ready() -> void:
	custom_minimum_size = Vector2(420, 120)
	mouse_filter = Control.MOUSE_FILTER_PASS


## Shows a model and one of its patterns (its response asked of the audio core again only when the model changes).
func show_mic(model_id: String, the_pattern: Dictionary) -> void:
	var key := model_id + "|" + str(the_pattern.get("name", ""))
	if key == _shown:
		return
	_shown = key
	model = model_id
	pattern = the_pattern
	var hz := PackedFloat32Array()
	for i in POINTS:
		hz.append(LOW_HZ * pow(HIGH_HZ / LOW_HZ, float(i) / float(POINTS - 1)))
	_response = app.audio.get_mic_response(model, hz)
	queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	var curve := Rect2(Vector2(28, 4), Vector2(size.x - size.y - 46, size.y - 22))
	draw_rect(curve, Color(0.06, 0.065, 0.08))
	for db: float in [-10.0, 0.0, 10.0]:  # the decibel lines
		var y: float = curve.position.y + (0.5 - db / (2.0 * RANGE_DB)) * curve.size.y
		draw_line(Vector2(curve.position.x, y), Vector2(curve.end.x, y), Color(1, 1, 1, 0.18 if db == 0.0 else 0.07), 1.0)
		draw_string(font, Vector2(0, y + 4), "%+d" % int(db) if db != 0.0 else "0", HORIZONTAL_ALIGNMENT_RIGHT, 24, 9, DIM)
	for hz: float in [100.0, 1000.0, 10000.0]:  # the decades
		var x: float = curve.position.x + log(hz / LOW_HZ) / log(HIGH_HZ / LOW_HZ) * curve.size.x
		draw_line(Vector2(x, curve.position.y), Vector2(x, curve.end.y), Color(1, 1, 1, 0.07), 1.0)
		draw_string(font, Vector2(x - 20, curve.end.y + 12), {100.0: "100", 1000.0: "1k", 10000.0: "10k"}[hz], HORIZONTAL_ALIGNMENT_CENTER, 40, 9, DIM)
	if _response.size() == POINTS:
		var line := PackedVector2Array()
		for i in POINTS:
			var y := curve.position.y + (0.5 - clampf(_response[i], -RANGE_DB, RANGE_DB) / (2.0 * RANGE_DB)) * curve.size.y
			line.append(Vector2(curve.position.x + float(i) / float(POINTS - 1) * curve.size.x, y))
		draw_polyline(line, ink, 2.0, true)
	# The pattern: from above, its front up.
	var radius := (size.y - 16) / 2.0
	var centre := Vector2(size.x - radius - 6, radius + 4)
	draw_arc(centre, radius, 0, TAU, 48, Color(1, 1, 1, 0.12), 1.0)
	draw_arc(centre, radius / 2.0, 0, TAU, 48, Color(1, 1, 1, 0.06), 1.0)
	draw_line(centre - Vector2(radius, 0), centre + Vector2(radius, 0), Color(1, 1, 1, 0.06), 1.0)
	draw_line(centre - Vector2(0, radius), centre + Vector2(0, radius), Color(1, 1, 1, 0.06), 1.0)
	if pattern.is_empty():
		return
	for band in [0, 2, 1]:  # (the middle band last, on top)
		var a: float = float(pattern.pressure[band])
		var b: float = float(pattern.gradient[band])
		var front := PackedVector2Array()
		var back := PackedVector2Array()
		for i in 73:
			var angle := TAU * i / 72.0
			var r := a + b * cos(angle)
			var p := centre + Vector2(sin(angle), -cos(angle)) * absf(r) * radius
			(front if r >= 0.0 else back).append(p)
		var tone := Color(ink, 1.0 if band == 1 else 0.35)
		if front.size() > 1:
			draw_polyline(front, tone, 2.0 if band == 1 else 1.0, true)
		if back.size() > 1:
			for i in range(0, back.size() - 1, 2):  # (opposite in polarity: dashed)
				draw_line(back[i], back[i + 1], tone, 2.0 if band == 1 else 1.0)
	draw_string(font, Vector2(centre.x - radius, size.y - 1), "front ↑", HORIZONTAL_ALIGNMENT_CENTER, radius * 2.0, 9, DIM)
