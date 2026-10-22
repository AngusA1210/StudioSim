# Building and running

**macOS** needs Xcode command-line tools, CMake, git, and Godot 4.5 or newer (`brew install --cask godot`).

```bash
tools/build.sh
godot --path game
```

**Windows** needs Visual Studio 2022 or newer (its C++ workload), CMake, Python, Git for Windows (whose Git Bash runs the
build script), and Godot 4.5 or newer. In Git Bash:

```bash
tools/build.sh
```

then open `game/project.godot` in Godot (or run it with `godot --path game`).

`tools/build.sh` fetches the libraries that aren't kept in git (Steam Audio, miniaudio, the VST 3 SDK), builds the
audio core and the Godot extension, runs the offline audio checks, registers the extension with the Godot project,
and then runs the game silently with pretend key presses and clicks to check the controls and menus
(`game/tests/ui_check.gd`). Open `game/project.godot` in the Godot editor to work on the scene and scripts. Every
change to the audio core is also built and checked on Windows by GitHub Actions (`.github/workflows/windows.yml`).

On Windows the keys are as on a Mac with Ctrl for Cmd and Alt for Option, and the screen names them that way. The
sound goes through Windows' own audio (WASAPI); MIDI keyboards are found as Windows lists them (plugged in while
SoundRoom runs, they turn up within a few seconds). Plug-ins are VST3s (see [Plug-ins](plugins.md)).

Use **wired** headphones. Bluetooth headphones add 150–250 ms of delay that no software can remove; the
"Output latency" readout shows what your current device adds.

The game opens on a title screen with the default room already playing behind it. From there you make a **new room**
or **open** one (see [Rooms](rooms-and-recording.md)), check which device the sound is going to (and be warned if it is one that adds
delay, such as Bluetooth), and open the audio setup and settings. The menu inside the room has a button to come back
to the title, which then offers to go back into the room.
