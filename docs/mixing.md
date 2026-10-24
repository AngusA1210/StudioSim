# Tracks, folders and the mix

Each instrument is a track, in the mix window and (in a Record room) the edit window, in the same order.

- **Names and colours**: rename a track by right-clicking its name (in either window) or double-clicking it in the
  edit window; its name over it in the room changes too, and a plug-in instrument keeps a name given it rather than
  taking its plug-in's. **Colour** in the same menu offers a palette, as Pro Tools does: the track's name in the room,
  its light, its strip and its clips take it (the instrument's paint stays as it was made).
- **Choosing tracks**: click a track's name in the edit window to choose it, Shift-click for every track from the
  last one chosen to it, Cmd-click for one more or one fewer; in the mix window Shift-click and Cmd-click the names
  (a plain click opens the instrument's window). Chosen tracks are lit.
- **Routing folders**, as in Pro Tools: **⌘G** (or **New folder** in a track's menu) puts the chosen tracks in a new
  folder. Its tracks play into its bus (an aux input) rather than straight to the master, and from there through its
  inserts and its fader to the master, so one fader brings a whole drum kit up or down, and a compressor or EQ on it
  works on them together. Muting a folder silences its tracks; soloing it solos them, and soloing one of its tracks
  lets the folder be heard. The room's reverb of its tracks comes from the tracks themselves, as their own sends
  would, so its fader is their direct sound. A folder can hold aux tracks and other folders too, as many deep as you
  like (a drum folder in a band folder, say): each plays into the one it is in. In the edit window the folder's row
  comes over its tracks', which are set in under it; its arrow shows or hides them (and all in them). A track's menu
  moves it **into** another folder or **out of** its own (into the one that is in), and so does its output in the
  mix window; only folders it can go in are offered (never itself, or one its own sound already reaches, which would
  go round in a circle). Cmd-G puts the chosen tracks, folders and aux tracks among them, in a new stereo folder where
  the first of them was; a track's menu makes a new mono one as well. A folder's menu takes it away, what was in it going where the folder went. Soloing a track lets
  everything its sound goes through be heard: the folders it is in, and the aux tracks it sends to.
- **Aux tracks and sends**, as in Pro Tools: **New stereo aux track** or **New mono aux track** (in a track's menu;
  an empty send's makes a stereo one) makes an aux track, a bus with its own inserts (a reverb or a delay, say), mute, solo and fader, playing to the master. A
  track's **sends**, A to E, play a copy of it into an aux: after the track's fader, the track as heard in the room
  (it follows the fader and mute), or **before the fader**, its own sound straight (it doesn't), at a level of its
  own. A send dragged sideways onto another send (on its strip or another) moves there with its automation (Option:
  a copy). In the mix window each strip's sends are under its inserts, as in Pro Tools: click
  an empty send to send to an aux (or a new one); drag a send up or down for its level (Shift for fine moves; the
  scroll wheel nudges it), double-click it for 0 dB, Cmd-click it off and on, right-click it for before or after the
  fader, another aux, or none. Folders and aux tracks have sends of their own (after their fader, what leaves it;
  before it, what reaches it), and an aux track can go in a folder. An aux's strip comes after the tracks' (or in its
  folder), saying how many sends come in; soloing a track lets the auxes it sends to be heard. An aux has a row in the
  edit window, after the tracks (or in its folder).
- Folders, aux tracks, sends, names and colours are all kept with the room (and in templates).

## The room and the mix

There are two mixes, as a studio has. **The room** is what you hear standing in it: each instrument where it stands,
at its level there, with the room's reverb, through the room's master. **The mix** is what the tracks put out, as
a control room hears them: the microphones' tracks, and each instrument's direct output (as a DI's, or a synth's line
out), through their faders, pans, sends, folders and aux tracks to the mix's master and its inserts. The main outputs
play one or the other: **H** switches between them (or HEAR on either master in the mix window), and the screen says
which. So with microphones up you can hear the mix alone, as headphones would, without the room's own sound on top.
Each master can go to a pair of outputs of its own as well, all the time (its output menu): headphones of their own,
say, or a recorder. Both masters are masters as a DAW has them: inserts A to E, a limiter, a fader that can be
automated (a row each at the foot of the edit window), a name and a colour (crimson to begin with; right-click the name
to rename or recolour it).

An instrument's inserts come before the split, so a plug-in on it shapes its sound in the room too (as an amp's pedals
do); its fader, pan, mute, solo and sends are the mix's. Its level in the room, and its mute there, are at the foot of
its strip, apart. A microphone hears the room, so an instrument muted in the room is muted for the mics too, and one
muted in the mix is still heard by them. Where the room is, the listener is where you stand; the mix doesn't change as
you walk about.

## The mix window

Tab opens the mix window, docked along the bottom of the screen so the room stays in view. It is laid out like a
mixing desk: a channel strip for every instrument, side by side (then the folders' and aux tracks'), and on the right
the Room Reverb, the room's master and the mix's master. At the top of each strip are its **inserts**, A to E, and
under them its **sends**, A to E (see Aux tracks and sends). A fader whose track's automation is read moves with it, and
in Touch, Latch or Write, holding one writes it.

- **Names**: click a strip's name to open the instrument's own window (an amp's knobs and pedals, a pattern, a
  Speaker's panel); the mix window comes back when it closes. Right-click the name to **duplicate** the instrument
  (as Pro Tools duplicates a track: the copy stands beside it, its strip comes next, and it has the same fader,
  pattern, volume, head, cabinet, knobs, pedals and inserts, plug-in settings included, and its clips and automation;
  its input starts off, and a
  loop pedal comes without its loop), to rename it or give it a colour, to put it in a folder or take it out, or to
  remove it from the room.
- **Output**, under each strip's input: where it plays, as a Pro Tools track's output: **→ Master**, or into a
  routing folder (a folder's and an aux's strip have one too: into another folder).
- **Inserts** at the top of each strip, A to E, as in Pro Tools: plug-ins played in order on the instrument's sound
  before its fader (on an amp, after its pedals and the amp). Click an empty one to choose a plug-in, a full one to
  open or close its window, Cmd-click (or Ctrl-click) to bypass it, which turns it blue, and right-click to replace or
  remove it. Drag one to another slot, on its own strip or another instrument's, to move it there (it swaps places
  with whatever was there); hold Option as you drop it to copy it instead, settings and all. Closing the mix window
  puts the plug-in windows away.
- **Each strip**: the input (MIDI, or a list of hardware inputs for a Speaker or an amp; a microphone's model and
  pattern), its output, its **pan** pot, buttons for input (I), mute (M) and solo (S), a fader with the strip's meter
  beside it, and under the fader its level and its peak readout; then, apart, **in the room**: the instrument's level
  there (a small fader across, 0 dB as it was made, with its meter along its foot), and its mute there (M); and the
  instrument's name in its colour.
- **Pan**: a pot, as Pro Tools has: drag up or right to turn it right, down or left to turn it left (Shift for fine
  moves), turn the scroll wheel to nudge it, double-click or Alt-click it for the middle. It reads as Pro Tools reads
  it: "<50" to the left, "50>" to the right, "C" in the middle. An instrument's pans its direct output in the mix (in the
  room it is where it stands); a stereo mic's is its balance. Every instrument's pan can be automated. Faders run from +12 dB down to silence, spaced as on a console.
  Drag one to move it (Shift for fine moves), turn the scroll wheel to nudge it, or double-click or Alt-click it for
  0 dB. 0 dB is the level the instrument was made at, heard from right beside it, and the strip's meter reads it at
  that level, as a DAW's track meter reads what the track sends to the master.
- **Metering**: the channel meters read before the fader (after the inserts), as with Pro Tools' pre-fader
  metering, so a fader pulled down or a mute doesn't hide what the channel is doing. Right-click any fader or meter
  to have them read after the fader instead; the choice is remembered. The masters' meters read what leaves them.
- **Gain reduction**: beside each meter, as in Pro Tools, a thin orange meter falls from the top as far as the
  strip's compressors and limiters are turning it down (24 dB down its height; hover over it for the figure): a
  track's insert plug-ins that show their gain reduction (most compressors and limiters do, among their controls), an
  amp's compressor pedal, and on the masters their limiter (and the Mix Master's inserts).
- **Delay compensation**: plug-ins that look ahead (a limiter, a linear-phase EQ) make their tracks late, and say by
  how much. At the foot of each strip, as Pro Tools shows it, **dly** is how late its plug-ins make it (in samples:
  its inserts', a plug-in instrument's, an amp's plug-in pedals') and **cmp** how far it is held back to meet the
  latest at the master, so that every track reaches the mix together; the Mix Master's **tot** is how far the whole mix
  is held back. A folder's and an aux's own plug-ins count along the way: a folder's tracks are lined up within it, and
  each send is held back to meet the others at its aux. A bypassed plug-in keeps its delay, as in a DAW, so bypassing
  it moves nothing in time; and a plug-in pedal in an amp's parallel loop has the preamp's own signal held back to meet
  it, rather than combing against it. Only the mix is held back: the room is heard as it is played, as a real one is.
  While the mix is heard the click is held back with it, and recordings are lined up allowing for it. It can be switched
  off in Settings; it is worked out again whenever plug-ins come or go and as they report a change.
- **Peak readouts**: as in Pro Tools, the number beside each fader's level holds the highest peak (in dBFS) until
  you click it, and turns red once anything reaches full scale. Clicking a meter clears it too; Alt-click clears
  every one, the master's included.
- **Folders**: a routing folder's strip comes before its tracks', in a frame of the folder's colour that holds them
  all (a folder in it framed within): its inserts (plug-ins, on what its tracks play into it), its pan, mute and solo,
  and its fader and meter. A folder is **stereo** or **mono**, as made (a track's menu offers a new stereo folder or a
  new mono one, and likewise aux tracks) or changed by right-clicking its name. A stereo one has two channels, its
  inserts in stereo, its meter two bars, and two pans, one for each side, as a stereo track has in Pro Tools (hard left
  and hard right to begin with, its stereo as it is); a mono one sums what reaches it
  to one channel as it arrives, its inserts and its meter that one, and its pan places it, as a mono track's does. In
  the edit window its colour runs down beside its tracks' headers. See Tracks and folders.
- **Room Reverb**: the room's reverb return, a fader with a stereo meter of its own beside the room's master, as an
  aux return sits beside the master on a desk. 0 dB is the room's own reverb; down to the bottom there is none, up to
  +12 dB it is wetter than the room. It is the room's: the mix has none unless a track sends to an aux with a reverb on
  it. Its level is kept with the room.
- **Room Master**: how loud the room is as you hear it standing there, with its stereo meter and peak readout, and
  HEAR, lit while the main outputs play the room.
- **Mix Master**: its inserts, A to E, in stereo on the whole mix (a bus compressor, an EQ; they can be automated,
  in its lanes at the foot of the edit window), its output (the main outputs only, while it is heard, or a pair of
  outputs of its own as well), LIMIT, its fader with a stereo meter and peak readout, and HEAR. Both master faders
  start at 0 dB and go no higher. The limiter comes last, after the fader, as an output limiter does: with it on,
  neither the mix nor the room gets past its ceiling (-1 dBFS to begin with; Settings changes it), and the window says
  by how many decibels the master you are hearing is being held back whenever it is (each master's own limiting shows
  on its gain reduction meter). Bringing the master down eases it. With it off, the mix is
  the plain sum of the tracks, and whatever the main outputs play over full scale is cut off and reported as clipping.

Rather than instructions written across it, the line at the foot of the window says what the mouse is over: an
insert, a button, a fader, the limiter. The amp and Speaker panels work the same way.

The output is set to leave headroom right beside an instrument, so from across the room the room is fairly quiet:
raise the room's master to taste and watch the meter. An instrument is at its own level within 1.5 m of it and gets no
louder however close you stand; beyond that it falls 6 dB for each doubling of distance, as the inverse square law
has it. That can be made gentler (down to 0, where distance makes no difference) under Distance falloff in the
Settings page of the menu.

In the room, the master meter stands at the top right of the screen (it can be switched off in Settings). Under it
is the recent peak, or "limit" or "CLIP" when either is happening. Beside the tempo, a lamp shows whether
binaural rendering (B) is on, and in a Record room another says FOLLOWS PLAYBACK while insertion follows playback (N).
