extends RefCounted
## Every kind of instrument that can stand in the room, and how the instrument menu groups them.
##
## For each kind: its name and a line about it, how it looks (colour; how tall its model stands, `top`, and the
## floor it covers, `footprint`, both in metres), the height its sound comes from, how loud it is and how much of
## it goes to the room reverb, and for MIDI instruments the octave the computer keyboard starts in. "live_input"
## marks the kinds that play an audio input rather than notes. scripts/instrument_models.gd draws them.

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
}

# The two families of instrument. "coming" is a line about what will join the group later.
const GROUPS := [
	{"title": "MIDI instruments",
		"about": "Played from the computer keyboard or a MIDI controller, and each can loop a pattern on the sequencer. A new one starts with an empty pattern.",
		"kinds": ["drums", "bass", "pad", "bells", "keys"], "coming": ""},
	{"title": "Live input",
		"about": "Bring a microphone, or an instrument plugged into your audio interface, into the room. Switch a speaker's input on (I) to hear it.",
		"kinds": ["live"], "coming": "Guitar and bass amplifiers will join this group."},
]
