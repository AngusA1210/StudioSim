extends Node
## A room's mode, and a Record room's timeline, as a DAW has one.
##
## A Jam room is what SoundRoom always was: every instrument's pattern looping round, the music starting from the top
## with Space. A Record room has a timeline: its transport plays from the playhead (and stopping goes back there, as
## Pro Tools does, or with insertion following playback stays where the music stopped), loop playback goes round a range of bars (the first four, to begin with), and its tracks can be
## armed and recorded (Cmd-Space starts recording from the playhead, Cmd-Space or Space stops it). An armed Speaker or
## amp records its hardware input as it comes in, before its pedals, amp and inserts, to a WAV file in the room's
## Audio Files folder; an armed instrument records the notes played on it. The patterns still loop, from bar 1.
##
## What is recorded becomes a clip on its track: an audio clip refers to part of its file (as Pro Tools' clips refer to
## their parent file), a MIDI clip holds its notes. A new take covers what was on its track where it was recorded.
## Each instrument keeps its clips in `clips`: audio {kind "audio", file (in the room's folder), name, start, offset,
## length, fade_in, fade_out, xfade (seconds: a crossfade into the clip that starts where it ends), gain_db (its clip gain)},
## MIDI {kind "midi", name, start, length (steps), notes [{step, length, note,
## velocity}]}. Positions in steps are sixteenths from the start of bar 1; audio is placed in seconds, so it stays where
## it was played if the tempo changes, while MIDI follows the tempo. Clips can be trimmed (an audio clip only ever shows
## less or more of its file; a MIDI clip keeps the notes trimmed off, and they come back if it is drawn out again),
## split, nudged, faded and given a gain, several at once, and every edit can be undone (Cmd-Z) and redone (Cmd-X). A
## loop recording (Loop Record, Option-L) makes a take of each pass: the last one shown, the rest kept in the clip's
## `takes` ({take: its number, and the rest of a clip}) to choose from.

signal changed  # the clips or the transport changed: whatever draws them draws again

const STEPS_PER_BAR := 16
const AUDIO_FOLDER := "Audio Files"
const GRIDS := [["Off", 0], ["Bar", 16], ["Beat", 4], ["1/8", 2], ["1/16", 1]]
const UNDO_LEVELS := 32
const NUDGE_SECONDS := 0.01  # how far a clip is nudged with the grid off
const MIN_CLIP_GAIN_DB := -48.0  # and below: silent
const MAX_CLIP_GAIN_DB := 24.0

var app
var audio: SoundRoomAudio
var mode := "jam"         # "jam" or "record"
var playhead := 0.0       # steps: where playing and recording start from
var loop_on := true
var loop_start := 0.0     # steps (between them too: a clip's length, say)
var loop_end := 64.0
var playing := false
var recording := false
var grid := 4             # steps a clip snaps to (0: free)
var _started_at := 0.0    # where playing began: stopping goes back there
var _taking := false      # recording has stopped; what it took is on its way
var _looping := false     # the recording going is a loop recording
var punch_in := 0.0       # where the recording going records from (steps)
var punch_out := -1.0     # and to (-1: until it is stopped)
var _stop_at := -1.0      # where it stops of itself: the punch out and the post-roll after it
var _peaks := {}          # a file's peaks, for drawing its clips
var _undo := []           # before each edit, what it was and every track's clips: [what, {inst: clips}], the latest last
var _redo := []


func setup(the_app) -> void:
	app = the_app
	audio = app.audio


func is_record() -> bool:
	return mode == "record"


## Where the music is, in steps: where it is playing, or the playhead (as it is while a count-in counts).
func position() -> float:
	if not playing or (recording and counting_in() > 0):
		return playhead if not playing else _started_at
	return audio.get_timeline_position()


## How many beats of a count-in are still to come before recording starts (0: none).
func counting_in() -> int:
	return audio.get_count_in() if recording else 0


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
	loop_start = float(t.get("loop_start", 0.0))
	loop_end = float(t.get("loop_end", 64.0))
	_started_at = playhead
	_undo.clear()
	_redo.clear()
	restart(bool(t.get("playing", true)))


## The music going again as the mode has it.
func restart(play := true) -> void:
	for inst in app.instruments:
		inst.armed = false
		audio.set_record_arm(inst.source_id, false)
		sync(inst)
	for folder in app.folders + app.auxes + [app.master_track]:
		sync(folder)
	app.follow_live_inputs()
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


## From the playhead, or with a pre-roll, that much before it (stopping still goes back to the playhead).
func start_playing() -> void:
	_started_at = playhead
	audio.play_from(maxf(playhead - app.settings.preroll_bars * STEPS_PER_BAR, 0.0))
	playing = true
	app.sequence_running = true
	changed.emit()


## Stops, and the playhead goes back to where playing began; or, with insertion following playback (N), stays where
## the music stopped.
func stop() -> void:
	var stopped_at: float = position()
	if recording:
		_stop_recording()
	audio.set_sequencer_running(false)
	playing = false
	app.sequence_running = false
	playhead = maxf(stopped_at, 0.0) if app.settings.insertion_follows else _started_at
	changed.emit()


## Puts the playhead at a step (playing on from there, if it is playing).
func locate(step: float) -> void:
	playhead = maxf(step, 0.0)
	if playing and not recording:
		_started_at = playhead
		audio.play_from(playhead)
	changed.emit()


func set_loop(on: bool, start := -1.0, end := -1.0) -> void:
	loop_on = on
	if start >= 0.0 and end > start:
		loop_start = start
		loop_end = end
	audio.set_loop_range(loop_on, loop_start, loop_end)
	changed.emit()


## A step snapped to the grid (the nearest line), or as it is with the grid off.
func snap(step: float, to := -1) -> float:
	var size := grid if to < 0 else to
	return step if size <= 0 else roundf(step / size) * size


# ── Recording ────────────────────────────────────────────────────────────────────────────────────────────────

## Arming a track (record-ready), as Pro Tools has it: its input button stays as it was. An armed Speaker or amp is
## heard through its input while stopped or recording and plays back what it recorded while playing (Auto Input); with
## its input monitored (I), always its input. An armed instrument takes the notes played, as with its input on.
func set_armed(inst, on: bool) -> void:
	if inst.armed == on:
		return
	inst.armed = on
	audio.set_record_arm(inst.source_id, on)
	if not inst.playable:
		app.follow_live_inputs()  # the audio input open while anything wants it
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
	# Loop Record (from a stop): round the loop from its start, a take each time round. Or punching in and out (from a
	# stop) over the range on the ruler, as over a selection in Pro Tools, the post-roll played after it.
	_looping = app.settings.loop_record and not playing and loop_end - loop_start >= 1.0
	var to := -1.0
	if _looping:
		if not loop_on:
			set_loop(true)
		from = loop_start
		playhead = loop_start
	elif app.settings.punch and not playing and loop_end > loop_start:
		from = loop_start
		to = loop_end
		playhead = loop_start
	var count_in: float = app.settings.count_in_bars * STEPS_PER_BAR if not playing else 0.0  # (not while playing: it records straight away)
	var preroll: float = app.settings.preroll_bars * STEPS_PER_BAR if not playing else 0.0
	if not audio.start_recording(files, from, count_in, _looping, preroll, to):
		return audio.get_error()
	punch_in = from
	punch_out = to
	_stop_at = to + app.settings.postroll_bars * STEPS_PER_BAR if to >= 0.0 else -1.0
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


## What a recording is doing: "count-in", "pre-roll", "recording", "post-roll", or "" when it isn't.
func phase() -> String:
	if not recording:
		return ""
	if counting_in() > 0:
		return "count-in"
	var at: float = audio.get_timeline_position()
	if at < punch_in - 0.01:
		return "pre-roll"
	if punch_out >= 0.0 and at >= punch_out:
		return "post-roll"
	return "recording"


func _process(_delta: float) -> void:
	if recording and _stop_at >= 0.0 and phase() == "post-roll" and audio.get_timeline_position() >= _stop_at:
		stop()  # the punch out, and the post-roll after it: done
	if _taking:
		var took: Dictionary = audio.take_recording()
		if not took.is_empty():
			_taking = false
			_add_takes(took)


## What a recording took becomes clips: each covering what was on its track where it was recorded. A loop recording's
## passes become takes, stacked in one clip over the loop: the last whole pass shown, the others to choose from.
func _add_takes(took: Dictionary) -> void:
	var looped := _looping
	_looping = false
	if took.notes.is_empty() and took.get("sustain", []).is_empty() and took.audio.all(func(take): return float(take.seconds) <= 0.0):
		app.session.notice.emit("Nothing was recorded")  # (stopped during the count-in, say)
		return
	remember("Loop record" if looped else "Record")
	var by_id := {}
	for inst in app.instruments:
		by_id[inst.source_id] = inst
	var sps: float = took.step_seconds  # seconds a step
	var start_step: float = took.start_step  # (a little before where it was asked to start: it starts a moment after)
	var end_step: float = took.end_step
	# What was played in time with what was heard reached the engine late, by the time the sound took to come out and,
	# for audio, the time the input took to come in: each take goes back by as much, so it lands where it was played.
	var stats: Dictionary = audio.get_stats()
	var heard_late := float(stats.get("output_latency_ms", 0.0)) / 1000.0
	var audio_late := heard_late + float(stats.get("input_latency_ms", 0.0)) / 1000.0
	var passes := _passes(end_step) if looped else []
	for take in took.audio:
		var inst = by_id.get(int(take.source))
		if inst == null or float(take.seconds) <= 0.0:
			continue
		var file: String = str(take.path).get_file()
		var clip := {"kind": "audio", "file": AUDIO_FOLDER.path_join(file), "name": file.get_basename(), "fade_in": 0.0, "fade_out": 0.0}
		if looped:  # each pass: the loop's span of the file, from where it was played
			var stack := []
			for k in passes.size():
				var pass_span: Vector2 = passes[k]
				var each: Dictionary = clip.duplicate()
				each.name = "%s take %d" % [file.get_basename(), k + 1]
				each.take = k + 1
				each.start = loop_start * sps
				each.offset = (pass_span.x - start_step) * sps + audio_late
				each.length = minf((pass_span.y - pass_span.x) * sps, float(take.seconds) - float(each.offset))
				if each.length > 0.05:
					stack.append(each)
			_stack(inst, "audio", stack, loop_start * sps, loop_end * sps, end_step)
		else:
			var at := start_step * sps - audio_late  # where the file's first moment was played (before bar 1, even)
			clip.start = maxf(at, 0.0)
			clip.offset = clip.start - at
			clip.length = float(take.seconds) - float(clip.offset)
			_cover(inst, "audio", clip.start, clip.start + clip.length)
			inst.clips.append(clip)
	var notes_of := {}
	for n in took.notes:
		notes_of.get_or_add(int(n.source), []).append(n)
	for source in notes_of:
		var inst = by_id.get(source)
		if inst == null:
			continue
		var base := "%s %d" % [inst.display_name, inst.clips.size() + 1]
		if looped:  # each note to the pass it was played in, placed in the loop
			var stack := []
			for k in passes.size():
				stack.append({"kind": "midi", "name": "%s take %d" % [base, k + 1], "take": k + 1, "start": loop_start,
					"length": passes[k].y - passes[k].x, "notes": []})
			for n in notes_of[source]:
				var played := float(n.step) - heard_late / sps
				var k := clampi(int(floor((played - loop_start) / (loop_end - loop_start))), 0, stack.size() - 1)
				stack[k].notes.append({"step": maxf(played - passes[k].x, 0.0), "length": float(n.length), "note": int(n.note), "velocity": float(n.velocity)})
			_stack(inst, "midi", stack, loop_start, loop_end, end_step)
		else:
			var clip_start := maxf(start_step, 0.0)
			var notes := []
			for n in notes_of[source]:
				var played := float(n.step) - heard_late / sps
				notes.append({"step": maxf(played - clip_start, 0.0), "length": float(n.length), "note": int(n.note), "velocity": float(n.velocity)})
			_cover(inst, "midi", clip_start, end_step)
			inst.clips.append({"kind": "midi", "name": base, "start": clip_start, "length": maxf(end_step - clip_start, 1.0), "notes": notes})
	# The sustain pedal, as it was played: into each instrument's automation lane over what was recorded (a loop
	# recording's, as in the pass shown), in place of what was there.
	var pedal_of := {}
	for p in took.get("sustain", []):
		pedal_of.get_or_add(int(p.source), []).append(p)
	var shown := passes.size() - 1
	for k in range(passes.size() - 1, -1, -1):
		if passes[k].y - passes[k].x >= loop_end - loop_start - 0.01:
			shown = k
			break
	for source in pedal_of:
		var inst = by_id.get(source)
		if inst == null or not inst.playable:
			continue
		var events := []
		for p in pedal_of[source]:
			var at := float(p.step) - heard_late / sps
			if looped:
				if shown < 0 or at < passes[shown].x or at >= passes[shown].y:
					continue
				at = loop_start + at - passes[shown].x
			events.append([maxf(at, 0.0), 1.0 if p.on else 0.0])
		_take_pedal(inst, events, loop_start if looped else maxf(start_step, 0.0), loop_end if looped else end_step)
	for inst in app.instruments:
		sync(inst)
	app.session.notice.emit("Recorded %d takes" % passes.size() if looped and passes.size() > 1 else "Recorded")
	changed.emit()


## The pedal as played from `from` to `to`, in an instrument's sustain lane in place of what was there: up where it
## starts (down, if the first it did was come up), up again at the end, and then as the lane had it.
func _take_pedal(inst, events: Array, from: float, to: float) -> void:
	var old: Array = inst.automation.get("sustain", [])
	var lane := old.filter(func(p): return float(p[0]) < from)
	lane.append([from, 1.0 if not events.is_empty() and float(events[0][1]) == 0.0 else 0.0])
	for e in events:
		if float(e[1]) != float(lane.back()[1]):
			lane.append(e)
	if float(lane.back()[1]) > 0.5:
		lane.append([to, 0.0])
	var after: float = app.automation.value_at(old, "sustain", to)
	if after != float(lane.back()[1]):
		lane.append([to + 0.01, after])
	lane.append_array(old.filter(func(p): return float(p[0]) > to + 0.01))
	inst.automation.sustain = lane


## A loop recording's passes, each [start, end) in steps counted on from the loop's start (the first pass starting
## there): every pass it went right round, and the last if it got a beat or more in.
func _passes(end_step: float) -> Array:
	var length := loop_end - loop_start
	var out := []
	var at := loop_start
	while at < end_step - 0.01:
		var to := minf(at + length, end_step)
		if to - at >= 4.0 or to - at >= length - 0.01:
			out.append(Vector2(at, to))
		at += length
	return out


## A loop recording's takes on a track: over the loop, covering what was there, the last whole one shown and the rest in
## its `takes`.
func _stack(inst, kind: String, stack: Array, from: float, to: float, end_step: float) -> void:
	if stack.is_empty():
		return
	var shown := stack.size() - 1
	for k in range(stack.size() - 1, -1, -1):  # the last whole pass
		if stack[k].length >= (loop_end - loop_start) * (step_seconds() if kind == "audio" else 1.0) - 0.01:
			shown = k
			break
	var clip: Dictionary = stack[shown]
	clip.takes = []
	for k in stack.size():
		if k != shown:
			clip.takes.append(stack[k])
	_cover(inst, kind, from, to)
	inst.clips.append(clip)


## Shows take `which` of a clip's takes (its index in `takes`) in the clip's place, the one shown going in with the rest.
func choose_take(inst, index: int, which: int) -> void:
	var clip: Dictionary = inst.clips[index]
	var takes: Array = clip.get("takes", [])
	if which < 0 or which >= takes.size():
		return
	remember("Choose take")
	var chosen: Dictionary = takes[which].duplicate(true)
	var others: Array = takes.duplicate(true)
	others.remove_at(which)
	var was: Dictionary = clip.duplicate(true)
	was.erase("takes")
	others.append(was)
	others.sort_custom(func(a, b): return int(a.get("take", 0)) < int(b.get("take", 0)))
	chosen.takes = others
	inst.clips.remove_at(index)
	_cover(inst, chosen.kind, float(chosen.start), float(chosen.start) + float(chosen.length))
	inst.clips.append(chosen)
	sync(inst)
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
			before.erase("fade_out")
			before.erase("xfade")
			kept.append(_trimmed(before))
		if clip.start + clip.length > to:  # and after
			var after: Dictionary = clip.duplicate(true)
			var cut: float = to - clip.start
			after.start = to
			after.length = clip.length - cut
			after.erase("fade_in")
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
	if inst.get("is_master"):  # the master: its fader's automation
		var trimmed: Array = inst.automation.get("volume", []) if is_record() else []
		audio.set_master_automation(trimmed.map(func(p): return [float(p[0]), float(p[1])]))
		return
	if inst.is_folder:  # a folder or an aux: its automation only
		audio.set_track(inst.source_id, [], [], automation_data(inst))
		return
	var notes := []
	if is_record():
		for clip in inst.clips:
			if clip.kind == "midi":
				for n in clip.notes:
					if float(n.step) >= 0.0 and float(n.step) < float(clip.length):  # (the rest are trimmed off)
						notes.append({"step": float(clip.start) + float(n.step), "length": minf(float(n.length), float(clip.length) - float(n.step)),
							"note": int(n.note), "velocity": float(n.velocity)})
	audio.set_track(inst.source_id, notes, engine_clips(inst) if is_record() else [], automation_data(inst))


## A track's automation as the audio core plays it (none in a Jam room): its volume in the audio core's own terms, the
## fader's 0 dB being the level the instrument was made at.
func automation_data(track) -> Dictionary:
	if not is_record():
		return {}
	var trim: float = 0.0 if track.is_folder else linear_to_db(track.normal_gain())
	var lanes: Dictionary = track.automation
	var out := {"volume": lanes.get("volume", []).map(func(p): return [float(p[0]), float(p[1]) + trim if float(p[1]) > -79.0 else -80.0]),
		"mute": lanes.get("mute", []).duplicate()}
	if not track.is_folder and track.playable:
		out.sustain = lanes.get("sustain", []).duplicate()
	out.params = app.automation.param_lanes(track)  # its knobs', plug-ins' and sends'
	return out


## A track's audio clips as the audio core plays them. Where two meet and the first has a crossfade, each reaches into the
## other's time with the audio its file has beyond the cut (Pro Tools' handles), the first fading out as the second
## fades in.
func engine_clips(inst) -> Array:
	var out := []
	var reach := {}  # clip index → [before its start, after its end] (seconds) it plays for crossfades
	for c in inst.clips.size():
		var span := crossfade_span(inst, c)
		if span.x + span.y > 0.0:
			reach.get_or_add(c, [0.0, 0.0])[1] = span.y
			reach.get_or_add(_meets(inst, c), [0.0, 0.0])[0] = span.x
	for c in inst.clips.size():
		var clip: Dictionary = inst.clips[c]
		if clip.kind != "audio":
			continue
		var extra: Array = reach.get(c, [0.0, 0.0])
		var into: float = crossfade_span(inst, c).x + crossfade_span(inst, c).y  # its crossfade out
		var from_c: int = _met_by(inst, c)
		var out_of: float = 0.0 if from_c < 0 else crossfade_span(inst, from_c).x + crossfade_span(inst, from_c).y  # and in
		out.append({"path": file_path(clip), "start": float(clip.start) - extra[0], "offset": float(clip.offset) - extra[0],
			"length": float(clip.length) + extra[0] + extra[1], "fade_in": out_of if out_of > 0.0 else float(clip.get("fade_in", 0.0)),
			"fade_out": into if into > 0.0 else float(clip.get("fade_out", 0.0)), "gain": gain_of(clip)})
	return out


## The audio clip on the track that starts where clip `c` ends (-1: none).
func _meets(inst, c: int) -> int:
	var clip: Dictionary = inst.clips[c]
	if clip.kind != "audio":
		return -1
	var end: float = float(clip.start) + float(clip.length)
	for other in inst.clips.size():
		if other != c and inst.clips[other].kind == "audio" and absf(float(inst.clips[other].start) - end) < 1e-4:
			return other
	return -1


## The audio clip that ends where clip `c` starts (-1: none).
func _met_by(inst, c: int) -> int:
	for other in inst.clips.size():
		if other != c and _meets(inst, other) == c:
			return other
	return -1


## The crossfade from clip `c` into the one that starts where it ends: how far it reaches before the cut and after it
## (seconds). Centred on the cut where both files have the audio for it; leaning to one side where only one does.
func crossfade_span(inst, c: int) -> Vector2:
	var clip: Dictionary = inst.clips[c]
	var want: float = float(clip.get("xfade", 0.0))
	var next := _meets(inst, c) if want > 0.0 else -1
	if next < 0:
		return Vector2.ZERO
	var after_clip: Dictionary = inst.clips[next]
	var handle_after: float = maxf(file_seconds(clip) - float(clip.offset) - float(clip.length), 0.0)  # the first's file, past its end
	var handle_before: float = maxf(float(after_clip.offset), 0.0)  # the second's, before its start
	var most := minf(want, minf(float(clip.length), float(after_clip.length)))
	var post := minf(most / 2.0, handle_after)
	var pre := minf(most - post, handle_before)
	post = minf(most - pre, handle_after)
	return Vector2(pre, post) if pre + post > 0.001 else Vector2.ZERO


## Sets the crossfade where clip `c` meets the next (seconds; 0 takes it away). Their own fades there give way to it.
func set_crossfade(inst, c: int, seconds: float, send := true) -> void:
	var next := _meets(inst, c)
	if next < 0:
		return
	inst.clips[c].xfade = maxf(seconds, 0.0)
	inst.clips[c].fade_out = 0.0
	inst.clips[next].fade_in = 0.0
	if send:
		sync(inst)
		changed.emit()


func file_path(clip: Dictionary) -> String:
	return app.session.room_folder().path_join(str(clip.get("file", ""))) if app.session.has_room() else str(clip.get("file", ""))


## Where a clip starts and ends, in steps.
func clip_steps(clip: Dictionary) -> Vector2:
	if clip.kind == "audio":
		return Vector2(float(clip.start) / step_seconds(), (float(clip.start) + float(clip.length)) / step_seconds())
	return Vector2(float(clip.start), float(clip.start) + float(clip.length))


## Whether a clip can go on a track: audio on a Speaker or an amp, MIDI on an instrument.
static func fits(clip: Dictionary, inst) -> bool:
	return not inst.is_folder and (clip.kind == "audio") == (not inst.playable)


## Moves a clip (or with `copy`, a second of it) to start at `step` on track `to`, covering what it lands on.
func place_clip(from_inst, index: int, to_inst, step: float, copy := false) -> void:
	if index < 0 or index >= from_inst.clips.size():
		return
	var clip: Dictionary = from_inst.clips[index].duplicate(true)
	if not fits(clip, to_inst):
		return
	remember("Copy clip" if copy else "Move clip")
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
		remember("Delete clip")
		inst.clips.remove_at(index)
		sync(inst)
		changed.emit()


## Moves one end of a clip to `step`, as Pro Tools' trim tool does: its start ("start") or its end ("end"), the rest
## staying where it is. An audio clip can't reach past either end of its file. Its fades get no longer than it is.
func trim_clip(inst, index: int, edge: String, step: float, send := true) -> void:
	var clip: Dictionary = inst.clips[index]
	var per := step_seconds() if clip.kind == "audio" else 1.0  # the clip's own units in a step
	var at := maxf(step, 0.0) * per
	var shortest := 0.25 * per
	var end: float = clip.start + clip.length
	if edge == "start":
		var new_start := minf(at, end - shortest)
		if clip.kind == "audio":
			new_start = maxf(new_start, float(clip.start) - float(clip.offset))  # not before its file begins
			clip.offset = float(clip.offset) + new_start - float(clip.start)
		else:
			var moved: float = new_start - float(clip.start)
			for n in clip.notes:
				n.step = float(n.step) - moved
		clip.start = new_start
		clip.length = end - new_start
	else:
		var new_end := maxf(at, float(clip.start) + shortest)
		if clip.kind == "audio":
			new_end = minf(new_end, float(clip.start) + file_seconds(clip) - float(clip.offset))  # nor after it ends
		clip.length = new_end - float(clip.start)
	_fit_fades(clip)
	if send:
		sync(inst)
		changed.emit()


## Sets how long a clip's fade in ("fade_in") or out ("fade_out") lasts, in seconds; the two can't overlap.
func set_fade(inst, index: int, which: String, seconds: float, send := true) -> void:
	var clip: Dictionary = inst.clips[index]
	if clip.kind != "audio":
		return
	var other := "fade_out" if which == "fade_in" else "fade_in"
	clip[which] = clampf(seconds, 0.0, float(clip.length) - float(clip.get(other, 0.0)))
	if send:
		sync(inst)
		changed.emit()


func _fit_fades(clip: Dictionary) -> void:
	if clip.kind == "audio":
		clip.fade_in = minf(float(clip.get("fade_in", 0.0)), float(clip.length))
		clip.fade_out = minf(float(clip.get("fade_out", 0.0)), float(clip.length) - float(clip.fade_in))


## Cuts a clip in two at `step`, as Pro Tools' Separate (Cmd-E) does: both halves stay where they were, the first keeping
## its fade in and the second its fade out, and the second named after the first. Returns the second's index, or -1 if
## `step` isn't inside the clip.
func separate(inst, index: int, step: float) -> int:
	if index < 0 or index >= inst.clips.size():
		return -1
	var clip: Dictionary = inst.clips[index]
	var span := clip_steps(clip)
	if step <= span.x + 0.01 or step >= span.y - 0.01:
		return -1
	remember("Separate clip")
	var cut: float = step * (step_seconds() if clip.kind == "audio" else 1.0) - float(clip.start)
	var first: Dictionary = clip.duplicate(true)
	var second: Dictionary = clip.duplicate(true)
	first.length = cut
	second.start = float(clip.start) + cut
	second.length = float(clip.length) - cut
	second.name = _part_name(inst, str(clip.get("name", "")))
	if clip.kind == "audio":
		first.fade_out = 0.0
		first.erase("xfade")  # (a crossfade out of the clip goes with its end, to the second half)
		second.fade_in = 0.0
		second.offset = float(clip.offset) + cut
		_fit_fades(first)
	else:
		first.notes = clip.notes.filter(func(n): return float(n.step) < cut)
		second.notes = clip.notes.filter(func(n): return float(n.step) >= cut).map(func(n):
			return {"step": float(n.step) - cut, "length": n.length, "note": n.note, "velocity": n.velocity})
	inst.clips[index] = first
	inst.clips.append(second)
	sync(inst)
	changed.emit()
	return inst.clips.size() - 1


## "Speaker_01-01", "-02"...: a name for a part of a clip, the first its track doesn't have yet.
func _part_name(inst, name: String) -> String:
	var base := name
	var dash := name.rfind("-")
	if dash > 0 and name.substr(dash + 1).is_valid_int():
		base = name.substr(0, dash)
	var taken := {}
	for clip in inst.clips:
		taken[str(clip.get("name", ""))] = true
	var number := 1
	while taken.has("%s-%02d" % [base, number]):
		number += 1
	return "%s-%02d" % [base, number]


## Nudges a clip along by one grid line (`direction` 1 later, -1 earlier), or by 10 ms with the grid off. Returns its
## index afterwards.
func nudge(inst, index: int, direction: int) -> int:
	var span := clip_steps(inst.clips[index])
	var amount: float = float(grid) if grid > 0 else NUDGE_SECONDS / step_seconds()
	place_clip(inst, index, inst, maxf(span.x + direction * amount, 0.0))
	return inst.clips.size() - 1


## A clip's gain (Pro Tools' clip gain) as a factor: its `gain_db`, from -48 dB (silence below) to +24 dB.
static func gain_of(clip: Dictionary) -> float:
	var db := float(clip.get("gain_db", 0.0))
	return 0.0 if db <= MIN_CLIP_GAIN_DB else db_to_linear(db)


## Sets the clips' gain, in dB.
func set_clip_gain(items: Array, db: float, send := true) -> void:
	for it in items:
		if it.clip.kind == "audio":
			it.clip.gain_db = clampf(snappedf(db, 0.01), MIN_CLIP_GAIN_DB, MAX_CLIP_GAIN_DB)
	if send:
		_sync_items(items)


# ── Several clips at once ([{inst, clip}], the clip its Dictionary itself) ───────────────────────────────────────

## Where a clip is on its track now (-1: gone).
static func index_of(inst, clip: Dictionary) -> int:
	for i in inst.clips.size():
		if is_same(inst.clips[i], clip):
			return i
	return -1


## Moves clips together (or with `copy`, seconds of them): `delta` steps along (not before bar 1), and `rows` tracks
## down, if every one of them fits the track it would land on (otherwise each stays on its own). Each covers what it
## lands on. Returns them where they are now.
func move_clips(items: Array, delta: float, rows := 0, copy := false, what := "", order := []) -> Array:
	if items.is_empty():
		return []
	remember(what if what != "" else ("Copy clips" if copy else "Move clips"))
	var earliest := INF
	for it in items:
		earliest = minf(earliest, clip_steps(it.clip).x)
	delta = maxf(delta, -earliest)
	var tracks: Array = order if not order.is_empty() else app.instruments  # (the rows as the edit window has them)
	var fit := rows != 0
	for it in items:
		var row: int = tracks.find(it.inst) + rows
		fit = fit and row >= 0 and row < tracks.size() and fits(it.clip, tracks[row])
	if not copy:
		for it in items:
			var at := index_of(it.inst, it.clip)
			if at >= 0:
				it.inst.clips.remove_at(at)
	var moved := []
	for it in items:
		var clip: Dictionary = it.clip.duplicate(true)
		clip.start = float(clip.start) + delta * (step_seconds() if clip.kind == "audio" else 1.0)
		var to = tracks[tracks.find(it.inst) + rows] if fit else it.inst
		_cover(to, clip.kind, clip.start, clip.start + clip.length)
		to.clips.append(clip)
		moved.append({"inst": to, "clip": clip})
	_sync_items(items + moved)
	return moved


func remove_clips(items: Array) -> void:
	if items.is_empty():
		return
	remember("Delete clips" if items.size() > 1 else "Delete clip")
	for it in items:
		var at := index_of(it.inst, it.clip)
		if at >= 0:
			it.inst.clips.remove_at(at)
	_sync_items(items)


## Where clips start and end together, in steps.
func span_of(items: Array) -> Vector2:
	var span := Vector2(INF, -INF)
	for it in items:
		var each := clip_steps(it.clip)
		span = Vector2(minf(span.x, each.x), maxf(span.y, each.y))
	return span


func _sync_items(items: Array) -> void:
	var done := []
	for it in items:
		if not done.has(it.inst):
			done.append(it.inst)
			sync(it.inst)
	changed.emit()


func file_seconds(clip: Dictionary) -> float:
	return audio.get_audio_seconds(file_path(clip))


# ── Undo ─────────────────────────────────────────────────────────────────────────────────────────────────────

## Before an edit: every track's clips as they are, to go back to (Cmd-Z). `what` names the edit, for the screen.
func remember(what: String) -> void:
	_undo.append([what, _snapshot()])
	if _undo.size() > UNDO_LEVELS:
		_undo.pop_front()
	_redo.clear()


## Cmd-Z: the clips as they were before the last edit. Returns what was undone, or "".
func undo() -> String:
	if _undo.is_empty():
		return ""
	var last: Array = _undo.pop_back()
	_redo.append([last[0], _snapshot()])
	_restore(last[1])
	return last[0]


## Cmd-Shift-Z: the last edit undone, done again. Returns what was redone, or "".
func redo() -> String:
	if _redo.is_empty():
		return ""
	var next: Array = _redo.pop_back()
	_undo.append([next[0], _snapshot()])
	_restore(next[1])
	return next[0]


## What Cmd-Z would undo, or "" (and what Cmd-Shift-Z would redo).
func undo_what() -> String:
	return _undo.back()[0] if not _undo.is_empty() else ""


func redo_what() -> String:
	return _redo.back()[0] if not _redo.is_empty() else ""


func _snapshot() -> Dictionary:
	var shot := {}
	for inst in app.instruments:
		shot[inst] = {"clips": inst.clips.duplicate(true), "automation": inst.automation.duplicate(true)}
	for folder in app.folders + app.auxes + [app.master_track]:
		shot[folder] = {"automation": folder.automation.duplicate(true)}
	return shot


func _restore(shot: Dictionary) -> void:
	for track in shot:
		if (track is Object and not is_instance_valid(track)) or not (app.has_track(track) or track == app.master_track):
			continue
		if shot[track].has("clips"):
			track.clips = shot[track].clips.duplicate(true)
		track.automation = shot[track].automation.duplicate(true)
		sync(track)
	changed.emit()


## A clip's file's loudest moments, a hundred to the second, for drawing it (read once).
func peaks(clip: Dictionary) -> PackedFloat32Array:
	var path := file_path(clip)
	if not _peaks.has(path):
		_peaks[path] = audio.get_audio_peaks(path, 100.0)
	return _peaks[path]
