extends SceneTree
# The demo videos, recorded from the real app rather than from the screen: each one a scene (tools/video/scenes/
# <name>.gd) set up and played through the app's own functions, as the website's screenshots are, drawn off-screen at
# 1920x1080 a frame at a time, with its sound rendered by the audio core in step with each frame (main.gd's --offline:
# no sound card, and no clock but the frames'). However long a frame takes to draw, picture and sound stay together.
#
# Into video/_out/<name>/ (video/ is not kept in git): frames/, a JPEG for each frame, and sound.wav. tools/video/
# record.sh runs this and then makes the MP4 of them (tools/video/encode.swift):
#   tools/video/record.sh <name>
#
# A guitar or a keyboard is played from files rather than by hand, as they would be played live (in video/sources/):
# a DI recording as an amp's or a Speaker's input (live_input), a MIDI file's notes on an instrument as a controller
# plays them (play_midi), each note at its own sample.

const UI := preload("res://scripts/ui.gd")
const SIZE := Vector2i(1920, 1080)
const SCALE := 1.25  # the interface at 125 %, as in the screenshots
const RATE := 48000  # the audio core's rate, offline
const INPUTS := 2    # the inputs a live input has offline (the audio core's kOfflineInputs)

var here := ""     # tools/video/
var sources := ""  # video/sources/: the DI and MIDI files played
var out := ""      # video/_out/<scene>/
var fps := 30
var per_frame := RATE / 30  # samples
var main
var view: SubViewport
var cam: Camera3D

var recording := false
var frame := 0                       # frames saved
var at := 0                          # samples rendered
var sound := PackedFloat32Array()    # what was heard while recording (interleaved stereo)
var events: Array = []               # [[sample, Callable]] in order: notes, each at its own sample
var input := PackedFloat32Array()    # a live input's audio (mono), from sample input_start (-1: none)
var input_start := -1

var hear_from_camera := true  # while the video's camera is the one looked through, the room heard from it too
var _look := Vector3.ZERO  # what the camera looks at
var _caption: PanelContainer
var _caption_text: Label
var _caption_tween: Tween


func _initialize() -> void:
	here = ProjectSettings.globalize_path("res://").path_join("../tools/video").simplify_path()
	sources = here.path_join("../../video/sources").simplify_path() + "/"
	var scene_name := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--scene="):
			scene_name = arg.trim_prefix("--scene=")
		elif arg.begins_with("--fps="):
			fps = int(arg.trim_prefix("--fps="))
	per_frame = RATE / fps
	var script_path := here.path_join("scenes/%s.gd" % scene_name)
	if scene_name == "" or not FileAccess.file_exists(script_path):
		_fail("no scene \"%s\": give --scene=<name>, one of tools/video/scenes/" % scene_name)
		return
	out = here.path_join("../../video/_out/" + scene_name).simplify_path() + "/"
	DirAccess.make_dir_recursive_absolute(out + "frames")
	for old in DirAccess.get_files_at(out + "frames"):
		DirAccess.remove_absolute(out + "frames/" + old)

	view = SubViewport.new()
	view.size = SIZE
	view.size_2d_override = Vector2i(Vector2(SIZE) / SCALE)
	view.size_2d_override_stretch = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	view.msaa_3d = Viewport.MSAA_4X
	root.add_child(view)
	main = load("res://main.tscn").instantiate()
	view.add_child(main)
	view.notification(Node.NOTIFICATION_VP_MOUSE_ENTER)
	_build_caption()
	process_frame.connect(_tick)
	_run(load(script_path).new())


func _run(scene) -> void:
	await frames(30)
	if not main.audio.get_device_config().get("offline", false):
		_fail("run with --offline (tools/video/record.sh does)")
		return
	cam = Camera3D.new()
	cam.near = 0.05
	main.add_child(cam)
	await scene.run(self)
	if recording:
		stop()
	quit(0)


func _fail(why: String) -> void:
	printerr("RECORD FAILED: ", why)
	quit(1)


# ── Each frame: the picture drawn last saved, and the sound heard over it rendered ───────────────────────────

func _tick() -> void:
	if main == null or main.audio == null:
		return
	if recording:
		view.get_texture().get_image().save_jpg(out + "frames/%05d.jpg" % frame, 0.92)
		frame += 1
	if hear_from_camera and cam != null and cam.current:  # (after the player's own, which it then stands in for)
		main.audio.set_listener(cam.global_transform)
	_render(per_frame)


## Renders `n` samples, stopping at each event's sample to send it (so that a note sounds where it was played, to
## within the audio core's block of 128).
func _render(n: int) -> void:
	var end := at + n
	while not events.is_empty() and events[0][0] < end:
		var event: Array = events.pop_front()
		if event[0] > at:
			_chunk(event[0] - at)
		event[1].call()
	if end > at:
		_chunk(end - at)


func _chunk(n: int) -> void:
	var feed := PackedFloat32Array()
	if main.live_input:  # (always handed in while the input is open, silent or not, as an interface's would be)
		feed.resize(n * INPUTS)
		if input_start >= 0:
			for i in n:
				var k := at + i - input_start
				if k >= 0 and k < input.size():
					feed[i * INPUTS] = input[k]
	var got: PackedFloat32Array = main.audio.render_offline(n, feed, INPUTS if main.live_input else 0)
	if recording:
		sound.append_array(got)
	at += n


# ── For the scenes ─────────────────────────────────────────────────────────────────────────────────────────

func frames(n: int) -> void:
	for i in n:
		await process_frame


func seconds(t: float) -> void:
	await frames(maxi(1, roundi(t * fps)))


## Starts the recording: from the next frame, each one saved, and the sound.
func start() -> void:
	recording = true
	frame = 0
	sound = PackedFloat32Array()
	print("RECORDING")


## Stops it, and writes its sound.
func stop() -> void:
	recording = false
	_write_wav(out + "sound.wav", sound)
	print("RECORDED %d frames at %d fps (%.1f s) into %s" % [frame, fps, frame / float(fps), out])


## The room from the video's own camera, the screen's readouts put away.
func camera(from: Vector3, look: Vector3, fov := 60.0) -> void:
	cam.fov = fov
	cam.look_at_from_position(from, look, Vector3.UP)
	cam.make_current()
	_look = look
	main.hud.visible = false


## The camera moved, eased, from where it is to `from`, looking at `look`, over `duration` seconds.
func glide(from: Vector3, look: Vector3, duration: float, fov := -1.0) -> void:
	var from_0 := cam.global_position
	var look_0 := _look
	var fov_0 := cam.fov
	var fov_1 := fov_0 if fov < 0.0 else fov
	var n := maxi(1, roundi(duration * fps))
	for i in n:
		var t := smoothstep(0.0, 1.0, float(i + 1) / n)
		cam.fov = lerpf(fov_0, fov_1, t)
		cam.look_at_from_position(from_0.lerp(from, t), look_0.lerp(look, t), Vector3.UP)
		await process_frame
	_look = look


## The camera round `centre` at `distance` and `height`, from `from_degrees` to `to_degrees`, over `duration`.
func orbit(centre: Vector3, distance: float, height: float, from_degrees: float, to_degrees: float, duration: float, fov := 60.0) -> void:
	cam.fov = fov
	cam.make_current()
	main.hud.visible = false
	var n := maxi(1, roundi(duration * fps))
	for i in n + 1:
		var a := deg_to_rad(lerpf(from_degrees, to_degrees, smoothstep(0.0, 1.0, float(i) / n)))
		cam.look_at_from_position(centre + Vector3(sin(a) * distance, height, cos(a) * distance), centre, Vector3.UP)
		if i < n:
			await process_frame
	_look = centre


## Back to the player's own view, with the screen's readouts.
func player_view() -> void:
	main.hud.visible = true
	main.player.look_through()


## A caption along the bottom ("" puts it away), faded in.
func caption(text: String) -> void:
	if _caption_tween != null:
		_caption_tween.kill()
	_caption_tween = create_tween()
	if text == "":
		_caption_tween.tween_property(_caption, "modulate:a", 0.0, 0.3)
		return
	_caption_text.text = text
	_caption.modulate.a = 0.0
	_caption_tween.tween_property(_caption, "modulate:a", 1.0, 0.3)


## A MIDI file's notes and sustain pedal (video/sources/<name>) on an instrument, from `after` seconds from now, each
## at its own sample, as a controller plays them. Returns the file's tempo (BPM) and how long it lasts (seconds).
func play_midi(inst, name: String, after := 0.0) -> Dictionary:
	var song: Dictionary = load(here.path_join("midi_file.gd")).read(sources + name)
	if song.is_empty():
		_fail("could not read the MIDI file " + sources + name)
		return song
	var id: int = inst.source_id
	var audio = main.audio
	var from := at + roundi(after * RATE)
	for e in song.events:
		var sample: int = from + roundi(e[0] * RATE)
		match e[1]:
			"on":
				events.append([sample, func() -> void: audio.note_on(id, e[2], e[3])])
			"off":
				events.append([sample, func() -> void: audio.note_off(id, e[2])])
			"sustain":
				events.append([sample, func() -> void: audio.set_sustain(id, e[2] == 1)])
	events.sort_custom(func(a, b): return a[0] < b[0])
	return song


## A DI recording (video/sources/<name>, a WAV) as an amp's or a Speaker's input, on the interface's input 1, from
## `after` seconds from now, as if played into it there and then. Returns how long it lasts (seconds).
func live_input(inst, name: String, after := 0.0) -> float:
	input = _read_wav(sources + name)
	if input.is_empty():
		_fail("could not read the DI recording " + sources + name)
		return 0.0
	main.set_input_channel(inst, 0)
	main.set_input(inst, true)
	input_start = at + roundi(after * RATE)
	return input.size() / float(RATE)


# ── WAV files ──────────────────────────────────────────────────────────────────────────────────────────────

## Interleaved stereo, written as 32-bit floats.
func _write_wav(path: String, data: PackedFloat32Array) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	var bytes := data.size() * 4
	f.store_buffer("RIFF".to_ascii_buffer())
	f.store_32(4 + 26 + 12 + 8 + bytes)
	f.store_buffer("WAVE".to_ascii_buffer())
	f.store_buffer("fmt ".to_ascii_buffer())
	f.store_32(18)
	f.store_16(3)  # IEEE float
	f.store_16(2)
	f.store_32(RATE)
	f.store_32(RATE * 8)
	f.store_16(8)
	f.store_16(32)
	f.store_16(0)
	f.store_buffer("fact".to_ascii_buffer())
	f.store_32(4)
	f.store_32(data.size() / 2)
	f.store_buffer("data".to_ascii_buffer())
	f.store_32(bytes)
	f.store_buffer(data.to_byte_array())
	f.close()


## A WAV's first channel as floats, at 48 kHz (16-, 24- or 32-bit, or 32-bit float; another rate converted, simply).
func _read_wav(path: String) -> PackedFloat32Array:
	var none := PackedFloat32Array()
	var b := FileAccess.get_file_as_bytes(path)
	if b.size() < 12 or b.slice(0, 4).get_string_from_ascii() != "RIFF" or b.slice(8, 12).get_string_from_ascii() != "WAVE":
		return none
	var format := 0
	var channels := 0
	var rate := 0
	var bits := 0
	var data_at := -1
	var data_size := 0
	var pos := 12
	while pos + 8 <= b.size():
		var id := b.slice(pos, pos + 4).get_string_from_ascii()
		var size := b.decode_u32(pos + 4)
		if id == "fmt ":
			format = b.decode_u16(pos + 8)
			channels = b.decode_u16(pos + 10)
			rate = b.decode_u32(pos + 12)
			bits = b.decode_u16(pos + 22)
			if format == 0xFFFE and size >= 40:  # (extensible: its real format further on)
				format = b.decode_u16(pos + 32)
		elif id == "data":
			data_at = pos + 8
			data_size = mini(size, b.size() - data_at)
			break
		pos += 8 + size + (size & 1)
	if data_at < 0 or channels < 1 or not (format == 1 and bits in [16, 24, 32] or format == 3 and bits == 32):
		return none
	var step: int = channels * bits / 8
	var n: int = data_size / step
	var mono := PackedFloat32Array()
	mono.resize(n)
	for i in n:
		var p := data_at + i * step
		if format == 3:
			mono[i] = b.decode_float(p)
		elif bits == 16:
			mono[i] = b.decode_s16(p) / 32768.0
		elif bits == 24:
			var v := b[p] | (b[p + 1] << 8) | (b[p + 2] << 16)
			mono[i] = (v - 16777216 if v >= 8388608 else v) / 8388608.0
		else:
			mono[i] = b.decode_s32(p) / 2147483648.0
	if rate == RATE:
		return mono
	print("(the DI recording is at %d Hz: converted to %d)" % [rate, RATE])
	var ratio := float(rate) / RATE
	var converted := PackedFloat32Array()
	converted.resize(int(n / ratio))
	for i in converted.size():
		var x := i * ratio
		var k := int(x)
		converted[i] = lerpf(mono[k], mono[mini(k + 1, n - 1)], x - k)
	return converted


func _build_caption() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 120
	view.add_child(layer)
	var holder := MarginContainer.new()
	holder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	holder.add_theme_constant_override("margin_bottom", 54)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(holder)
	_caption = PanelContainer.new()
	_caption.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_caption.size_flags_vertical = Control.SIZE_SHRINK_END
	_caption.add_theme_stylebox_override("panel", UI.box(Color(UI.WINDOW, 0.92), UI.LINE_STRONG, UI.PANEL_RADIUS, 26.0, 14.0))
	_caption.modulate.a = 0.0
	holder.add_child(_caption)
	_caption_text = Label.new()
	_caption_text.add_theme_font_size_override("font_size", 24)
	_caption_text.add_theme_color_override("font_color", UI.INK)
	_caption_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_caption.add_child(_caption_text)
