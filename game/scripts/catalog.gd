extends RefCounted
## Every kind of instrument that can stand in the room, and how the instrument menu groups them.
##
## For each kind: its name and a line about it, how it looks (colour; how tall its model stands, `top`, and the
## floor it covers, `footprint`, both in metres), the height its sound comes from, how loud it is and how much of
## it goes to the room reverb, and for MIDI instruments the octave the computer keyboard starts in. "live_input"
## marks the kinds that play an audio input rather than notes. scripts/instrument_models.gd draws them.
## Then the effect pedals an amp can have in front of it, and how their knobs read.

const KINDS := {
	"drums": {"name": "Drums", "about": "A drum kit, eight pieces in all, one on each key.", "color": Color(1.0, 0.42, 0.26),
		"top": 1.45, "footprint": Vector2(1.5, 1.2), "height": 0.9, "gain": 0.50, "send": 0.6},
	"bass": {"name": "Bass", "about": "A bass synthesizer. Notes hold for as long as the key is down.", "color": Color(0.58, 0.44, 1.0),
		"top": 1.2, "footprint": Vector2(0.8, 0.5), "height": 1.0, "gain": 0.38, "send": 0.4, "octave": -2},
	"pad": {"name": "Pad", "about": "A modular synthesizer: soft, slow chords that swell and fade.", "color": Color(0.25, 0.84, 0.75),
		"top": 1.7, "footprint": Vector2(0.9, 0.5), "height": 1.6, "gain": 1.0, "send": 1.0},
	"bells": {"name": "Bells", "about": "Tubular bells: bright tones that ring and die away.", "color": Color(1.0, 0.82, 0.29),
		"top": 1.96, "footprint": Vector2(0.9, 0.5), "height": 1.6, "gain": 0.42, "send": 1.0, "octave": 1},
	"keys": {"name": "Keys", "about": "An electric piano. A sustain pedal works on it.", "color": Color(1.0, 0.48, 0.82),
		"top": 0.98, "footprint": Vector2(1.2, 0.55), "height": 0.95, "gain": 0.20, "send": 0.9},
	"live": {"name": "Speaker", "about": "Plays an input just as it comes in, from where the speaker stands.", "color": Color(0.55, 0.78, 1.0),
		"top": 1.72, "footprint": Vector2(0.6, 0.6), "height": 1.45, "gain": 1.5, "send": 0.7, "live_input": true},
	# Amps: their output level is set in the audio core, so "gain" is 1. Each has a loop pedal on the floor in front,
	# and room for effect pedals beside it.
	"guitar_combo": {"name": "Guitar Combo", "about": "A 1x12 combo for guitar: clean to crunch. With a loop pedal.",
		"color": Color(0.95, 0.85, 0.62), "top": 0.56, "footprint": Vector2(0.64, 0.3), "height": 0.3, "gain": 1.0, "send": 0.5,
		"live_input": true, "amp": true},
	"guitar_stack": {"name": "Guitar Stack", "about": "A high-gain head on a 4x12 cabinet. With a loop pedal.",
		"color": Color(0.95, 0.32, 0.32), "top": 1.1, "footprint": Vector2(0.78, 0.4), "height": 0.4, "gain": 1.0, "send": 0.5,
		"live_input": true, "amp": true},
	"bass_combo": {"name": "Bass Combo", "about": "A 1x15 combo for bass: deep and round. With a loop pedal.",
		"color": Color(0.5, 0.88, 0.45), "top": 0.8, "footprint": Vector2(0.58, 0.45), "height": 0.38, "gain": 1.0, "send": 0.4,
		"live_input": true, "amp": true},
	"bass_stack": {"name": "Bass Stack", "about": "A head on an 8x10 cabinet: punchy, with more drive. With a loop pedal.",
		"color": Color(0.82, 0.86, 0.95), "top": 1.62, "footprint": Vector2(0.62, 0.48), "height": 0.7, "gain": 1.0, "send": 0.4,
		"live_input": true, "amp": true},
}

# An amp's knobs, in the order they sit on its panel.
const AMP_CONTROLS := ["gain", "bass", "mid", "treble", "presence", "master"]

# The effect pedals an amp's board can hold, in the order the pedal menu lists them (audio_core/src/core/pedals.h has
# what each does). Each control is [name, readout, where it starts]: the readout says how its setting reads in real
# units, and "switch" makes it a switch rather than a knob. Knobs run 0 to 10, as printed on a pedal.
const PEDAL_ORDER := ["tuner", "gate", "compressor", "overdrive", "fuzz", "envelope_filter", "chorus", "phaser", "tremolo",
	"delay", "reverb", "plugin"]
const PEDALS := {
	"tuner": {"name": "Tuner", "color": Color(0.3, 0.42, 0.62),
		"about": "Shows the note it hears and how many cents sharp or flat. Mutes the guitar while it is on, unless Mute is off.",
		"controls": [["MUTE", "switch", 1.0]]},
	"gate": {"name": "Noise Gate", "color": Color(0.42, 0.45, 0.5),
		"about": "Silences the hiss and hum between notes: anything quieter than the threshold is shut out.",
		"controls": [["THRESHOLD", "threshold", 3.5], ["RELEASE", "release", 4.0]]},
	"compressor": {"name": "Compressor", "color": Color(0.22, 0.46, 0.88),
		"about": "Evens out loud and soft playing, for sustain and snap. Blend mixes the untouched signal back in.",
		"controls": [["SUSTAIN", "plain", 5.0], ["ATTACK", "attack", 3.0], ["LEVEL", "level", 5.0], ["BLEND", "percent", 10.0]]},
	"overdrive": {"name": "Overdrive", "color": Color(0.27, 0.7, 0.36),
		"about": "A warm, mid-heavy drive that keeps the lows tight. In front of a crunchy amp it pushes it harder.",
		"controls": [["DRIVE", "plain", 5.0], ["TONE", "tone_drive", 5.0], ["LEVEL", "level", 5.0]]},
	"fuzz": {"name": "Fuzz", "color": Color(0.85, 0.24, 0.22),
		"about": "Thick, sustaining fuzz: two clipping stages, and a tone that sweeps from dark to bright through a scooped middle.",
		"controls": [["SUSTAIN", "plain", 6.0], ["TONE", "plain", 5.0], ["VOLUME", "level", 5.0]]},
	"envelope_filter": {"name": "Envelope Filter", "color": Color(0.78, 0.32, 0.7),
		"about": "An auto-wah: a resonant filter that opens the harder you play. Off, the band-pass switch gives a low-pass for funk bass.",
		"controls": [["SENSITIVITY", "plain", 5.0], ["RANGE", "range", 5.0], ["RESONANCE", "q", 5.0], ["BAND-PASS", "switch", 1.0]]},
	"chorus": {"name": "Chorus", "color": Color(0.45, 0.74, 0.95),
		"about": "A slowly wavering copy alongside the guitar, for shimmer. Mix all the way up is vibrato.",
		"controls": [["RATE", "rate_chorus", 4.0], ["DEPTH", "depth_ms", 5.0], ["MIX", "percent", 5.0]]},
	"phaser": {"name": "Phaser", "color": Color(1.0, 0.56, 0.18),
		"about": "Notches swept up and down the sound, for swirl. Resonance makes them sharper.",
		"controls": [["RATE", "rate_phaser", 3.0], ["DEPTH", "plain", 7.0], ["RESONANCE", "plain", 4.0]]},
	"tremolo": {"name": "Tremolo", "color": Color(0.95, 0.8, 0.26),
		"about": "The volume pulsing, from a smooth throb (Shape down) to a hard chop (Shape up).",
		"controls": [["RATE", "rate_tremolo", 5.0], ["DEPTH", "percent", 6.0], ["SHAPE", "plain", 3.0]]},
	"delay": {"name": "Delay", "color": Color(0.8, 0.82, 0.87),
		"about": "Echoes, darker with each repeat. With Sync on, Time picks a note value at the room's tempo. Its echoes ring on after it is switched off.",
		"controls": [["TIME", "time", 5.5], ["REPEATS", "repeats", 4.0], ["MIX", "percent", 4.0], ["TONE", "tone_delay", 5.0], ["SYNC", "switch", 0.0]]},
	"reverb": {"name": "Reverb", "color": Color(0.22, 0.7, 0.68),
		"about": "A room or a hall around the guitar, before it reaches the amp. Its tail rings on after it is switched off.",
		"controls": [["DECAY", "decay", 5.0], ["TONE", "tone_reverb", 5.0], ["MIX", "percent", 3.0]]},
	"plugin": {"name": "Plug-in", "color": Color(0.55, 0.56, 0.62),
		"about": "Holds one of the effect plug-ins installed on this computer, with its own window, before the amp.",
		"controls": []},
}
# What the delay's Time picks with Sync on, at the room's tempo.
const DELAY_NOTES := ["1/16", "1/8 triplet", "1/8", "dotted 1/8", "1/4 triplet", "1/4", "dotted 1/4", "1/2"]


# The two families of instrument. "coming" is a line about what will join the group later.
const GROUPS := [
	{"title": "MIDI instruments",
		"about": "Played from the computer keyboard or a MIDI controller, and each can loop a pattern on the sequencer. A new one starts with an empty pattern.",
		"kinds": ["drums", "bass", "pad", "bells", "keys"], "coming": ""},
	{"title": "Live input",
		"about": "Bring a microphone, or a guitar or bass plugged into your audio interface, into the room. Switch its input on (I) to hear it.",
		"kinds": ["live", "guitar_combo", "guitar_stack", "bass_combo", "bass_stack"], "coming": ""},
]


## A pedal knob's setting in real units, as the audio core reads it. `controls` are all the pedal's settings (the
## delay's Time reads differently with Sync on).
static func pedal_readout(readout: String, value: float, controls: Array = []) -> String:
	var v := clampf(value, 0.0, 10.0)
	var spread := func(low: float, high: float) -> float: return low * pow(high / low, v / 10.0)
	match readout:
		"threshold":
			return "%d dB" % roundi(-80.0 + 6.0 * v)
		"release":
			return _ms(spread.call(0.01, 1.0))
		"attack":
			return _ms(spread.call(0.0005, 0.05))
		"level":
			return "-inf" if v <= 0.0 else "%+.1f dB" % (40.0 * log(v / 5.0) / log(10.0))
		"percent":
			return "%d %%" % roundi(v * 10.0)
		"repeats":
			return "%d %%" % roundi(v * 9.5)
		"tone_drive":
			return _hz(spread.call(700.0, 7000.0))
		"range":
			return _hz(spread.call(600.0, 5000.0))
		"q":
			return "Q %.1f" % spread.call(0.7, 10.0)
		"rate_chorus":
			return "%.2f Hz" % spread.call(0.1, 6.0)
		"rate_phaser":
			return "%.2f Hz" % spread.call(0.05, 6.0)
		"rate_tremolo":
			return "%.1f Hz" % spread.call(1.0, 12.0)
		"depth_ms":
			return "%.1f ms" % (0.4 * v)
		"time":
			if controls.size() > 4 and controls[4] > 0.5:
				return DELAY_NOTES[roundi(v / 10.0 * 7.0)]
			return _ms(spread.call(0.04, 1.5))
		"tone_delay":
			return _hz(spread.call(1200.0, 12000.0))
		"decay":
			return "%.1f s" % spread.call(0.3, 8.0)
		"tone_reverb":
			return _hz(spread.call(1500.0, 12000.0))
	return "%.1f" % v


static func _ms(seconds: float) -> String:
	return "%.1f ms" % (seconds * 1000.0) if seconds < 0.01 else "%d ms" % roundi(seconds * 1000.0)


static func _hz(hz: float) -> String:
	return "%.1f kHz" % (hz / 1000.0) if hz >= 1000.0 else "%d Hz" % roundi(hz)


const NOTE_NAMES := ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]


## A MIDI note's name and octave, as a tuner shows it: 40 is E2, a guitar's open low E.
static func note_name(note: int) -> String:
	return "%s%d" % [NOTE_NAMES[posmod(note, 12)], note / 12 - 1]
