# Roadmap

Done so far: the native audio pipeline, instruments that can be added, placed and removed and each played from the
keyboard or a MIDI controller, a pattern sequencer with tempo, swing and a metronome, live audio input through
Speakers, guitar and bass amps with boards of effect pedals (a loop pedal and a plug-in pedal among them), a title
screen, a mix window laid out like a DAW's with plug-in inserts on every channel, a room whose size and walls
can be changed, with sound bending round the walls and a reverb that follows the size (on a fader of its own), surfaces and
walls of real materials that reflect, scatter and let sound through as those do (reflections off every surface and the walls
standing in the room, and off two in turn), rooms saved as sessions (with
templates, auto-save and backups), presets and copy and paste for plug-ins and instruments, and Record rooms: a
timeline, an edit window, recording audio and MIDI to clips (with a count-in, a pre-roll and post-roll, punching in and out, and loop recording
into takes, comped from them), editing them (trims, fades and crossfades, clip gain, splits, nudges, several at once, a MIDI editor
for the notes, undo), tracks with names and colours, in routing folders (folders in folders too) with faders, inserts and sends of their own, and
automation (volume, mute, pan, the sustain pedal, an amp's knobs and its pedals', plug-ins' controls, sends and the master), drawn or
written as it plays, aux tracks with sends, recordings read from disk as they play, microphones that record the
room from where they stand (dynamics, condensers, ribbons and a measurement mic, with their patterns, proximity
effect, responses and noise, and stereo pairs on stereo tracks, mid-side among them), and the room and the mix apart,
each with its master (the mix's with inserts), either one on the main outputs; and drums miked as in a studio (an
acoustic kit heard drum by drum, each head and cymbal from its own place, with the heads' polarity, near field and
bleed, where across a head or cymbal a mic is placed, the kick's port and a mic inside it, a mic's polarity, the
mic panel's distances drum by drum, and a kit miked up in one go); and you in the room: a body as tall as you set,
hearing from between its ears and seeing from its eyes, seated on a kit's stool to play it, and a free camera that
flies about the room, heard from it or from you; and Windows played on a real machine, every check passing, with ASIO
for an interface's own driver.

To do, roughly in this order:

1. **Multiplayer**, the final goal (begun: a player hosts their room and others join it by address, the room and
   everything in it kept the same for everyone, each player's body seen by the others, notes played heard by all,
   the patterns in step on the session's clock, live inputs' sound streamed between players with Opus, voices from
   the players' bodies, and Record rooms together: one transport, each player recording what they arm, recordings'
   files sent to everyone, with a count-in and punching together; hosting over the internet, the router asked to
   open the ports by UPnP, or meeting through a session server by a code, directly or by way of its relay; a room
   browser for the rooms on one network; the host's rules (a name, a password, listed or not, the most players,
   what joining players may do, asking a player to leave); getting back in after a lost connection; see
   [Playing together](playing-together.md)); rooms listed across the internet, on a free Cloudflare Worker. Next: the
   room list set up and its address put in ([Setting up the room list](room-list.md)).

Also wanted along the way: MIDI on Linux, and VR through OpenXR. Perhaps later a free version with Jam rooms
only, Record rooms coming with the full one.
