# SoundRoom

A shared 3D space for playing music together. Instruments sit in a room, you walk around it in first person,
and everything you hear is rendered binaurally from where you stand and which way you face.

This is the first milestone of the engine: one player, one room, the full audio pipeline. Networking, recording
and VR come later (see the roadmap below).

## Build and run (macOS)

Needs Xcode command-line tools, CMake, git, and Godot 4.5 or newer (`brew install --cask godot`).

```bash
tools/build.sh
godot --path game
```

`tools/build.sh` fetches the libraries that aren't kept in git (Steam Audio, miniaudio), builds the audio core and
the Godot extension, runs the offline audio checks, and registers the extension with the Godot project.
Open `game/project.godot` in the Godot editor to work on the scene and scripts.

Use **wired** headphones. Bluetooth headphones add 150–250 ms of delay that no software can remove; the
"Output latency" readout shows what your current device adds.

## Controls

| Key | Action |
| --- | --- |
| W A S D, mouse | move, look (click to capture the mouse, Esc to release) |
| Shift | run |
| G or click | pick up the instrument you're facing, put it down |
| F | mute or unmute the instrument you're facing |
| E | play the Keys when you're next to them (A–; are white keys, W E T Y U O P black, Z/X octave, Q stops) |
| MIDI keyboard | plays the Keys from anywhere, with velocity and sustain pedal; plug in any time |
| I | live input on/off: your microphone or audio interface comes out of the Amp (macOS asks for permission once) |
| B | binaural on/off (compare with plain stereo) |
| R | room reverb on/off |

## How it's put together

```
game/                      Godot project: the room, player, instruments and HUD (GDScript)
audio_core/
  src/core/                the audio engine, plain C++ with no Godot dependency
    engine.*               device, command queue, mixing, the shared clock
    instruments.*          synthesized drums, bass, pad, bells, the playable keys, and live input
    sequencer.*            the groove, scheduled to the exact sample
    spatializer.*          Steam Audio: distance, air absorption, wall filtering, binaural (HRTF)
    acoustics.h            how much each frequency band dims when sound bends around a wall edge
    midi_input.*           MIDI controllers, read straight into the audio thread (CoreMIDI; other platforms to do)
    mix.*                  room reverb (feedback delay network) and output limiter
  src/godot/               the Godot extension wrapping the engine (SoundRoomAudio node)
  tests/engine_tests.cpp   offline checks: levels, binaural direction, walls, note latency, MIDI, live input
prototypes/sound-room/     the original browser prototype, for reference
tools/                     build and dependency scripts
```

Godot owns the world: rendering, input, physics and wall geometry. It sends positions, note events and each
instrument's route around walls (`game/scripts/acoustics.gd`) to the audio core through a lock-free queue and never
waits on it. MIDI controllers and the audio input bypass Godot entirely and go straight into the audio core. The audio core runs
on its own real-time thread with 128-sample blocks, so a dropped game frame never glitches the sound.

`audio_core/build/engine_tests --device` opens your output device silently and prints the latency it reports.

## Roadmap

1. **Single-player spatial sandbox** (current): the native audio pipeline, placeable instruments, the playable Keys,
   MIDI controllers, live audio input, and sound bending around wall edges.
   Next: choosing audio devices and input channels in-game, more instruments, saving a room's layout.
2. **Multiplayer jam**: session server, a networked clock, note events and low-latency audio streams.
3. **Recording and long-distance play**: multitrack session recording; interval and overdub modes.
4. **Worlds as content**: saving, sharing and building spaces; more instruments.
5. **VR** via OpenXR.
6. **Platform**: accounts, moderation, regional servers, latency-aware matchmaking.

## Third-party

- [Godot Engine](https://godotengine.org) and [godot-cpp](https://github.com/godotengine/godot-cpp) (MIT)
- [Steam Audio](https://github.com/ValveSoftware/steam-audio) (Apache 2.0)
- [miniaudio](https://github.com/mackron/miniaudio) (public domain / MIT-0)
