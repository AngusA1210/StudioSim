extends RefCounted
## A master (the mix's, or the room's: `which`), as a track: at the foot of the edit window, its volume's lane under it
## (A), its automation mode, its fader as the mix window has it (a master fader), and its inserts (on a bus of its own in
## the audio core, played on the whole of that master's sound). It has a name and a colour, crimson to begin with, and
## nothing else a track has.

const CRIMSON := Color(0.78, 0.11, 0.24)

var app
var which := "mix"  # "mix" or "room"
var display_name := "Mix Master"
var color := CRIMSON
var automation := {}
var auto_mode := "read"
var lanes := ["volume"]
var is_master := true
var is_folder := true  # (not an instrument: no clips, no input)
var is_aux := false
var members: Array = []
var open := true
var muted := false
var soloed := false
var armed := false
var input_on := false
var source_id := -1
var inserts: Array = []
var reduction_db := 0.0  # what its limiter and its inserts' compressors took off since the last frame
var sends: Array = []


func normal_gain() -> float:
	return 1.0
var level_db: float:  # the master fader
	get:
		if app == null:
			return 0.0
		return app.room_volume_db if which == "room" else app.master_volume_db
	set(value):
		if app != null:
			if which == "room":
				app.set_room_volume_db(value)
			else:
				app.set_master_volume_db(value)
