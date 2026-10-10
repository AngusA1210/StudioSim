extends CharacterBody3D
## First-person player: walks the room, aims at instruments, carries them, and sits down at one to play it.
## While you are at an instrument the computer keyboard and any MIDI controller play that instrument.
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
# have to work while playing (Q, Z, X, Tab, M, N, C, Space, Backspace, B, R, I) are deliberately not among these keys.
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
var held := {}      # physical key → MIDI note currently sounding
var remove_pending = null  # instrument that Backspace was pressed on once; a second press removes it

var _remove_deadline := 0

var _room_half := Vector2.ZERO
var _partition_min := Vector3.ZERO
var _partition_max := Vector3.ZERO


func setup(the_app, room_instruments: Array, room_size: Vector3, partition_center: Vector3, partition_size: Vector3) -> void:
	app = the_app
	audio = app.audio
	instruments = room_instruments
	_room_half = Vector2(room_size.x / 2, room_size.z / 2)
	_partition_min = partition_center - partition_size / 2
	_partition_max = partition_center + partition_size / 2

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
	audio.set_midi_target(inst.source_id)


func stop_playing() -> void:
	if playing != null:
		audio.all_notes_off(playing.source_id)
	audio.set_midi_target(-1)
	held.clear()
	playing = null


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


## One of the menus or the pattern editor is up: the keyboard and mouse belong to it.
func _ui_open() -> bool:
	for panel in [app.menu, app.sequencer, app.instrument_menu]:
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
			audio.note_off(playing.source_id, held[key])
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
			if at != null and not at.playable:
				app.menu.open(app.menu.IO_TAB)  # a live input: where its hardware input is chosen
			elif playing != null or can_play_target():
				app.sequencer.open(at)
			return
		KEY_N:
			app.instrument_menu.open()
			return
		KEY_BACKSPACE, KEY_DELETE:
			_ask_to_remove(carried if carried != null else at)
			return
		KEY_M:
			if at != null:
				at.toggle_quiet()
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
			app.set_live_input(not app.live_input)
			return
	if playing != null:
		if key == KEY_Q:
			stop_playing()
		elif key == KEY_Z or key == KEY_X:
			octave = clampi(octave + (1 if key == KEY_X else -1), -3, 3)
		elif KEYMAP.has(key):
			var note := 60 + 12 * octave + int(KEYMAP[key])
			audio.note_on(playing.source_id, note, 0.8)
			held[key] = note
		return
	match key:
		KEY_E:
			if can_play_target():
				start_playing(target)
		KEY_G:
			_grab_or_drop()


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

	if playing != null and _distance_to(playing) > PLAY_REACH + 0.6:
		stop_playing()
	_update_carry()


func _process(_delta: float) -> void:
	audio.set_listener(camera.global_transform)
	if remove_pending != null and (Time.get_ticks_msec() >= _remove_deadline
			or (remove_pending != carried and remove_pending != target and remove_pending != playing)):
		remove_pending = null  # too slow, or looking at something else now
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
	if playing != null:
		for key in held:
			audio.note_off(playing.source_id, held[key])
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
	var p := global_position + ahead * CARRY_DISTANCE
	p.x = clampf(p.x, -_room_half.x + 0.6, _room_half.x - 0.6)
	p.z = clampf(p.z, -_room_half.y + 0.6, _room_half.y - 0.6)
	var margin := 0.5
	if p.x > _partition_min.x - margin and p.x < _partition_max.x + margin and p.z > _partition_min.z - margin \
			and p.z < _partition_max.z + margin:
		p.x = _partition_min.x - margin if global_position.x < (_partition_min.x + _partition_max.x) / 2 else _partition_max.x + margin
	p.y = clampf(EYE_HEIGHT - 0.35 + sin(pitch) * 1.4, carried.size.y / 2 + 0.25, 2.8)
	carried.global_position = p


func _distance_to(inst) -> float:
	return ear_position().distance_to(inst.global_position)
