extends RefCounted
## The mix's master, as a track for automation's sake: at the foot of the edit window, its volume's lane under it (A),
## its automation mode, and its fader as the mix window has it (the mix's master fader), and its inserts (on a bus of
## its own in the audio core, played on the whole mix). It has nothing else a track has. (The room's master has no
## automation.)

var app
var display_name := "Mix Master"
var color := Color(0.75, 0.77, 0.82)
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
var sends: Array = []


func normal_gain() -> float:
	return 1.0
var level_db: float:  # the master fader
	get:
		return app.master_volume_db if app != null else 0.0
	set(value):
		if app != null:
			app.set_master_volume_db(value)
