extends Node3D
## One instrument in the room: its model, label and light, plus its sound source in the audio core.
## It stands on the floor; the node's origin is where the sound comes from, `source_height` above the floor.

const Models := preload("res://scripts/instrument_models.gd")
const Catalog := preload("res://scripts/catalog.gd")
const INPUT_GREEN := Color(0.36, 0.9, 0.5)
# How an amp's loop pedal, if it has one, shows what it is doing: on the pedal's light, and under the amp's name.
const LOOP_LOOKS := {
	"waiting": ["waiting for the bar", Color(1.0, 0.75, 0.3)],
	"recording": ["● REC", Color(1.0, 0.3, 0.28)],
	"playing": ["▶ LOOP", Color(0.4, 0.9, 0.5)],
	"overdubbing": ["● DUB", Color(1.0, 0.6, 0.2)],
	"stopped": ["■ loop stopped", Color(0.55, 0.58, 0.65)],
}

var kind := ""
var display_name := ""
var color := Color.WHITE        # its track's colour: its name in the room, its light, its strip and its clips
var model_color := Color.WHITE  # its paint, as it was made (a track's colour changed doesn't repaint the drums)
var named := false              # its name was given it (a plug-in instrument then keeps it, rather than taking its plug-in's)
var is_folder := false
var is_aux := false
var automation := {}        # its automation's points: {volume, mute, sustain} (see automation.gd)
var auto_mode := "read"     # off, read, touch, latch or write
var lanes := ["volume"]     # what its automation lanes show in the edit window, in order
var sends := [{}, {}, {}, {}, {}]  # its sends, A to E: {} or {aux, level_db, pre, on} (see main.set_send)
var takes_open := false     # its loop recordings' takes shown under it in the edit window, to comp from
var source_height := 1.0  # metres above the floor the sound comes from
var top := 1.0            # how tall the model stands
var footprint := Vector2.ONE
var playable := false  # can be played by hand, and has a pattern the sequencer plays
var default_octave := 0  # where the computer keyboard starts when you sit down at it
var source_id := -1
var muted := false     # its mixer channel is muted (for a Speaker, also M in the room)
var soloed := false
var loop_on := true    # playable instruments: whether the sequencer plays their pattern
var input_on := false  # it takes input: MIDI controllers play it, or a Speaker plays its hardware input
var input_channel := -1  # live-input instruments: the hardware input they play (0-based), or -1 for all of them
var level_db := 0.0    # its fader: how far above or below its normal level it is set
var volume_db := 0.0   # a Speaker's own volume (its panel), before the fader
# Its channel meter, as linear levels where 1 is full scale: this frame's peak and average, and the highest peak
# since its peak readout was last cleared (read by the game each frame; see main.gd).
var meter_peak := 0.0
var meter_rms := 0.0
var peak_hold := 0.0
var is_amp := false    # a guitar or bass amp, with knobs and a loop pedal
var drum_kit := false  # each key plays a drum (the drums, the garage kit)
var plays_plugin := false  # a plug-in instrument: it plays one of the instrument plug-ins on the computer
var instrument_plugin := {}  # what that plug-in is, from the audio core: {plugin_id, plugin_name, plugin_maker, editor_open}
var amp_controls := {"gain": 5.0, "bass": 5.0, "mid": 5.0, "treble": 5.0, "presence": 5.0, "master": 5.0}
var amp_head := ""      # an amp's head and cabinet (catalog.gd lists them), and whether each is in use
var amp_cabinet := ""
var head_on := true
var cabinet_on := true
var looper := {}       # what its loop pedal is doing, from the audio core: state "none" if it has none (amps only)
var pedals := []       # its effect pedals, in signal order, from the audio core: [{kind, on, controls, plugin_name...}]
var tuner := {}        # what its tuner hears while one is on: {pitched, note, cents, frequency}; empty otherwise
var inserts := []      # its channel's plug-ins, one entry per insert slot: [{plugin_name, on, editor_open...}]
var carried := false
var clips := []        # its clips on a Record room's timeline (timeline.gd)
var armed := false     # armed for recording
var glow := 0.0

var _audio: SoundRoomAudio
var _normal_gain := 1.0  # what 0 dB on its fader means to the audio core
var _sent_position := Vector3.INF  # where the audio core last heard this instrument was
var _model: Node3D
var _accent: StandardMaterial3D  # the parts in its own colour, which light up as it plays
var _light: OmniLight3D
var _label: Label3D
var _input_badge: Label3D
var _loop_label: Label3D
var _led: StandardMaterial3D  # the loop pedal's light, while it has one
var _pedal_spot := Vector3.ZERO  # where the loop pedal stands; the effect pedals line up beside it
var _pedal_row: Node3D
var _pedal_leds: Array = []
var _pedal_signature := ""
var _collider: CollisionShape3D


func setup(spec: Dictionary, audio: SoundRoomAudio) -> void:
	_audio = audio
	kind = spec.kind
	display_name = spec.name
	color = spec.color
	model_color = spec.color
	source_height = spec.height
	top = spec.top
	footprint = spec.footprint
	playable = not spec.get("live_input", false)
	default_octave = spec.get("octave", 0)
	is_amp = spec.get("amp", false)
	drum_kit = spec.get("drum_kit", false)
	plays_plugin = spec.get("plugin", false)
	amp_head = spec.get("head", "")
	amp_cabinet = spec.get("cabinet", "")
	name = display_name
	position = Vector3(spec.position.x, source_height, spec.position.z)

	_normal_gain = spec.gain
	source_id = audio.add_source(kind, position, spec.gain, spec.send)
	if source_id < 0:
		return  # the room is full; whoever asked for this instrument gives up on it

	_pedal_row = Node3D.new()
	_build_model()

	_light = OmniLight3D.new()
	_light.light_color = color
	_light.omni_range = 4.0
	add_child(_light)

	_label = Label3D.new()
	_label.text = display_name
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.font_size = 40
	_label.pixel_size = 0.004
	_label.outline_size = 10
	_label.modulate = color.lightened(0.35)
	add_child(_label)
	# A green "i" under the name while it takes input, as a DAW marks a track whose input is on.
	_input_badge = Label3D.new()
	_input_badge.text = "i"
	_input_badge.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_input_badge.font_size = 44
	_input_badge.pixel_size = 0.004
	_input_badge.outline_size = 12
	_input_badge.modulate = INPUT_GREEN
	_input_badge.visible = false
	add_child(_input_badge)
	_loop_label = Label3D.new()  # an amp's loop pedal: recording, looping, overdubbing
	_loop_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_loop_label.font_size = 30
	_loop_label.pixel_size = 0.004
	_loop_label.outline_size = 8
	_loop_label.visible = false
	add_child(_loop_label)

	# Something solid to bump into, on the default layer only (sound passes through instruments).
	var body := StaticBody3D.new()
	_collider = CollisionShape3D.new()
	_collider.shape = BoxShape3D.new()
	body.add_child(_collider)
	add_child(body)
	_place_parts()


## Its model, made again when an amp changes cabinet: how tall it stands and the floor it covers follow, and with
## them where its name, its light and its pedals go.
func _build_model() -> void:
	if _model != null:
		_model.remove_child(_pedal_row)
		_model.queue_free()
	var built: Dictionary = Models.build(kind, model_color, amp_cabinet)
	_model = built.node
	_model.position.y = -source_height  # the model is drawn from the floor up
	add_child(_model)
	_accent = built.accent
	top = built.get("top", top)
	footprint = built.get("footprint", footprint)
	_pedal_spot = built.get("pedal_spot", Vector3.ZERO)
	_model.add_child(_pedal_row)
	_pedal_signature = "-"  # the pedals line up again in front of it


func _place_parts() -> void:
	_light.position = Vector3(0, top - source_height + 0.15, 0.6)  # above and in front, lighting it from the player's side
	_label.position = Vector3(0, top - source_height + 0.3, 0)
	_input_badge.position = _label.position - Vector3(0, 0.15, 0)
	_loop_label.position = _label.position - Vector3(0, 0.3, 0)
	(_collider.shape as BoxShape3D).size = Vector3(footprint.x * 0.85, top, footprint.y * 0.85)
	_collider.position.y = top / 2 - source_height


## An amp's head and cabinet, and whether each is in use. A new cabinet is drawn as well as heard.
func set_voice(head: String, use_head: bool, cabinet: String, use_cabinet: bool) -> void:
	amp_head = head
	head_on = use_head
	_audio.set_amp_head(source_id, head, use_head)
	_audio.set_amp_cabinet(source_id, cabinet, use_cabinet)
	cabinet_on = use_cabinet
	if cabinet != amp_cabinet:
		amp_cabinet = cabinet
		_build_model()
		_place_parts()


func _process(delta: float) -> void:
	if source_id < 0:
		return
	var target := minf(1.0, sqrt(_audio.get_source_level(source_id)) * 1.6)
	glow = lerpf(glow, target, minf(1.0, delta * (40.0 if target > glow else 7.0)))
	var on := 0.25 if muted else 1.0
	_accent.emission_energy_multiplier = (0.12 + 1.5 * glow) * on
	_light.light_energy = (0.1 + 1.6 * glow) * on
	inserts = _audio.get_inserts(source_id)
	if plays_plugin:
		instrument_plugin = _audio.get_instrument_plugin(source_id)
	if is_amp:
		_show_pedals()
		_show_looper()


## An amp's effect pedals, as the audio core has them, on the floor in a row in front of it (the first in line on the
## right as you face the amp), each lit while it is on; and what the tuner hears while one is on.
func _show_pedals() -> void:
	pedals = _audio.get_pedals(source_id)
	var signature := ""
	for p in pedals:
		signature += p.kind + "|"
	if signature != _pedal_signature:
		_pedal_signature = signature
		for child in _pedal_row.get_children():
			child.queue_free()
		_pedal_leds.clear()
		_led = null
		for i in pedals.size():
			var spec: Dictionary = Catalog.PEDALS[pedals[i].kind]
			var knobs := 0
			for control in spec.controls:
				knobs += 0 if control[1] == "switch" else 1
			var box: Dictionary = Models.loop_pedal() if pedals[i].kind == "looper" else Models.stomp_box(spec.color, knobs)
			box.node.position = _pedal_spot + Vector3(0.09 * ((pedals.size() - 1) / 2.0 - i), 0.0, 0.0)
			_pedal_row.add_child(box.node)
			_pedal_leds.append(box.led)
			if pedals[i].kind == "looper":
				_led = box.led
	var tuning := false
	for i in pedals.size():
		if pedals[i].kind != "looper":  # its light shows what the loop is doing instead
			_pedal_leds[i].emission_energy_multiplier = 2.5 if pedals[i].on else 0.0
		tuning = tuning or (pedals[i].on and pedals[i].kind == "tuner")
	tuner = _audio.get_tuner(source_id) if tuning else {}


func _show_looper() -> void:
	looper = _audio.get_looper(source_id)
	var state: String = looper.get("state", "empty")
	var look: Array = LOOP_LOOKS.get(state, ["", Color.BLACK])
	var text: String = look[0]
	if state in ["recording", "playing", "overdubbing"]:
		text += "  %.1f s" % (looper.length if state == "recording" else looper.position)
	var ink: Color = look[1]
	if not tuner.is_empty():  # tuning: the note and how far off it is, over whatever the loop is doing
		var off: float = tuner.get("cents", 0.0)
		var note := "TUNER  %s  %+.0f ¢" % [Catalog.note_name(tuner.note), off] if tuner.get("pitched", false) else "TUNER  -"
		text = note + ("\n" + text if text != "" else "")
		ink = Color(0.4, 0.9, 0.5) if tuner.get("pitched", false) and absf(off) < 3.0 else Color(1.0, 0.75, 0.3)
	_loop_label.text = text
	_loop_label.modulate = ink
	_loop_label.visible = text != "" and _label.visible
	if _led != null:
		_led.emission = look[1]
		_led.emission_energy_multiplier = 0.0 if state in ["empty", "none"] else (2.5 if state in ["recording", "overdubbing"] else 1.5)


## Tells the audio core where this instrument is, if it has moved.
func sync_position() -> void:
	if not global_position.is_equal_approx(_sent_position):
		_sent_position = global_position
		_audio.set_source_position(source_id, global_position)


## Turns it to face a point on the floor (its front is the side a player stands at).
func face(point: Vector3) -> void:
	rotation.y = atan2(point.x - global_position.x, point.z - global_position.z)


## Its mixer channel: muted, soloed, and whether that leaves it silent once every solo in the room is counted.
func set_channel(is_muted: bool, is_soloed: bool, silent: bool) -> void:
	muted = is_muted
	soloed = is_soloed
	_audio.set_source_muted(source_id, silent)
	_refresh_label()


## Its level: 0 dB is the level it was made at, heard from within a metre and a half.
func normal_gain() -> float:  # what 0 dB on its fader stands for in the audio core
	return _normal_gain


func set_level_db(db: float) -> void:
	level_db = db
	_audio.set_source_gain(source_id, 0.0 if db <= -79.0 else _normal_gain * db_to_linear(db))


func set_input(on: bool) -> void:
	input_on = on
	_audio.set_source_input(source_id, on)
	_input_badge.visible = on and _label.visible


func set_input_channel(channel: int) -> void:
	input_channel = channel
	_audio.set_source_input_channel(source_id, channel)


## Stops or restarts the sequencer playing this instrument's pattern. It can still be played by hand.
func set_loop(on: bool) -> void:
	loop_on = on
	_audio.set_source_loop(source_id, on)
	_refresh_label()


## Its track's colour: its name over it in the room and its light, and wherever its track is shown.
func set_color(new_color: Color) -> void:
	color = new_color
	_light.light_color = color
	_label.modulate = color.lightened(0.35)
	_refresh_label()


## A new name (a plug-in instrument takes its plug-in's): over it in the room, and wherever else it is shown.
func set_display_name(new_name: String) -> void:
	display_name = new_name
	name = new_name.validate_node_name()
	_refresh_label()


## The name floating above it. The title screen hides these so they don't drift behind its words.
func set_label_visible(on: bool) -> void:
	_label.visible = on
	_input_badge.visible = on and input_on
	if not on:
		_loop_label.visible = false


func set_carried(value: bool) -> void:
	carried = value
	_collider.disabled = value


func set_highlighted(value: bool) -> void:
	_label.outline_modulate = color.darkened(0.2) if value else Color(0, 0, 0, 0.85)


func _refresh_label() -> void:
	var notes := []
	if muted:
		notes.append("muted")
	if playable and not loop_on:
		notes.append("loop off")
	_label.text = display_name + ("  (%s)" % ", ".join(notes) if not notes.is_empty() else "")
	_label.modulate.a = 0.55 if not notes.is_empty() else 1.0
