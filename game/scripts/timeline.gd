extends Node
## A room's mode, and a Record room's timeline, as a DAW has one.
##
## A Jam room is what SoundRoom always was: every instrument's pattern looping round, the music starting from the top
## with Space. A Record room has a timeline: its transport plays from the playhead (and stopping goes back there, as
## Pro Tools does), loop playback goes round a range of bars (the first four, to begin with), and its tracks can be
## armed and recorded (Cmd-Space starts recording from the playhead, Cmd-Space or Space stops it). An armed Speaker or
## amp records its hardware input as it comes in, before its pedals, amp and inserts, to a WAV file in the room's
## Audio Files folder; an armed instrument records the notes played on it. The patterns still loop, from bar 1.
##
## What is recorded becomes a clip on its track: an audio clip refers to part of its file (as Pro Tools' clips refer to
## their parent file), a MIDI clip holds its notes. A new take covers what was on its track where it was recorded.
## Each instrument keeps its clips in `clips`: audio {kind "audio", file (in the room's folder), name, start, offset,
## length (seconds)}, MIDI {kind "midi", name, start, length (steps), notes [{step, length, note, velocity}]}.
## Positions in steps are sixteenths from the start of bar 1; audio is placed in seconds, so it stays where it was
## played if the tempo changes, while MIDI follows the tempo.

signal changed  # the clips or the transport changed: whatever draws them draws again

const STEPS_PER_BAR := 16
const AUDIO_FOLDER := "Audio Files"
const GRIDS := [["Off", 0], ["Bar", 16], ["Beat", 4], ["1/8", 2], ["1/16", 1]]

var app
var audio: SoundRoomAudio
var mode := "jam"         # "jam" or "record"
var playhead := 0.0       # steps: where playing and recording start from
var loop_on := true
var loop_start := 0       # steps
var loop_end := 64
var playing := false
var recording := false
var grid := 4             # steps a clip snaps to (0: free)
var _started_at := 0.0    # where playing began: stopping goes back there
var _taking := false      # recording has stopped; what it took is on its way
var _peaks := {}          # a file's peaks, for drawing its clips


func setup(the_app) -> void:
	app = the_app
	audio = app.audio


func is_record() -> bool:
	return mode == "record"


## Where the music is, in steps: where it is playing, or the playhead.
func position() -> float:
	return audio.get_timeline_position() if playing else playhead


func step_seconds() -> float:
	return 60.0 / app.tempo / 4.0


# ── The room's mode ──────────────────────────────────────────────────────────────────────────────────────────

## A room just made or opened: its mode and timeline as `data` has them (a room's file, a template), each track's clips
## sent to the audio core, and the music going as it should: a Jam room's patterns from the top, a Record room from its
## playhead if it was playing (a new one is).
func load_from(data: Dictionary, new_mode := "") -> void:
	if recording:
		stop()
	mode = new_mode if new_mode != "" else str(data.get("mode", "jam"))
	var t: Dictionary = data.get("timeline", {})
	playhead = float(t.get("playhead", 0.0))
	loop_on = bool(t.get("loop_on", true))
	loop_start = int(t.get("loop_start", 0))
	loop_end = int(t.get("loop_end", 64))
	_started_at = playhead
	restart(bool(t.get("playing", true)))


## The music going again as the mode has it.
func restart(play := true) -> void:
	for inst in app.instruments:
		inst.armed = false
		audio.set_record_arm(inst.source_id, false)
		sync(inst)
	if is_record():
		audio.set_loop_range(loop_on, loop_start, loop_end)
		audio.set_sequencer_running(false)
		playing = false
		app.sequence_running = false
		if play:
			start_playing()
	else:
		audio.set_loop_range(false, 0, 0)
		playing = false
		app.sequence_running = true
		audio.set_sequencer_running(false)
		audio.set_sequencer_running(true)
	changed.emit()


func set_mode(new_mode: String) -> void:
	mode = new_mode
	restart(true)


## What a room's file keeps of the timeline.
func to_data() -> Dictionary:
	return {"playhead": playhead, "loop_on": loop_on, "loop_start": loop_start, "loop_end": loop_end, "playing": playing and not recording}


# ── The transport ────────────────────────────────────────────────────────────────────────────────────────────

## Space: play from the playhead, or stop (and go back to where playing began).
func toggle_play() -> void:
	if playing:
		stop()
	else:
		start_playing()


func start_playing() -> void:
	_started_at = playhead
	audio.play_from(playhead)
	playing = true
	app.sequence_running = true
	changed.emit()


func stop() -> void:
	if recording:
		_stop_recording()
	audio.set_sequencer_running(false)
	playing = false
	app.sequence_running = false
	playhead = _started_at
	changed.emit()


## Puts the playhead at a step (playing on from there, if it is playing).
func locate(step: float) -> void:
	playhead = maxf(step, 0.0)
	if playing and not recording:
		_started_at = playhead
		audio.play_from(playhead)
	changed.emit()


func set_loop(on: bool, start := -1, end := -1) -> void:
	loop_on = on
	if start >= 0 and end > start:
		loop_start = start
		loop_end = end
	audio.set_loop_range(loop_on, loop_start, loop_end)
	changed.emit()


## A step snapped to the grid (the nearest line), or as it is with the grid off.
func snap(step: float, to := -1) -> float:
	var size := grid if to < 0 else to
	return step if size <= 0 else roundf(step / size) * size


# ── Recording ────────────────────────────────────────────────────────────────────────────────────────────────

## Arming a track. An armed one's input goes on, so that it can be heard (and played) while it records.
func set_armed(inst, on: bool) -> void:
	inst.armed = on
	audio.set_record_arm(inst.source_id, on)
	if on and not inst.input_on:
		app.set_input(inst, true)
	changed.emit()


## Cmd-Space: recording from the playhead (or from where it is playing), or, while recording, stopping. Returns why it
## couldn't start, or "".
func toggle_record() -> String:
	if recording:
		stop()
		return ""
	return start_recording()


func start_recording() -> String:
	if not is_record():
		return "recording is for Record rooms (the Room button in the menu can switch this room over)"
	if not app.session.has_room():
		return "the room has to be saved first: recordings go in its folder"
	var armed: Array = app.instruments.filter(func(inst): return inst.armed)
	if armed.is_empty():
		return "no track is armed (R on its row in the Edit window)"
	var folder: String = app.session.room_folder().path_join(AUDIO_FOLDER)
	DirAccess.make_dir_recursive_absolute(folder)
	var files := []
	for inst in armed:
		if not inst.playable:
			files.append([inst.source_id, folder.path_join(_take_name(folder, inst.display_name))])
	var from := playhead if not playing else audio.get_timeline_position()
	if not audio.start_recording(files, from):
		return audio.get_error()
	if not playing:
		_started_at = playhead
	playing = true
	recording = true
	app.sequence_running = true
	changed.emit()
	return ""


func _stop_recording() -> void:
	audio.stop_recording()
	recording = false
	_taking = true


## "Speaker_01.wav", "Speaker_02.wav"...: the first not in the folder yet.
func _take_name(folder: String, track: String) -> String:
	var base: String = app.library._safe(track).replace(" ", "_")
	var number := 1
	while FileAccess.file_exists(folder.path_join("%s_%02d.wav" % [base, number])):
		number += 1
	return "%s_%02d.wav" % [base, number]


func _process(_delta: float) -> void:
	if _taking:
		var took: Dictionary = audio.take_recording()
		if not took.is_empty():
			_taking = false
			_add_takes(took)


## What a recording took becomes clips: each covering what was on its track where it was recorded.
func _add_takes(took: Dictionary) -> void:
	var by_id := {}
	for inst in app.instruments:
		by_id[inst.source_id] = inst
	var seconds_per_step: float = took.step_seconds
	var start_step: float = took.start_step
	var end_step: float = took.end_step
	# What was played in time with what was heard reached the engine late, by the time the sound took to come out and,
	# for audio, the time the input took to come in: each take goes back by as much, so it lands where it was played.
	var stats: Dictionary = audio.get_stats()
	var heard_late := float(stats.get("output_latency_ms", 0.0)) / 1000.0
	var audio_late := heard_late + float(stats.get("input_latency_ms", 0.0)) / 1000.0
	for take in took.audio:
		var inst = by_id.get(int(take.source))
		if inst == null or float(take.seconds) <= 0.0:
			continue
		var start := maxf(start_step * seconds_per_step - audio_late, 0.0)
		var file: String = str(take.path).get_file()
		_cover(inst, "audio", start, start + float(take.seconds))
		inst.clips.append({"kind": "audio", "file": AUDIO_FOLDER.path_join(file), "name": file.get_basename(), "start": start, "offset": 0.0,
			"length": float(take.seconds)})
	var notes_of := {}
	for n in took.notes:
		notes_of.get_or_add(int(n.source), []).append(n)
	for source in notes_of:
		var inst = by_id.get(source)
		if inst == null:
			continue
		var notes := []
		for n in notes_of[source]:
			var played := float(n.step) - heard_late / seconds_per_step if seconds_per_step > 0.0 else float(n.step)
			notes.append({"step": maxf(played - start_step, 0.0), "length": float(n.length), "note": int(n.note), "velocity": float(n.velocity)})
		_cover(inst, "midi", start_step, end_step)
		inst.clips.append({"kind": "midi", "name": "%s %d" % [inst.display_name, inst.clips.size() + 1], "start": start_step,
			"length": maxf(end_step - start_step, 1.0), "notes": notes})
	for inst in app.instruments:
		sync(inst)
	app.session.notice.emit("Recorded")
	changed.emit()


## Cuts away what a track's clips of a kind have from `from` to `to` (seconds for audio, steps for MIDI), as a new take
## or a clip dropped there covers them: a clip inside goes, one across an end is trimmed, one across both is split.
func _cover(inst, kind: String, from: float, to: float) -> void:
	var kept := []
	for clip in inst.clips:
		if clip.kind != kind or clip.start >= to or clip.start + clip.length <= from:
			kept.append(clip)
			continue
		if clip.start < from:  # what comes before
			var before: Dictionary = clip.duplicate(true)
			before.length = from - clip.start
			kept.append(_trimmed(before))
		if clip.start + clip.length > to:  # and after
			var after: Dictionary = clip.duplicate(true)
			var cut: float = to - clip.start
			after.start = to
			after.length = clip.length - cut
			if kind == "audio":
				after.offset = float(clip.offset) + cut
			else:
				after.notes = clip.notes.map(func(n): return {"step": float(n.step) - cut, "length": n.length, "note": n.note, "velocity": n.velocity})
			kept.append(_trimmed(after))
	inst.clips = kept


## A MIDI clip without the notes that now fall outside it.
func _trimmed(clip: Dictionary) -> Dictionary:
	if clip.kind == "midi":
		clip.notes = clip.notes.filter(func(n): return float(n.step) >= 0.0 and float(n.step) < float(clip.length))
	return clip


# ── Clips ────────────────────────────────────────────────────────────────────────────────────────────────────

## Sends a track's clips to the audio core (in a Jam room, none: its timeline isn't played).
func sync(inst) -> void:
	var notes := []
	var clips := []
	if is_record():
		for clip in inst.clips:
			if clip.kind == "midi":
				for n in clip.notes:
					if float(n.step) < float(clip.length):
						notes.append({"step": float(clip.start) + float(n.step), "length": minf(float(n.length), float(clip.length) - float(n.step)),
							"note": int(n.note), "velocity": float(n.velocity)})
			elif clip.kind == "audio":
				clips.append({"path": file_path(clip), "start": float(clip.start), "offset": float(clip.offset), "length": float(clip.length)})
	audio.set_track(inst.source_id, notes, clips)


func file_path(clip: Dictionary) -> String:
	return app.session.room_folder().path_join(str(clip.get("file", ""))) if app.session.has_room() else str(clip.get("file", ""))


## Where a clip starts and ends, in steps.
func clip_steps(clip: Dictionary) -> Vector2:
	if clip.kind == "audio":
		return Vector2(float(clip.start) / step_seconds(), (float(clip.start) + float(clip.length)) / step_seconds())
	return Vector2(float(clip.start), float(clip.start) + float(clip.length))


## Whether a clip can go on a track: audio on a Speaker or an amp, MIDI on an instrument.
static func fits(clip: Dictionary, inst) -> bool:
	return (clip.kind == "audio") == (not inst.playable)


## Moves a clip (or with `copy`, a second of it) to start at `step` on track `to`, covering what it lands on.
func place_clip(from_inst, index: int, to_inst, step: float, copy := false) -> void:
	if index < 0 or index >= from_inst.clips.size():
		return
	var clip: Dictionary = from_inst.clips[index].duplicate(true)
	if not fits(clip, to_inst):
		return
	if not copy:
		from_inst.clips.remove_at(index)
	clip.start = maxf(step, 0.0) * (step_seconds() if clip.kind == "audio" else 1.0)
	_cover(to_inst, clip.kind, clip.start, clip.start + clip.length)
	to_inst.clips.append(clip)
	sync(from_inst)
	if to_inst != from_inst:
		sync(to_inst)
	changed.emit()


func remove_clip(inst, index: int) -> void:
	if index >= 0 and index < inst.clips.size():
		inst.clips.remove_at(index)
		sync(inst)
		changed.emit()


## A clip's file's loudest moments, a hundred to the second, for drawing it (read once).
func peaks(clip: Dictionary) -> PackedFloat32Array:
	var path := file_path(clip)
	if not _peaks.has(path):
		_peaks[path] = audio.get_audio_peaks(path, 100.0)
	return _peaks[path]
