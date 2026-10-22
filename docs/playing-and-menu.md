# Playing, sequencing and the menu

Every MIDI instrument in the room can be played by hand. Walk up to one and press E: the
computer keyboard becomes a small piano for it, and any MIDI controller plays it too (see [Inputs](instruments.md#inputs)). The drums
work like a drum machine: each key is a drum, laid out like a General MIDI kit
(C kick, D snare, F# closed hat, A# open hat, F and A toms, D# clap, C# crash) and repeated in every octave.

Each instrument also has a pattern that the sequencer loops. The room starts with the default groove. Press P at an
instrument to edit its pattern on a step grid, one bar at a time:

- click a square to add a note, click a note to remove it, right-click a note to step through loud, medium, soft
  and "now and then" (a soft note that plays one time in four)
- a pattern repeats every one, two or four bars; melodic instruments choose how long new notes last
- M (or the Loop switch) stops an instrument playing its pattern, so you can play it yourself

All patterns follow one tempo (40 to 240 BPM) with adjustable swing. The metronome click marks each beat, higher on
the first beat of the bar, and plays straight into your ears rather than from a place in the room. The tempo and the
patterns go back to the defaults at each start until rooms can be saved.

## The menu

- **Metronome**: start and stop the patterns, tempo, swing, the click and its volume.
- **Room**: the room's size and the walls inside it (see above).
- **Playback Engine**: which output device the audio engine runs on, and the hardware buffer size (32–1024 samples).
  The sample rate follows the device. Shows the resulting latency (the buffer, the device, and what binaural rendering
  adds while it is switched on: about a quarter of a buffer, measured as the engine starts; while the mix is heard,
  its delay compensation instead) and CPU use.
- **I/O**: which of the device's outputs carry the mix, the input device, and which hardware input each Speaker plays.
  Live input always starts switched off, so an open microphone never meets a pair of speakers by surprise.
- **MIDI**: every MIDI device the system sees, with a tick box each and a light that flashes when it sends notes.
- **Settings**: binaural, distance falloff, the limiter's ceiling, delay compensation, text size, field of view, mouse sensitivity, room lighting, full screen (which
  SoundRoom then opens in every time), whether the master meter and the audio readout are shown on screen, and
  auto-save and backups for the room.

Choices are saved (Godot's user data folder, `settings.cfg`) and restored at the next start. If a saved device
isn't connected, the system default is used until it is.
