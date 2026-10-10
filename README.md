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

## Controls

| Key | Action |
| --- | --- |
| W A S D, mouse | move, look (click to capture the mouse) |
| Shift | run |
| G or click | pick up the instrument you're facing, put it down |
| E | play the instrument you're next to; Q stops |
| A S D F G H J K L ; | white keys while playing (W E T Y U O P are the black keys, Z/X change octave) |
| MIDI keyboard | plays the instrument you are playing, with velocity (and the sustain pedal on the Keys); plug in any time |
| Tab | open the pattern editor for the instrument you're next to or playing |
| M | switch that instrument's loop off or on (for the Speaker: mute) |
| Space | start or stop every instrument's pattern |
| C | metronome click on/off |
| Esc | the menu (see below); the music keeps playing while it's open |
| I | live input on/off: your microphone or audio interface comes out of the Speaker (macOS asks for permission once) |
| B | binaural on/off (compare with plain stereo) |
| R | room reverb on/off |

## Playing and sequencing

Every instrument in the room (drums, bass, pad, bells, keys) can be played by hand. Walk up to one and press E: the
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
- **Playback Engine**: which output device the audio engine runs on, and the hardware buffer size (32–1024 samples).
  The sample rate follows the device. Shows the resulting latency and CPU use.
- **I/O**: which of the device's outputs carry the mix, the input device, and which hardware input the Speaker plays.
  Live input always starts switched off, so an open microphone never meets a pair of speakers by surprise.
- **MIDI**: every MIDI device the system sees, with a tick box each and a light that flashes when it sends notes.
- **Settings**: master volume, binaural, reverb, text size, field of view, mouse sensitivity, on-screen audio readout.

Choices are saved (Godot's user data folder, `settings.cfg`) and restored at the next start. If a saved device
isn't connected, the system default is used until it is.

## How it's put together

```
game/                      Godot project: the room, player, instruments, HUD, menu and pattern editor (GDScript)
audio_core/
  src/core/                the audio engine, plain C++ with no Godot dependency
    engine.*               device, command queue, mixing, the shared clock
    instruments.*          synthesized drums, bass, pad, bells and keys (each playable live or by pattern), live input
    sequencer.*            the clock (tempo, swing), pattern notes, and the default groove, scheduled to the exact sample
    spatializer.*          Steam Audio: distance, air absorption, wall filtering, binaural (HRTF)
    acoustics.h            how much each frequency band dims when sound bends around a wall edge
    midi_input.*           MIDI controllers, read straight into the audio thread (CoreMIDI; other platforms to do)
    mix.*                  room reverb (feedback delay network) and output limiter
  src/godot/               the Godot extension wrapping the engine (SoundRoomAudio node)
  tests/engine_tests.cpp   offline checks: levels, binaural direction, walls, latency, MIDI, live input, sequencer
game/tests/ui_check.gd     the game driven by pretend keys and clicks: playing, the pattern editor, the menus
prototypes/sound-room/     the original browser prototype, for reference
tools/                     build and dependency scripts
```

Godot owns the world: rendering, input, physics and wall geometry. It sends positions, note events, pattern edits
and each instrument's route around walls (`game/scripts/acoustics.gd`) to the audio core through a lock-free queue and never
waits on it. MIDI controllers and the audio input bypass Godot entirely and go straight into the audio core. The audio core runs
on its own real-time thread with 128-sample blocks, so a dropped game frame never glitches the sound.

Diagnostics that don't need the game:

- `audio_core/build/engine_tests --device` lists the audio devices, opens the default output silently and prints the
  latency it reports. Add a device name and buffer size to try another: `--device "Volt 476" 64`.
- `audio_core/build/engine_tests --midi` lists MIDI devices and reports what they send for 15 seconds.
- `audio_core/build/engine_tests --dump before.f32` writes what the default room plays as raw samples. Dump before
  and after a change to the engine and compare the files to see whether the sound changed.

## Roadmap

Done so far: the native audio pipeline, placeable instruments that can each be played from the keyboard or a MIDI
controller, a pattern sequencer with tempo, swing and a metronome, live audio input through the Speaker, and sound
bending around wall edges.

To do, roughly in this order:

1. **Creating instruments**: a menu for making new instruments out of thin air and placing them in the room.
2. **Title screen.**
3. **Adjustable room dimensions.**
4. **Templates**: save and load a room's dimensions, its instrument layout, and their sequences (and the tempo).
5. **Guitar and bass amplifiers** with controls that work the way real amps do: combo amps, and heads with
   separate cabinets. (The Speaker is the plain, uncoloured way to hear an input until then.)
6. **Recording.**
7. **Plug-in hosting**, if it proves practical.
8. **Multiplayer**, the final goal: a session server, a networked clock, note events and low-latency audio streams.

Also wanted along the way: MIDI on Windows and Linux, and VR through OpenXR.

## Third-party

- [Godot Engine](https://godotengine.org) and [godot-cpp](https://github.com/godotengine/godot-cpp) (MIT)
- [Steam Audio](https://github.com/ValveSoftware/steam-audio) (Apache 2.0)
- [miniaudio](https://github.com/mackron/miniaudio) (public domain / MIT-0)
