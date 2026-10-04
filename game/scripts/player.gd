extends CharacterBody3D
## First-person player: walks the room, aims at instruments, carries and mutes them, and plays the Keys.
## The camera is also the listener, so the audio core hears the room from here.

const EYE_HEIGHT := 1.65
const WALK_SPEED := 2.8
const RUN_SPEED := 5.5
const TURN_SPEED := 1.9  # arrow keys, radians per second
const MOUSE_SENSITIVITY := 0.0022
const REACH := 4.2
const PLAY_REACH := 2.8
const AIM_COS := 0.955  # within about 17° of where you're facing
const CARRY_DISTANCE := 1.5

# Computer keyboard as a piano, the usual DAW layout. Values are semitones above the base C.
const KEYMAP := {
	KEY_A: 0, KEY_W: 1, KEY_S: 2, KEY_E: 3, KEY_D: 4, KEY_F: 5, KEY_T: 6, KEY_G: 7, KEY_Y: 8,
	KEY_H: 9, KEY_U: 10, KEY_J: 11, KEY_K: 12, KEY_O: 13, KEY_L: 14, KEY_P: 15, KEY_SEMICOLON: 16,
}

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
var binaural := true
var reverb := true
var live_input := false
var live_input_error := ""

var _room_half := Vector2.ZERO
var _partition_min := Vector3.ZERO
var _partition_max := Vector3.ZERO


func setup(audio_core: SoundRoomAudio, room_instruments: Array, room_size: Vector3, partition_center: Vector3,
		partition_size: Vector3) -> void:
	audio = audio_core
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
	camera.fov = 75.0
	camera.near = 0.05
	add_child(camera)
	camera.make_current()
	place(Vector3(0.0, 0.0, 3.6), 0.0)


func place(at: Vector3, facing_yaw: float) -> void:
	position = at
	yaw = facing_yaw
	pitch = 0.0
	_apply_look()


## The microphone / audio interface stays closed until asked for. Its sound comes out of the Amp.
func toggle_live_input() -> void:
	if audio.set_live_input(not live_input):
		live_input = not live_input
		live_input_error = ""
	else:
		live_input = false
		live_input_error = audio.get_error()


func ear_position() -> Vector3:
	return camera.global_position


func can_play_target() -> bool:
	return target != null and target.playable and _distance_to(target) < PLAY_REACH


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		yaw -= event.relative.x * MOUSE_SENSITIVITY
		pitch = clampf(pitch - event.relative.y * MOUSE_SENSITIVITY, -1.45, 1.45)
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
	if key == KEY_ESCAPE:
		if playing != null:
			_stop_playing()
		else:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return
	if key == KEY_B:
		binaural = not binaural
		audio.set_binaural(binaural)
		return
	if key == KEY_R:
		reverb = not reverb
		audio.set_reverb(reverb)
		return
	if key == KEY_I:
		toggle_live_input()
		return
	if playing != null:
		if key == KEY_Q:
			_stop_playing()
		elif key == KEY_Z or key == KEY_X:
			octave = clampi(octave + (1 if key == KEY_X else -1), -2, 2)
		elif KEYMAP.has(key):
			var note := 60 + 12 * octave + int(KEYMAP[key])
			audio.note_on(playing.source_id, note, 0.8)
			held[key] = note
		return
	match key:
		KEY_E:
			if can_play_target():
				playing = target
		KEY_G:
			_grab_or_drop()
		KEY_F:
			if target != null:
				target.set_muted(not target.muted)


func _physics_process(delta: float) -> void:
	var forward := 0.0
	var strafe := 0.0
	var turn := 0.0
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
		_stop_playing()
	_update_carry()


func _process(_delta: float) -> void:
	audio.set_listener(camera.global_transform)
	var aimed = null if carried != null else _pick_target()
	if aimed != target:
		if target != null:
			target.set_highlighted(false)
		if aimed != null:
			aimed.set_highlighted(true)
		target = aimed


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


func _stop_playing() -> void:
	if playing != null:
		audio.all_notes_off(playing.source_id)
	held.clear()
	playing = null


func _distance_to(inst) -> float:
	return ear_position().distance_to(inst.global_position)
