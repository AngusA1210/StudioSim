extends Node
## Automation, as Pro Tools and Logic have it: a track's volume, mute and (an instrument's) sustain pedal changing as
## the music plays, from breakpoints drawn in the edit window (A shows a lane under each track) or written as it plays,
## its fader and mute button moved by hand. Each track has an automation mode, as Pro Tools' tracks do:
##   Off    its automation is ignored;
##   Read   it is played;
##   Touch  it is played, and written while the track's fader is held (going back to what was there when it is let go);
##   Latch  it is played, and written from when the fader is first held until the music stops;
##   Write  it is written all the while the music plays (and then the track goes to Touch).
## A mute button pressed while the music plays, in Touch, Latch or Write, is written from then until it stops. The
## sustain pedal is written as an instrument records, from the pedal itself. A track keeps its points as `automation`:
## {volume: [[step, dB]], mute: [[step, 1 or 0]], sustain: [[step, 1 or 0]]}, in steps (they follow the tempo), and
## the audio core plays them to the sample. Writing can be undone as any edit can.

const MODES := ["off", "read", "touch", "latch", "write"]
const MODE_NAMES := {"off": "Off", "read": "Read", "touch": "Touch", "latch": "Latch", "write": "Write"}
const NAMES := {"volume": "Volume", "mute": "Mute", "sustain": "Sustain pedal"}
const RETURN_STEPS := 0.5   # how long Touch takes to go back to what was there, after the fader is let go
const THIN_DB := 0.2        # points written closer than this to the line between their neighbours are left out

var app
var timeline
var audio: SoundRoomAudio
var _held := {}         # track → true while its fader is held (the mix window says)
var _writing := {}      # track → {param: [[step, value], ...] written so far this pass}
var _mute_before := {}  # track → its mute button as it was before writing mute began
var _sent := {}         # track → [volume, mute, sustain] read, as the audio core was last told
var _gain_sent := {}    # track → the dB sent while stopped (its automation at the playhead)
var _was_playing := false


func setup(the_app) -> void:
	app = the_app
	timeline = app.timeline
	audio = app.audio


## The parameters a track can have automated: volume and mute, and an instrument's sustain pedal.
static func params_for(track) -> Array:
	return ["volume", "mute"] if track.is_folder or not track.playable else ["volume", "mute", "sustain"]


func points(track, param: String) -> Array:
	return track.automation.get(param, [])


func has_points(track, param: String) -> bool:
	return not points(track, param).is_empty()


## A parameter's value at a step, as the audio core plays it: volume glided between its points and level before the
## first and after the last; mute and the pedal on or off from each point to the next, off before the first.
static func value_at(lane: Array, param: String, step: float) -> float:
	if lane.is_empty():
		return 0.0
	if param != "volume":
		var value := 0.0
		for p in lane:
			if float(p[0]) > step:
				break
			value = float(p[1])
		return value
	if step <= float(lane[0][0]):
		return float(lane[0][1])
	for i in range(1, lane.size()):
		var a: Array = lane[i - 1]
		var b: Array = lane[i]
		if step <= float(b[0]):
			var span := float(b[0]) - float(a[0])
			return float(b[1]) if span <= 1e-9 else lerpf(float(a[1]), float(b[1]), (step - float(a[0])) / span)
	return float(lane.back()[1])


## Whether a track's automation of a parameter is played now.
func reads(track, param: String) -> bool:
	return track.auto_mode != "off" and not _writing.get(track, {}).has(param) and not (param == "volume" and _held.get(track, false))


## What a track's fader shows: its volume automation where the music is (stopped, at the playhead) while that is read,
## or the fader as it was set.
func shown_level(track) -> float:
	if reads(track, "volume") and has_points(track, "volume"):
		return value_at(points(track, "volume"), "volume", timeline.position())
	return track.level_db


## Whether its mute button is lit: muted by hand, or (playing) by its automation.
func shown_mute(track) -> bool:
	if track.muted:
		return true
	return timeline.playing and reads(track, "mute") and value_at(points(track, "mute"), "mute", timeline.position()) > 0.5


func is_writing(track, param := "volume") -> bool:
	return _writing.get(track, {}).has(param)


## Its fader held (true) or let go, in the mix window. In Touch or Latch, playing, holding it starts writing; in Touch,
## letting it go stops, and the automation goes back to what was there.
func touch(track, held: bool) -> void:
	if held:
		_held[track] = true
		if timeline.playing and timeline.is_record() and track.auto_mode in ["touch", "latch"] and not is_writing(track):
			_begin(track, "volume")
	else:
		_held.erase(track)
		if track.auto_mode == "touch" and is_writing(track):
			_commit(track, "volume", true)


## Its mute button pressed: while the music plays, in Touch, Latch or Write, that is written until it stops.
func mute_pressed(track) -> void:
	if timeline.playing and timeline.is_record() and track.auto_mode in ["touch", "latch", "write"] and not is_writing(track, "mute"):
		_mute_before[track] = not track.muted  # (it has just changed)
		_begin(track, "mute")


func _begin(track, param: String) -> void:
	_writing.get_or_add(track, {})[param] = [[timeline.position(), _now(track, param)]]


## What is being written: the fader's level, or whether the mute button is down.
static func _now(track, param: String) -> float:
	return track.level_db if param == "volume" else (1.0 if track.muted else 0.0)


func _process(_delta: float) -> void:
	if app == null:
		return
	var playing: bool = timeline.playing and timeline.is_record()
	if playing and not _was_playing:  # it starts: Write writes from here on
		for track in app.track_order():
			if track.auto_mode == "write":
				_begin(track, "volume")
	if playing:
		var at: float = timeline.position()
		for track in _writing.keys():
			if not app.has_track(track):
				_writing.erase(track)
				continue
			for param in _writing[track]:
				var written: Array = _writing[track][param]
				if not written.is_empty() and at < float(written.back()[0]) - 0.5:  # the loop went round: what was written goes in
					_splice(track, param, written, false)
					written.clear()
				written.append([at, _now(track, param)])
	elif _was_playing:  # it stopped: all that was written goes in, and a track that was writing goes to Touch
		for track in _writing.keys():
			for param in _writing[track].keys():
				_commit(track, param, false)
		_writing.clear()
		for track in app.track_order():
			if track.auto_mode == "write":
				track.auto_mode = "touch"
	_was_playing = playing
	for track in app.track_order():
		_tell(track)


## Tells the audio core which of a track's automation to play, and (stopped) where its volume automation has the fader.
func _tell(track) -> void:
	var read := [reads(track, "volume"), reads(track, "mute"), reads(track, "sustain")]
	if _sent.get(track) != read:
		audio.set_automation_read(track.source_id, read[0], read[1], read[2])
		_sent[track] = read
	if not timeline.playing and read[0] and has_points(track, "volume") and timeline.is_record():
		var db := value_at(points(track, "volume"), "volume", timeline.playhead)
		if _gain_sent.get(track) != db:
			_apply_gain(track, db)
			_gain_sent[track] = db
	elif _gain_sent.has(track):  # back to its fader
		_gain_sent.erase(track)
		_apply_gain(track, track.level_db)


func _apply_gain(track, db: float) -> void:
	var gain: float = 0.0 if db <= -79.0 else db_to_linear(db) * (1.0 if track.is_folder else track.normal_gain())
	audio.set_source_gain(track.source_id, gain)


func _commit(track, param: String, back_to_old: bool) -> void:
	var written: Array = _writing.get(track, {}).get(param, [])
	if _writing.has(track):
		_writing[track].erase(param)
		if _writing[track].is_empty():
			_writing.erase(track)
	if not written.is_empty():
		_splice(track, param, written, back_to_old)
	if param == "mute" and _mute_before.has(track):  # the button back as it was: what it did is in the automation now
		app.set_muted(track, _mute_before[track])
		_mute_before.erase(track)


## What was written, in place of what was there over its span. In Touch, it then goes back to what was there.
func _splice(track, param: String, written: Array, back_to_old: bool) -> void:
	var old: Array = points(track, param)
	var from := float(written[0][0])
	var to := float(written.back()[0])
	var until := to + (RETURN_STEPS if back_to_old else 0.0)
	var lane := []
	for p in old:
		if float(p[0]) < from:
			lane.append(p)
	if not old.is_empty() and param == "volume":
		lane.append([maxf(from - 0.01, 0.0), value_at(old, param, from)])
	lane.append_array(_thin(written, param))
	if not old.is_empty():
		lane.append([until + 0.01, value_at(old, param, until)])
	elif param != "volume":
		lane.append([to + 0.01, 0.0])
	elif back_to_old:  # (with nothing there before: back to where the fader was when it was taken hold of)
		lane.append([until + 0.01, float(written[0][1])])
	for p in old:
		if float(p[0]) > until + 0.01:
			lane.append(p)
	timeline.remember("Write automation")
	track.automation[param] = lane
	timeline.sync(track)
	timeline.changed.emit()


## Fewer points for the same line: for volume, only those that bend it; for mute, only the changes.
static func _thin(written: Array, param: String) -> Array:
	var out := [written[0]]
	for i in range(1, written.size()):
		var p: Array = written[i]
		if param != "volume":
			if float(p[1]) != float(out.back()[1]):
				out.append(p)
			continue
		if i == written.size() - 1:
			out.append(p)
			continue
		var a: Array = out.back()
		var b: Array = written[i + 1]
		var span := float(b[0]) - float(a[0])
		var line := float(b[1]) if span <= 1e-9 else lerpf(float(a[1]), float(b[1]), (float(p[0]) - float(a[0])) / span)
		if absf(float(p[1]) - line) > THIN_DB:
			out.append(p)
	return out


# ── Editing the points (the edit window's lanes) ────────────────────────────────────────────────────────────

## A point added (or moved to) at a step, keeping them in order. Returns its index.
func add_point(track, param: String, step: float, value: float) -> int:
	var lane: Array = track.automation.get_or_add(param, [])
	var at := 0
	while at < lane.size() and float(lane[at][0]) <= step:
		at += 1
	lane.insert(at, [step, value])
	return at


func set_mode(track, mode: String) -> void:
	if mode in MODES:
		track.auto_mode = mode
