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
for an interface's own driver; the room's surfaces drawn as their materials; StudioSim made into an app of its
own, opened with a double-click, without Godot; amps recording what they play, with their DI kept beside it to reamp;
and a tutorial from the title screen.

Playing together is working: a player hosts their room and others join it, the room and everything in it kept the
same for everyone, each player's body seen by the others, notes played heard by all, the patterns in step on the
session's clock, live inputs' sound streamed between players with Opus, voices from the players' bodies, and Record
rooms together (one transport, each player recording what they arm, recordings' files sent to everyone, with a
count-in and punching together); hosting over the internet, the router asked to open the ports by UPnP, or meeting
through a session server by a code; a room browser for the rooms on one network and those listed across the internet
(on a free Cloudflare Worker); the host's rules; getting back in after a lost connection (see
[Playing together](playing-together.md)). It is still to be tried by ear between computers on different networks.

To do, in this order:

1. **A website** for StudioSim, where it can be downloaded: what it is, pictures of it, its features, a guide (the
   docs), the downloads for macOS and Windows (from the repository's releases), and a link to the source. It is
   built (`website/`, see [The website](website.md)): a static site, to be published free on Cloudflare Pages beside
   the room list, its downloads marked as coming until the release, with a domain of its own if wanted.
2. **Demonstration videos**: short ones of its features (walking a room and hearing it change, an amp miked up, a
   recording made and edited, playing together), for the website and to show it. Recorded from the app itself, with
   its sound.
3. **A public release**, free and open source, in the usual steps:
   - a **licence** chosen and added (MIT is the simplest and suits every library StudioSim uses; the GPL would make
     anything built from it open too), and a third-party notices page in the app, as those libraries' licences ask;
   - the **repository made public**, with a README for newcomers, how to build it, and how to contribute;
   - **apps people can open without warnings**: on a Mac signed with an Apple Developer ID and notarized by Apple,
     universal (Intel Macs too); on Windows signed with a code-signing certificate. Without ASIO in the Windows app,
     unless Steinberg's ASIO licence agreement is signed (WASAPI needs none);
   - **numbered versions** (0.1.0 to begin with) with release notes, the apps built and attached to each release
     (GitHub Actions can build them), and the website's download links following the latest;
   - a **place to report problems** (GitHub Issues), and a first round of people trying it before it is announced.
4. **More for playing and recording music**, from then on: VR through OpenXR among the first, MIDI on Linux, and
   whatever playing and recording together ask for.
