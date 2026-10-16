# SoundRoom

A shared 3D space for playing music together. Instruments sit in a room, you walk around it in first person,
and everything you hear is rendered binaurally from where you stand and which way you face.

So far it is one player in one room with the full audio pipeline: instruments you can walk up to and play, a
sequencer that loops a pattern on each of them, and live input from a microphone or audio interface. Saving rooms,
recording, amplifiers and multiplayer come later (see the roadmap below).

## Build and run (macOS)

Needs Xcode command-line tools, CMake, git, and Godot 4.5 or newer (`brew install --cask godot`).

```bash
tools/build.sh
godot --path game
```

`tools/build.sh` fetches the libraries that aren't kept in git (Steam Audio, miniaudio), builds the audio core and
the Godot extension, runs the offline audio checks, registers the extension with the Godot project, and then runs
the game silently with pretend key presses and clicks to check the controls and menus (`game/tests/ui_check.gd`).
Open `game/project.godot` in the Godot editor to work on the scene and scripts.

Use **wired** headphones. Bluetooth headphones add 150–250 ms of delay that no software can remove; the
"Output latency" readout shows what your current device adds.

The game opens on a title screen with the room already playing behind it. From there you can check which device
the sound is going to (and be warned if it is one that adds delay, such as Bluetooth), open the audio setup and
settings, and enter the room. The menu inside the room has a button to come back to it.

## Controls

| Key | Action |
| --- | --- |
| W A S D, mouse | move, look (click to capture the mouse); the arrow keys walk and turn too |
| Shift | run |
| G or click | pick up the instrument you're facing, put it down (it turns to face you) |
| N | the instrument menu: add an instrument to the room |
| Backspace, twice | remove the instrument you're facing or carrying |
| E | play the instrument you're next to; Q stops |
| A S D F G H J K L ; | white keys while playing (W E T Y U O P are the black keys, Z/X change octave) |
| K | the keyboard: the letter keys play every instrument whose input is on, from wherever you stand. The arrow keys walk and turn meanwhile; Q or Esc closes it |
| I | that instrument's input on/off (see below) |
| MIDI keyboard | plays every instrument whose input is on, with velocity (and the sustain pedal on the Keys); plug in any time |
| Enter | open the pattern editor for the instrument you're next to or playing (at an amp: its knobs and pedals; at a Speaker: its volume and input) |
| M | switch that instrument's loop off or on (for a Speaker or an amp: mute) |
| L O U J | at an amp with a loop pedal: L the footswitch (record, close the loop, overdub), O stop or play, U undo or redo the last overdub, J twice to clear |
| 1 to 8 | at an amp, stamp on its pedals: each switches that pedal on or off (the loop pedal: its footswitch) |
| Tab | the mix window (you can still walk about while it is open) |
| Space | start or stop every instrument's pattern |
| C | metronome click on/off |
| Esc | the menu (see below), including the room's size and walls; the music keeps playing while it's open |
| B | binaural on/off (compare with plain stereo) |
| R | room reverb on/off |

Facing an instrument, a card at the right of the screen lists what each key does to it.

Every key here can be changed on the **Controls** page of the menu: click an action's key, then press the new one
(an action that had it takes the old key). Esc, the arrow keys, 1 to 8 and the note keys stay as they are. While you
are at an instrument or have the keyboard open, the note keys are notes, and whatever else they are given waits until
you get up or close it.

## Instruments

There are two families of instrument, and the instrument menu (N) adds either to the room, up to 32 in all:

- **MIDI instruments** (drums, bass, pad, bells, keys) are played from the computer keyboard or a MIDI controller,
  and each can loop a pattern on the sequencer.
- **Live inputs** bring a microphone, or an instrument plugged into the audio interface, into the room: the Speaker,
  which plays an input just as it comes in, and four guitar and bass amplifiers, each with a board of pedals in
  front of it (see below).

Each is drawn as its real counterpart, standing on the floor: a drum kit, a bass synthesizer, a modular synthesizer
for the pad, tubular bells, an electric piano, a PA speaker on a tripod, and the amps with their pedals in front of
them. The parts in the instrument's colour light up as it plays.

Pick one and it appears in your hands: walk it to where it should stand and click to put it down. A new MIDI
instrument starts with an empty pattern, so it is silent until you play it or write it a pattern (the pattern editor
can load the default one). A new Speaker plays the hardware input chosen in the menu, which can be changed later in
its mix window strip or on the I/O page; several Speakers can each play a different input. A Speaker's own
**volume** (Enter at it, or click its name in the mix window) goes up to +24 dB, as on a big powered PA speaker, so that
it can fill a large room; it comes after the Speaker's inserts and before its fader. A second instrument of a kind is numbered and a
paler colour, to tell them apart. Like the tempo and the patterns, the instruments you add are not saved yet.

### Inputs

Every instrument has an input that can be on or off, as a track's input is in a DAW, and a green **i** under its
name shows when it is on. A MIDI instrument with its input on plays what the MIDI keyboard sends; several can be on
at once, so one keyboard can play a layer of instruments. A Speaker with its input on plays its hardware input; the
audio input opens when the first Speaker's input goes on and closes when the last goes off.

Sitting down at an instrument (E) switches its input on until you get up, so the MIDI keyboard plays whatever you are
at. Switch an input on yourself (I, or the I button in the mix window) and it stays on when you walk away. The
computer keyboard plays the instrument you are sitting at, along with any others whose input is on. Every input
starts switched off, so an open microphone never meets a pair of speakers by surprise.

### Amps, pedals and the loop pedal

An amp is a **head** and a **cabinet**, and any head goes with any cabinet. The four in the instrument menu start as a
Crunch head in a 1x12 combo (Guitar Combo), a High Gain head on a 4x12 (Guitar Stack), a Bass Round 1x15 combo (Bass
Combo) and a Bass Punch head on an 8x10 (Bass Stack); the amp panel (Enter) changes either, and the amp in the room is
drawn with the cabinet it has.

| Head | | Cabinet | |
| --- | --- | --- | --- |
| Clean | lots of headroom, clean and bright | 1x12 open back | lighter lows, a sweet top |
| Crunch | clean at low gain, crunch as Gain goes up | 2x12 open back | fuller, still airy |
| High Gain | two gain stages, tight lows | 4x12 closed back | a firm low thump and a midrange bite |
| Bass: Round | deep and round, gentle drive | 1x15 bass | deep, soft on top |
| Bass: Punch | punchy, more top end and drive | 4x10 bass | tight lows, more top |
| | | 8x10 bass | big lows, a growl in the mids |

The cabinets are how the speakers sound in the room, as you hear them standing in front of the amp, rather than how a
microphone pressed against the cone hears them: no close-miking's boomy lows or bright peak, only the speakers' own
response. Either part can be **bypassed**. Without its head, the amp plays whatever reaches it straight through the
cabinet, so an amp plug-in on a Plug-in pedal can be the head; without its cabinet, it is a flat, full-range speaker,
for a plug-in that brings its own cabinet.

The head has the knobs of a real amp, 0 to 10: **Gain** (how hard the preamp is driven, from clean into distortion),
**Bass**, **Middle** and **Treble** (flat at 5), **Presence** (the top end the power amp lets through) and **Master**
(the amp's volume: 5 is unity, 10 is +12 dB, and it works with the head bypassed too). Enter, facing an amp,
opens its panel: drag a knob up or down (Shift for fine moves), turn the scroll wheel over it, or double-click it for
5. The panel also has the amp's input switch and which hardware input it plays. Plug a guitar or bass straight into
the interface's instrument input; the amp is the only processing it needs. Wear headphones.

#### Effect pedals

An amp starts with an empty board. The amp panel's **Pedalboard** runs the way the signal does: from the input through
up to eight pedals, in order, then the amp. **+ Pedal** adds one at the end of the line; click a pedal to set it up
underneath, where its knobs read in real units (decibels, milliseconds, hertz), **Earlier** and **Later** move it
along the board, and its footswitch, or its number key (1 to 8, in the panel or facing the amp in the room), switches
it on or off. A pedal switched off passes the guitar through untouched. The pedals stand on the floor in front of the
amp, each with a light that is lit while it is on.

| Pedal | Controls | What it does |
| --- | --- | --- |
| Tuner | Mute | Shows the note and how many cents sharp or flat, on the panel and over the amp, to within a cent, from a five-string bass's low B up. Mutes the guitar while it is on, unless Mute is off. |
| Noise Gate | Threshold, Release | Shuts out the hiss and hum between notes. |
| Compressor | Sustain, Attack, Level, Blend | Evens out loud and soft playing; Blend mixes the untouched signal back in. |
| Overdrive | Drive, Tone, Level | A warm, mid-heavy drive that keeps the lows tight, for pushing an amp harder. |
| Fuzz | Sustain, Tone, Volume | Two clipping stages and a tone that sweeps through a scooped middle. |
| Envelope Filter | Sensitivity, Range, Resonance, Band-pass | An auto-wah: the filter opens the harder you play. Off, the switch gives a low-pass, for funk bass. |
| Chorus | Rate, Depth, Mix | A slowly wavering copy beside the guitar; Mix at 10 is vibrato. |
| Phaser | Rate, Depth, Resonance | Notches swept up and down. |
| Tremolo | Rate, Depth, Shape | The volume pulsing, from a smooth throb to a hard chop. |
| Delay | Time, Repeats, Mix, Tone, Sync | Echoes that darken with each repeat. With Sync on, Time picks a note value (a sixteenth up to a half, triplets and dotted notes too) at the room's tempo. |
| Reverb | Decay, Tone, Mix | A room or hall before the amp. |
| Loop Pedal | Level, Sync, Overdub after recording | Records what reaches it and plays it round and round (see below). One to an amp. |
| Plug-in | (its own window) | One of the effect plug-ins installed on your Mac, before the amp (see Plug-ins below). |

Delay and Reverb let their echoes and tail ring on after they are switched off, as many real ones do.

#### The loop pedal

Put one on an amp's board from **+ Pedal** (an amp can have one). It records the guitar as audio, not notes, as it
reaches it: a loop keeps the effects before it on the board, and plays through the pedals after it and through the
amp's current knobs, so where it stands on the board is up to you, as on a real one (at the end of the line is
usual). It works like a single-track looper pedal:

- **L, the footswitch** (or its number key): the first press starts recording, the second closes the loop and plays it, and from then on
  each press starts or stops an overdub laid on top. Pressing it on an empty pedal switches the amp's input on.
- **K** stops the loop, or plays it again from the top. **U** undoes the last overdub, and redoes it. **J**, pressed
  twice, clears the loop.
- On the amp panel (click it on the board) it has the same controls as buttons, a display of what the pedal is doing and where it is in the loop,
  and its options: **Loop level**, **Sync to the bars** (on at first: while the patterns are running, recording
  starts on the next bar line and a loop is a whole number of bars, so it stays in time with them; with the
  patterns stopped, or Sync off, it starts and ends the moment you press) and **After recording** (play the loop, or
  go straight into an overdub).

A loop can be up to 90 seconds long. The pedal's light and the label under the amp's name show recording, playing
and overdubbing from across the room. Loops survive a change of buffer size, but changing the sample rate clears
them, and like everything else they are not saved yet. Taking the loop pedal off the board takes its loop with it, so
with a loop recorded that takes a second press.

## Plug-ins

SoundRoom hosts the effect plug-ins installed on your Mac as Audio Units: the format plug-in makers install alongside
their Pro Tools (AAX) and VST3 versions. They go on a channel's **inserts** in the mix window (on any instrument) or
on an amp's **Plug-in pedal** (before the amp). Either way the plug-in browser opens: your plug-ins grouped **by type**
(EQ, dynamics, delay, reverb, amps and cabinets...) or **by maker**, with a search box. Choose one and its own window
opens, floating over the room. Plug-ins get the room's tempo, for those that keep time.

Most plug-ins don't say what kind of effect they are, so the types are worked out from their names: a good guess, not
a certainty (`audio_core/build/engine_tests --plugins` lists what each was taken for). By maker is always exact. A
plug-in that only comes as AAX can't be used, since only Pro Tools can host those. Plug-ins run inside SoundRoom as
they would inside a DAW, so one that crashes takes SoundRoom with it, and like the rest of the room their settings
aren't saved yet. Each instrument is a single point of sound in the room, so a plug-in's stereo output is heard as
one channel, from where the instrument stands.

**Amp simulators** (TONE3000 and other amp and cabinet models) work in two ways:

- **As the head of one of SoundRoom's amps**: put the simulator on the amp's Plug-in pedal, bypass the amp's head, and
  keep its cabinet. This suits a model of an amp alone, and gives you the pedals in front of it and a cabinet heard as
  it would be in the room. A model that includes a miked cabinet carries that microphone's sound with it; bypass the
  amp's cabinet for those, or use an amp-only model and let SoundRoom's cabinet do the rest.
- **On a Speaker**: the Speaker plays its input as it comes in, so with the simulator on its first insert the Speaker
  is the amp, sounding from where it stands, full range. Put it where the amp should stand, pick the interface input
  the guitar is plugged into, and switch its input on.

## The mix window

Tab opens the mix window, docked along the bottom of the screen so the room stays in view. It is laid out like a
mixing desk: a channel strip for every instrument, side by side, and the master strip on the right.

- **Names**: click a strip's name to open the instrument's own window (an amp's knobs and pedals, a pattern, a
  Speaker's panel); the mix window comes back when it closes. Right-click the name to remove the instrument from the
  room.
- **Inserts** at the top of each strip, A to E, as in Pro Tools: plug-ins played in order on the instrument's sound
  before its fader (on an amp, after its pedals and the amp). Click an empty one to choose a plug-in, a full one to
  open or close its window, Cmd-click (or Ctrl-click) to bypass it, which turns it blue, and right-click to replace or
  remove it. Drag one to another slot, on its own strip or another instrument's, to move it there (it swaps places
  with whatever was there); hold Option as you drop it to copy it instead, settings and all. Closing the mix window
  puts the plug-in windows away.
- **Each strip**: the input (MIDI, or a list of hardware inputs for a Speaker or an amp), buttons for input (I),
  mute (M) and solo (S), a fader with the strip's meter beside it, and under the fader its level and its peak
  readout, then the instrument's name in its colour. Faders run from +12 dB down to silence, spaced as on a console.
  Drag one to move it (Shift for fine moves), turn the scroll wheel to nudge it, or double-click or Alt-click it for
  0 dB. 0 dB is the level the instrument was made at, heard from right beside it, and the strip's meter reads it at
  that level, as a DAW's track meter reads what the track sends to the master.
- **Pre-fader meters** (in the window's header): the channel meters read before the fader, after the inserts, as
  Pro Tools' pre-fader metering does. Off, they read after it.
- **Peak readouts**: as in Pro Tools, the number beside each fader's level holds the highest peak (in dBFS) until
  you click it, and turns red once anything reaches full scale. Clicking a meter clears it too; Alt-click clears
  every one, the master's included.
- **Master**: LIMIT, the master fader with a stereo meter, and the output's peak readout. The master is laid out as
  a DAW's master track: the limiter is an insert, so it comes before the fader and works just as hard wherever the
  fader is. With it on, the mix can't reach full scale on its way to the fader, and the window says by how many
  decibels it is being held back whenever it is: the cue to bring an instrument down. With it off, the mix is the
  plain sum of the instruments. Either way, whatever leaves the master fader over full scale is cut off and
  reported as clipping, so a master pushed above 0 dB can clip even with the limiter on.

The output is set to leave headroom right beside an instrument, so from across the room the mix is fairly quiet:
raise the master to taste and watch the meter. An instrument is at its own level within 1.5 m of it and gets no
louder however close you stand; beyond that it falls 6 dB for each doubling of distance, as the inverse square law
has it. That can be made gentler (down to 0, where distance makes no difference) under Distance falloff in the
Settings page of the menu.

In the room, the master meter stands at the top right of the screen (it can be switched off in Settings). Under it
is the recent peak, or "limit" or "CLIP" when either is happening. Beside the tempo, two lamps show whether
binaural rendering (B) and the room reverb (R) are on.

## The room

The Room page of the menu changes the room itself, while the music plays:

- **Size**: width and length from 4 to 40 m, height from 2.4 to 12 m. The reverb follows: a bigger room rings for
  longer but more quietly, a small one is short and close. Instruments, walls and you are brought inside if the room
  shrinks past them.
- **Walls**: a floor plan of the room, seen from above with the instruments and yourself marked on it. Drag on the
  floor to draw a wall, drag a wall to move it, drag the dot at either end to turn and stretch it. Walls can stand at
  any angle and there can be up to 16. Each has its own height.

Sound finds its way round the walls. Behind one, an instrument is duller and seems to come from the edge its sound
bends round; the longer the detour, the duller it gets, highs first. A wall lower than the ceiling also lets sound
over the top. Walls that meet close the gap between them, so four walls to the ceiling make a booth that all but
shuts an instrument away, and a wall built out from the side of the room can only be passed at its free end.

The room is lit by a grid of lamps that grows with it, so a large room is no darker than the default one. Settings
has a Room lighting slider if it is still too dim or too bright for your screen.

The room goes back to the default each time SoundRoom starts, until rooms can be saved.

## Playing and sequencing

Every MIDI instrument in the room can be played by hand. Walk up to one and press E: the
computer keyboard becomes a small piano for it, and any MIDI controller plays it too (see Inputs, above). The drums
work like a drum machine: each key is a drum, laid out like a General MIDI kit
(C kick, D snare, F# closed hat, A# open hat, F and A toms, D# clap, C# crash) and repeated in every octave.

Each instrument also has a pattern that the sequencer loops. The room starts with the default groove. Press Enter at
an instrument to edit its pattern on a step grid, one bar at a time:

- click a square to add a note, click a note to remove it, right-click a note to step through loud, medium, soft
  and "now and then" (a soft note that plays one time in four)
- a pattern repeats every one, two or four bars; melodic instruments choose how long new notes last
- M (or the Loop switch) stops an instrument playing its pattern, so you can play it yourself

All patterns follow one tempo (40 to 240 BPM) with adjustable swing. The metronome click marks each beat, higher on
the first beat of the bar, and plays straight into your ears rather than from a place in the room. The tempo and the
patterns go back to the defaults at each start until rooms can be saved.

## The menu

- **Metronome**: start and stop the patterns, tempo, swing, the click and its volume.
- **Room**: the room's size and the walls inside it (see above).
- **Playback Engine**: which output device the audio engine runs on, and the hardware buffer size (32–1024 samples).
  The sample rate follows the device. Shows the resulting latency (the buffer, the device, and the quarter of a
  buffer that binaural rendering adds while it is switched on) and CPU use.
- **I/O**: which of the device's outputs carry the mix, the input device, and which hardware input each Speaker plays.
  Live input always starts switched off, so an open microphone never meets a pair of speakers by surprise.
- **MIDI**: every MIDI device the system sees, with a tick box each and a light that flashes when it sends notes.
- **Settings**: binaural, reverb, distance falloff, text size, field of view, mouse sensitivity, room lighting, full screen (which
  SoundRoom then opens in every time), and whether the master meter and the audio readout are shown on screen.

Choices are saved (Godot's user data folder, `settings.cfg`) and restored at the next start. If a saved device
isn't connected, the system default is used until it is.

## How it's put together

```
game/                      Godot project: the room, player, instruments, HUD, menus, mix window, pattern editor (GDScript)
  scripts/catalog.gd       every kind of instrument and the two groups the instrument menu shows them in
  scripts/room.gd          the room's floor, ceiling and walls, built to whatever size and layout is set
  scripts/instrument_models.gd   what each instrument looks like, built from simple shapes
  scripts/mixer.gd         the mix window: channel strips, faders (fader.gd) and meters (level_meter.gd)
  scripts/amp_panel.gd     an amp's knobs (knob.gd) and its pedalboard
  scripts/plugin_browser.gd  the plug-ins installed, by type or by maker, for an insert or a Plug-in pedal
audio_core/
  src/core/                the audio engine, plain C++ with no Godot dependency
    engine.*               device, command queue, mixing, the shared clock
    instruments.*          synthesized drums, bass, pad, bells and keys (each playable live or by pattern), live input
    amp.*                  the guitar and bass amps: preamp drive (oversampled), tone stack, presence, cabinet
    looper.*               the loop pedal: record, overdub, undo/redo, synced to the bars
    pedals.*               the pedals in front of an amp: tuner, gate, compressor, drives, modulation, delay, reverb, looper
    plugin_host*           the effect plug-ins installed on the computer: Audio Units on macOS, and their windows
    plugin_category.cpp    what kind of effect a plug-in seems to be, from its name
    sequencer.*            the clock (tempo, swing), pattern notes, and the default groove, scheduled to the exact sample
    spatializer.*          Steam Audio: distance, air absorption, wall filtering, binaural (HRTF)
    room_geometry.*        the walls: which way round them sound reaches the listener, and how much further that is
    acoustics.h            how much each frequency band dims when sound bends around a wall edge
    midi_input.*           MIDI controllers, read straight into the audio thread (CoreMIDI; other platforms to do)
    mix.*                  room reverb (feedback delay network, sized to the room) and output limiter
                           (the output meter and the distance law live in engine.* and spatializer.*)
  src/godot/               the Godot extension wrapping the engine (SoundRoomAudio node)
  tests/engine_tests.cpp   offline checks: levels, binaural direction, walls, latency, MIDI, live input, sequencer, amps, pedals, plug-ins, loop pedal
game/tests/ui_check.gd     the game driven by pretend keys and clicks: title, playing, patterns, instruments, amps, room, menus
prototypes/sound-room/     the original browser prototype, for reference
tools/                     build and dependency scripts
```

Godot owns the world: rendering, input, physics, and where the walls and instruments are. It tells the audio core
the room's size and walls, where each instrument and the listener are, and the notes and pattern edits. The audio
core works out how sound travels through that room: which way round the walls each instrument is heard, and how the
room rings. Commands reach the audio thread through a lock-free queue, so the game never waits on it. MIDI controllers and the audio input bypass Godot entirely and go straight into the audio core. The audio core runs
on its own real-time thread with 128-sample blocks, so a dropped game frame never glitches the sound.

Diagnostics that don't need the game:

- `audio_core/build/engine_tests --device` lists the audio devices, opens the default output silently and prints the
  latency it reports. Add a device name and buffer size to try another: `--device "Volt 476" 64`.
- `audio_core/build/engine_tests --midi` lists MIDI devices and reports what they send for 15 seconds.
- `audio_core/build/engine_tests --plugins` lists the effect plug-ins installed, with the type each was taken for.
- `audio_core/build/engine_tests --dump before.f32` writes what the default room plays as raw samples. Dump before
  and after a change to the engine and compare the files to see whether the sound changed.

## Roadmap

Done so far: the native audio pipeline, instruments that can be added, placed and removed and each played from the
keyboard or a MIDI controller, a pattern sequencer with tempo, swing and a metronome, live audio input through
Speakers, guitar and bass amps with boards of effect pedals (a loop pedal and a plug-in pedal among them), a title
screen, a mix window laid out like a DAW's with plug-in inserts on every channel, and a room whose size and walls
can be changed, with sound bending round the walls and a reverb that follows the size.

To do, roughly in this order:

1. **Templates**: save and load a room's dimensions and walls, its instrument layout, and their sequences (and the
   tempo). Choosing one will go on the title screen.
2. **Recording.**
3. **More plug-ins**: inserts on the master, plug-in settings saved with the room (with templates), and perhaps VST3
   and Windows.
4. **The room's sound**: a reverb amount you can set, then wall materials, each absorbing and diffusing sound in its
   own way, which shape how the room's reverb rings.
5. **Multiplayer**, the final goal: a session server, a networked clock, note events and low-latency audio streams.

Also wanted along the way: MIDI on Windows and Linux, and VR through OpenXR.

## Third-party

- [Godot Engine](https://godotengine.org) and [godot-cpp](https://github.com/godotengine/godot-cpp) (MIT)
- [Steam Audio](https://github.com/ValveSoftware/steam-audio) (Apache 2.0)
- [miniaudio](https://github.com/mackron/miniaudio) (public domain / MIT-0)
