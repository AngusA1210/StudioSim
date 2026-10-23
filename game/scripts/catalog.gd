extends RefCounted
## Every kind of instrument that can stand in the room, and how the instrument menu groups them.
##
## For each kind: its name and a line about it, how it looks (colour; how tall its model stands, `top`, and the
## floor it covers, `footprint`, both in metres), the height its sound comes from, how loud it is and how much of
## it goes to the room reverb, and for MIDI instruments the octave the computer keyboard starts in. "live_input"
## marks the kinds that play an audio input rather than notes, "drum_kit" those whose keys are drums (each key a
## piece), "plugin" the one that plays an instrument plug-in, and "mic" the microphones, which hear the room rather
## than sound in it (their "height" is the capsule's). scripts/instrument_models.gd draws them.
## Then the effect pedals an amp can have in front of it, and how their knobs read.

const KINDS := {
	"drums": {"name": "Drums", "about": "A drum machine, eight pieces in all, one on each key.", "color": Color(1.0, 0.42, 0.26),
		"top": 1.45, "footprint": Vector2(1.5, 1.2), "height": 0.9, "gain": 0.50, "send": 0.6, "drum_kit": true},
	"bass": {"name": "Bass", "about": "A bass synthesizer. Notes hold for as long as the key is down.", "color": Color(0.58, 0.44, 1.0),
		"top": 1.2, "footprint": Vector2(0.8, 0.5), "height": 1.0, "gain": 0.38, "send": 0.4, "octave": -2},
	"pad": {"name": "Pad", "about": "A modular synthesizer: soft, slow chords that swell and fade.", "color": Color(0.25, 0.84, 0.75),
		"top": 1.7, "footprint": Vector2(0.9, 0.5), "height": 1.6, "gain": 1.0, "send": 1.0},
	"bells": {"name": "Bells", "about": "Tubular bells: bright tones that ring and die away.", "color": Color(1.0, 0.82, 0.29),
		"top": 1.96, "footprint": Vector2(0.9, 0.5), "height": 1.6, "gain": 0.42, "send": 1.0, "octave": 1},
	"keys": {"name": "Keys", "about": "An electric piano. A sustain pedal works on it.", "color": Color(1.0, 0.48, 0.82),
		"top": 0.98, "footprint": Vector2(1.2, 0.55), "height": 0.95, "gain": 0.20, "send": 0.9},
	# The acoustic kits, with the drum machine's pieces and keys (a ride on the clap's). As loud played as the drums.
	"garage_drums": {"name": "Garage Kit", "about": "A rock kit played loud: ringing, loose and raw; its own track has a garage's crunch and slap.",
		"color": Color(0.88, 0.16, 0.14), "top": 1.45, "footprint": Vector2(1.6, 1.3), "height": 0.9, "gain": 0.38, "send": 0.6,
		"drum_kit": true},
	"studio_drums": {"name": "Studio Kit", "about": "The same kit in a studio, tuned and damped: punchy, tight and clean.",
		"color": Color(0.6, 0.3, 0.9), "top": 1.45, "footprint": Vector2(1.6, 1.3), "height": 0.9, "gain": 0.45, "send": 0.6,
		"drum_kit": true},
	# One of the instrument plug-ins on the computer, chosen when it is made, and named after it.
	"plugin_synth": {"name": "Plug-in Instrument", "about": "One of your instrument plug-ins: a synthesizer, a sampler, a piano.",
		"color": Color(0.66, 0.72, 1.0), "top": 1.3, "footprint": Vector2(0.9, 0.5), "height": 1.0, "gain": 1.4, "send": 0.8,
		"plugin": true},
	"live": {"name": "Speaker", "about": "Plays an input just as it comes in, from where the speaker stands.", "color": Color(0.55, 0.78, 1.0),
		"top": 1.72, "footprint": Vector2(0.6, 0.6), "height": 1.45, "gain": 1.5, "send": 0.7, "live_input": true},
	# Amps: their output level is set in the audio core, so "gain" is 1. Each has room for a board of effect pedals,
	# the loop pedal among them, on the floor in front.
	"guitar_combo": {"name": "Guitar Combo", "about": "A 1x12 combo for guitar: clean to crunch. With room for pedals.",
		"color": Color(0.95, 0.85, 0.62), "top": 0.56, "footprint": Vector2(0.64, 0.3), "height": 0.3, "gain": 1.0, "send": 0.5,
		"live_input": true, "amp": true, "head": "crunch", "cabinet": "1x12"},
	"guitar_stack": {"name": "Guitar Stack", "about": "A high-gain head on a 4x12 cabinet. With room for pedals.",
		"color": Color(0.95, 0.32, 0.32), "top": 1.1, "footprint": Vector2(0.78, 0.4), "height": 0.4, "gain": 1.0, "send": 0.5,
		"live_input": true, "amp": true, "head": "high_gain", "cabinet": "4x12"},
	"bass_combo": {"name": "Bass Combo", "about": "A 1x15 combo for bass: deep and round. With room for pedals.",
		"color": Color(0.5, 0.88, 0.45), "top": 0.8, "footprint": Vector2(0.58, 0.45), "height": 0.38, "gain": 1.0, "send": 0.4,
		"live_input": true, "amp": true, "head": "bass_round", "cabinet": "1x15"},
	"bass_stack": {"name": "Bass Stack", "about": "A head on an 8x10 cabinet: punchy, with more drive. With room for pedals.",
		"color": Color(0.82, 0.86, 0.95), "top": 1.62, "footprint": Vector2(0.62, 0.48), "height": 0.7, "gain": 1.0, "send": 0.4,
		"live_input": true, "amp": true, "head": "bass_punch", "cabinet": "8x10"},
	# Microphones on boom stands: each a track of its own, recording what the room sounds like where it stands. Each
	# starts as a model (audio_core/src/core/microphones.h has them), which its panel can change; a stereo pair is two,
	# on one stand.
	"mic": {"name": "Measurement Mic", "about": "Flat and omni: it hears the room just as it is, from where it stands.",
		"color": Color(0.86, 0.88, 0.94), "top": 1.4, "footprint": Vector2(0.4, 0.4), "height": 1.2, "gain": 1.0, "send": 0.0, "mic": true,
		"model": "flat"},
	"mic_dynamic": {"name": "Dynamic Mic", "about": "A cardioid dynamic for snare, toms and guitar amps: close up and full, with bite.",
		"color": Color(0.62, 0.66, 0.74), "top": 1.0, "footprint": Vector2(0.4, 0.4), "height": 0.6, "gain": 1.0, "send": 0.0, "mic": true,
		"model": "dynamic"},
	"mic_kick": {"name": "Kick Mic", "about": "A big dynamic for kick drum and bass cabinets: deep lows, the box scooped, the click lifted.",
		"color": Color(0.8, 0.42, 0.4), "top": 0.7, "footprint": Vector2(0.4, 0.4), "height": 0.35, "gain": 1.0, "send": 0.0, "mic": true,
		"model": "kick"},
	"mic_condenser": {"name": "Condenser Mic", "about": "A large-diaphragm condenser: detailed and open, cardioid, omni or figure-8.",
		"color": Color(0.9, 0.78, 0.5), "top": 1.9, "footprint": Vector2(0.4, 0.4), "height": 1.6, "gain": 1.0, "send": 0.0, "mic": true,
		"model": "condenser"},
	"mic_pencil": {"name": "Pencil Mic", "about": "A small-diaphragm condenser for acoustic guitar and cymbals: accurate and even.",
		"color": Color(0.74, 0.86, 0.92), "top": 1.6, "footprint": Vector2(0.4, 0.4), "height": 1.3, "gain": 1.0, "send": 0.0, "mic": true,
		"model": "pencil"},
	"mic_ribbon": {"name": "Ribbon Mic", "about": "A figure-8 ribbon: smooth and dark, front and back alike, big lows close up.",
		"color": Color(0.78, 0.62, 0.86), "top": 1.4, "footprint": Vector2(0.4, 0.4), "height": 1.1, "gain": 1.0, "send": 0.0, "mic": true,
		"model": "ribbon"},
	"mic_pair": {"name": "Stereo Pair", "about": "Two mics on one bar, one stereo track: XY, ORTF, a spaced pair, Blumlein or mid-side.",
		"color": Color(0.6, 0.86, 0.78), "top": 2.2, "footprint": Vector2(0.4, 0.4), "height": 1.9, "gain": 1.0, "send": 0.0, "mic": true,
		"model": "pencil", "stereo": true},
}

# The ways a stereo pair of microphones can be set up, on one bar: each capsule's turn from the way the pair points
# (degrees; positive to the left), how far apart they are (metres: the first on the left), and the patterns they
# want. A spaced pair's spacing can be changed; a mid-side pair's two are a mid (facing ahead) and a side (a figure-8,
# its front to the left), decoded to left and right in its track, as wide as it is set.
const MIC_PAIRS := {
	"xy": {"name": "XY", "about": "Two cardioids at the same point, 90° apart: the image from their angles alone, mono-safe.",
		"turns": [45.0, -45.0], "spacing": 0.0, "patterns": ["cardioid", "cardioid"]},
	"ortf": {"name": "ORTF", "about": "Two cardioids 17 cm apart, 110° apart: their angles and their timing both make the image, as ears do.",
		"turns": [55.0, -55.0], "spacing": 0.17, "patterns": ["cardioid", "cardioid"]},
	"ab": {"name": "Spaced pair (A/B)", "about": "Two omnis side by side, apart by as much as you like: wide and roomy, the image from timing.",
		"turns": [0.0, 0.0], "spacing": 0.6, "patterns": ["omni", "omni"]},
	"blumlein": {"name": "Blumlein", "about": "Two figure-8s at the same point, 90° apart: the front and the room behind in true stereo.",
		"turns": [45.0, -45.0], "spacing": 0.0, "patterns": ["figure8", "figure8"]},
	"ms": {"name": "Mid-side (M/S)", "about": "A mid mic facing ahead and a figure-8 side mic across it, decoded to left and right: as wide as you set it, and perfectly mono-safe.",
		"turns": [0.0, 90.0], "spacing": 0.0, "patterns": ["cardioid", "figure8"], "mid_side": true},
}
const MIC_PAIR_ORDER := ["xy", "ortf", "ab", "blumlein", "ms"]
const MIC_PAIRS_SHORT := {"xy": "XY", "ortf": "ORTF", "ab": "A/B", "blumlein": "BLUMLEIN", "ms": "M/S"}
# The pattern names as they read, and as short as a mix window strip has room for; and the models' short names.
const MIC_PATTERNS := {"omni": "Omni", "cardioid": "Cardioid", "supercardioid": "Supercardioid", "figure8": "Figure-8"}
const MIC_PATTERNS_SHORT := {"omni": "OMNI", "cardioid": "CARD", "supercardioid": "SUPER", "figure8": "FIG-8"}
const MIC_MODELS_SHORT := {"flat": "FLAT", "dynamic": "DYN", "kick": "KICK", "condenser": "LDC", "pencil": "SDC", "ribbon": "RIBBON"}

# An amp's knobs, in the order they sit on its panel.
const AMP_CONTROLS := ["gain", "bass", "mid", "treble", "presence", "master"]

# An amp's heads and cabinets (audio_core/src/core/amp.h): any head with any cabinet, and either can be bypassed.
# [what the audio core calls it, its name, a line about it]
const AMP_HEADS := [
	["clean", "Clean", "Lots of headroom: clean and bright until it is pushed hard."],
	["crunch", "Crunch", "Clean at low gain, breaking up into crunch as Gain goes up."],
	["high_gain", "High Gain", "Two gain stages and tight lows, for heavy rhythm and lead."],
	["bass_round", "Bass: Round", "Deep and round, with gentle drive."],
	["bass_punch", "Bass: Punch", "Punchy, with more top end, and more drive to give."],
]
const AMP_CABINETS := [
	["1x12", "1x12 open back", "One 12-inch speaker in an open back: lighter lows, a sweet top."],
	["2x12", "2x12 open back", "Two 12s, open-backed: fuller than the 1x12, still airy."],
	["4x12", "4x12 closed back", "Four 12s in a closed box: a firm low thump and a midrange bite."],
	["1x15", "1x15 bass", "One 15-inch: deep and soft on top."],
	["4x10", "4x10 bass", "Four 10s: tight, punchy lows and more top end."],
	["8x10", "8x10 bass", "Eight 10s: big lows and a growl in the mids."],
]
# The speakers a cabinet can hold, of its size (audio_core/src/core/amp.h has how each sounds): [id, name, size in
# inches, about]. Each is rated for so many watts: a head of more turned up drives them into compression and breakup.
const AMP_SPEAKERS := [
	["british_25", "British 25 W", 12, "Warm and mid-forward, with a soft top. 25 W each: a small combo turned up pushes them into breakup."],
	["british_60", "British 60 W", 12, "The low mids pulled back and an aggressive upper-mid bite. 60 W each: hard to push."],
	["american_vintage", "American vintage", 12, "Scooped, with a sparkly top and loose lows. 20 W each: they break up early."],
	["british_alnico", "British alnico", 12, "Chiming and bright, sweet on top. 15 W each: the first to compress and break up."],
	["american_10", "American 10", 10, "Bright and tight. 25 W each."],
	["bass_10", "Bass 10", 10, "Punchy, a growl in the mids, an extended top. 250 W each."],
	["bass_15", "Bass 15", 15, "Deep, and soft on top. 400 W."],
]
const CABINET_INCHES := {"1x12": 12, "2x12": 12, "4x12": 12, "1x15": 15, "4x10": 10, "8x10": 10}
const CABINET_SPEAKERS := {"1x12": "american_vintage", "2x12": "british_alnico", "4x12": "british_60", "1x15": "bass_15",
	"4x10": "bass_10", "8x10": "bass_10"}  # each cabinet's usual speakers


## The speakers a cabinet can hold: those of its size.
static func speakers_for(cabinet: String) -> Array:
	return AMP_SPEAKERS.filter(func(s): return s[2] == CABINET_INCHES.get(cabinet, 12))


static func speaker_fits(speaker: String, cabinet: String) -> bool:
	return speakers_for(cabinet).any(func(s): return s[0] == speaker)

# The effect pedals an amp's board can hold, in the order the pedal menu lists them (audio_core/src/core/pedals.h has
# what each does). Each control is [name, readout, where it starts]: the readout says how its setting reads in real
# units, and "switch" makes it a switch rather than a knob. Knobs run 0 to 10, as printed on a pedal.
const PEDAL_ORDER := ["tuner", "gate", "compressor", "overdrive", "fuzz", "envelope_filter", "chorus", "phaser", "tremolo",
	"delay", "reverb", "looper", "plugin"]
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
	"looper": {"name": "Loop Pedal", "color": Color(0.2, 0.22, 0.26),
		"about": "Records what reaches it and plays it round and round, with overdubs on top. One to an amp; L, O, U and J work it.",
		"controls": [["LEVEL", "level", 5.0], ["SYNC", "switch", 1.0], ["OVERDUB AFTER RECORDING", "switch", 0.0]]},
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
		"kinds": ["drums", "garage_drums", "studio_drums", "bass", "pad", "bells", "keys", "plugin_synth"], "coming": ""},
	{"title": "Live input",
		"about": "Bring what you plug into your audio interface (your own microphone, a guitar, a bass) into the room. Switch its input on (I) to hear it.",
		"kinds": ["live", "guitar_combo", "guitar_stack", "bass_combo", "bass_stack"], "coming": ""},
	{"title": "Microphones",
		"about": "Placed anywhere in the room, a microphone hears it from where it stands (the instruments as they reach it, with the walls and the reverb) and records that. Arm it (R) to record it; its input on (I) lets you hear it.",
		"kinds": ["mic_dynamic", "mic_kick", "mic_condenser", "mic_pencil", "mic_ribbon", "mic_pair", "mic"], "coming": ""},
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
