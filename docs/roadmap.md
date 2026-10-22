# Roadmap

Done so far: the native audio pipeline, instruments that can be added, placed and removed and each played from the
keyboard or a MIDI controller, a pattern sequencer with tempo, swing and a metronome, live audio input through
Speakers, guitar and bass amps with boards of effect pedals (a loop pedal and a plug-in pedal among them), a title
screen, a mix window laid out like a DAW's with plug-in inserts on every channel, a room whose size and walls
can be changed, with sound bending round the walls and a reverb that follows the size (on a fader of its own), rooms saved as sessions (with
templates, auto-save and backups), presets and copy and paste for plug-ins and instruments, and Record rooms: a
timeline, an edit window, recording audio and MIDI to clips (with a count-in, a pre-roll and post-roll, punching in and out, and loop recording
into takes, comped from them), editing them (trims, fades and crossfades, clip gain, splits, nudges, several at once, a MIDI editor
for the notes, undo), tracks with names and colours, in routing folders (folders in folders too) with faders, inserts and sends of their own, and
automation (volume, mute, pan, the sustain pedal, an amp's knobs and its pedals', plug-ins' controls, sends and the master), drawn or
written as it plays, aux tracks with sends, recordings read from disk as they play, microphones that record the
room from where they stand (dynamics, condensers, ribbons and a measurement mic, with their patterns, proximity
effect, responses and noise, and stereo pairs on stereo tracks, mid-side among them), and the room and the mix apart,
each with its master (the mix's with inserts), either one on the main outputs.

To do, roughly in this order:

1. **Windows, played**: built and checked on every change; next, played and listened to on a Windows machine, and
   ASIO for interfaces whose Windows drivers want it.
2. **The room's sound**: reflections off the walls standing in the room (as well as its own), and second ones (off one
   surface, then another) before the reverb takes over.
3. **You in the room**: an avatar whose height you can set (the ears and eyes go with it; the view is a little tall
   for some now), which multiplayer will show to the others; and a free camera, detached from the avatar, that flies
   about the room with nothing in its way.
4. **Multiplayer**, the final goal: a session server, a networked clock, note events and low-latency audio streams.

Also wanted along the way: MIDI on Linux, and VR through OpenXR. Perhaps later a free version with Jam rooms
only, Record rooms coming with the full one.
