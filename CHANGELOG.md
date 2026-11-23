# Releases

Every version of StudioSim, the newest first, and what each brought. A **Stable** version is the one to download for
playing and recording; a **Preview** has the newest features first, before they have been played as long. The website's
Releases page and each release's notes on GitHub are made from this file.

## 0.2.0

**Preview** · 23 November 2026

A new look for the whole app, a view of a microphone from behind it, amps made for a guitar plugged straight into an
interface, and cabinets with real speakers behind their grilles.

### New

- **A new look**, the website's: every window, menu and control restyled, with teal for what is on or chosen, each
  instrument's colour marking its tracks, and every shortcut shown as a key beside its button.
- **A microphone seen from behind it**: its panel now looks along its aim from just behind and above it, the mic in
  sight and its axis drawn out to what it points at. **V** switches to the view from its capsule, as before.
- **An amp's input level**: Instrument (Hi-Z) for a guitar or bass plugged into an interface's instrument input with
  its gain all the way down, or Line for a signal already at line level, with a trim and a meter.
- **Cabinets with real speakers**: each speaker in its own hole in a baffle, behind a cloth grille on a guitar cabinet
  or perforated metal on a bass one, each drawn where the sound is heard from, so a mic placed by eye on a speaker
  hears what you'd expect there.
- **The sample rate**, 44.1 or 48 kHz, chosen in the menu's Playback Engine page, and your interface set to it.

### Fixed

- A plug-in's knobs can be turned while the computer keyboard plays it: its window no longer takes the keyboard when
  clicked (the Moog Minimoog and other plug-ins drawn with JUCE among them).
- Audio starts with an interface set to 88.2, 96 or 192 kHz: StudioSim sets it to 48 or 44.1 kHz, or converts if it
  can't be set.
- An armed track's input switch says that it is still heard while armed, rather than seeming not to turn off.
- Playing together, the patterns stay in step more steadily.

### Changed

- The Mac disk image opens on StudioSim and the Applications folder alone; the licence and notices are inside the app.

## 0.1.0

**Stable** · 15 November 2026

The first release: free software under the GPL, for macOS (Apple silicon) and Windows.

- **A room you can shape**: its size, walls standing in it, and what every surface is made of. Sound bends round
  walls, leaks through them, reflects off them and rings as the materials have it, heard binaurally from where you
  stand.
- **Instruments**: drum kits, synths, keys, guitar and bass amps with pedalboards and a loop pedal, Speakers for live
  input, and plug-in instruments, played from the computer keyboard or a MIDI controller.
- **Microphones** that hear the room from where they stand, with real models, pickup patterns and stereo pairs, and
  acoustic kits miked drum by drum.
- **Jam rooms** for playing over looping patterns, and **Record rooms** with a timeline, recording, clip editing and
  automation.
- **A mix window** laid out like a DAW's: inserts, sends, folders, aux tracks, delay compensation, and the room and
  the mix as separate masters.
- **Plug-ins**: VST3 on macOS and Windows, Audio Units on macOS.
- **Playing together**: one player hosts their room and others join it, from a room browser or by address, with the
  patterns in step, live inputs streamed between players, voices, and Record rooms recorded together.
- **A tutorial** on the title screen, rooms saved as sessions with templates and backups, keys of your own, a free
  camera and an avatar.
