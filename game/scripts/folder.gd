extends RefCounted
## A routing folder, as Pro Tools has them (Cmd-G puts the tracks chosen in a new one): its tracks play into its bus,
## an aux input in the audio core, rather than straight to the master, and from there through its inserts (in stereo)
## and its fader to the master, or to the folder it is in. Its tracks can be instruments', aux tracks, and other
## folders with theirs. It has a name and a colour as a track does, a meter, mute and solo, and sends of its own. Muting
## it silences its tracks; soloing it solos them, and soloing one of its tracks lets it be heard. The room's reverb of
## its tracks comes from the tracks themselves, as their own sends would, so its fader is their direct sound. It isn't
## in the room: it is in the mix window, as a strip, and in the edit window, its tracks under it. An aux track is one of
## these too (`is_aux`), with no tracks of its own: the sends play into it.

const DEFAULT_COLOR := Color(0.72, 0.74, 0.8)

var source_id := -1         # its bus in the audio core
var display_name := "Folder"
var color := DEFAULT_COLOR
var level_db := 0.0
var muted := false
var soloed := false
var inserts: Array = []     # as the audio core tells them, as an instrument's
var members: Array = []     # its tracks (instruments', aux tracks, folders), in their order
var open := true            # its tracks shown under it in the edit window
var meter_peak := 0.0       # as the mix window shows it, dBFS as it reaches the master
var meter_rms := 0.0
var peak_hold := 0.0
var is_folder := true
var automation := {}        # its volume's and mute's points (see automation.gd)
var auto_mode := "read"
var lanes := ["volume"]
var is_aux := false         # an aux track: a bus its tracks' sends play into, rather than a folder of tracks
var armed := false          # (a folder records nothing: for the track headers' sake)
var input_on := false
var sends := [{}, {}, {}, {}, {}]  # A to E, as an instrument's (see main.set_send)


## A folder's fader is its bus's gain as it is (see instrument.gd's, whose 0 dB is the level it was made at).
func normal_gain() -> float:
	return 1.0
