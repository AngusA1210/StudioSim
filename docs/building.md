# Building and running

**macOS** needs Xcode command-line tools, CMake, git, and Godot 4.7 or newer (`brew install --cask godot`).

```bash
tools/build.sh
godot --path game
```

**Windows** needs Visual Studio 2022 or newer (its C++ workload), CMake, Python, Git for Windows (whose Git Bash runs the
build script), and Godot 4.7 or newer. In Git Bash:

```bash
tools/build.sh
```

then open `game/project.godot` in Godot (or run it with `godot --path game`).

`tools/build.sh` fetches the libraries that aren't kept in git (Steam Audio, miniaudio, the VST 3 SDK, Opus), builds the
audio core, the Godot extension and the [session server](session-server.md), runs the offline audio and session server
checks and the [room list](playing-together.md#the-room-list)'s, registers the extension with the Godot project,
and then runs the game silently with pretend key presses and clicks to check the controls and menus
(`game/tests/ui_check.gd`). Open `game/project.godot` in the Godot editor to work on the scene and scripts. Every
change to the audio core or the room list is also built and checked on Windows by GitHub Actions
(`.github/workflows/windows.yml`).

On Windows the keys are as on a Mac with Ctrl for Cmd and Alt for Option, and the screen names them that way. The
sound goes through Windows' own audio (WASAPI), or through an interface's ASIO driver, which most interfaces need for
low latency. ASIO needs Steinberg's ASIO SDK, which the build doesn't fetch: download it from
[steinberg.net](https://www.steinberg.net/developers/) and unpack it so that
`audio_core/thirdparty/asiosdk/common/iasiodrv.h` exists, then build again. ASIO drivers then appear among the outputs
as "ASIO: " and the driver's name; the driver's own inputs are the live input, and its buffer sizes are the ones its
control panel allows. `audio_core/build/Release/engine_tests.exe --device "ASIO: <driver>" 128` opens one on its own
and prints its latency. A build with ASIO is for your own computer: the released Windows app leaves it out until
Steinberg's proprietary ASIO licence is signed, since the SDK's GPL edition doesn't allow it to be shipped together
with the Intel libraries built into Steam Audio's Windows DLL (StudioSim's own licence allows both; see the
[README](../README.md#licence)). MIDI keyboards are found as Windows lists them (plugged in while
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

- On a Mac it is exported for both kinds of Mac (Godot's templates are made so), but runs on Apple silicon alone:
  the audio core is built for it alone, so far. `tools/package.sh` takes its Intel half off. It is signed only for
  this computer ("ad-hoc"): copied to another Mac, macOS refuses to open it at first, until **Open Anyway** in
  **System Settings › Privacy & Security** is clicked. Opening anywhere without that needs an Apple Developer ID
  ($99 a year) and Apple's notarization. Windows likewise warns about an app from an unknown publisher until it is
  signed with a code-signing certificate.
- On Windows, Microsoft's C++ runtime is built into the audio core (`/MT`), so the app needs no Visual C++
  Redistributable installed.
- It keeps its rooms, templates and presets in the same folder as StudioSim run from Godot: the **StudioSim folder**
  in Settings, which is the project's folder until another is chosen there. (Given to someone who has never run
  StudioSim from Godot, it uses the folder their latest room is in, or else **Music/StudioSim**.) Its other settings
  are the same as Godot's runs too.
- The title screen names its version and the commit it was built from (`tools/export.sh` writes it into the app).

## Making a release

`tools/package.sh`, after `tools/export.sh`, packs the app as it is downloaded, with StudioSim's licence and
`THIRD-PARTY-NOTICES.txt` (the licences of what it is built with, made by `tools/notices.sh`):

- on a Mac, `dist/StudioSim-macOS.dmg`, a disk image that opens on StudioSim and the Applications folder alone, to
  drag the one onto the other. Its window is laid out by `tools/dmg_settings.py`, with
  [dmgbuild](https://github.com/dmgbuild/dmgbuild), which the script puts in `dist/.dmgbuild` the first time (it needs
  the internet then). The licence and the notices are inside the app, in `StudioSim.app/Contents/Resources`;
- on Windows, `dist/StudioSim-Windows-Setup.exe`, an installer made with [Inno Setup](https://jrsoftware.org/isinfo.php)
  (`tools/installer/StudioSim.iss`). It installs for the user alone, with no administrator's password, in their own
  programs folder, with a Start menu entry, a desktop shortcut, and an uninstaller in Settings › Apps (which leaves
  their rooms). The licence and the notices are installed beside it.

Releases are made on GitHub's computers, by `.github/workflows/release.yml`. For a new version:

1. Change `config/version` in `game/project.godot`.
2. Add its entry at the top of `CHANGELOG.md`: `## 0.3.0`, a blank line, then `**Preview** · 30 November 2026` (or
   `**Stable**`), then what it brought. A Preview is offered on the website as **Latest**, beside the Stable version;
   a Stable one becomes the **Stable** download.
3. Commit, and push the tag alone, not `main` yet:

   ```bash
   git tag v0.3.0 && git push origin v0.3.0
   ```

4. When the release is published (Actions › Release, about half an hour), push `main`: the website then offers the
   new version, its files already there.

The workflow fails at once if `CHANGELOG.md` has no entry for the version. It builds both apps from scratch (with
Godot's own release, checked against its checksums), checks that the Mac one is for Apple silicon and signed and that
the Windows one needs no runtime a PC mightn't have, packs them, and publishes a release with both files, their
checksums, and notes made by `tools/release_notes.py` (`tools/release_notes.md`, with the version's entry). A Preview is
published as a pre-release, so GitHub's latest release stays the Stable one. Run by hand from the Actions tab, it
makes the files without publishing them, to try.

To make a Preview the Stable version once it has been played enough, change its `**Preview**` to `**Stable**` in
`CHANGELOG.md` and push `main` (the website follows), and on GitHub edit its release: untick **Set as a pre-release**
and tick **Set as the latest release**.

Use **wired** headphones. Bluetooth headphones add 150–250 ms of delay that no software can remove; the
"Output latency" readout shows what your current device adds.

The game opens on a title screen with the default room already playing behind it. From there you make a **new room**
or **open** one (see [Rooms](rooms-and-recording.md)), check which device the sound is going to (and be warned if it is one that adds
delay, such as Bluetooth), and open the audio setup and settings. The menu inside the room has a button to come back
to the title, which then offers to go back into the room.
