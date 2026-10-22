extends Node3D
## One instrument in the room: its model, label and light, plus its sound source in the audio core.
## It stands on the floor; the node's origin is where the sound comes from, `source_height` above the floor. A
## microphone (`is_mic`) is one of these too: its origin is its capsule, where it hears the room from, and the way it
## faces is the way it points. A stereo mic (`is_stereo_mic`: a stereo pair, one stereo track) has two capsules on a
## bar, either side of its origin, each turned from the way it faces as its setup has it.

const Models := preload("res://scripts/instrument_models.gd")
const Catalog := preload("res://scripts/catalog.gd")
const INPUT_GREEN := Color(0.36, 0.9, 0.5)
# A padlock, yellow, over a locked instrument's name.
const LOCK_SVG := "<svg xmlns='http://www.w3.org/2000/svg' width='64' height='64' viewBox='0 0 64 64'><path d='M20 29 V20 a12 12 0 0 1 24 0 V29' fill='none' stroke='#1a1408' stroke-width='11' stroke-linecap='round'/><path d='M20 29 V20 a12 12 0 0 1 24 0 V29' fill='none' stroke='#f5c542' stroke-width='6' stroke-linecap='round'/><rect x='12' y='27' width='40' height='31' rx='6' fill='#f5c542' stroke='#1a1408' stroke-width='3'/><circle cx='32' cy='40' r='4.5' fill='#1a1408'/><rect x='30' y='41' width='4' height='9' rx='2' fill='#1a1408'/></svg>"
static var _lock_texture: Texture2D
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
var muted := false     # its mixer channel is muted: its direct output (a microphone's track), in the mix
var room_muted := false  # it is silent in the room (M at it): no one there hears it, nor do the microphones
var room_db := 0.0     # its level in the room: how loud it sounds where it stands (0 dB: as it was made)
var soloed := false
var loop_on := true    # playable instruments: whether the sequencer plays their pattern
var input_on := false  # it takes input: MIDI controllers play it, or a Speaker plays its hardware input
var locked := false    # it stays where it is (Cmd-L): it can't be carried, nor a microphone moved or aimed
var input_channel := -1  # live-input instruments: the hardware input they play (0-based), or -1 for all of them
var level_db := 0.0    # its fader, in the mix (its direct output): how far above or below its normal level it is set
var room_meter_peak := 0.0  # its meter in the room (the game's, each frame; see main.gd)
var room_meter_rms := 0.0
var volume_db := 0.0   # a Speaker's own volume (its panel), before the fader
# Its channel meter, as linear levels where 1 is full scale: this frame's peak and average, and the highest peak
# since its peak readout was last cleared (read by the game each frame; see main.gd).
var meter_peak := 0.0
var meter_rms := 0.0
var peak_hold := 0.0
var is_amp := false    # a guitar or bass amp, with knobs and a loop pedal
var drum_kit := false  # each key plays a drum (the drums, the garage kit)
var plays_plugin := false  # a plug-in instrument: it plays one of the instrument plug-ins on the computer
var is_mic := false    # a microphone: it hears the room from where it stands, and its track records that
var mic_tilt := 0.0    # a microphone: how far it points down (degrees; the way it faces is its aim round)
var mic_gain_db := 0.0 # a microphone's gain, before it is recorded, as a preamp's
var mic_model := ""    # which model it is (microphones.h: "flat", "dynamic", "kick", "condenser", "pencil", "ribbon")
var mic_pattern := ""  # and which of its pickup patterns ("omni", "cardioid", "supercardioid", "figure8")
var pan := 0.0         # where its track sits in the stereo (its direct output; a microphone's track): -1 left, 1 right
# A stereo mic: how its two are set up (catalog.gd's MIC_PAIRS), how far apart they are, and for a mid-side pair its
# side mic's model and how wide it is decoded (1: as it hears it).
var is_stereo_mic := false
var pair_technique := ""
var pair_spacing := 0.0
var side_model := "condenser"
var ms_width := 1.0
var instrument_plugin := {}  # what that plug-in is, from the audio core: {plugin_id, plugin_name, plugin_maker, editor_open}
var amp_controls := {"gain": 5.0, "bass": 5.0, "mid": 5.0, "treble": 5.0, "presence": 5.0, "master": 5.0}
var amp_head := ""      # an amp's head and cabinet (catalog.gd lists them), and whether each is in use
var amp_cabinet := ""
var amp_speaker := ""   # the speakers in its cabinet (catalog.gd: AMP_SPEAKERS), of the cabinet's size
var head_on := true
var cabinet_on := true
var loop_mix := 0.5    # its effects loop's Mix (a parallel loop): how much of what comes back is blended in, 0 to 1
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
var _sent_aim := Vector3.INF       # and, a microphone, which way it points
var _capsules_moved := false       # a stereo mic set up afresh: its capsules sent again
var _sent_speakers := ""           # an amp: where its cabinet was, and which, when the audio core was last told
var _labels_shown := true          # (the title screen hides the names)
var _model: Node3D
var _accent: StandardMaterial3D  # the parts in its own colour, which light up as it plays
var _light: OmniLight3D
var _label: Label3D
var _input_badge: Label3D
var _lock_badge: Sprite3D  # the padlock over its name while it is locked
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
	is_mic = spec.get("mic", false)
	is_stereo_mic = spec.get("stereo", false)
	playable = not spec.get("live_input", false) and not is_mic
	default_octave = spec.get("octave", 0)
	is_amp = spec.get("amp", false)
	drum_kit = spec.get("drum_kit", false)
	plays_plugin = spec.get("plugin", false)
	amp_head = spec.get("head", "")
	amp_cabinet = spec.get("cabinet", "")
	amp_speaker = Catalog.CABINET_SPEAKERS.get(amp_cabinet, "")
	name = display_name
	position = Vector3(spec.position.x, source_height, spec.position.z)

	_normal_gain = spec.gain
	source_id = audio.add_source(("stereo_mic" if is_stereo_mic else "mic") if is_mic else kind, position, spec.gain, spec.send)
	if source_id < 0:
		return  # the room is full; whoever asked for this instrument gives up on it
	if is_mic:
		mic_model = spec.get("model", "flat")
		mic_pattern = ""
		_audio.set_mic_model(source_id, mic_model, mic_pattern)

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
	if _lock_texture == null:
		var image := Image.new()
		image.load_svg_from_string(LOCK_SVG, 1.0)
		_lock_texture = ImageTexture.create_from_image(image)
	_lock_badge = Sprite3D.new()
	_lock_badge.texture = _lock_texture
	_lock_badge.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_lock_badge.pixel_size = 0.0028
	_lock_badge.visible = false
	add_child(_lock_badge)
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
	var built: Dictionary = Models.build("mic" if is_mic else kind, model_color, amp_cabinet, {"height": source_height, "tilt": mic_tilt,
		"model": mic_model, "capsules": mic_capsules() if is_stereo_mic else []})
	_model = built.node
	_model.position.y = -source_height  # the model is drawn from the floor up
	add_child(_model)
	_accent = built.accent
	top = built.get("top", top)
	footprint = built.get("footprint", footprint)
	_pedal_spot = built.get("pedal_spot", Vector3.ZERO)
	_model.add_child(_pedal_row)
	_pedal_signature = "-"  # the pedals line up again in front of it


## Hides it from a camera that leaves out the 3D layer `bit` (1 to 20), or with 0 shows it to every camera again: a
## microphone's model and name, while you look out from its capsule.
func set_hidden_layer(bit: int) -> void:
	for node in find_children("*", "GeometryInstance3D", true, false):
		node.layers = (1 << (bit - 1)) if bit > 0 else 1


func _place_parts() -> void:
	_light.position = Vector3(0, top - source_height + 0.15, 0.6)  # above and in front, lighting it from the player's side
	_label.position = Vector3(0, top - source_height + 0.3, 0)
	_input_badge.position = _label.position - Vector3(0, 0.15, 0)
	_lock_badge.position = _label.position + Vector3(0, 0.17, 0)
	_loop_label.position = _label.position - Vector3(0, 0.3, 0)
	(_collider.shape as BoxShape3D).size = Vector3(footprint.x * 0.85, top, footprint.y * 0.85)
	_collider.position.y = top / 2 - source_height


## An amp's head and cabinet, and whether each is in use, and the speakers in the cabinet (none given, or of another
## size: the ones it has, if they fit, or else the cabinet's usual ones). A new cabinet is drawn as well as heard.
func set_voice(head: String, use_head: bool, cabinet: String, use_cabinet: bool, speaker := "") -> void:
	amp_head = head
	head_on = use_head
	_audio.set_amp_head(source_id, head, use_head)
	_audio.set_amp_cabinet(source_id, cabinet, use_cabinet)
	cabinet_on = use_cabinet
	if speaker == "" or not Catalog.speaker_fits(speaker, cabinet):
		speaker = amp_speaker if cabinet == amp_cabinet and Catalog.speaker_fits(amp_speaker, cabinet) else Catalog.CABINET_SPEAKERS.get(cabinet, "")
	amp_speaker = speaker
	_audio.set_amp_speaker(source_id, speaker)
	if cabinet != amp_cabinet:
		amp_cabinet = cabinet
		_build_model()
		_place_parts()


func _process(delta: float) -> void:
	if source_id < 0:
		return
	var heard: float = _audio.get_source_level(source_id) if is_mic else _audio.get_source_room_level(source_id)  # (as it sounds in the room)
	var target := minf(1.0, sqrt(heard) * 1.6)
	glow = lerpf(glow, target, minf(1.0, delta * (40.0 if target > glow else 7.0)))
	var on := 0.25 if (room_muted or (is_mic and muted)) else 1.0
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


## Tells the audio core where this instrument is, if it has moved (and a microphone, which way it points).
func sync_position() -> void:
	if radiates():
		_sync_speakers()
	elif not global_position.is_equal_approx(_sent_position):
		_sent_position = global_position
		_audio.set_source_position(source_id, global_position)
		_capsules_moved = is_stereo_mic
	if is_mic:
		var aim := mic_aim()
		if not aim.is_equal_approx(_sent_aim) or _capsules_moved:
			_sent_aim = aim
			_capsules_moved = false
			if not is_stereo_mic:
				_audio.set_mic_aim(source_id, aim)
			else:  # each capsule, where it is on the bar and the way it points
				var capsules := mic_capsules()
				for k in capsules.size():
					_audio.set_mic_capsule(source_id, k, global_transform * capsules[k].at)
					_audio.set_mic_aim(source_id, (global_transform.basis * capsules[k].aim).normalized(), k)


## Whether it is a loudspeaker the audio core hears cone by cone (radiation.h): an amp's cabinet, the PA Speaker.
func radiates() -> bool:
	return is_amp or kind == "live"


## An amp's cabinet (or the Speaker), as the audio core hears it: from the middle of its grille (as the listener hears
## it), and each of its cones on its own (as the microphones do), told again whenever it moves, turns or changes cabinet.
func _sync_speakers() -> void:
	var signature := "%s|%s|%s" % [global_transform, amp_cabinet, kind]
	if signature == _sent_speakers:
		return
	_sent_speakers = signature
	_sent_position = global_position
	var world := speakers_in_room()
	_audio.set_source_position(source_id, world.baffle)
	_audio.set_source_radiator(source_id, PackedVector3Array(world.cones), world.facing, world.inches, world.back != null,
		world.back if world.back != null else Vector3.ZERO, world.width, world.coverage)


## An amp's speakers (or the Speaker's), where they are in the room: {cones (each one's middle, its dust cap), baffle (the
## middle of its grille), back (its open back's middle, or null), facing, inches, width, coverage (a horn's)}.
func speakers_in_room() -> Dictionary:
	var local: Dictionary = Models.speakers(amp_cabinet, kind.ends_with("_combo")) if is_amp else Models.pa_speakers()
	var lift := Vector3(0, source_height, 0)  # (the model is drawn from the floor up)
	var place := func(p: Vector3) -> Vector3: return global_transform * (p - lift)
	return {"cones": local.cones.map(place), "baffle": place.call(local.baffle), "back": place.call(local.back) if local.back != null else null,
		"facing": global_transform.basis.z.normalized(), "inches": local.inches, "width": local.width, "coverage": local.coverage}


## Where its sound comes from, as `from` has it: a loudspeaker's nearest cone, or anything else's middle.
func sound_point(from: Vector3) -> Vector3:
	if not radiates():
		return global_position
	var best := Vector3.INF
	for cone: Vector3 in speakers_in_room().cones:
		if best == Vector3.INF or cone.distance_to(from) < best.distance_to(from):
			best = cone
	return best


## The way a microphone points, in the room: the way it faces, tilted down by its tilt.
func mic_aim() -> Vector3:
	var t := deg_to_rad(mic_tilt)
	return (global_transform.basis * Vector3(0.0, -sin(t), cos(t))).normalized()


## A stereo mic's two capsules, as it sees them: [{at (from its origin), aim, turn (radians), model}], the left (or
## mid) one first.
func mic_capsules() -> Array:
	var spec: Dictionary = Catalog.MIC_PAIRS.get(pair_technique, Catalog.MIC_PAIRS.xy)
	var t := deg_to_rad(mic_tilt)
	var out := []
	for k in 2:
		var turn := deg_to_rad(float(spec.turns[k]))
		var aim := Basis(Vector3.UP, turn) * Vector3(0.0, -sin(t), cos(t))
		out.append({"at": Vector3(pair_spacing / 2.0 * (1.0 if k == 0 else -1.0), 0.0, 0.0), "aim": aim, "turn": turn,
			"model": side_model if k == 1 and spec.get("mid_side", false) else mic_model})
	return out


## A microphone's model and pattern ("" for the model's own): a stereo mic's two alike, but a mid-side pair's side,
## which stays a figure-8.
func set_mic_model(model: String, pattern := "") -> void:
	mic_model = model
	mic_pattern = pattern
	var mid_side: bool = is_stereo_mic and Catalog.MIC_PAIRS.get(pair_technique, {}).get("mid_side", false)
	_audio.set_mic_model(source_id, model, pattern, 0 if mid_side else -1)
	if mid_side:
		_audio.set_mic_model(source_id, side_model, "figure8", 1)
	_build_model()
	_place_parts()
	_capsules_moved = true


## A stereo mic's setup: how its two are set up, how far apart, a mid-side pair's side mic and width.
func set_pair(technique: String, spacing: float, side := "condenser", width := 1.0) -> void:
	pair_technique = technique
	pair_spacing = spacing
	side_model = side
	ms_width = width
	var mid_side: bool = Catalog.MIC_PAIRS.get(technique, {}).get("mid_side", false)
	_audio.set_mic_mid_side(source_id, mid_side, ms_width)
	set_mic_model(mic_model, mic_pattern)


func set_ms_width(width: float) -> void:
	ms_width = clampf(width, 0.0, 2.0)
	_audio.set_mic_mid_side(source_id, true, ms_width)


func set_pan(value: float) -> void:
	self.pan = clampf(value, -1.0, 1.0)
	_audio.set_source_pan(source_id, self.pan)


## Draws it again (a stereo pair set up another way).
func rebuild() -> void:
	_build_model()
	_place_parts()
	_refresh_label()


## Turns it to face a point on the floor (its front is the side a player stands at).
func face(point: Vector3) -> void:
	rotation.y = atan2(point.x - global_position.x, point.z - global_position.z)


## Its mixer channel: muted and soloed; whether that (or its folder's mute) silences it in the room; and whether a
## solo elsewhere takes it out of the mix, which leaves it sounding in the room, for the microphones to hear.
func set_channel(is_muted: bool, is_soloed: bool, silent: bool, solo_muted := false) -> void:
	muted = is_muted
	soloed = is_soloed
	_audio.set_source_muted(source_id, silent)
	_audio.set_source_solo_muted(source_id, solo_muted)
	_refresh_label()


## Whether it plays one of the audio interface's inputs (a Speaker, an amp), rather than notes or what a mic hears.
func is_live() -> bool:
	return not playable and not is_mic


## A microphone's capsule height over the floor (metres), how far it points down (degrees), its gain (dB): the stand
## drawn again to match.
func set_mic_height(height: float) -> void:
	source_height = clampf(height, 0.05, 4.0)
	position.y = source_height
	_build_model()
	_place_parts()
	sync_position()


func set_mic_tilt(degrees: float) -> void:
	mic_tilt = clampf(degrees, -90.0, 90.0)
	_build_model()
	_place_parts()
	_capsules_moved = true


func set_mic_gain(db: float) -> void:
	mic_gain_db = clampf(db, -20.0, 40.0)
	_audio.set_source_volume(source_id, db_to_linear(mic_gain_db))


## Its level: 0 dB is the level it was made at, heard from within a metre and a half.
func normal_gain() -> float:  # what 0 dB on its fader stands for in the audio core
	return _normal_gain


func set_level_db(db: float) -> void:
	level_db = db
	_audio.set_source_gain(source_id, 0.0 if db <= -79.0 else _normal_gain * db_to_linear(db))


## Its level in the room, and its mute there.
func set_room_db(db: float) -> void:
	room_db = db
	_audio.set_source_room_gain(source_id, 0.0 if db <= -79.0 else _normal_gain * db_to_linear(db))


func set_room_muted(on: bool) -> void:
	room_muted = on
	_audio.set_source_room_muted(source_id, on)
	_refresh_label()


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
	_labels_shown = on
	_label.visible = on
	_input_badge.visible = on and input_on
	_lock_badge.visible = on and locked
	if not on:
		_loop_label.visible = false


## Locked, it stays where it stands: the yellow padlock over its name says so.
func set_locked(on: bool) -> void:
	locked = on
	_lock_badge.visible = on and _label.visible


func lock_shown() -> bool:  # (for the checks)
	return _lock_badge.visible


## Where it stands and which way it faces (a microphone, its height and how far down it points too), to be put back.
func placement() -> Dictionary:
	return {"position": global_position, "yaw": rotation.y, "height": source_height, "tilt": mic_tilt}


func set_carried(value: bool) -> void:
	carried = value
	_collider.disabled = value


func set_highlighted(value: bool) -> void:
	_label.outline_modulate = color.darkened(0.2) if value else Color(0, 0, 0, 0.85)


func _refresh_label() -> void:
	var notes := []
	if room_muted or (is_mic and muted):  # (an instrument: muted in the room; a microphone: its track)
		notes.append("muted")
	if playable and not loop_on:
		notes.append("loop off")
	_label.text = display_name + ("  (%s)" % ", ".join(notes) if not notes.is_empty() else "")
	_label.modulate.a = 0.55 if not notes.is_empty() else 1.0
