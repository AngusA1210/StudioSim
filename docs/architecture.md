# How it's put together

```
game/                      Godot project: the room, player, instruments, HUD, menus, mix window, pattern editor (GDScript)
  scripts/catalog.gd       every kind of instrument (and the microphone) and the groups the instrument menu shows them in
  scripts/room.gd          the room's floor, ceiling and walls, built to whatever size and layout is set
  scripts/room_surfaces.gd how each material looks: one shader drawing planks, brick, tiles, folds and the rest
  scripts/instrument_models.gd   what each instrument looks like, built from simple shapes
  scripts/player.gd        you: walking, looking, carrying, playing (on a kit's stool), the free camera, and where the
                           room is heard from
  scripts/avatar.gd        a body as tall as it is set, in proportion, posed each frame (two-bone IK for its limbs)
  scripts/mixer.gd         the mix window: channel strips, faders (fader.gd), pan pots (pan_control.gd), levels in the
                           room (mini_fader.gd) and meters (level_meter.gd)
  scripts/amp_panel.gd     an amp's knobs (knob.gd) and its pedalboard
  scripts/mic_panel.gd     a microphone's model, place, aim and gain, and the view from its capsule (mic_graph.gd draws
                           its response and pattern), a stereo pair's setup, and how far each instrument is from it
                           (a kit's drum by drum)
  scripts/kit_mics.gd      an acoustic kit miked up in one go: each setup's mics, where they go and how they are set
  scripts/plugin_browser.gd  the plug-ins installed, by type or by maker, for an insert or a Plug-in pedal
  scripts/session.gd       the open room: its file, saving, auto-save and backups
  scripts/rooms_page.gd    making a new room (from a template) and opening one
  scripts/you_page.gd      your name and height, from the title screen, your body turning beside them
  scripts/net.gd           playing together: hosting and joining, the players and their bodies, the session's clock
                           and the patterns kept in step with it, notes played
  scripts/room_sync.gd     the room kept the same for everyone: what changed sent, what came applied, in the host's order
  scripts/meeting.gd       meeting through a session server: the host's code, finding a session by it, a relay
  scripts/discovery.gd     the room browser: the rooms hosted on this network, found by a broadcast, and the host's answers
  scripts/room_list.gd     the rooms hosted over the internet: a hosted room put on the room list, the list fetched
  scripts/together_page.gd playing together, from the title screen: the room browser, hosting, direct connect, the session
  scripts/library.gd       what a room holds, templates, instrument and plug-in presets, and copied settings
  scripts/timeline.gd      a room's mode; a Record room's transport, recording and clips
  scripts/edit_window.gd   the edit window (its tracks and clips drawn by timeline_view.gd, a clip's notes by midi_editor.gd)
  scripts/folder.gd        a routing folder: its bus, fader, inserts and tracks (track_menu.gd: a track's menu)
  scripts/automation.gd    the tracks' automation: what the controls show, Touch, Latch and Write, its points
  scripts/master_track.gd  the mix's master, as a track for automation and its inserts
  scripts/preset_menu.gd   the Presets menu of a plug-in or an instrument
audio_core/
  src/core/                the audio engine, plain C++ with no Godot dependency
    engine.*               device, command queue, the room and the mix, the shared clock; microphones hearing the room
    radiation.*            how a cabinet's cones radiate (beaming, the near field, open and closed backs), and a kit's heads and cymbals
    net_audio.*            playing together: live inputs' sound and voices between players (Opus over UDP, through
                           the host), held back just enough to ride out the network
    plugin_window_*        a plug-in's own window, on each platform
    plugin_panel_mac       on a Mac, the floating panel every plug-in's window is: the keyboard left with the room,
                           unless something in it is typed into
    microphones.*          the microphone models: their pickup patterns, responses and sensitivities
    instruments.*          synthesized drums, the garage kit, bass, pad, bells and keys (each playable live or by pattern), live input
    plugin_synth.*         a plug-in instrument: an instrument plug-in played by MIDI, live and by pattern, to the sample
    amp.*                  the guitar and bass amps: preamp drive (oversampled), tone stack, presence, cabinet
    looper.*               the loop pedal: record, overdub, undo/redo, synced to the bars
    pedals.*               the pedals in front of an amp: tuner, gate, compressor, drives, modulation, delay, reverb, looper
    plugin_host*           the plug-ins installed on the computer: VST3 (everywhere) and Audio Units (macOS), their presets
    plugin_category.cpp    what kind of effect a plug-in seems to be, from its name
    sequencer.*            the clock (tempo, swing, playing from a step, loop playback), pattern notes, and the default groove
    recorder.* wav.*       recording: what armed tracks take in, written to WAV files on a thread of its own; reading them
    disk_stream.*          the recordings read from disk as they play: in chunks, a few seconds ahead, by a thread of its own
    interpolation.*        reading a sound between its samples, as late as it reaches a microphone, without dulling its top end
    spatializer.*          Steam Audio: distance, air absorption, wall filtering, binaural (HRTF), the reflections' Ambisonic field
    room_geometry.*        the walls: which way round them sound reaches the listener, how much further that is, and their faces as mirrors
    materials.*            what each material absorbs, scatters and lets through, band by band, and the reverb a room of them has
    acoustics.h            how much each frequency band dims when sound bends around a wall edge
    midi_input*            MIDI controllers, read straight into the audio thread (CoreMIDI on a Mac, WinMM on Windows)
    mix.*                  room reverb (feedback delay network, sized to the room) and output limiter
                           (the output meter and the distance law live in engine.* and spatializer.*)
    compensation.h         the delay lines delay compensation is made of
  src/godot/               the Godot extension wrapping the engine (StudioSimAudio node)
  src/server/              the session server, a program of its own that players meet through (session-server.md)
  tests/engine_tests.cpp   offline checks: levels, binaural direction, walls, latency, MIDI, live input, sequencer, amps, pedals, plug-ins, loop pedal
  tests/session_server_tests.cpp  the session server's checks: codes, finding a session, a relay
game/tests/ui_check.gd     the game driven by pretend keys and clicks: title, playing, patterns, instruments, amps, room, menus,
                           presets, and rooms (making, saving, backups, opening), and playing together
game/tests/together_guest.gd  a second copy of the game that joins the room ui_check.gd hosts, and does what it asks
services/room-list/        the room list: a Cloudflare Worker (worker.js) and its D1 table, its checks, and a stand-in
prototypes/studiosim/      the original browser prototype, for reference
tools/                     build, export (the app) and dependency scripts, and the icon's drawing (make_icon.py)
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
