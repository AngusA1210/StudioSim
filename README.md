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
| W A S D, mouse | move, look (click to capture the mouse) |
| Shift | run |
| G or click | pick up the instrument you're facing, put it down |
| N | the instrument menu: add an instrument to the room |
| Backspace, twice | remove the instrument you're facing or carrying |
| E | play the instrument you're next to; Q stops |
| A S D F G H J K L ; | white keys while playing (W E T Y U O P are the black keys, Z/X change octave) |
| MIDI keyboard | plays the instrument you are playing, with velocity (and the sustain pedal on the Keys); plug in any time |
| Tab | open the pattern editor for the instrument you're next to or playing (at a Speaker: choose its input) |
| M | switch that instrument's loop off or on (for a Speaker: mute) |
| Space | start or stop every instrument's pattern |
| C | metronome click on/off |
| Esc | the menu (see below), including the room's size and walls; the music keeps playing while it's open |
| I | live input on/off: your microphone or audio interface comes out of the Speaker (macOS asks for permission once) |
| B | binaural on/off (compare with plain stereo) |
| R | room reverb on/off |

## Instruments

There are two families of instrument, and the instrument menu (N) adds either to the room, up to 32 in all:

- **MIDI instruments** (drums, bass, pad, bells, keys) are played from the computer keyboard or a MIDI controller,
  and each can loop a pattern on the sequencer.
- **Live inputs** bring a microphone, or an instrument plugged into the audio interface, into the room. For now
  that means the Speaker, which plays an input just as it comes in; guitar and bass amplifiers will join it.

Pick one and it appears in your hands: walk it to where it should stand and click to put it down. A new MIDI
instrument starts with an empty pattern, so it is silent until you play it or write it a pattern (the pattern editor
can load the default one). A new Speaker plays the hardware input chosen in the menu, which can be changed later on
the I/O page; several Speakers can each play a different input. A second instrument of a kind is numbered and a
paler colour, to tell them apart. Like the tempo and the patterns, the instruments you add are not saved yet.

## Levels

The Mixer page of the menu is where levels are managed, in decibels:

- **Instruments**: a fader for everything in the room. 0 dB is the level an instrument was made at; a small meter
  beside each shows it as heard from right next to it.
- **Distance**: an instrument is at its own level within 1.5 m of it and gets no louder however close you stand.
  Beyond that it falls by a set amount for each doubling of distance: 3 dB by default, adjustable from 0 to 6. (6 dB
  is the figure for a single source in the open air. In a room the reverberation makes up some of that loss, and the
  gentler default keeps levels more even as you move about.)
- **Master**: the output volume, a stereo meter with peak hold, and the limiter. With the limiter on, the output
  cannot clip, and the page says by how many decibels it is being held back whenever it is: the cue to turn
  something down. With it off, the output is the plain sum of the mix, as on a mixing desk's master fader, and
  anything over full scale is cut off and reported as clipping.

A small master meter also sits on screen in the room (it can be switched off in Settings). It reads "limit" or
"CLIP" when either is happening.

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
computer keyboard becomes a small piano for it, and any MIDI controller plays it too. With nobody at an instrument a
MIDI controller plays nothing. The drums are a drum machine: each key is a drum, laid out like a General MIDI kit
(C kick, D snare, F# closed hat, A# open hat, F and A toms, D# clap, C# crash) and repeated in every octave.

Each instrument also has a pattern that the sequencer loops. The room starts with the default groove. Press Tab at
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
- **Mixer**: a fader for each instrument, the distance falloff, the master volume, meter and limiter (see above).
- **Room**: the room's size and the walls inside it (see above).
- **Playback Engine**: which output device the audio engine runs on, and the hardware buffer size (32–1024 samples).
  The sample rate follows the device. Shows the resulting latency (the buffer, the device, and the quarter of a
  buffer that binaural rendering adds while it is switched on) and CPU use.
- **I/O**: which of the device's outputs carry the mix, the input device, and which hardware input each Speaker plays.
  Live input always starts switched off, so an open microphone never meets a pair of speakers by surprise.
- **MIDI**: every MIDI device the system sees, with a tick box each and a light that flashes when it sends notes.
- **Settings**: binaural, reverb, text size, field of view, mouse sensitivity, room lighting, and whether the
  master meter and the audio readout are shown on screen.

Choices are saved (Godot's user data folder, `settings.cfg`) and restored at the next start. If a saved device
isn't connected, the system default is used until it is.

## How it's put together

```
game/                      Godot project: the room, player, instruments, HUD, menus and pattern editor (GDScript)
  scripts/catalog.gd       every kind of instrument and the two groups the instrument menu shows them in
  scripts/room.gd          the room's floor, ceiling and walls, built to whatever size and layout is set
audio_core/
  src/core/                the audio engine, plain C++ with no Godot dependency
    engine.*               device, command queue, mixing, the shared clock
    instruments.*          synthesized drums, bass, pad, bells and keys (each playable live or by pattern), live input
    sequencer.*            the clock (tempo, swing), pattern notes, and the default groove, scheduled to the exact sample
    spatializer.*          Steam Audio: distance, air absorption, wall filtering, binaural (HRTF)
    room_geometry.*        the walls: which way round them sound reaches the listener, and how much further that is
    acoustics.h            how much each frequency band dims when sound bends around a wall edge
    midi_input.*           MIDI controllers, read straight into the audio thread (CoreMIDI; other platforms to do)
    mix.*                  room reverb (feedback delay network, sized to the room) and output limiter
                           (the output meter and the distance law live in engine.* and spatializer.*)
  src/godot/               the Godot extension wrapping the engine (SoundRoomAudio node)
  tests/engine_tests.cpp   offline checks: levels, binaural direction, walls, latency, MIDI, live input, sequencer
game/tests/ui_check.gd     the game driven by pretend keys and clicks: title, playing, patterns, instruments, room, menus
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
- `audio_core/build/engine_tests --dump before.f32` writes what the default room plays as raw samples. Dump before
  and after a change to the engine and compare the files to see whether the sound changed.

## Roadmap

Done so far: the native audio pipeline, instruments that can be added, placed and removed and each played from the
keyboard or a MIDI controller, a pattern sequencer with tempo, swing and a metronome, live audio input through
Speakers, a title screen, and a room whose size and walls can be changed, with sound bending round the walls and a
reverb that follows the size.

To do, roughly in this order:

1. **Templates**: save and load a room's dimensions and walls, its instrument layout, and their sequences (and the
   tempo). Choosing one will go on the title screen.
2. **Guitar and bass amplifiers** with controls that work the way real amps do: combo amps, and heads with
   separate cabinets. They join the live-input group of the instrument menu. (The Speaker is the plain, uncoloured
   way to hear an input until then.)
3. **Recording.**
4. **Plug-in hosting**, if it proves practical.
5. **Multiplayer**, the final goal: a session server, a networked clock, note events and low-latency audio streams.

Also wanted along the way: MIDI on Windows and Linux, and VR through OpenXR.

## Third-party

- [Godot Engine](https://godotengine.org) and [godot-cpp](https://github.com/godotengine/godot-cpp) (MIT)
- [Steam Audio](https://github.com/ValveSoftware/steam-audio) (Apache 2.0)
- [miniaudio](https://github.com/mackron/miniaudio) (public domain / MIT-0)
