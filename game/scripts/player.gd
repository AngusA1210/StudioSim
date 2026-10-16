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

# Computer keyboard as a piano, the usual DAW layout. Values are semitones above the base C. The shortcuts that
# have to work while playing (Q, Z, X, Tab, Enter, M, N, C, Space, Backspace, B, R, I) are deliberately not among these keys.
const KEYMAP := {
	KEY_A: 0, KEY_W: 1, KEY_S: 2, KEY_E: 3, KEY_D: 4, KEY_F: 5, KEY_T: 6, KEY_G: 7, KEY_Y: 8,
	KEY_H: 9, KEY_U: 10, KEY_J: 11, KEY_K: 12, KEY_O: 13, KEY_L: 14, KEY_P: 15, KEY_SEMICOLON: 16,
}

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
func _ui_open() -> bool:
	for panel in [app.title, app.menu, app.sequencer, app.mixer, app.amp_panel, app.instrument_menu]:
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
	# The instrument these keys act on: the one you are playing, or else the one you are facing.
	var at = playing if playing != null else target
	match key:
		KEY_ESCAPE:
			if playing != null:
				stop_playing()
			else:
				app.menu.open()
			return
		KEY_TAB:
			app.mixer.open()
			return
		KEY_ENTER, KEY_KP_ENTER:
			if at != null and at.playable and (playing != null or can_play_target()):
				app.sequencer.open(at)
			elif at != null and at.is_amp and _distance_to(at) < PLAY_REACH + 0.5:
				app.amp_panel.open(at)
			return
		KEY_N:
			app.instrument_menu.open()
			return
		KEY_BACKSPACE, KEY_DELETE:
			_ask_to_remove(carried if carried != null else at)
			return
		KEY_M:  # an instrument's loop; a Speaker has none, so it mutes
			if at != null and at.playable:
				at.set_loop(not at.loop_on)
			elif at != null:
				app.set_muted(at, not at.muted)
			return
		KEY_SPACE:
			app.set_sequence_running(not app.sequence_running)
			return
		KEY_C:
			app.set_click(not app.settings.click)
			return
		KEY_B:
			app.set_binaural(not app.settings.binaural)
			return
		KEY_R:
			app.set_reverb(not app.settings.reverb)
			return
		KEY_I:
			if at != null:
				app.set_input(at, not at.input_on)
			return
	if playing != null:
		if key == KEY_Q:
			stop_playing()
		elif key == KEY_Z or key == KEY_X:
			octave = clampi(octave + (1 if key == KEY_X else -1), -3, 3)
		elif KEYMAP.has(key):
			var note := 60 + 12 * octave + int(KEYMAP[key])
			var ids := [playing.source_id]  # the instrument you're at, and any others whose input is on
			for inst in app.armed_instruments():
				if inst != playing:
					ids.append(inst.source_id)
			for id in ids:
				audio.note_on(id, note, 0.8)
			held[key] = [note, ids]
		return
	match key:
		KEY_E:
			if can_play_target():
				start_playing(target)
		KEY_G:
			_grab_or_drop()
		KEY_L, KEY_K, KEY_U, KEY_J:  # an amp's loop pedal, if it has one
			if target != null and target.is_amp and target.looper.get("state", "none") != "none":
				_loop_pedal(target, key)
		KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8:  # stamping on an amp's pedals
			if target != null and target.is_amp:
				app.stomp(target, key - KEY_1)


## The loop pedal's buttons as keys: L the footswitch, K stop or play, U undo or redo, J clear (twice).
func _loop_pedal(amp, key: int) -> void:
	var loop: Dictionary = amp.looper
	match key:
		KEY_L:
			app.looper_action(amp, "press")
		KEY_K:
			app.looper_action(amp, "play" if loop.get("state", "") == "stopped" else "stop")
		KEY_U:
			app.looper_action(amp, "undo" if loop.get("can_undo", false) else "redo")
		KEY_J:
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
	if not _ui_open():
		if playing == null:  # while playing, these keys are notes
			forward += float(Input.is_physical_key_pressed(KEY_W)) - float(Input.is_physical_key_pressed(KEY_S))
			strafe += float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A))
		forward += float(Input.is_physical_key_pressed(KEY_UP)) - float(Input.is_physical_key_pressed(KEY_DOWN))
		turn += float(Input.is_physical_key_pressed(KEY_LEFT)) - float(Input.is_physical_key_pressed(KEY_RIGHT))
	if turn != 0.0:
		yaw += turn * TURN_SPEED * delta
		_apply_look()

	var basis_flat := Basis(Vector3.UP, yaw)
	var wish := basis_flat * Vector3(strafe, 0.0, -forward)
	var speed := RUN_SPEED if Input.is_physical_key_pressed(KEY_SHIFT) else WALK_SPEED
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
