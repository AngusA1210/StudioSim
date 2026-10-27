# SoundRoom

A shared 3D space for playing music together. Instruments stand in a room, you walk around it in first person, and
everything you hear is rendered binaurally from where you stand and which way you face.

It is also a workstation: rooms can be recorded, edited and mixed the way a DAW works, with Pro Tools as the model.

## What's in it

- **A room you can shape**: its size, walls standing in it, and what every surface is made of. Sound bends round walls,
  leaks through them, reflects off them and rings as the materials have it.
- **Instruments**: drum kits, synths, keys, guitar and bass amps with pedalboards and a loop pedal, PA speakers for live
  input, and plug-in instruments. Played from the computer keyboard or a MIDI controller.
- **Microphones** that hear the room from where they stand, with real models, pickup patterns and stereo pairs.
- **Jam rooms** for playing over looping patterns, and **Record rooms** with a timeline, recording, clip editing and
  automation.
- **A mix window** laid out like a DAW's: inserts, sends, folders, aux tracks, delay compensation, and the room and the
  mix as separate masters.
- **Plug-ins**: VST3 on macOS and Windows, Audio Units on macOS.
- **Playing together**: one player hosts their room and others join it, from a room browser on one network or by
  address over the internet, with no server needed. The host sets a name, a password and what joining players may
  do. Each player hears the room from where they stand, with the patterns in step on a shared clock, live inputs
  streamed between players, voices, and Record rooms recorded together.

## Build and run

macOS needs the Xcode command-line tools, CMake, git and Godot 4.5 or newer. Windows needs Visual Studio 2022 or newer,
CMake, Python, Git for Windows and Godot. Then, in a terminal (Git Bash on Windows):

```bash
tools/build.sh
godot --path game
```

The build script fetches the libraries kept out of git, builds the audio core and the Godot extension, and runs the
offline checks. Use wired headphones: Bluetooth adds a delay no software can remove.

## Documentation

The details of each feature live in [docs/](docs/README.md): controls, instruments and microphones, plug-ins, rooms and
recording, mixing, room acoustics, and how the code is put together.

## Roadmap

1. Multiplayer: begun (hosting and joining, over the internet too, through a session server where routers won't
   open ports, the room shared, a shared clock, live inputs and voices streamed, Record rooms together); next, a
   session server run for everyone.

The full list is in [docs/roadmap.md](docs/roadmap.md).

## Third-party

- [Godot Engine](https://godotengine.org) and [godot-cpp](https://github.com/godotengine/godot-cpp) (MIT)
- [Steam Audio](https://github.com/ValveSoftware/steam-audio) (Apache 2.0)
- [miniaudio](https://github.com/mackron/miniaudio) (public domain / MIT-0)
- [VST 3 SDK](https://github.com/steinbergmedia/vst3sdk) (MIT; VST is a registered trademark of Steinberg Media Technologies GmbH)
- [Opus](https://opus-codec.org) (BSD 3-clause), for the sound between players
