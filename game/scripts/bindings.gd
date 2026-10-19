extends RefCounted
## The keys, which can be changed on the Controls page of the menu (and are saved with the settings). Each action
## has one key. A few never change: Esc (back out of anything), the arrow keys (they always walk and turn, even while
## the letter keys are notes), 1 to 8 (an amp's pedals), and the note keys themselves: A S D F G H J K L ; for the
## white keys and W E T Y U O P for the black, while you are at an instrument or have the keyboard open. Then those
## keys are notes, and whatever else they do waits until you get up or close the keyboard.

# [action, what it does, its key to begin with], in the order the Controls page lists them.
const ACTIONS := [
	["forward", "Walk forward", KEY_W],
	["back", "Walk back", KEY_S],
	["left", "Step left", KEY_A],
	["right", "Step right", KEY_D],
	["run", "Run (hold)", KEY_SHIFT],
	["play", "Play the instrument you face", KEY_E],
	["keyboard", "Keyboard: play every instrument whose input is on", KEY_K],
	["stop", "Get up from an instrument, close the keyboard", KEY_Q],
	["octave_down", "Octave down (while playing)", KEY_Z],
	["octave_up", "Octave up (while playing)", KEY_X],
	["input", "Input on / off", KEY_I],
	["edit", "Its pattern, an amp's panel, a Speaker's panel", KEY_APOSTROPHE],
	["plugin_window", "A plug-in instrument's own window", KEY_P],
	["loop", "Its loop on / off (a Speaker or amp: mute)", KEY_M],
	["carry", "Pick up, put down", KEY_G],
	["add", "Add an instrument", KEY_T],
	["duplicate", "Duplicate what you face, with all its settings", KEY_V],
	["remove", "Remove what you face (twice)", KEY_BACKSPACE],
	["mixer", "The mix window", KEY_TAB],
	["edit_window", "The edit window (a Record room), from the room or the mix window", KEY_R],
	["transport", "Start / stop the patterns", KEY_SPACE],
	["to_start", "The playhead back to the start (a Record room)", KEY_ENTER],
	["follow", "Insertion follows playback on / off (a Record room)", KEY_N],
	["click", "Metronome click", KEY_C],
	["binaural", "Binaural on / off", KEY_B],
	["loop_switch", "Loop pedal: record, play, overdub", KEY_L],
	["loop_stop", "Loop pedal: stop / play", KEY_O],
	["loop_undo", "Loop pedal: undo / redo", KEY_U],
	["loop_clear", "Loop pedal: clear (twice)", KEY_J],
]
# Keys that always mean the same, whatever is bound.
const FIXED := {KEY_ESCAPE: "Esc: back out", KEY_UP: "walk", KEY_DOWN: "walk", KEY_LEFT: "turn", KEY_RIGHT: "turn",
	KEY_1: "pedal 1", KEY_2: "pedal 2", KEY_3: "pedal 3", KEY_4: "pedal 4", KEY_5: "pedal 5", KEY_6: "pedal 6", KEY_7: "pedal 7",
	KEY_8: "pedal 8"}
# Second keys for a few actions, as on most keyboards.
const ALSO := {KEY_KP_ENTER: "to_start", KEY_DELETE: "remove"}
# The computer keyboard as a piano, the usual DAW layout: semitones above the C the octave starts on.
const NOTES := {
	KEY_A: 0, KEY_W: 1, KEY_S: 2, KEY_E: 3, KEY_D: 4, KEY_F: 5, KEY_T: 6, KEY_G: 7, KEY_Y: 8,
	KEY_H: 9, KEY_U: 10, KEY_J: 11, KEY_K: 12, KEY_O: 13, KEY_L: 14, KEY_P: 15, KEY_SEMICOLON: 16,
}

var keys := {}  # action → physical keycode


func _init(saved := {}) -> void:
	reset()
	for action in saved:
		if keys.has(action) and int(saved[action]) > 0:
			keys[action] = int(saved[action])


func reset() -> void:
	keys.clear()
	for entry in ACTIONS:
		keys[entry[0]] = entry[2]


func key(action: String) -> int:
	return keys.get(action, KEY_NONE)


## The action a key does, or "".
func action_for(keycode: int) -> String:
	for action in keys:
		if keys[action] == keycode:
			return action
	return ALSO.get(keycode, "")


## Whether an action's key is held down (movement and running are read this way, every frame).
func is_down(action: String) -> bool:
	return Input.is_physical_key_pressed(key(action))


func label(action: String) -> String:
	return name_of(key(action))


static func name_of(keycode: int) -> String:
	match keycode:
		KEY_SEMICOLON:
			return ";"
		KEY_APOSTROPHE:
			return "'"
		KEY_BACKSPACE:
			return "Backspace"
	return OS.get_keycode_string(keycode)


## Gives an action a new key. An action that had it already takes this one's old key, so no two share one.
## Returns that action, or "". Keys that never change can't be given.
func bind(action: String, keycode: int) -> String:
	if not keys.has(action) or FIXED.has(keycode):
		return ""
	var other := ""
	for each in keys:
		if each != action and keys[each] == keycode:
			other = each
	if other != "":
		keys[other] = keys[action]
	keys[action] = keycode
	return other


## What to save: only the keys that differ from the ones it began with.
func changed() -> Dictionary:
	var out := {}
	for entry in ACTIONS:
		if keys[entry[0]] != entry[2]:
			out[entry[0]] = keys[entry[0]]
	return out
