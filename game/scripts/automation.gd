extends Node
## Automation, as Pro Tools and Logic have it: a track's volume and mute, an instrument's sustain pedal, an amp's
## knobs, its plug-ins' controls (on its inserts, its Plug-in pedals, a plug-in instrument's own), its sends' levels,
## and the master fader, changing as the music plays: from points drawn in the edit window (A shows a lane under each
## track, with more to add) or written as it plays, its controls moved by hand. Each track has an automation mode, as
## Pro Tools' tracks do:
##   Off    its automation is ignored;
##   Read   it is played;
##   Touch  it is played, and written while one of its controls is held (going back to what was there when let go);
##   Latch  it is played, and written from when a control is first held until the music stops;
##   Write  its volume is written all the while the music plays, and any other control once moved (then it is in Touch).
## A plug-in's control is written when it is turned in the plug-in's own window (seen to change as it plays), and in
## Touch goes back once it has been still a moment. A mute pressed as it plays, in Touch, Latch or Write, is written
## until it stops. The sustain pedal is written as an instrument records, from the pedal itself.
##
## A track keeps its points as `automation`: {param: [[step, value], ...]}, in steps (they follow the tempo), and the
## lanes the edit window shows it in as `lanes`. A param is "volume" (dB), "mute" and "sustain" (1 on, 0 off),
## "amp:gain" and the other knobs (0 to 10), a stock pedal's knob "stomp:<place on the board>:<knob>" (0 to 10), a
## track's "pan" (-1 left to 1 right: an instrument's direct output, a microphone's track; a stereo mic's balance),
## "send:0" to "send:4" (dB), or a plug-in's control: "insert:<slot>:<id>", "pedal:<place on the board>:<id>" or
## "instrument:<id>", kept from 0 to 1 across the control's range. A plug-in's automation (or a pedal's) goes where it
## goes: to another slot, another track, another place on the board. The audio core plays them all to the block
## (volume and mute to the sample).

const MODES := ["off", "read", "touch", "latch", "write"]
const MODE_NAMES := {"off": "Off", "read": "Read", "touch": "Touch", "latch": "Latch", "write": "Write"}
const Catalog := preload("res://scripts/catalog.gd")
const NAMES := {"volume": "Volume", "mute": "Mute", "sustain": "Sustain pedal", "pan": "Pan"}
const PanControl := preload("res://scripts/pan_control.gd")
const KNOB_NAMES := {"gain": "Gain", "bass": "Bass", "mid": "Middle", "treble": "Treble", "presence": "Presence", "master": "Master"}
const RETURN_STEPS := 0.5   # how long Touch takes to go back to what was there, after a control is let go
const THIN := 0.2           # points written closer than this (dB) to the line between their neighbours are left out
const STILL_SECONDS := 0.6  # a plug-in's control unmoved this long is taken to have been let go

var app
var timeline
var audio: SoundRoomAudio
var _held := {}         # track → {param: true} while one of its controls is held (the mix window, an amp's panel)
var _writing := {}      # track → {param: [[step, value], ...] written so far this pass}
var _moved_at := {}     # track → {param: when a plug-in's control last moved, while it is written}
var _mute_before := {}  # track → its mute button as it was before writing mute began
var _sent := {}         # track → what the audio core was last told to read
var _held_back := {}    # track → the params left out of what the audio core plays (being written), as last sent
var _applied := {}      # track → {param: value} set while stopped (its automation at the playhead)
var _plugin_seen := {}  # "id:param" → the value a plug-in's control was last seen at
var _controls := {}     # "id:param" → {at, info}: a plug-in control's details, as last asked for
var _was_playing := false
var _notified := 0.0


func setup(the_app) -> void:
	app = the_app
	timeline = app.timeline
	audio = app.audio


# ── What can be automated ──────────────────────────────────────────────────────────────────────────────────

static func is_switch(param: String) -> bool:
	return param in ["mute", "sustain"]


static func is_plugin(param: String) -> bool:
	return param.begins_with("insert:") or param.begins_with("pedal:") or param.begins_with("instrument:")


## A knob from 0 to 10: an amp's, or a stock pedal's.
static func is_knob(param: String) -> bool:
	return param.begins_with("amp:") or param.begins_with("stomp:")


## A stock pedal's knob's spec, as the catalog has it ([name, readout, resting]), or [] if there is no such pedal now.
static func _stomp_spec(track, param: String) -> Array:
	var parts := param.split(":")
	var at := int(parts[1])
	if track.get("pedals") == null or at >= track.pedals.size():
		return []
	var controls: Array = Catalog.PEDALS.get(str(track.pedals[at].kind), {}).get("controls", [])
	return controls[int(parts[2])] if int(parts[2]) < controls.size() else []


## A plug-in control's param, split: [place ("insert", "pedal", "instrument"), index, its id].
static func plugin_parts(param: String) -> Array:
	var parts := param.split(":")
	if parts[0] == "instrument":
		return ["instrument", 0, int(parts[1])]
	return [parts[0], int(parts[1]), int(parts[2])]


## The params a track has besides its plug-ins': volume and mute; an instrument's sustain pedal; an amp's knobs; its
## sends (those that go somewhere: a folder's and an aux's too); an instrument's pan. The master has its volume (and its
## inserts' controls).
func params_for(track) -> Array:
	if track.get("is_master"):
		return ["volume"]
	var out := ["volume", "mute"]
	if not track.is_folder and track.playable:
		out.append("sustain")
	if not track.is_folder and track.is_amp:
		for control in KNOB_NAMES:
			out.append("amp:" + control)
	if not track.is_folder:  # (its direct output's; a microphone's track's)
		out.append("pan")
	for slot in track.sends.size():
		if not track.sends[slot].is_empty():
			out.append("send:%d" % slot)
	return out


## The plug-ins on a track and their controls, and an amp's stock pedals and their knobs: [{name (the plug-in's or the
## pedal's, and where), params: [{param, name}]}].
func plugin_params(track) -> Array:
	var out := []
	var places := []
	for slot in track.inserts.size():
		if str(track.inserts[slot].get("plugin_name", "")) != "":
			places.append(["insert", slot, "%s (insert %s)" % [track.inserts[slot].plugin_name, char(65 + slot)]])
	if not track.is_folder and track.is_amp:
		for i in track.pedals.size():
			var kind := str(track.pedals[i].kind)
			if kind == "plugin" and str(track.pedals[i].get("plugin_name", "")) != "":
				places.append(["pedal", i, "%s (pedal %d)" % [track.pedals[i].plugin_name, i + 1]])
			elif kind != "plugin" and kind != "looper":  # a stock pedal: its knobs
				var knobs := []
				var specs: Array = Catalog.PEDALS[kind].controls
				for c in specs.size():
					if specs[c][1] != "switch":
						knobs.append({"param": "stomp:%d:%d" % [i, c], "name": str(specs[c][0]).capitalize()})
				if not knobs.is_empty():
					places.append(["stomp", i, "%s (pedal %d)" % [Catalog.PEDALS[kind].name, i + 1], knobs])
	if not track.is_folder and track.plays_plugin and str(track.instrument_plugin.get("plugin_name", "")) != "":
		places.append(["instrument", 0, str(track.instrument_plugin.plugin_name)])
	for place in places:
		if place[0] == "stomp":
			out.append({"name": place[2], "params": place[3]})
			continue
		var controls := []
		for p in audio.get_plugin_parameters(track.source_id, place[0], place[1]):
			var key: String = ("instrument:%d" % int(p.id)) if place[0] == "instrument" else ("%s:%d:%d" % [place[0], place[1], int(p.id)])
			controls.append({"param": key, "name": str(p.name)})
		out.append({"name": place[2], "params": controls})
	return out


## A plug-in control's details ({name, min, max, unit, value}), or {} if its plug-in has gone. Its plug-in's list of
## controls is asked for a second at a time at most (a big plug-in has hundreds); its value, each time.
func plugin_control(track, param: String) -> Dictionary:
	var parts := plugin_parts(param)
	var key := "%d:%s" % [track.source_id, param]
	var known: Dictionary = _controls.get(key, {})
	if known.is_empty() or Time.get_ticks_msec() - int(known.at) > 1000:
		known = {"at": Time.get_ticks_msec(), "info": {}}
		for p in audio.get_plugin_parameters(track.source_id, parts[0], parts[1]):
			if int(p.id) == parts[2]:
				known.info = {"name": str(p.name), "min": float(p.min), "max": float(p.max), "unit": str(p.unit)}
		_controls[key] = known
	if known.info.is_empty():
		return {}
	var out: Dictionary = known.info.duplicate()
	out.value = audio.get_plugin_parameter(track.source_id, parts[0], parts[1], parts[2])
	return out


## What a param is called, for a lane's button and the hint line.
func name_of(track, param: String) -> String:
	if NAMES.has(param):
		return NAMES[param]
	if param.begins_with("amp:"):
		return KNOB_NAMES.get(param.substr(4), param)
	if param.begins_with("send:"):
		return "Send %s" % char(65 + int(param.substr(5)))
	if param.begins_with("stomp:"):
		var spec := _stomp_spec(track, param)
		return str(spec[0]).capitalize() if not spec.is_empty() else "a pedal's knob"
	var control := plugin_control(track, param)
	return str(control.get("name", "a plug-in's control"))


## A value as it reads: dB, a knob's number, a plug-in's own value and unit, on or off.
func value_text(track, param: String, value: float) -> String:
	if param == "volume" or param.begins_with("send:"):
		return "-inf" if value <= -79.0 else "%+.1f dB" % value
	if is_switch(param):
		return "on" if value > 0.5 else "off"
	if param == "pan":
		return PanControl.readout(value)
	if param.begins_with("amp:"):
		return "%.1f" % value
	if param.begins_with("stomp:"):
		var spec := _stomp_spec(track, param)
		var at := int(param.split(":")[1])
		return "%.1f" % value if spec.is_empty() else "%.1f  (%s)" % [value, Catalog.pedal_readout(spec[1], value, track.pedals[at].controls)]
	var control := plugin_control(track, param)
	if control.is_empty():
		return "%.0f%%" % (value * 100.0)
	var native: float = lerpf(control.min, control.max, value)
	var parts := plugin_parts(param)  # (as the plug-in writes it, where it says: a VST3's are 0 to 1 otherwise)
	var written: String = audio.get_plugin_parameter_text(track.source_id, parts[0], parts[1], parts[2], native)
	if written != "":
		return written
	return ("%.2f" % native if absf(control.max - control.min) <= 2.0 else "%.1f" % native) + (" " + control.unit if control.unit != "" else "")


## Where a value is, from 0 (a lane's foot) to 1 (its top): volume and sends on the fader's own scale.
static func height_of(param: String, value: float) -> float:
	if param == "volume" or param.begins_with("send:"):
		return preload("res://scripts/fader.gd").position_of(value)
	if is_knob(param):
		return value / 10.0
	if param == "pan":  # (left at the foot, right at the top)
		return (clampf(value, -1.0, 1.0) + 1.0) / 2.0
	return clampf(value, 0.0, 1.0)


static func value_from(param: String, height: float) -> float:
	height = clampf(height, 0.0, 1.0)
	if param == "volume" or param.begins_with("send:"):
		return snappedf(preload("res://scripts/fader.gd").level_at(height), 0.1)
	if is_knob(param):
		return snappedf(height * 10.0, 0.05)
	if param == "pan":
		return snappedf(height * 2.0 - 1.0, 0.01)
	if is_switch(param):
		return 1.0 if height > 0.5 else 0.0
	return snappedf(height, 0.001)


# ── The points ─────────────────────────────────────────────────────────────────────────────────────────────

func points(track, param: String) -> Array:
	return track.automation.get(param, [])


func has_points(track, param: String) -> bool:
	return not points(track, param).is_empty()


## A param's value at a step, as the audio core plays it: glided between its points and level before the first and
## after the last; mute and the pedal on or off from each point to the next, off before the first.
static func value_at(lane: Array, param: String, step: float) -> float:
	if lane.is_empty():
		return 0.0
	if is_switch(param):
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


## A point added (or moved to) at a step, keeping them in order. Returns its index.
func add_point(track, param: String, step: float, value: float) -> int:
	if track.get("is_master") and param == "volume":  # (a master's fader stops at 0 dB)
		value = minf(value, 0.0)
	var lane: Array = track.automation.get_or_add(param, [])
	var at := 0
	while at < lane.size() and float(lane[at][0]) <= step:
		at += 1
	lane.insert(at, [step, value])
	return at


func set_mode(track, mode: String) -> void:
	if mode in MODES:
		track.auto_mode = mode


## What a control is now, by hand: the fader, the mute button, a knob, a send, a plug-in's control (0 to 1).
func now(track, param: String) -> float:
	if param == "volume":
		return track.level_db
	if param == "mute":
		return 1.0 if track.muted else 0.0
	if param == "pan":
		return float(track.get("pan")) if track.get("pan") != null else 0.0
	if param.begins_with("amp:"):
		return float(track.amp_controls.get(param.substr(4), 5.0))
	if param.begins_with("stomp:"):
		var parts := param.split(":")
		return float(track.pedals[int(parts[1])].controls[int(parts[2])]) if int(parts[1]) < track.pedals.size() else 5.0
	if param.begins_with("send:"):
		var send: Dictionary = track.sends[int(param.substr(5))]
		return float(send.get("level_db", 0.0))
	if is_plugin(param):
		var control := plugin_control(track, param)
		return 0.0 if control.is_empty() or control.max <= control.min else (control.value - control.min) / (control.max - control.min)
	return 0.0


# ── As the music plays ─────────────────────────────────────────────────────────────────────────────────────

## Whether a track's automation of a param is played now.
func reads(track, param: String) -> bool:
	return track.auto_mode != "off" and not _writing.get(track, {}).has(param) and not _held.get(track, {}).has(param)


## What a fader shows: its automation where the music is (stopped, at the playhead) while that is read, or the fader.
func shown_level(track) -> float:
	return shown(track, "volume")


## Any control likewise: an amp's knob in its panel, a send in the mix window.
func shown(track, param: String) -> float:
	if reads(track, param) and has_points(track, param):
		return value_at(points(track, param), param, timeline.position())
	return now(track, param)


## Whether its mute button is lit: muted by hand, or (playing) by its automation.
func shown_mute(track) -> bool:
	if track.muted:
		return true
	return timeline.playing and reads(track, "mute") and value_at(points(track, "mute"), "mute", timeline.position()) > 0.5


func is_writing(track, param := "volume") -> bool:
	return _writing.get(track, {}).has(param)


## One of its controls held (true) or let go: a fader in the mix window, a knob in an amp's panel, a send. In Touch or
## Latch (or Write, for any but its volume), playing, holding it starts writing; in Touch, letting go stops, and it
## goes back to what was there.
func touch(track, held: bool, param := "volume") -> void:
	if held:
		_held.get_or_add(track, {})[param] = true
		if timeline.playing and timeline.is_record() and track.auto_mode in ["touch", "latch", "write"] and not is_writing(track, param):
			_begin(track, param)
	else:
		if _held.has(track):
			_held[track].erase(param)
			if _held[track].is_empty():
				_held.erase(track)
		if track.auto_mode == "touch" and is_writing(track, param):
			_commit(track, param, true)


## Its mute button pressed: while the music plays, in Touch, Latch or Write, that is written until it stops.
func mute_pressed(track) -> void:
	if timeline.playing and timeline.is_record() and track.auto_mode in ["touch", "latch", "write"] and not is_writing(track, "mute"):
		_mute_before[track] = not track.muted  # (it has just changed)
		_begin(track, "mute")


func _begin(track, param: String) -> void:
	_writing.get_or_add(track, {})[param] = [[timeline.position(), now(track, param)]]
	if is_plugin(param):
		_moved_at.get_or_add(track, {})[param] = Time.get_ticks_msec()
	_sync_if_held_back(track)


## Every track, the master too: what the windows show, in order.
func _tracks() -> Array:
	return app.track_order() + app.master_tracks()


func _process(delta: float) -> void:
	if app == null:
		return
	var playing: bool = timeline.playing and timeline.is_record()
	if playing and not _was_playing:  # it starts: Write writes the volume from here on
		_plugin_seen.clear()
		for track in _tracks():
			if track.auto_mode == "write":
				_begin(track, "volume")
	if playing:
		_watch_plugins()
		var at: float = timeline.position()
		for track in _writing.keys():
			if not (app.has_track(track) or app.master_tracks().has(track)):
				_writing.erase(track)
				continue
			for param in _writing[track].keys():
				var written: Array = _writing[track][param]
				if not written.is_empty() and at < float(written.back()[0]) - 0.5:  # the loop went round: what was written goes in
					_splice(track, param, written, false)
					written.clear()
				written.append([at, now(track, param)])
				if is_plugin(param) and track.auto_mode == "touch" and Time.get_ticks_msec() - int(_moved_at[track][param]) > STILL_SECONDS * 1000.0:
					_commit(track, param, true)  # (still a moment: let go)
		_notified += delta
		if _notified > 0.1:  # the plug-ins' windows shown what automation sets, ten times a second
			_notified = 0.0
			_notify_plugins()
	elif _was_playing:  # it stopped: all that was written goes in, and a track that was writing goes to Touch
		for track in _writing.keys():
			for param in _writing[track].keys():
				_commit(track, param, false)
		_writing.clear()
		_moved_at.clear()
		for track in _tracks():
			if track.auto_mode == "write":
				track.auto_mode = "touch"
	_was_playing = playing
	for track in _tracks():
		_tell(track)


## A plug-in's control seen to change as it plays (turned in its window) on a track in Touch, Latch or Write, with a
## lane for it: that is written; while it is, it is noted as moving.
func _watch_plugins() -> void:
	for track in app.track_order():
		if not (track.auto_mode in ["touch", "latch", "write"]):
			continue
		for param in track.lanes:
			if not is_plugin(param):
				continue
			var parts := plugin_parts(param)
			var value: float = audio.get_plugin_parameter(track.source_id, parts[0], parts[1], parts[2])
			var key := "%d:%s" % [track.source_id, param]
			var seen = _plugin_seen.get(key)
			_plugin_seen[key] = value
			if seen == null or absf(value - float(seen)) < 1e-5:
				continue
			# It moved: by automation (as its lane has it), or by hand.
			if not is_writing(track, param):
				var control := plugin_control(track, param)
				if control.is_empty():
					continue
				var span: float = maxf(absf(control.max - control.min), 1e-6)
				var expected: float = lerpf(control.min, control.max, value_at(points(track, param), param, timeline.position())) \
					if has_points(track, param) else INF
				if absf(value - expected) > 1e-3 * span:
					_begin(track, param)
			if is_writing(track, param):
				_moved_at.get_or_add(track, {})[param] = Time.get_ticks_msec()


## Plug-in windows shown the controls automation is moving.
func _notify_plugins() -> void:
	for track in app.track_order():
		if track.auto_mode == "off":
			continue
		for param in track.lanes:
			if is_plugin(param) and has_points(track, param) and reads(track, param):
				var parts := plugin_parts(param)
				audio.notify_plugin_parameter(track.source_id, parts[0], parts[1], parts[2])


## Tells the audio core which of a track's automation to play, and (stopped) puts its controls where its automation has
## them at the playhead.
func _tell(track) -> void:
	var off: bool = track.auto_mode == "off"
	if track.get("is_master"):
		var read_master := [reads(track, "volume"), not off]
		if _sent.get(track) != read_master:
			audio.set_master_automation_read(read_master[0], track.which)
			audio.set_automation_read(track.source_id, false, false, false, read_master[1])  # (its inserts' controls)
			_sent[track] = read_master
	else:
		var read := [reads(track, "volume"), reads(track, "mute"), reads(track, "sustain"), not off]
		if _sent.get(track) != read:
			audio.set_automation_read(track.source_id, read[0], read[1], read[2], read[3])
			_sent[track] = read
	if timeline.playing or not timeline.is_record():
		return
	# Stopped: each control where its automation is at the playhead (and the fader back, once it no longer reads).
	var applied: Dictionary = _applied.get_or_add(track, {})
	for param in params_for(track) + track.automation.keys().filter(func(p): return is_plugin(p) or p.begins_with("stomp:")):
		if is_switch(param):
			continue
		if reads(track, param) and has_points(track, param):
			var value := value_at(points(track, param), param, timeline.playhead)
			if applied.get(param) != value:
				_apply(track, param, value)
				applied[param] = value
		elif applied.has(param):
			applied.erase(param)
			if param == "volume":
				_apply(track, param, now(track, param))


## Sets a control to a value from its automation (stopped, at the playhead).
func _apply(track, param: String, value: float) -> void:
	if param == "volume":
		var gain: float = 0.0 if value <= -79.0 else db_to_linear(value)
		if track.get("is_master"):
			app.apply_master_gain(minf(gain, 1.0), track.which)
		else:
			audio.set_source_gain(track.source_id, gain * (1.0 if track.is_folder else track.normal_gain()))
	elif param == "pan":
		app.set_pan(track, value)
	elif param.begins_with("amp:"):
		app.set_amp_control(track, param.substr(4), value)
	elif param.begins_with("stomp:"):
		var parts := param.split(":")
		if int(parts[1]) < track.pedals.size():
			app.set_pedal_control(track, int(parts[1]), int(parts[2]), value)
	elif param.begins_with("send:"):
		app.set_send_level(track, int(param.substr(5)), value)
	elif is_plugin(param):
		var parts := plugin_parts(param)
		var control := plugin_control(track, param)
		if not control.is_empty():
			audio.set_plugin_parameter(track.source_id, parts[0], parts[1], parts[2], lerpf(control.min, control.max, value))


## The params being written now, which the audio core is to leave out (so that the hand is heard).
func held_back(track) -> Array:
	return _writing.get(track, {}).keys().filter(func(p): return not (p in ["volume", "mute", "sustain"]))


func _sync_if_held_back(track) -> void:
	var back := held_back(track)
	if _held_back.get(track, []) != back:
		_held_back[track] = back
		timeline.sync(track)


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
	_sync_if_held_back(track)


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
	if not old.is_empty() and not is_switch(param):
		lane.append([maxf(from - 0.01, 0.0), value_at(old, param, from)])
	lane.append_array(_thin(written, param))
	if not old.is_empty():
		lane.append([until + 0.01, value_at(old, param, until)])
	elif is_switch(param):
		lane.append([to + 0.01, 0.0])
	elif back_to_old:  # (with nothing there before: back to where the control was when it was taken hold of)
		lane.append([until + 0.01, float(written[0][1])])
	for p in old:
		if float(p[0]) > until + 0.01:
			lane.append(p)
	timeline.remember("Write automation")
	track.automation[param] = lane
	if not track.lanes.has(param):
		track.lanes.append(param)  # (a lane for it, to be seen)
	timeline.sync(track)
	timeline.changed.emit()


## Fewer points for the same line: only those that bend it (for a switch, only the changes).
static func _thin(written: Array, param: String) -> Array:
	var out := [written[0]]
	var close: float = THIN if (param == "volume" or param.begins_with("send:")) else (0.1 if is_knob(param) else 0.002)
	for i in range(1, written.size()):
		var p: Array = written[i]
		if is_switch(param):
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
		if absf(float(p[1]) - line) > close:
			out.append(p)
	return out


# ── Plug-ins and pedals moved ─────────────────────────────────────────────────────────────────────────────

## A place a plug-in (or a pedal) is in, as its controls' params begin: "insert" and a slot, "pedal" and a place on the
## board (its plug-in's controls, and a stock pedal's knobs as "stomp"), or "instrument".
static func _in_place(param: String, place: String, index: int) -> bool:
	match place:
		"insert":
			return param.begins_with("insert:%d:" % index)
		"send":
			return param == "send:%d" % index
		"pedal":
			return param.begins_with("pedal:%d:" % index) or param.begins_with("stomp:%d:" % index)
	return param.begins_with("instrument:")


static func _placed(param: String, index: int) -> String:
	var parts := param.split(":")
	if parts.size() == 3 or parts[0] == "send":
		parts[1] = str(index)
	return ":".join(parts)


## Renames a track's params (its points and its lanes, in their order) as `rename` has them: the same, another, or ""
## to take it away.
func _rename(track, rename: Callable) -> void:
	var kept := {}
	for param in track.automation:
		var to: String = rename.call(param)
		if to != "":
			kept[to] = track.automation[param]
	track.automation = kept
	var lanes := []
	for param in track.lanes:
		var to: String = rename.call(param)
		if to != "" and not lanes.has(to):
			lanes.append(to)
	track.lanes = lanes if not lanes.is_empty() else ["volume"]
	_forget(track)


## What a place's automation is: {points: {param: lane}, lanes: [those shown]}, taken off the track.
func _take(track, place: String, index: int) -> Dictionary:
	var taken := {"points": {}, "lanes": []}
	for param in track.automation:
		if _in_place(param, place, index):
			taken.points[param] = track.automation[param]
	taken.lanes = track.lanes.filter(func(p): return _in_place(p, place, index))
	_rename(track, func(p): return "" if _in_place(p, place, index) else p)
	return taken


func _put(track, index: int, taken: Dictionary) -> void:
	for param in taken.points:
		track.automation[_placed(param, index)] = taken.points[param]
	for param in taken.lanes:
		if not track.lanes.has(_placed(param, index)):
			track.lanes.append(_placed(param, index))
	_forget(track)


## A plug-in moved from one insert slot to another (on this track or another): its automation goes with it, and that of
## the one it swapped with goes the other way.
func insert_moved(from_track, from_slot: int, to_track, to_slot: int) -> void:
	slot_moved("insert", from_track, from_slot, to_track, to_slot)


## The same for a send (its level's automation), or for any slot of a kind (`place`: "insert" or "send").
func slot_moved(place: String, from_track, from_slot: int, to_track, to_slot: int) -> void:
	if from_track == to_track:
		_rename(from_track, func(p): return _placed(p, to_slot) if _in_place(p, place, from_slot) else (
			_placed(p, from_slot) if _in_place(p, place, to_slot) else p))
	else:
		var moving := _take(from_track, place, from_slot)
		var displaced := _take(to_track, place, to_slot)
		_put(to_track, to_slot, moving)
		_put(from_track, from_slot, displaced)
		timeline.sync(to_track)
	timeline.sync(from_track)


## A second of a plug-in (or a pedal) made somewhere else: its automation copied there, in place of what was there.
func copied(from_track, place: String, from_index: int, to_track, to_index: int) -> void:
	var original := {"points": {}, "lanes": []}
	for param in from_track.automation:
		if _in_place(param, place, from_index):
			original.points[param] = from_track.automation[param].map(func(p): return p.duplicate())
	original.lanes = from_track.lanes.filter(func(p): return _in_place(p, place, from_index))
	if place in ["insert", "send"]:
		_take(to_track, place, to_index)
	_put(to_track, to_index, original)
	timeline.sync(to_track)


## A plug-in (or a pedal) taken away, or another put in its place: its automation goes with it.
func dropped(track, place: String, index := 0) -> void:
	if track.automation.keys().any(func(p): return _in_place(p, place, index)) or track.lanes.any(func(p): return _in_place(p, place, index)):
		_take(track, place, index)
		timeline.sync(track)


## An amp's board changed order: `order` is, for each pedal's old place, its new one (-1: gone). Each pedal's automation
## follows it.
func pedals_moved(track, order: Array) -> void:
	_rename(track, func(p):
		if not (p.begins_with("pedal:") or p.begins_with("stomp:")):
			return p
		var at := int(p.split(":")[1])
		var to: int = order[at] if at < order.size() else at
		return "" if to < 0 else _placed(p, to))
	timeline.sync(track)


## What was remembered of a track's params is forgotten (they may now mean something else).
func _forget(track) -> void:
	_controls.clear()
	_plugin_seen.clear()
	_applied.erase(track)
	if _writing.has(track):
		_writing.erase(track)
		_sync_if_held_back(track)


## A track's controls' automation as the audio core plays it (see timeline.automation_data), each in the control's own
## terms, less any being written just now.
func param_lanes(track) -> Array:
	var out := []
	var back := held_back(track)
	for param in track.automation:
		var lane: Array = track.automation[param]
		if lane.is_empty() or back.has(param) or param in ["volume", "mute", "sustain"]:
			continue
		if param == "pan":
			out.append({"target": "pan", "index": 0, "param": 0, "points": lane})
		elif param.begins_with("amp:"):
			out.append({"target": "amp", "index": KNOB_NAMES.keys().find(param.substr(4)), "param": 0, "points": lane})
		elif param.begins_with("stomp:"):
			var parts: PackedStringArray = str(param).split(":")
			out.append({"target": "stomp", "index": int(parts[1]), "param": int(parts[2]), "points": lane})
		elif param.begins_with("send:"):
			var send: Dictionary = track.sends[int(param.substr(5))]
			var trim: float = linear_to_db(track.normal_gain()) if send.get("pre", false) else 0.0  # (before the fader: as at 0 dB)
			out.append({"target": "send", "index": int(param.substr(5)), "param": 0,
				"points": lane.map(func(p): return [float(p[0]), float(p[1]) + trim if float(p[1]) > -79.0 else -80.0])})
		elif is_plugin(param):
			var parts := plugin_parts(param)
			var control := plugin_control(track, param)
			if control.is_empty():
				continue
			out.append({"target": parts[0], "index": parts[1], "param": parts[2],
				"points": lane.map(func(p): return [float(p[0]), lerpf(control.min, control.max, float(p[1]))])})
	return out
