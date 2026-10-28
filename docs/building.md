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

`tools/build.sh` fetches the libraries that aren't kept in git (Steam Audio, miniaudio, the VST 3 SDK, Opus), builds the
audio core, the Godot extension and the [session server](session-server.md), runs the offline audio and session server
checks, registers the extension with the Godot project,
and then runs the game silently with pretend key presses and clicks to check the controls and menus
(`game/tests/ui_check.gd`). Open `game/project.godot` in the Godot editor to work on the scene and scripts. Every
change to the audio core is also built and checked on Windows by GitHub Actions (`.github/workflows/windows.yml`).

On Windows the keys are as on a Mac with Ctrl for Cmd and Alt for Option, and the screen names them that way. The
sound goes through Windows' own audio (WASAPI), or through an interface's ASIO driver, which most interfaces need for
low latency. ASIO needs Steinberg's ASIO SDK, which the build can't fetch (it is licensed by agreement with
Steinberg): download it from [steinberg.net](https://www.steinberg.net/developers/) and unpack it so that
`audio_core/thirdparty/asiosdk/common/iasiodrv.h` exists, then build again. ASIO drivers then appear among the outputs
as "ASIO: " and the driver's name; the driver's own inputs are the live input, and its buffer sizes are the ones its
control panel allows. `audio_core/build/Release/engine_tests.exe --device "ASIO: <driver>" 128` opens one on its own
and prints its latency. MIDI keyboards are found as Windows lists them (plugged in while
StudioSim runs, they turn up within a few seconds). Plug-ins are VST3s (see [Plug-ins](plugins.md)).

## Making the app

`tools/export.sh` makes StudioSim into an app of its own, which opens with a double-click and doesn't need Godot:
`dist/macOS/StudioSim.app` on a Mac, `dist/Windows/StudioSim.exe` on Windows (in Git Bash; the `.exe` holds
everything of the game's, and the two DLLs beside it are the audio core and Steam Audio, which go with it). Each is
made on its own kind of computer.

```bash
tools/export.sh
```

It needs Godot's export templates for the Godot version it runs with, installed once: in the Godot editor, **Editor ›
Manage Export Templates › Download and Install**. It builds the audio core's extension again for Godot's release
runtime, in `audio_core/build-release` (the editor and the checks use `audio_core/build`'s), so allow a quarter of an
hour the first time. The presets are in `game/export_presets.cfg`: the name, version (the project's,
`application/config/version`), icon (`game/icon.png`, drawn by `tools/make_icon.py`), the texts a Mac shows when
StudioSim first asks for an audio input or the local network, and no Godot splash at start.

What to know about the app:

- On a Mac it runs on Apple silicon (the audio core is built for it alone, so far), and it is signed only for this
  computer ("ad-hoc"). Copied to another Mac, macOS refuses to open it at first: right-click it and choose **Open**, or
  allow it in **System Settings › Privacy & Security**. Opening anywhere without that needs an Apple Developer ID
  ($99 a year) and Apple's notarization. Windows likewise warns about an app from an unknown publisher until it is
  signed with a code-signing certificate.
- Its rooms, templates and presets are kept in **Music/StudioSim**, not in the project's folder as when it runs from
  Godot. A room from the project's `Rooms` folder opens with **Open room › Browse**. Its settings are the same as
  Godot's runs, though.
- On Windows it is built with ASIO only if the ASIO SDK is in place (as for `tools/build.sh`). Giving that build to
  anyone else needs Steinberg's ASIO licence agreement signed first.

Use **wired** headphones. Bluetooth headphones add 150–250 ms of delay that no software can remove; the
"Output latency" readout shows what your current device adds.

The game opens on a title screen with the default room already playing behind it. From there you make a **new room**
or **open** one (see [Rooms](rooms-and-recording.md)), check which device the sound is going to (and be warned if it is one that adds
delay, such as Bluetooth), and open the audio setup and settings. The menu inside the room has a button to come back
to the title, which then offers to go back into the room.
