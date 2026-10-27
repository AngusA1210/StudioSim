extends CharacterBody3D
## First-person player: walks the room, aims at instruments, carries them, and sits down at one to play it.
## Sitting at an instrument switches its input on (until you get up), so the MIDI keyboard plays it; the computer
## keyboard plays it too. Both also play every other instrument whose input you have switched on yourself. At a kit
## you sit on its stool.
## You have a body (avatar.gd) as tall as the menu says: the audio core hears the room from the middle of its head,
## between its ears, and you see from its eyes, a little above and in front of them. The free camera (F) leaves it
## where it is and flies about the room, through anything; you hear from your body still, or from the camera.

const Avatar := preload("res://scripts/avatar.gd")
const COLOR := Color(0.4, 0.62, 0.9)  # your shirt and headphones
const MIN_HEIGHT := 1.4
const MAX_HEIGHT := 2.1
const STOOL := Vector3(0.0, Avatar.STOOL_TOP, 0.66)  # the top of a kit's stool, on its model (instrument_models.gd)
const AT_A_KIT := -0.42  # sitting down at a kit, you look down at it
const FLY_SPEED := 2.5
const FLY_FAST := 7.0
const RISE := KEY_E  # the free camera, up and down (as in an editor's fly mode)
const SINK := KEY_Q
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
var audio: StudioSimAudio
var instruments: Array = []
var camera: Camera3D  # your eyes
var head: Node3D  # the middle of your head, between your ears, turned as you look: where you hear from
var avatar  # your body
var height := 1.75
var yaw := 0.0
var pitch := 0.0
var seated_at = null  # the kit whose stool you sit on
var flying := false  # the free camera
var fly_camera: Camera3D
var fly_yaw := 0.0
var fly_pitch := 0.0
var target = null   # instrument you're aiming at
var carried = null  # instrument you're carrying
var playing = null  # instrument you're playing
var octave := 0
var typing := false  # the keyboard (K) is open: the letter keys play every instrument whose input is on
# A plug-in instrument whose window was opened from the room (P): the window stands above the on-screen keyboard, the
# letter keys play the instrument (and any whose input is on), and the mouse is free to work the window. A click in
# the room, Esc, Q or the window's own close button puts it away and hands the mouse back to looking about.
var plugin_open = null
var _plugin_shown := false  # its window did open (automated runs have no windows to open)
var keyboard_octave := 0
var held := {}      # physical key → [MIDI note sounding, the instruments it was sent to]
var remove_pending = null  # instrument that Backspace was pressed on once; a second press removes it
var _sat_input := false    # sitting down switched the input on, so getting up switches it off again
var clear_pending = null   # the amp whose loop J was pressed for once; a second press clears it
var _clear_deadline := 0

var _remove_deadline := 0
var _shape: CollisionShape3D
var _stood := {}  # where you stood before you sat down: {position, yaw, pitch}
var _last_position := Vector3.ZERO  # (how fast your body goes, for its stride)


func setup(the_app, room_instruments: Array) -> void:
	app = the_app
	audio = app.audio
	instruments = room_instruments

	_shape = CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.3
	_shape.shape = capsule
	add_child(_shape)

	head = Node3D.new()
	add_child(head)
	camera = Camera3D.new()
	camera.fov = app.settings.fov
	camera.near = 0.05
	camera.cull_mask = 0xFFFFF & ~(1 << (Avatar.LAYER - 1))  # (your own body isn't in your way)
	head.add_child(camera)
	camera.make_current()
	avatar = Avatar.new()
	add_child(avatar)
	fly_camera = Camera3D.new()
	fly_camera.top_level = true  # (it goes where it flies, whatever your body does)
	fly_camera.near = 0.05
	add_child(fly_camera)
	set_height(app.settings.height)
	avatar.set_name_tag(app.settings.player_name)
	place(Vector3(0.0, 0.0, 3.6), 0.0)


func place(at: Vector3, facing_yaw: float) -> void:
	if flying:
		stop_flying()
	if seated_at != null:  # (up, and where you are put)
		seated_at = null
		_shape.disabled = false
		_place_head()
	position = at
	_last_position = at
	yaw = facing_yaw
	pitch = 0.0
	_apply_look()


## How tall you are (metres): your eyes and ears, and your body, go with it.
func set_height(tall: float) -> void:
	height = clampf(tall, MIN_HEIGHT, MAX_HEIGHT)
	(_shape.shape as CapsuleShape3D).height = height
	_shape.position.y = height / 2.0
	avatar.build(height, COLOR)
	_place_head()


func _place_head() -> void:
	head.position = Avatar.ears_at(height, STOOL.y if seated_at != null else -1.0)
	camera.position = Avatar.eyes_from_ears(height)


## Where you hear from: the middle of your head.
func ear_position() -> Vector3:
	return head.global_position


## Where the room is heard from, and which way: your head, or the free camera if it is flying and set to be heard from.
func listener_transform() -> Transform3D:
	if flying and app.settings.free_camera_hears == "camera":
		return fly_camera.global_transform
	return head.global_transform


## The view you look through: your eyes, or the free camera.
func view_camera() -> Camera3D:
	return fly_camera if flying else camera


func look_through() -> void:
	view_camera().make_current()


## Where you stand (before you sat down, if you are at a kit), and which way you face.
func standing_spot() -> Dictionary:
	if seated_at != null and not _stood.is_empty():
		return {"position": _stood.position, "yaw": _stood.yaw}
	return {"position": global_position, "yaw": yaw}


## Everything in the room moved by `shift` (one of its walls moved): you too, and where you stood before you sat down.
func shift(by: Vector3) -> void:
	global_position += by
	_last_position += by
	if not _stood.is_empty():
		_stood.position += by


## The free camera: it starts at your eyes and flies about the room, through anything; your body stays where it is.
func start_flying() -> void:
	if flying:
		return
	put_down()
	if target != null:
		target.set_highlighted(false)
		target = null
	flying = true
	fly_yaw = yaw
	fly_pitch = pitch
	fly_camera.fov = camera.fov
	fly_camera.global_transform = Transform3D(Basis.from_euler(Vector3(fly_pitch, fly_yaw, 0.0)), camera.global_position)
	fly_camera.make_current()


## Back to your eyes; or, `put_here`, with you standing where the camera is, facing its way.
func stop_flying(put_here := false) -> void:
	if not flying:
		return
	flying = false
	if put_here:
		if playing != null:
			stop_playing()
		var under := Vector3(fly_camera.global_position.x, 0.0, fly_camera.global_position.z)
		place(app.room.settle(under, 0.3, 0.3, under), fly_yaw)
		pitch = clampf(fly_pitch, -1.45, 1.45)
		_apply_look()
	camera.make_current()


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
	if inst.drum_kit:
		_sit(inst)


func stop_playing() -> void:
	release_keys()
	var was = playing
	playing = null
	if was != null and _sat_input and was.input_on:
		app.set_input(was, false)
	_sat_input = false
	_stand_up()


## On a kit's stool, facing it, looking down at it: your eyes and ears where a seated drummer's are.
func _sit(kit) -> void:
	_stood = {"position": global_position, "yaw": yaw, "pitch": pitch}
	seated_at = kit
	_shape.disabled = true  # (the kit's own box would push you off its stool)
	velocity = Vector3.ZERO
	global_position = kit.to_room(Vector3(STOOL.x, 0.0, STOOL.z))
	_last_position = global_position
	yaw = kit.global_rotation.y
	pitch = AT_A_KIT
	_place_head()
	_apply_look()


## Up from the stool, back where you stood before.
func _stand_up() -> void:
	if seated_at == null:
		return
	seated_at = null
	_shape.disabled = false
	global_position = app.room.settle(_stood.position, 0.3, 0.3, _stood.position)
	_last_position = global_position
	yaw = _stood.yaw
	pitch = _stood.pitch
	_stood = {}
	_place_head()
	_apply_look()


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
## Opens a plug-in instrument's window from the room, above the on-screen keyboard, the letter keys playing it.
func open_plugin_window(inst) -> void:
	stop_playing()
	close_keyboard()
	plugin_open = inst
	keyboard_octave = inst.default_octave
	_plugin_shown = app.show_instrument_editor(inst, true)
	if _plugin_shown:
		app.place_instrument_editor(inst, app.hud.piano_top_fraction())
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


## Puts the window away (a click in the room, Esc, Q, or its own close button), and the mouse goes back to looking.
func close_plugin_window() -> void:
	if plugin_open == null:
		return
	release_keys()
	if app.instruments.has(plugin_open):
		app.show_instrument_editor(plugin_open, false)
	plugin_open = null
	_plugin_shown = false
	if not _ui_open():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func forget(inst) -> void:
	if plugin_open == inst:
		plugin_open = null
		_plugin_shown = false
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
	for panel in [app.title, app.menu, app.sequencer, app.amp_panel, app.speaker_panel, app.mic_panel, app.instrument_menu, app.name_prompt, app.rooms_page,
			app.you_page, app.together_page]:
		if panel != null and panel.is_open():
			return false
	if app.session != null and app.session.is_asking():  # "Save the changes?": the arrows are for its buttons
		return false
	if app.plugin_browser != null and app.plugin_browser.visible:
		return false
	return not (get_viewport().gui_get_focus_owner() is LineEdit)


func _ui_open() -> bool:
	if app.session != null and app.session.is_asking():
		return true
	for panel in [app.title, app.menu, app.sequencer, app.mixer, app.amp_panel, app.speaker_panel, app.mic_panel, app.instrument_menu, app.name_prompt, app.edit_window,
			app.rooms_page, app.you_page, app.together_page]:
		if panel != null and panel.is_open():
			return true
	return false


func _unhandled_input(event: InputEvent) -> void:
	if _ui_open():
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var sensitivity: float = MOUSE_SENSITIVITY * app.settings.mouse_sensitivity
		if flying:
			fly_yaw -= event.relative.x * sensitivity
			fly_pitch = clampf(fly_pitch - event.relative.y * sensitivity, -1.5, 1.5)
		else:
			yaw -= event.relative.x * sensitivity
			pitch = clampf(pitch - event.relative.y * sensitivity, -1.45, 1.45)
		_apply_look()
	elif event is InputEventMouseButton and event.pressed and plugin_open != null:  # a click outside its window
		close_plugin_window()
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
				app.net.played(id, "off", held[key][0])
			held.erase(key)
		return
	if key == KEY_ESCAPE:  # always backs out: a plug-in's window put away, the free camera back to you, up from an
		# instrument, the keyboard closed, or the menu
		if plugin_open != null:
			close_plugin_window()
		elif flying:
			stop_flying()
		elif playing != null:
			stop_playing()
		elif typing:
			close_keyboard()
		else:
			app.menu.open()
		return
	var notes := playing != null or typing or plugin_open != null  # the letter keys are a piano
	if notes and Bindings.NOTES.has(key) and app.bindings.action_for(key) != "edit":  # (the panel's key opens it, seated too)
		_note_on(key)
		return
	if flying and (key == RISE or key == SINK):  # (held, up and down: see _fly)
		return
	# The instrument these keys act on: the one you are playing, or else the one you are facing.
	var at = playing if playing != null else target
	var keys = app.bindings
	match keys.action_for(key):
		"mixer":
			app.mixer.open()
		"free_camera":  # with Shift, you are put where it is
			if flying:
				stop_flying(event.shift_pressed)
			else:
				start_flying()
		"edit":
			if at != null and at.playable and (playing != null or can_play_target()):
				app.sequencer.open(at)
			elif at != null and at.is_amp and _distance_to(at) < PLAY_REACH + 0.5:
				app.amp_panel.open(at)
			elif at != null and at.is_mic and _distance_to(at) < PLAY_REACH + 0.5:
				app.mic_panel.open(at)
			elif at != null and not at.playable and _distance_to(at) < PLAY_REACH + 0.5:
				app.speaker_panel.open(at)
		"plugin_window":  # a plug-in instrument's own window, with the keyboard under it
			if at != null and at.plays_plugin and not notes:
				open_plugin_window(at)
		"add":
			if app.net.check("move"):
				app.instrument_menu.open()
		"duplicate":  # a second of what you face or carry, with its settings, in your hands to be put down
			var original = carried if carried != null else at
			if original != null and not notes and app.net.check("move"):
				var copy = app.duplicate_instrument(original, original.global_position)
				if copy != null:
					carry(copy)
		"remove":
			_ask_to_remove(carried if carried != null else at)
		"loop":  # an instrument's loop; a Speaker or an amp has none, so it mutes in the room (a microphone, its track)
			if at != null and at.playable:
				at.set_loop(not at.loop_on)
			elif at != null and at.is_mic:
				app.set_muted(at, not at.muted)
			elif at != null:
				app.set_room_muted(at, not at.room_muted)
		"monitor":  # hear the room, or the mix
			app.toggle_monitor()
		"transport":
			app.toggle_transport()
		"to_start":  # as Return is in Pro Tools
			if app.timeline.is_record():
				app.timeline.locate(0.0)
		"follow":
			if app.timeline.is_record():
				app.toggle_follow()
		"edit_window":
			if app.timeline.is_record():
				app.edit_window.open()
		"click":
			app.set_click(not app.settings.click)
		"binaural":
			app.set_binaural(not app.settings.binaural)
		"input":
			if at != null:
				app.set_input(at, not at.input_on)
		"stop":
			if plugin_open != null:
				close_plugin_window()
			elif playing != null:
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
			elif keys.action_for(key) == "loop_switch" and not notes and app.timeline.is_record():  # else a Record room's loop playback
				app.timeline.set_loop(not app.timeline.loop_on)
		_:
			if not notes and key >= KEY_1 and key <= KEY_8 and target != null and target.is_amp:  # stamping on its pedals
				app.stomp(target, key - KEY_1)


## A note on the computer keyboard: to the instrument you're at and every other instrument whose input is on, or with
## the keyboard open, to every instrument whose input is on.
## The on-screen keyboard clicked (and let go): as the key it shows, while the letter keys are notes.
func piano_down(key: int) -> void:
	if (playing != null or typing or plugin_open != null) and Bindings.NOTES.has(key) and not held.has(key):
		_note_on(key)


func piano_up(key: int) -> void:
	if held.has(key):
		for id in held[key][1]:
			audio.note_off(id, held[key][0])
			app.net.played(id, "off", held[key][0])
		held.erase(key)


func _note_on(key: int) -> void:
	var base: int = octave if playing != null else keyboard_octave
	var note := 60 + 12 * base + int(Bindings.NOTES[key])
	var ids := [playing.source_id] if playing != null else ([plugin_open.source_id] if plugin_open != null else [])
	for inst in app.armed_instruments():
		if inst != playing and inst != plugin_open:
			ids.append(inst.source_id)
	for id in ids:
		audio.note_on(id, note, 0.8)
		app.net.played(id, "on", note, 0.8)
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
	if flying:
		_fly(delta, forward, strafe, turn)
		_pose_avatar(delta)
		return
	if turn != 0.0:
		yaw += turn * TURN_SPEED * delta
		_apply_look()
	if seated_at != null:  # on its stool, wherever the kit is put
		if instruments.has(seated_at):
			global_position = seated_at.to_room(Vector3(STOOL.x, 0.0, STOOL.z))
		_pose_avatar(delta)
		return

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
	_pose_avatar(delta)


## The free camera, flying the way it looks (and up or down), never out of the room.
func _fly(delta: float, forward: float, strafe: float, turn: float) -> void:
	fly_yaw += turn * TURN_SPEED * delta
	var rise := 0.0
	if _can_move() and not Input.is_key_pressed(KEY_META) and not Input.is_key_pressed(KEY_CTRL):
		var notes := playing != null or typing or plugin_open != null
		rise = float(Input.is_physical_key_pressed(RISE) and not (notes and Bindings.NOTES.has(RISE))) - float(Input.is_physical_key_pressed(SINK))
	var look := Basis.from_euler(Vector3(fly_pitch, fly_yaw, 0.0))
	var wish := look * Vector3(strafe, 0.0, -forward) + Vector3(0.0, rise, 0.0)
	if wish.length() > 1.0:
		wish = wish.normalized()
	var at := fly_camera.global_position + wish * (FLY_FAST if app.bindings.is_down("run") else FLY_SPEED) * delta
	var half: Vector3 = app.room.size / 2.0
	at = Vector3(clampf(at.x, -half.x + 0.1, half.x - 0.1), clampf(at.y, 0.1, app.room.size.y - 0.1), clampf(at.z, -half.z + 0.1, half.z - 0.1))
	fly_camera.global_transform = Transform3D(look, at)


## Your body, as you are: walking, carrying, playing, or on a kit's stool with your feet on its pedals and your sticks
## over its hi-hat and snare.
func _pose_avatar(delta: float) -> void:
	var moved := (global_position - _last_position) / maxf(delta, 0.0001)
	_last_position = global_position
	var going := global_transform.basis.inverse() * Vector3(moved.x, 0.0, moved.z)
	var holding := "carry" if carried != null else ("play" if playing != null or plugin_open != null else "")
	var kit = seated_at if seated_at != null and instruments.has(seated_at) else null
	avatar.pose(Avatar.state_for(global_transform, height, pitch, going.limit_length(RUN_SPEED), kit, holding), delta)


func _process(_delta: float) -> void:
	if app.title == null or not app.title.is_open():  # on the title screen its own camera does the listening
		audio.set_listener(listener_transform())
	if plugin_open != null and _plugin_shown and not plugin_open.instrument_plugin.get("editor_open", true):
		close_plugin_window()  # closed with its own button, or put away by the mix window
	if remove_pending != null and (Time.get_ticks_msec() >= _remove_deadline
			or (remove_pending != carried and remove_pending != target and remove_pending != playing)):
		remove_pending = null  # too slow, or looking at something else now
	if clear_pending != null and (Time.get_ticks_msec() >= _clear_deadline or clear_pending != target):
		clear_pending = null
	var aimed = null if carried != null or flying else _pick_target()
	if aimed != target:
		if target != null:
			target.set_highlighted(false)
		if aimed != null:
			aimed.set_highlighted(true)
		target = aimed


## 1 if a movement key is held, 0 if not, or if it is a note key and the letter keys are notes just now.
func _held(action: String) -> float:
	if Input.is_key_pressed(KEY_META) or Input.is_key_pressed(KEY_CTRL):  # Cmd-S saves rather than walks
		return 0.0
	var keycode: int = app.bindings.key(action)
	if (playing != null or typing or plugin_open != null) and Bindings.NOTES.has(keycode):
		return 0.0
	return float(Input.is_physical_key_pressed(keycode))


## Removing takes two presses, so a slip of the finger doesn't cost an instrument and its pattern.
func _ask_to_remove(inst) -> void:
	if inst == null or not app.net.check("move"):
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
			app.net.played(id, "off", held[key][0])
	held.clear()


func _apply_look() -> void:
	rotation = Vector3(0.0, yaw, 0.0)
	if head:
		head.rotation = Vector3(pitch, 0.0, 0.0)
	if flying:
		fly_camera.global_transform = Transform3D(Basis.from_euler(Vector3(fly_pitch, fly_yaw, 0.0)), fly_camera.global_position)


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
		var put = carried
		carried = null
		if put.is_mic and app.nearest_instrument(put) != null:  # a microphone put down points at what it is nearest
			app.aim_mic(put, app.nearest_instrument(put))
		app.keep_mics_clear()  # (no mic inside an instrument, nor an instrument put down over one)
	elif target != null and app.net.carried_by_another(target) != "":
		app.session.notice.emit("%s is carrying %s" % [app.net.carried_by_another(target), target.display_name])
	elif target != null and target.locked:
		app.session.notice.emit("%s is locked in place (%s unlocks it)" % [target.display_name, app.bindings.label("lock")])
	elif target != null and not app.net.check("move"):
		pass
	elif target != null:
		app.note_move(target)  # (Cmd-Z puts it back where it was picked up from)
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
	if carried.is_mic:  # (and never inside an instrument)
		app.keep_mic_clear(carried)


func _distance_to(inst) -> float:
	return ear_position().distance_to(inst.global_position)
