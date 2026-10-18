extends CharacterBody3D
## First-person player: walks the room, aims at instruments, carries them, and sits down at one to play it.
## Sitting at an instrument switches its input on (until you get up), so the MIDI keyboard plays it; the computer
## keyboard plays it too. Both also play every other instrument whose input you have switched on yourself.
## The camera is also the listener, so the audio core hears the room from here.

const EYE_HEIGHT := 1.65
const WALK_SPEED := 2.8
const RUN_SPEED := 5.5
const TURN_SPEED := 1.9  # arrow keys, radians per second
const MOUSE_SENSITIVITY := 0.0022  # multiplied by the setting
const REACH := 4.2
const PLAY_REACH := 2.8
const AIM_COS := 0.955  # within about 17° of where you're facing
const CARRY_DISTANCE := 1.5
const REMOVE_WINDOW_MS := 3000  # how long the second Backspace has to follow the first

const Bindings := preload("res://scripts/bindings.gd")  # the keys, and the computer keyboard as a piano (NOTES)
const KEYMAP := Bindings.NOTES

var app  # main.gd: settings and the audio core
var audio: SoundRoomAudio
var instruments: Array = []
var camera: Camera3D
var yaw := 0.0
var pitch := 0.0
var target = null   # instrument you're aiming at
var carried = null  # instrument you're carrying
var playing = null  # instrument you're playing
var octave := 0
var typing := false  # the keyboard (K) is open: the letter keys play every instrument whose input is on
var keyboard_octave := 0
var held := {}      # physical key → [MIDI note sounding, the instruments it was sent to]
var remove_pending = null  # instrument that Backspace was pressed on once; a second press removes it
var _sat_input := false    # sitting down switched the input on, so getting up switches it off again
var clear_pending = null   # the amp whose loop J was pressed for once; a second press clears it
var _clear_deadline := 0

var _remove_deadline := 0



func setup(the_app, room_instruments: Array) -> void:
	app = the_app
	audio = app.audio
	instruments = room_instruments

	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.3
	capsule.height = 1.8
	shape.shape = capsule
	shape.position.y = 0.9
	add_child(shape)

	camera = Camera3D.new()
	camera.position.y = EYE_HEIGHT
	camera.fov = app.settings.fov
	camera.near = 0.05
	add_child(camera)
	camera.make_current()
	place(Vector3(0.0, 0.0, 3.6), 0.0)


func place(at: Vector3, facing_yaw: float) -> void:
	position = at
	yaw = facing_yaw
	pitch = 0.0
	_apply_look()


func ear_position() -> Vector3:
	return camera.global_position


func can_play_target() -> bool:
	return target != null and target.playable and _distance_to(target) < PLAY_REACH


## Sit down at an instrument: the computer keyboard and MIDI controllers now play it.
func start_playing(inst) -> void:
	if playing == inst:
		return
	stop_playing()
	if typing:
		close_keyboard()
	playing = inst
	octave = inst.default_octave
	var was_on: bool = inst.input_on
	if not was_on:
		app.set_input(inst, true)  # (this tells notice_input, which would mark the input as your own choice)
	_sat_input = not was_on


func stop_playing() -> void:
	release_keys()
	var was = playing
	playing = null
	if was != null and _sat_input and was.input_on:
		app.set_input(was, false)
	_sat_input = false


## An instrument's input was switched on or off. If it is the one you are sitting at, the choice is now yours:
## getting up leaves it as it is.
func notice_input(inst) -> void:
	if inst == playing:
		_sat_input = false


func put_down() -> void:
	if carried != null:
		_grab_or_drop()


## Take an instrument in hand, as G does: it follows you until you put it down.
func carry(inst) -> void:
	stop_playing()
	if carried != null:
		carried.set_carried(false)
	if target != null:
		target.set_highlighted(false)
		target = null
	carried = inst
	carried.set_carried(true)


## An instrument is leaving the room: let go of it.
func forget(inst) -> void:
	if playing == inst:
		stop_playing()
	if carried == inst:
		carried = null
	if target == inst:
		target = null
	if remove_pending == inst:
		remove_pending = null
	if clear_pending == inst:
		clear_pending = null


## The title screen, one of the menus or the pattern editor is up: the keyboard and mouse belong to it.
## Walking about: with nothing open, or only the mix window, which docks along the bottom so the room stays in view
## (unless something in it is being typed into).
func _can_move() -> bool:
	for panel in [app.title, app.menu, app.sequencer, app.amp_panel, app.speaker_panel, app.instrument_menu, app.name_prompt]:
		if panel != null and panel.is_open():
			return false
	if app.plugin_browser != null and app.plugin_browser.visible:
		return false
	return not (get_viewport().gui_get_focus_owner() is LineEdit)


func _ui_open() -> bool:
	for panel in [app.title, app.menu, app.sequencer, app.mixer, app.amp_panel, app.speaker_panel, app.instrument_menu, app.name_prompt]:
		if panel != null and panel.is_open():
			return true
	return false


func _unhandled_input(event: InputEvent) -> void:
	if _ui_open():
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var sensitivity: float = MOUSE_SENSITIVITY * app.settings.mouse_sensitivity
		yaw -= event.relative.x * sensitivity
		pitch = clampf(pitch - event.relative.y * sensitivity, -1.45, 1.45)
		_apply_look()
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		elif playing == null:
			_grab_or_drop()
	elif event is InputEventKey and not event.echo:
		_handle_key(event)


func _handle_key(event: InputEventKey) -> void:
	var key := event.physical_keycode
	if not event.pressed:
		if held.has(key):
			for id in held[key][1]:
				audio.note_off(id, held[key][0])
			held.erase(key)
		return
	if key == KEY_ESCAPE:  # always backs out: up from an instrument, the keyboard closed, or the menu
		if playing != null:
			stop_playing()
		elif typing:
			close_keyboard()
		else:
			app.menu.open()
		return
	var notes := playing != null or typing  # the letter keys are a piano
	if notes and Bindings.NOTES.has(key):
		_note_on(key)
		return
	# The instrument these keys act on: the one you are playing, or else the one you are facing.
	var at = playing if playing != null else target
	var keys = app.bindings
	match keys.action_for(key):
		"mixer":
			app.mixer.open()
		"edit":
			if at != null and at.playable and (playing != null or can_play_target()):
				app.sequencer.open(at)
			elif at != null and at.is_amp and _distance_to(at) < PLAY_REACH + 0.5:
				app.amp_panel.open(at)
			elif at != null and not at.playable and _distance_to(at) < PLAY_REACH + 0.5:
				app.speaker_panel.open(at)
		"add":
			app.instrument_menu.open()
		"duplicate":  # a second of what you face or carry, with its settings, in your hands to be put down
			var original = carried if carried != null else at
			if original != null and not notes:
				var copy = app.duplicate_instrument(original, original.global_position)
				if copy != null:
					carry(copy)
		"remove":
			_ask_to_remove(carried if carried != null else at)
		"loop":  # an instrument's loop; a Speaker or an amp has none, so it mutes
			if at != null and at.playable:
				at.set_loop(not at.loop_on)
			elif at != null:
				app.set_muted(at, not at.muted)
		"transport":
			app.set_sequence_running(not app.sequence_running)
		"click":
			app.set_click(not app.settings.click)
		"binaural":
			app.set_binaural(not app.settings.binaural)
		"reverb":
			app.set_reverb(not app.settings.reverb)
		"input":
			if at != null:
				app.set_input(at, not at.input_on)
		"stop":
			if playing != null:
				stop_playing()
			elif typing:
				close_keyboard()
		"octave_down", "octave_up":
			if notes:
				var step := 1 if keys.action_for(key) == "octave_up" else -1
				if playing != null:
					octave = clampi(octave + step, -3, 3)
				else:
					keyboard_octave = clampi(keyboard_octave + step, -3, 3)
		"keyboard":
			if not notes:
				open_keyboard()
		"play":
			if not notes and can_play_target():
				start_playing(target)
		"carry":
			if not notes:
				_grab_or_drop()
		"loop_switch", "loop_stop", "loop_undo", "loop_clear":  # an amp's loop pedal, if it has one
			if not notes and target != null and target.is_amp and target.looper.get("state", "none") != "none":
				_loop_pedal(target, keys.action_for(key))
		_:
			if not notes and key >= KEY_1 and key <= KEY_8 and target != null and target.is_amp:  # stamping on its pedals
				app.stomp(target, key - KEY_1)


## A note on the computer keyboard: to the instrument you're at and every other instrument whose input is on, or with
## the keyboard open, to every instrument whose input is on.
func _note_on(key: int) -> void:
	var base: int = octave if playing != null else keyboard_octave
	var note := 60 + 12 * base + int(Bindings.NOTES[key])
	var ids := [playing.source_id] if playing != null else []
	for inst in app.armed_instruments():
		if inst != playing:
			ids.append(inst.source_id)
	for id in ids:
		audio.note_on(id, note, 0.8)
	held[key] = [note, ids]


## The keyboard (K): the letter keys play every instrument whose input is on, from wherever you are. The arrow keys
## walk and turn meanwhile, and the mouse still looks about.
func open_keyboard() -> void:
	if playing != null:
		return
	typing = true


func close_keyboard() -> void:
	release_keys()
	typing = false


## The loop pedal's buttons as keys: the footswitch, stop or play, undo or redo, clear (twice).
func _loop_pedal(amp, action: String) -> void:
	var loop: Dictionary = amp.looper
	match action:
		"loop_switch":
			app.looper_action(amp, "press")
		"loop_stop":
			app.looper_action(amp, "play" if loop.get("state", "") == "stopped" else "stop")
		"loop_undo":
			app.looper_action(amp, "undo" if loop.get("can_undo", false) else "redo")
		"loop_clear":
			if clear_pending == amp and Time.get_ticks_msec() < _clear_deadline:
				clear_pending = null
				app.looper_action(amp, "clear")
			elif loop.get("state", "empty") != "empty":
				clear_pending = amp
				_clear_deadline = Time.get_ticks_msec() + REMOVE_WINDOW_MS


func _physics_process(delta: float) -> void:
	var forward := 0.0
	var strafe := 0.0
	var turn := 0.0
	if _can_move():
		forward += _held("forward") - _held("back")
		strafe += _held("right") - _held("left")
		forward += float(Input.is_physical_key_pressed(KEY_UP)) - float(Input.is_physical_key_pressed(KEY_DOWN))
		turn += float(Input.is_physical_key_pressed(KEY_LEFT)) - float(Input.is_physical_key_pressed(KEY_RIGHT))
	if turn != 0.0:
		yaw += turn * TURN_SPEED * delta
		_apply_look()

	var basis_flat := Basis(Vector3.UP, yaw)
	var wish := basis_flat * Vector3(strafe, 0.0, -forward)
	var speed := RUN_SPEED if app.bindings.is_down("run") else WALK_SPEED
	if wish.length() > 1.0:
		wish = wish.normalized()
	velocity.x = wish.x * speed
	velocity.z = wish.z * speed
	velocity.y = 0.0 if is_on_floor() else velocity.y - 9.8 * delta
	move_and_slide()
	# However crowded it gets (instruments brought in when the room shrinks push you about), you stay in the room.
	var inside: Vector3 = app.room.keep_inside(global_position, 0.3)
	global_position = Vector3(inside.x, global_position.y, inside.z)

	if playing != null and _distance_to(playing) > PLAY_REACH + 0.6:
		stop_playing()
	_update_carry()


func _process(_delta: float) -> void:
	if app.title == null or not app.title.is_open():  # on the title screen its own camera does the listening
		audio.set_listener(camera.global_transform)
	if remove_pending != null and (Time.get_ticks_msec() >= _remove_deadline
			or (remove_pending != carried and remove_pending != target and remove_pending != playing)):
		remove_pending = null  # too slow, or looking at something else now
	if clear_pending != null and (Time.get_ticks_msec() >= _clear_deadline or clear_pending != target):
		clear_pending = null
	var aimed = null if carried != null else _pick_target()
	if aimed != target:
		if target != null:
			target.set_highlighted(false)
		if aimed != null:
			aimed.set_highlighted(true)
		target = aimed


## 1 if a movement key is held, 0 if not, or if it is a note key and the letter keys are notes just now.
func _held(action: String) -> float:
	var keycode: int = app.bindings.key(action)
	if (playing != null or typing) and Bindings.NOTES.has(keycode):
		return 0.0
	return float(Input.is_physical_key_pressed(keycode))


## Removing takes two presses, so a slip of the finger doesn't cost an instrument and its pattern.
func _ask_to_remove(inst) -> void:
	if inst == null:
		return
	if remove_pending == inst and Time.get_ticks_msec() < _remove_deadline:
		app.remove_instrument(inst)
	else:
		remove_pending = inst
		_remove_deadline = Time.get_ticks_msec() + REMOVE_WINDOW_MS


## Called when the menu or the pattern editor opens: let go of any notes held on the computer keyboard.
func release_keys() -> void:
	for key in held:
		for id in held[key][1]:
			audio.note_off(id, held[key][0])
	held.clear()


func _apply_look() -> void:
	rotation = Vector3(0.0, yaw, 0.0)
	if camera:
		camera.rotation = Vector3(pitch, 0.0, 0.0)


## The instrument you're facing, judged by heading so a low instrument is selectable without looking down at it.
func _pick_target():
	var ahead := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var ear := ear_position()
	var best = null
	var best_dot := AIM_COS
	for inst in instruments:
		var to: Vector3 = inst.global_position - ear
		var flat := Vector3(to.x, 0.0, to.z)
		if to.length() > REACH or flat.length() < 0.001:
			continue
		if absf(atan2(to.y, flat.length()) - pitch) > 0.9:
			continue
		var d := flat.normalized().dot(ahead)
		if d > best_dot:
			best_dot = d
			best = inst
	return best


func _grab_or_drop() -> void:
	if carried != null:
		carried.set_carried(false)
		carried = null
	elif target != null:
		carried = target
		carried.set_carried(true)
		target.set_highlighted(false)
		target = null


func _update_carry() -> void:
	if carried == null:
		return
	var ahead := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var p := global_position + ahead * (CARRY_DISTANCE + maxf(carried.footprint.y, carried.footprint.x) * 0.35)
	p.y = carried.source_height  # instruments stay on the floor
	# Inside the room, and on your side of any wall, turned towards you.
	carried.global_position = app.room.settle(p, 0.6, 0.5, global_position)
	carried.face(global_position)


func _distance_to(inst) -> float:
	return ear_position().distance_to(inst.global_position)
