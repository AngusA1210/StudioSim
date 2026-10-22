# SoundRoom

A shared 3D space for playing music together. Instruments sit in a room, you walk around it in first person,
and everything you hear is rendered binaurally from where you stand and which way you face.

So far it is one player in one room with the full audio pipeline: instruments you can walk up to and play, a
sequencer that loops a pattern on each of them, and live input from a microphone or audio interface. Saving rooms,
recording, amplifiers and multiplayer come later (see the roadmap below).

## Build and run

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
SoundRoom runs, they turn up within a few seconds). Plug-ins are VST3s (below).

Use **wired** headphones. Bluetooth headphones add 150–250 ms of delay that no software can remove; the
"Output latency" readout shows what your current device adds.

The game opens on a title screen with the default room already playing behind it. From there you make a **new room**
or **open** one (see Rooms, below), check which device the sound is going to (and be warned if it is one that adds
delay, such as Bluetooth), and open the audio setup and settings. The menu inside the room has a button to come back
to the title, which then offers to go back into the room.

## Controls

| Key | Action |
| --- | --- |
| W A S D, mouse | move, look (click to capture the mouse); the arrow keys walk and turn too |
| Shift | run |
| G or click | pick up the instrument you're facing, put it down (it turns to face you) |
| ⌘L | lock the instrument you're facing (or carrying, or the microphone whose panel is open) in place, or unlock it: a yellow padlock floats over its name, and it can't be picked up, nor a microphone moved or aimed |
| T | the instrument menu: add an instrument to the room |
| V | duplicate the instrument you're facing or carrying, with its settings, pedals and plug-ins: the copy is in your hands to put down |
| Backspace, twice | remove the instrument you're facing or carrying |
| E | play the instrument you're next to; Q stops |
| A S D F G H J K L ; | white keys while playing (W E T Y U O are the black keys, Z/X change octave; P opens the panel, seated too) |
| K | the keyboard: the letter keys play every instrument whose input is on, from wherever you stand. The arrow keys walk and turn meanwhile; Q or Esc closes it |
| I | that instrument's input on/off (see below) |
| MIDI keyboard | plays every instrument whose input is on, with velocity (and the sustain pedal on the Keys); plug in any time |
| P | open the panel of the instrument you're facing: its pattern editor (at an amp: its knobs and pedals; at a Speaker: its volume and input; at a microphone: its place, seen from its capsule) |
| ' (beside Return) | at a plug-in instrument, open its plug-in's window above the on-screen keyboard, the letter keys playing it; a click in the room, Esc or Q puts it away |
| M | switch that instrument's loop off or on (for a Speaker or an amp: mute it in the room; for a microphone: mute its track) |
| L O U J | at an amp with a loop pedal: L the footswitch (record, close the loop, overdub), O stop or play, U undo or redo the last overdub, J twice to clear. Elsewhere in a Record room, L switches loop playback on and off |
| 1 to 8 | at an amp, stamp on its pedals: each switches that pedal on or off (the loop pedal: its footswitch) |
| Tab | the mix window (you can still walk about while it is open) |
| H | hear the room or the headphone mix on the main outputs; the screen says ROOM or HEADPHONE MIX (see The room and the mix) |
| Space | start or stop every instrument's pattern (a Record room: play from the playhead, or stop) |
| ⌘Space | a Record room: record the armed tracks from the playhead; again (or Space) to stop |
| R | a Record room: the edit window, from the room or the mix window (⌘= swaps the two) |
| Enter | a Record room: the playhead back to the start, from the room, the edit window or the mix window |
| N | a Record room: insertion follows playback on/off (stopping leaves the playhead where the music stopped, rather than going back to where it started), as in Pro Tools |
| ⌘Z, ⌘X | in the room: undo the last move of an instrument (carried and put down, or a microphone placed or aimed), and redo it. In the mix and edit windows (a Record room): undo the last edit to the clips (a recording, a move, a trim...), and redo it. Two histories apart (⌘⇧Z redoes too) |
| C | metronome click on/off |
| Esc | the menu (see below), including the room's size and walls; the music keeps playing while it's open |
| ⌘S | save the room |
| ⌘G | the mix or edit window: put the chosen tracks in a new routing folder |
| A | the edit window: show or hide the automation lanes under the tracks, as in Logic |
| B | binaural on/off (compare with plain stereo) |

Facing an instrument, a card at the right of the screen lists what each key does to it.

Every key here can be changed on the **Controls** page of the menu: click an action's key, then press the new one
(an action that had it takes the old key). The ⌘ shortcuts (save, record, undo, redo, split, duplicate a clip, and the
mix and edit windows in turn) are listed there too, and change the same way among themselves. Esc, the arrow keys, 1 to 8 and the note keys stay as they are. While you
are at an instrument or have the keyboard open, the note keys are notes, and whatever else they are given waits until
you get up or close it.

## Instruments

There are two families of instrument, and microphones; the instrument menu (T) adds any of them to the room, up to
32 in all (less one for each folder and aux track, and one for the mix master's inserts). The menu shows each as a
picture of it, as it stands in the room, with its name; what it is shows in the line at the foot while the mouse is
over it (and what a family is, over its heading):

- **MIDI instruments** (a drum machine, a garage kit, a studio kit, bass, pad, bells, keys, and plug-in instruments) are played from
  the computer keyboard or a MIDI controller, and each can loop a pattern on the sequencer.
- **Live inputs** bring what you plug into the audio interface (your own microphone, a guitar, a bass) into the room:
  the Speaker, which plays an input just as it comes in, and four guitar and bass amplifiers, each with a board of
  pedals in front of it (see below).
- **Microphones** hear the room from where they stand, and record that (see Microphones, below).

Each is drawn as its real counterpart, standing on the floor: the drum kits (set up as a drummer plays them, the
stool on your side with the kick and hi-hat pedals at your feet; the garage kit red on an old rug, the studio kit
purple), a bass
synthesizer, a modular synthesizer for the pad, tubular bells, an electric piano, a controller keyboard with a laptop
for a plug-in instrument, a PA speaker on a tripod, the amps with their pedals in front of them, and a microphone on a
boom stand. The parts in the instrument's colour light up as it plays.

**Drums** is a drum machine. The **Garage Kit** and the **Studio Kit** are one acoustic kit voiced two ways. Each
drum is its head's modes settling in pitch after the hit, the snare's wires buzz along with the kick and toms,
closing the hats chokes an open one, the crash's and ride's wash builds when hit again, harder hits are brighter, and
no two hits are quite alike. The garage kit is raw: barely damped, a ringing snare with loose wires, toms left to
ring (about 136 Hz and 85 Hz), trashy hats, a little crunch from being played loud, and the concrete walls slapping
back. The studio kit is tuned and damped: a punchy kick with a clear beater, a tight snare, toms (about 146 Hz and
96 Hz) that sing and stop, clean hats and smooth cymbals. All three kits are on the same keys, following the General
MIDI drum map, except that the acoustic kits have a ride (D#, as at 51) where the drum machine has a clap.

A **Plug-in Instrument** plays one of the instrument plug-ins on your Mac (Audio Unit synthesizers, samplers,
pianos), chosen from the plug-in browser when you pick it, and takes that plug-in's name. MIDI controllers, the
computer keyboard and its pattern play it like any instrument, sending it the sustain pedal, the mod wheel and the
other controllers, and pitch bend as well. **'**, facing it, opens the plug-in's own window just above the on-screen
keyboard: the letter keys play the instrument while you work the window with the mouse, and a click anywhere in the
room (or Esc, or Q, or the window's close button) puts it away and gives the mouse back to looking about. The
on-screen keyboard can be clicked to play too. A plug-in's window never takes the keyboard from the game (even those,
such as UAD's, that try to when clicked), so you can keep playing while you drag its knobs; only clicking a box in it
to type gives it the keyboard, until the click is done. Should the game lose the keyboard anyway, the notes held are
let go rather than left hanging; in the mix window its
strip shows the plug-in where others show their input: click it for the window, right-click it for another plug-in or
its presets. It is saved with the room, its plug-in's settings and all.

Pick one and it appears in your hands: walk it to where it should stand and click to put it down. A new MIDI
instrument starts with an empty pattern, so it is silent until you play it or write it a pattern (the pattern editor
can load the default one). A new Speaker plays the hardware input chosen in the menu, which can be changed later in
its mix window strip or on the I/O page; several Speakers can each play a different input. A Speaker's own
**volume** (P at it, or click its name in the mix window) goes up to +24 dB, as on a big powered PA speaker, so that
it can fill a large room; it comes after the Speaker's inserts and before its fader. A second instrument of a kind is numbered and a
paler colour, to tell them apart. Everything in the room is saved with it (see Rooms).

### Microphones

A **microphone** is a track of its own that records what the room sounds like from where it stands, rather than an
instrument's own input (its DI, or its notes): the instruments as they reach it, each from where it stands, with the
walls between them and the room's reverb, as a mic on a stand in a real room does. The instrument menu has the kinds
a studio has (models of each kind, not of any one maker's), each drawn as it looks, and any of them can be switched
to another in its panel:

| Mic | Pattern | Its sound | Sensitivity |
| --- | --- | --- | --- |
| **Dynamic** (instrument) | cardioid | lean far off, fuller close up; a presence lift around 5.5 kHz, little above 13 kHz | -8 dB |
| **Kick** (a big dynamic) | supercardioid | deep lows, the boxy low mids (around 380 Hz) scooped out, the beater's click (4 kHz) lifted | -8 dB |
| **Condenser** (large diaphragm, side-address) | cardioid, omni or figure-8 | detailed, a little low warmth, an open top around 9.5 kHz | +6 dB |
| **Pencil** (small-diaphragm condenser) | cardioid or omni | accurate and even, off axis too; a little air above 10 kHz | +3 dB |
| **Ribbon** (side-address) | figure-8 | smooth and dark on top, its back as loud as its front | -6 dB |
| **Measurement** | omni | flat from the lowest lows to the highest highs | 0 dB |

- **What it hears** follows the physics: each instrument's sound arrives as late as it takes to travel there at 343 m/s
  (two mics at different distances from a drum hear it at different times, as real ones do, with the same phase
  effects between them), 6 dB quieter for each doubling of the distance (and louder closer than 1.5 m, the distance
  an instrument is heard at its own level, down to 10 cm), dulled a little by the air and more by a wall it has to
  bend round, with the room's reverb on top, as diffuse there as anywhere. Moving a mic (or an instrument) while it
  plays bends the pitch a touch, as moving a real one would. A muted instrument is silent in the room, so a mic hears
  nothing of it; but a solo only takes the others out of the mix, so soloing a mic's track lets you hear just what it
  hears, every instrument still playing in the room. A microphone isn't heard in the room itself, so no mic hears
  another (nor itself).
- **Its pattern** decides how much it hears from each way round, the way the sound arrives (straight, or from the edge
  of a wall it bends round) against the way the mic points: an omni hears all round alike, a cardioid little from
  behind, a supercardioid less from the sides, a figure-8 its front and its back alike (the back in reverse polarity)
  and nothing from the sides. A pattern widens in the lows and narrows in the highs, as a real mic's does (a large
  condenser's omni hears less from behind in the highs). A directional mic hears less of the room's reverb than an omni
  does (a cardioid or a figure-8 a third of it, in energy), and has a **proximity effect**: close up, its lows rise,
  6 dB an octave below a corner that climbs as it nears the source (a figure-8 most, an omni not at all), up to
  +20 dB, so a dynamic that sounds lean at a metre sounds full at a few centimetres.
- **Its sensitivity** is how loud it is for the same sound, against the measurement mic: a dynamic or a ribbon needs
  more gain than a condenser, as real ones do.
- **Its noise**: each hisses as quietly as its model's self-noise (the sound level, A-weighted, that would make as
  much noise: a large condenser 8 dB(A), a pencil 14, a ribbon 16, a dynamic 18, the measurement mic 22), and its
  preamp adds its own, the more of it the more gain a quiet mic needs. The room's levels are set so that full scale,
  through the measurement mic at 0 dB of gain, is 120 dB SPL (an instrument heard at its own level is around 90 to
  105 dB SPL), so it is far below the music, but there in a quiet passage with a lot of gain, as with a real mic.
- **Placing it**: pick one from the menu, carry it (G) and put it down: it points at the instrument nearest it. Then
  **P** at it (or its name in the mix window) opens its panel, docked down the right of the screen, and the view
  goes to the mic's capsule, looking the way it points (its own model out of the way), with a cross at the middle and,
  under it, what it is pointing at, how far off and how far off its axis, as you would check it with your head beside
  the stand. In that view W A S D (or the arrows) move it along the floor, R and F raise and lower it, dragging aims
  it, and the scroll wheel moves it along its aim, closer or further (Shift for fine moves, in each): its keys are
  drawn in the corner of the view as they lie on the keyboard, each lit while held. ⌘Z undoes a move. The panel has
  its model and pattern (with its frequency response and its pattern drawn, the lows and highs fainter), where it
  stands, to the centimetre (across and along the room, from its middle), its capsule's height (where it hears
  from), which way it points (its bearing, clockwise from north, and how far down) or **Point it at** an instrument,
  and its **gain**, which comes before it records, as a preamp's does. Under them, how far each instrument is from it,
  how late its sound arrives, how loud it is there, and how far off its axis. Closing the panel puts the view back
  where you stand. Its pan is the mix window's.
- **Its track** is an audio track: arm it (R) and record, and it records what it hears (32-bit float, so a mic right up
  against a loud amp never clips the file); its input on (I) lets you hear it as it hears, and while it is armed it is
  heard while recording or stopped, its clips otherwise, as Pro Tools' Auto Input has a track. It plays through its
  inserts, fader and sends to the mix's master (or its folder), where its pan puts it in the stereo (equal-power; its
  strip says its model and pattern in its input's place, as "DYN · CARD"). Its takes are placed
  where they were heard, with no input latency to take off, since nothing came in through the interface; something
  played live along with it is heard by it as late as you play it, though, as in a real room with headphones that
  are late.
- **Stereo pairs**: two mics on a bar on one stand, as one **stereo track**: they record one stereo file, and it plays
  back in two channels, through stereo inserts, its fader, and its pan (a balance, as a stereo track's). Its panel
  sets it up as one of the classic ways: **XY** (two cardioids at one point, 90° apart: mono-safe, the image from
  their angles), **ORTF** (two cardioids 17 cm apart, 110° apart: angles and timing both, as ears have it), a
  **spaced pair** (A/B: two omnis side by side, as far apart as you like, wide and roomy), **Blumlein** (two
  figure-8s at one point, 90° apart: the front and the room behind in true stereo) or **mid-side** (M/S: a mid mic
  facing ahead, cardioid, omni or figure-8, and a figure-8 side mic across it). A mid-side pair is recorded as it
  hears, mid and side, and decoded to left and right in its track (left is mid plus side, right mid less side) as wide
  as its **width** says: 0 is mono, 100 % as the two hear it, more wider still, and it can be changed after recording.
  The pair takes the patterns its setup wants (pencils for the cardioids and omnis, ribbons for Blumlein, a large
  condenser's figure-8 for the side, unless their model has them), and is placed and pointed as one.
- **Its pan** (a stereo mic's balance) can be automated, as a lane under its track, and written as it plays by turning
  its pot in the mix window.
- It is kept with the room: where it stands, how high, how it points, its model, pattern, gain and pan, and a pair's
  setup. (A stereo pair kept as two mono mics, as rooms had it for a while, opens as two mics.)

### Inputs

Every instrument has an input that can be on or off, as a track's input is in a DAW, and a green **i** under its
name shows when it is on. A MIDI instrument with its input on plays what the MIDI keyboard sends; several can be on
at once, so one keyboard can play a layer of instruments. A Speaker with its input on plays its hardware input; the
audio input opens when the first Speaker's input goes on and closes when the last goes off.

Sitting down at an instrument (E) switches its input on until you get up, so the MIDI keyboard plays whatever you are
at. Switch an input on yourself (I, or the I button in the mix window) and it stays on when you walk away. The
computer keyboard plays the instrument you are sitting at, along with any others whose input is on. Every input
starts switched off, so an open microphone never meets a pair of speakers by surprise.

### Amps' speakers

A cabinet sounds as real ones do from where you are: each speaker is a cone in the baffle (seen through the grille),
heard on its own way. A cone beams: on its axis it is full-range; off it the highs fall away, the further and higher the
more. Close up it is in its near field: the level levels off rather than rising as 1/distance, the lows are fuller,
and where across the cone a mic sits matters: bright and biting at the dust cap, darker halfway out, darker still at the
edge. A 4x12's cones comb-filter between them; an open back is heard behind (reverse polarity, duller) and costs some
lows in front; behind a closed back only the lows wrap round. The listener hears the beaming too (a combo on the floor
beams at your knees). **Point it at** aims a mic at an amp's nearest dust cap. A mic a little way off also hears the
**floor's bounce**: each cone again from its image under the floor, a little late, so the sound has notches where the
bounce arrives half a wave late (and more where a whole wave late), as a real one does; up against the grille it hardly
matters. The floor's material sets how much of each band comes back (tile or wood, a strong bounce; a rug or carpet,
little of the highs), and the mic hears the room's walls and ceiling the same way (see The room). The PA
**Speaker** is heard the same way: its 10-inch woofer, and the horn over it covering 45 degrees either side evenly
and little beyond. (radiation.h has the physics.)

### Amps, pedals and the loop pedal

An amp is a **head** and a **cabinet**, and any head goes with any cabinet. The four in the instrument menu start as a
Crunch head in a 1x12 combo (Guitar Combo), a High Gain head on a 4x12 (Guitar Stack), a Bass Round 1x15 combo (Bass
Combo) and a Bass Punch head on an 8x10 (Bass Stack); the amp panel (') changes either, and the amp in the room is
drawn with the cabinet it has.

| Head | | Cabinet | |
| --- | --- | --- | --- |
| Clean | lots of headroom, clean and bright | 1x12 open back | lighter lows, a sweet top |
| Crunch | clean at low gain, crunch as Gain goes up | 2x12 open back | fuller, still airy |
| High Gain | two gain stages, tight lows | 4x12 closed back | a firm low thump and a midrange bite |
| Bass: Round | deep and round, gentle drive | 1x15 bass | deep, soft on top |
| Bass: Punch | punchy, more top end and drive | 4x10 bass | tight lows, more top |
| | | 8x10 bass | big lows, a growl in the mids |

Each cabinet holds **speakers** of its size, its usual ones to begin with; the amp panel's SPEAKERS changes them:

| Speakers | | Rated |
| --- | --- | --- |
| British 25 W (12") | warm and mid-forward, a soft top | 25 W each |
| British 60 W (12", the 4x12's) | the low mids pulled back, an aggressive upper-mid bite | 60 W each |
| American vintage (12", the 1x12's) | scooped, a sparkly top, loose lows | 20 W each |
| British alnico (12", the 2x12's) | chiming, bright and sweet | 15 W each |
| American 10 (10") | bright and tight | 25 W each |
| Bass 10 (10", the 4x10's and 8x10's) | punchy, a growl in the mids, an extended top | 250 W each |
| Bass 15 (15", the 1x15's) | deep, soft on top | 400 W |

A cabinet and its speakers are how they sound on the speakers' axis, far enough off to be past their near field, as a
maker measures a speaker; how they sound anywhere else, close up or off axis, the room works out from where the cones
are (see Amps' speakers), each speaker's cone breaking up where its own does. Either part can be **bypassed**. Without its head, the amp plays whatever reaches it straight through the
cabinet, so an amp plug-in on a Plug-in pedal can be the head; without its cabinet, it is a flat, full-range speaker,
for a plug-in that brings its own cabinet.

The head has the knobs of a real amp, 0 to 10: **Gain** (how hard the preamp is driven, from clean into distortion),
**Bass**, **Middle** and **Treble** (flat at 5), **Presence** (the top end the power amp lets through) and **Master**
(the amp's volume: 5 is unity, 10 is +12 dB, and it works with the head bypassed too). The master drives the
**power amp**: a push-pull pair of output tubes, which give out softly as they reach full power (a played string at 10
is some 7 dB louder than at 5, not 12, and grittier), and whose supply **sags** under a sustained load, so a loud
note dips just after its attack and blooms (most in the small Crunch head, with its tube rectifier; hardly at all in
the big Clean one). Each head has its wattage (Clean 85 W, Crunch 30, High Gain 100, Bass Round 300, Bass Punch 500), and
the speakers theirs: a head that can give more than its speakers take drives them, turned up, into compression (their
voice coils heating) and breakup, as a small combo cranked does. Press P facing an amp to
open its panel: drag a knob up or down (Shift for fine moves), turn the scroll wheel over it, or double-click it for
5. The panel also has the amp's input switch and which hardware input it plays. Plug a guitar or bass straight into
the interface's instrument input; the amp is the only processing it needs. Wear headphones.

An amp has an **effects loop**: on the board, pedals after PREAMP are sent out after the preamp and its tone stack and
returned before the power amp, so a delay or reverb there repeats the amp's own distorted sound. It is a parallel loop:
its **MIX** knob blends what comes back with the preamp's own signal, which carries on to the power amp beside it (half
and half to begin with; all the way up, everything goes through the pedals, as a series loop), so set a delay or reverb
in it fully wet. Drag a pedal across to move it in or out; the loop's own **+** adds one in it.

#### Effect pedals

An amp starts with an empty board. The amp panel's **Pedalboard** runs the way the signal does: from the input through
up to eight pedals, in order, then the amp. **+ Pedal** adds one at the end of the line; click a pedal to set it up
underneath, where its knobs read in real units (decibels, milliseconds, hertz), and its footswitch, or its number key
(1 to 8, in the panel or facing the amp in the room), switches it on or off. Drag a pedal along the board to move it
(a blue mark shows the gap it will go in); hold Option as you drop it to put a second one there instead, knobs and
plug-in settings and all. A pedal switched off passes the guitar through untouched. Click the **Pedalboard** heading
to fold the board away when you only want the amp; the number keys still work. The pedals stand on the floor in
front of the amp, each with a light that is lit while it is on. Move the mouse over a pedal for what it does.

| Pedal | Controls | What it does |
| --- | --- | --- |
| Tuner | Mute | Shows the note and how many cents sharp or flat, on the panel and over the amp, to within a cent, from a five-string bass's low B up. Mutes the guitar while it is on, unless Mute is off. |
| Noise Gate | Threshold, Release | Shuts out the hiss and hum between notes. |
| Compressor | Sustain, Attack, Level, Blend | Evens out loud and soft playing; Blend mixes the untouched signal back in. |
| Overdrive | Drive, Tone, Level | A warm, mid-heavy drive that keeps the lows tight, for pushing an amp harder. |
| Fuzz | Sustain, Tone, Volume | Two clipping stages and a tone that sweeps through a scooped middle. |
| Envelope Filter | Sensitivity, Range, Resonance, Band-pass | An auto-wah: the filter opens the harder you play. Off, the switch gives a low-pass, for funk bass. |
| Chorus | Rate, Depth, Mix | A slowly wavering copy beside the guitar; Mix at 10 is vibrato. |
| Phaser | Rate, Depth, Resonance | Notches swept up and down. |
| Tremolo | Rate, Depth, Shape | The volume pulsing, from a smooth throb to a hard chop. |
| Delay | Time, Repeats, Mix, Tone, Sync | Echoes that darken with each repeat. With Sync on, Time picks a note value (a sixteenth up to a half, triplets and dotted notes too) at the room's tempo. |
| Reverb | Decay, Tone, Mix | A room or hall before the amp. |
| Loop Pedal | Level, Sync, Overdub after recording | Records what reaches it and plays it round and round (see below). One to an amp. |
| Plug-in | (its own window) | One of the effect plug-ins installed on your Mac, before the amp (see Plug-ins below). |

Delay and Reverb let their echoes and tail ring on after they are switched off, as many real ones do.

#### The loop pedal

Put one on an amp's board from **+ Pedal** (an amp can have one). It records the guitar as audio, not notes, as it
reaches it: a loop keeps the effects before it on the board, and plays through the pedals after it and through the
amp's current knobs, so where it stands on the board is up to you, as on a real one (at the end of the line is
usual). It works like a single-track looper pedal:

- **L, the footswitch** (or its number key): the first press starts recording, the second closes the loop and plays it, and from then on
  each press starts or stops an overdub laid on top. Pressing it on an empty pedal switches the amp's input on.
- **K** stops the loop, or plays it again from the top. **U** undoes the last overdub, and redoes it. **J**, pressed
  twice, clears the loop.
- On the amp panel (click it on the board) it has the same controls as buttons, a display of what the pedal is doing and where it is in the loop,
  and its options: **Loop level**, **Sync to the bars** (on at first: while the patterns are running, recording
  starts on the next bar line and a loop is a whole number of bars, so it stays in time with them; with the
  patterns stopped, or Sync off, it starts and ends the moment you press) and **After recording** (play the loop, or
  go straight into an overdub).

A loop can be up to 90 seconds long. The pedal's light and the label under the amp's name show recording, playing
and overdubbing from across the room. Loops survive a change of buffer size, but changing the sample rate clears
them, and like everything else they are not saved yet. Taking the loop pedal off the board takes its loop with it, so
with a loop recorded that takes a second press.

## Plug-ins

SoundRoom hosts the plug-ins installed on your computer in the formats their makers install besides Pro Tools' AAX:
**VST3** on macOS and Windows (with Steinberg's VST 3 SDK, MIT-licensed), and on a Mac **Audio Units** as well. They go
on a channel's **inserts** in the mix window (on any instrument or master) or on an amp's **Plug-in pedal**. Either way
the plug-in browser opens: your plug-ins grouped **by type** (EQ, dynamics, delay, reverb, amps and cabinets...) or **by
maker**, with a search box; a plug-in installed in both formats is listed twice, each marked AU or VST3. Choose one and
its own window opens, floating over the room. Plug-ins get the room's tempo, for those that keep time.

A VST3 is known by its class id, which is the same on a Mac and on Windows, so a room whose plug-ins are VST3s opens
on either with its plug-ins and their settings. A room made with Audio Units, opened on Windows, gets the VST3 version
of each where it is installed (its settings start fresh, as the two formats keep them differently), and says so.
SoundRoom finds VST3s by reading the description in each plug-in's bundle, without loading it; one without loads once
to be asked, and is remembered. A VST3's controls show their values as the plug-in writes them in automation lanes.

Most plug-ins don't say what kind of effect they are (VST3s mostly do, and are grouped by what they say), so the types
of the rest are worked out from their names: a good guess, not a certainty (`audio_core/build/engine_tests --plugins`
lists what each was taken for). By maker is always exact. A plug-in that only comes as AAX can't be used, since only
Pro Tools can host those. Plug-ins run inside SoundRoom as
they would inside a DAW, so one that crashes takes SoundRoom with it. Their settings are kept with the room and in
presets (below). Each instrument is a single point of sound in the room, so a plug-in's stereo output is heard as
one channel, from where the instrument stands.

**Amp simulators** (TONE3000 and other amp and cabinet models) work in two ways:

- **As the head of one of SoundRoom's amps**: put the simulator on the amp's Plug-in pedal, bypass the amp's head, and
  keep its cabinet. This suits a model of an amp alone, and gives you the pedals in front of it and a cabinet heard as
  it would be in the room. A model that includes a miked cabinet carries that microphone's sound with it; bypass the
  amp's cabinet for those, or use an amp-only model and let SoundRoom's cabinet do the rest.
- **On a Speaker**: the Speaker plays its input as it comes in, so with the simulator on its first insert the Speaker
  is the amp, sounding from where it stands, full range. Put it where the amp should stand, pick the interface input
  the guitar is plugged into, and switch its input on.

## Rooms

A **room** is what a session is in a DAW: everything about it in one file. That covers its size and walls, and every
instrument where it stands, with its fader, mute and solo, its pattern (the MIDI notes, the pattern's length and
whether its loop is on), its inserts, an amp's head, cabinet, knobs and pedals, a Speaker's volume and input, and
every plug-in's settings. It also holds the master fader, the tempo and swing, and where you were standing. Each room has a folder of
its own, named after it, as a Pro Tools session does: the room's `.sroom` file (JSON) and a **Room Backups** folder.
Recorded audio will go there too once recording comes. Rooms go in the **Rooms** folder of the SoundRoom folder the
game runs from (here, `SoundRoom/Rooms`, beside `game/`) unless you choose another; git leaves it alone. A build made to
hand out keeps them in `~/Music/SoundRoom` instead.

- **New room…** (title screen): name the room, choose where it goes, choose its **mode** (Jam or Record, see below),
  pick a **template**, set its width, length and
  height (the template's to begin with), and tick what to bring over from the template: its walls, its instruments
  where they stand (and, for those, their patterns, their faders with mute and solo and the master fader, which is
  otherwise at 0 dB, the amp and Speaker settings,
  and the plug-ins with their settings), and its tempo and swing. Everything starts ticked. Create room saves the
  room and takes you in.
- **Open room…** lists the rooms in the rooms folder and those opened lately, the latest first. **Browse…** finds a
  room's file anywhere, a backup among them.
- **Saving**: ⌘S, or **Save** in the menu's header, which also names the room and says when it was saved. The
  header's **Room** button has Save as…, **Save as template…** and Show in Finder. Making or opening another room,
  or quitting, asks first whether to save any changes.
- **Auto-save** (Settings, off to begin with) saves the room every so many minutes while it has changes.
- **Backups** (Settings, on to begin with): every 10 minutes (or as set), if the room has changed, a copy of it as it
  is goes in its Room Backups folder (`Name backup 001.sroom`, `002`…). The oldest are thrown away past the number
  kept (10 to begin with). A backup opens like any room.

**Templates** appear only when making a room. Two are built in: the default room, and an empty room with no
instruments and no wall (made as a Record room, it starts stopped with nothing looping, at 90 BPM). Save a room as a template from the menu's Room button. Templates hold everything a room does,
and are kept in `SoundRoom/Templates` as `.srtemplate` files.

## Jam rooms and Record rooms

A **Jam room** is a loop: every instrument's pattern goes round to the tempo, and Space starts them all again from
the top or stops them. A **Record room** adds a timeline, and recording, as a DAW has them. Its patterns still loop
(each from bar 1), and a new one plays the first four bars round, so it starts just as a Jam room does. The mode is
chosen when a room is made (the last choice is remembered), and the Room button in the menu switches a room over
either way later; nothing it holds is lost.

In a Record room:

- **The transport**: Space plays from the playhead and stops, the playhead going back to where it started (as Pro
  Tools does); Enter puts it back at the start. With **insertion following playback** (N, or the edit window's Follow
  button, as Pro Tools has it), stopping leaves the playhead where the music stopped instead; the screen says FOLLOWS
  PLAYBACK while it does, and the choice is remembered. The screen's top right says where the music is (bar | beat,
  and minutes and seconds), whether it is recording, and the loop.
- **The edit window** (R from the room or the mix window, or the mix window's Edit window button): a row for each instrument, its name in its colour,
  and its clips along the bars. On each track's header, **R** makes it record-ready, **I** is its input, **M** mute and
  **S** solo. Option-click any of them for every track at once, as Pro Tools' all-tracks modifier has it, or
  Shift-Option-click for just the tracks chosen by their names (Shift-click names for a run of them, Cmd-click for one
  more), as its selected-tracks modifier has it (in the mix window too). Above them the ruler: click it to put the playhead there, drag along it to loop that range (**L**, or
  Loop, switches loop playback on and off, in the mix window and the room too). The counter at the top shows bar |
  beat with the time beside it; click it and type a bar (`5`), a bar and beat (`5 | 3`) or a time (`1:24`), then
  Enter, to go there. Clips and the ruler snap to the grid (Bar, Beat, 1/8, 1/16, or Off for anywhere). Scroll to
  move about (Shift for along), ⌘ and the wheel (or a pinch) to zoom; ↶ and ↷ beside the zoom undo and redo. Tab, or
  ⌘=, goes over to the mix window. The cursor and the line at the foot of the window say what a press would do where
  the mouse is.
- **Monitoring**, as Pro Tools has it. A Speaker's or an amp's **I** (input monitoring) means its input is heard,
  playing or not, rather than what it recorded. A record-ready Speaker or amp is heard through its input while
  stopped or recording, and plays back what it recorded while playing (Pro Tools' Auto Input), its I left off; the
  audio input opens for it either way. A record-ready instrument takes the notes played on it, as with its input on,
  and plays its clips back too.
- **Editing clips**, with the mouse as with Pro Tools' Smart Tool:
  - Click a clip to choose it (stopped, the playhead goes where you clicked too), and drag it along its track or to
    another that takes its kind; hold Option as you drop it for a copy. **Shift-click** chooses more (or one fewer),
    **⌘A** every clip: dragging one moves them all together, and the keys below work on all of them.
  - Drag either **end** to trim it. An audio clip only ever shows more or less of its file, never past either end of
    it; a MIDI clip keeps the notes trimmed off, and drawn out again they are back.
  - Drag an audio clip's **top corners** to fade it in or out (equal-power curves, drawn over the waveform); the cursor
    turns to a little fade, a ramp in a box, there.
  - Where two audio clips meet, drag the top of the seam to **crossfade** them: each plays on into the other's time
    with the audio its file has beyond the cut (Pro Tools' handles), centred on the cut where both files have it.
  - **Clip gain**, as Pro Tools has it: drag the little fader at an audio clip's foot up or down (Shift for fine
    moves; Option-click for 0 dB), or press **⌃⇧↑ ↓** to nudge the chosen clips a dB. It is shown beside the fader,
    and the waveform is drawn as loud as it plays, from -48 dB (silent below) to +24 dB.
  - **⌘E** splits the chosen clip at the playhead (with none chosen, every clip under it), as Pro Tools' Separate: the
    halves meet exactly, the first keeping the fade in and the second the fade out, named `Speaker_01-01` and so on.
  - **,** and **.** (or - and + on the number pad) nudge it a grid line earlier or later (10 ms with the grid off).
  - **⌘D** puts a second of it just after it, **Delete** takes it away, **U** loops it from its start to its end exactly
    (Logic's key for the same).
  - **⌘Z** undoes an edit (a recording, a move, a trim, a fade, a split...), up to 32 of them, and **⌘X** (or ⌘⇧Z)
    redoes it.
- **Automation**, as Pro Tools and Logic have it: **A** (or the edit window's Auto button) shows a lane under each
  track (a folder's, an aux's, and the master's, whose row is at the foot of the edit window). A lane shows one
  thing, chosen with its first button: **Volume**, **Mute**, an instrument's **Sustain pedal**, an amp's knobs
  (**Gain** to **Master**), its **Pan**, a send's level (**Send A** to **E**), any of the controls of the plug-ins on the
  track, each plug-in's in a submenu of its own (on its inserts, its Plug-in pedals, a plug-in instrument's own),
  or the knobs of an amp's stock pedals, each pedal's in a submenu too; the master's lanes are its fader and the
  controls of the plug-ins on its inserts. A plug-in's
  automation goes where the plug-in goes: dragged to another insert slot (on its track or another), its points and
  its lane go with it, and the one it swaps with takes its own the other way; copied (Option-drag), the copy has a
  copy of them; taken away, or replaced by another plug-in, they go with it. A pedal's go with it about the board. **+** adds another lane under the track, for another control, and **×** takes one
  away (its points are kept). Click a lane to add a point (dragging as you add it to place it); drag a point to move
  it (to the grid along; up and down on the fader's own scale), Shift-click for more, Option-click (or Delete, with
  them chosen) to take points away. Volume glides from point to point, and holds level before the first and after
  the last; mute and the pedal switch at each point. Played, a track's automation takes the place of its fader (which
  moves to show it, stopped too, at the playhead) and its mute button, to the sample; an amp's knobs and its pedals'
  (its panel shows them turning), the plug-ins' controls (their windows show them moving) and the sends' levels
  follow theirs, to the block. Stopped, each is where its lane has it at the playhead.
  - **Modes** (a lane's second button, or Automation in a track's menu in either window), as Pro Tools': **Off** (its
    automation ignored), **Read** (played; the default), **Touch** (written while a control is held as the music
    plays, going back to what was there when it is let go), **Latch** (written from when a control is first held until
    the music stops) and **Write** (the volume written all the while the music plays, and any other control once
    held; afterwards the track is in Touch). The controls are its fader, an amp's knobs and its pedals' in its panel, its sends in the
    mix window, and a plug-in's controls in the plug-in's own window (with a lane showing them: a control seen to
    move as the music plays is written, and in Touch goes back once it has been still a moment); the master fader
    writes the master's. A mute button pressed while it plays in Touch, Latch or Write is written until it stops, the
    button itself left as it was. Written moves are thinned to the points that bend the line, and undo as any edit does (⌘Z).
  - **The sustain pedal** played on an armed instrument as it records is written in its Sustain pedal lane, over what
    was recorded (a loop recording's, as in the take shown), and played back with its notes.
  - Automation is kept with the room, and in templates.
- **The MIDI editor**: double-click a MIDI clip for its notes, in the tracks' place (Esc, or ← Tracks, goes back), as
  Pro Tools' MIDI editor shows them: a row for each pitch with the piano down the left (click a key to hear it), the
  clip's bars along the top and each note's velocity as a stalk along the foot. Click an empty place to add a note a
  grid line long (drag as you add it to make it longer); click a note to choose it (Shift-click for more) and drag it
  along or up and down (Option as you drop: a copy); drag its right end to lengthen or shorten it; drag a stalk up or
  down for its velocity. Delete, ⌘A, ⌘D and comma and full stop work on the chosen notes, and every edit undoes.
- **Recording** (⌘Space, or Record): the armed tracks record from the playhead (or from where it is playing), loop
  playback waiting meanwhile. **Loop Record** (⌥L, as in Pro Tools; the Record button shows ⟳) records round the loop
  instead, from its start: each time round is a **take**, stacked in one clip over the loop with the last whole pass
  shown, so you can play a part over and over and choose the best. A clip with takes says how many; right-click it to
  choose another, which shows in its place (the rest are kept, to choose again).
  - **Comping**, as with Pro Tools' playlists and Logic's take folders: **Show the takes under the track** (in that
    menu) gives each take a lane of its own under the track. Drag along a take to put that part of it in the track
    (snapped to the grid), in place of what was there; click a take to put it in place of the part of the track over
    it. The parts of each take in the track are lit in its lane, and where two parts meet they crossfade for 10 ms.
    Every part keeps all the takes, so you can go on comping, and choosing a take from a part's menu changes that part
    alone. Comping undoes as any edit does.
  The edit window's **Options** menu (beside Follow; all remembered) has the rest, as Pro Tools' transport does:
  - a **count-in**, one bar or two: recording from a stop, the click counts the bars first, the music waiting at the
    playhead (Pro Tools' Count Off); the screen counts down the beats;
  - a **pre-roll**, one bar or two: playing or recording from a stop, the music starts that much before the playhead,
    and a recording starts when it gets there (stopping still goes back to the playhead);
  - **punching in and out** over the range on the ruler (drawn red then), as over a selection in Pro Tools: recording
    from a stop starts at its start (after any pre-roll) and stops at its end, the music playing on; with a
    **post-roll** of a bar or two it plays that much more, then stops of itself. An armed track is heard through its
    input only while it records, its clips in the pre-roll and post-roll (Pro Tools' Auto Input);
  - Loop Record. An armed Speaker or amp records its hardware input as it comes in, before its pedals,
  amp and inserts, to a WAV file (32-bit float) in the room's **Audio Files** folder, named after the track
  (`Speaker_01.wav`, `Speaker_02.wav`...). Played back, a take goes through the pedals, amp and inserts again, as a
  DAW plays a track back through its inserts (so an amp can be re-dialled after the playing). An armed instrument
  records the notes played on it (MIDI controllers, the computer keyboard, the on-screen keyboard). Takes are moved
  back by the latency of the sound coming out and going in, so they land where they were played. Stopping makes
  each take a clip, covering whatever its track had there.
- **Clips** are light: an audio clip is a part of its file (where it starts on the timeline, and where in the file and
  for how long), as Pro Tools' clips refer to their parent file, so moving, copying or covering one never touches
  the audio. Audio is placed in seconds (it stays where it was played if the tempo changes); MIDI in bars and beats
  (it follows the tempo). They are all saved in the room's file.
- **Read from disk as it plays**, as a DAW reads its tracks: a recording's file is opened by its header alone, and a
  disk thread reads its audio in chunks a few seconds ahead of the music (round the loop too, and from where playing
  starts before it starts), letting go of what has played once more than 256 MB is in memory, so a room hours long
  needs little memory. The Playback Engine page shows how much is read ahead, and how many buffers (if any) the disk
  was too slow for.

## Presets

**Plug-in presets**: right-click an insert and open **Presets**, or press **Presets** under a Plug-in pedal. It lists
the presets the plug-in comes with, then yours. **Save preset…** saves the plug-in's settings under a name in the file
every host of its format uses: an Audio Unit's `.aupreset` or a VST3's `.vstpreset`, in `Maker/Plug-in` under
`~/Library/Audio/Presets` on a Mac or `Documents/VST3 Presets` on Windows, so presets saved in another DAW show up in
SoundRoom and the other way round.

**Instrument presets** hold an instrument's sound, without where it stands or what it plays: the plug-ins on its
inserts, an amp's head, cabinet, knobs and pedals (the plug-ins on its pedals too), a Speaker's volume, and a plug-in
instrument's plug-in with its settings. They are on
the **Presets** button of an amp's or a Speaker's panel, and under **Presets** when you right-click an instrument's name
in the mix window. A preset loads onto any instrument of its family (an amp's onto any amp, a guitar combo's onto a bass
stack even), and the instrument menu (T) lists them under **Your presets**, to bring one into the room as a new
instrument. They are kept in `SoundRoom/Instrument Presets`.

**Copy settings** and **Paste settings** sit in the same Presets menus, as in Pro Tools: a plug-in's settings paste
onto the same plug-in anywhere (on an insert or a pedal), an instrument's onto another of its family.

## Tracks and folders

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
  go round in a circle). Cmd-G puts the chosen tracks, folders and aux tracks among them, in a new folder where the
  first of them was. A folder's menu takes it away, what was in it going where the folder went. Soloing a track lets
  everything its sound goes through be heard: the folders it is in, and the aux tracks it sends to.
- **Aux tracks and sends**, as in Pro Tools: **New aux track** (in a track's menu, or an empty send's) makes an aux
  track, a bus with its own inserts (a reverb or a delay, say), mute, solo and fader, playing to the master. A
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
  all (a folder in it framed within): its inserts (plug-ins in stereo, on what its tracks play into it), its pan, mute
  and solo, and its fader and meter. Its pan comes after its fader: a stereo folder's is a balance, as a stereo track's;
  right-click its name for Mono, which sums its sound and places it, as a mono track's pan does. In the edit window its
  colour runs down beside its tracks' headers. See Tracks and folders.
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
  by how many decibels it is being held back whenever it is. Bringing the master down eases it. With it off, the mix is
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

## The room

The Room page of the menu changes the room itself, while the music plays:

- **Size**: width and length from 4 to 40 m, height from 2.4 to 12 m. The reverb follows: a bigger room rings for
  longer but more quietly, a small one is short and close. Instruments, walls and you are brought inside if the room
  shrinks past them.
- **What it's made of**: its floor, its ceiling and each of its four walls (north is the way you first face), each a
  material from its menu: drywall, plaster, brick, concrete, wood panelling, glass, heavy curtain, acoustic foam,
  acoustic panels, diffuser panels or bookshelves for the walls; acoustic tiles and most of those for the ceiling; a
  wooden floor, tiles, concrete, a rug or carpet underfoot. Hover over one for what it does. A room starts with drywall walls, a wooden floor and an
  acoustic-tile ceiling, and rings for about 0.7 s. Kept with the room.
- **Walls**: a floor plan of the room, seen from above with the instruments and yourself marked on it (the room's own
  walls in their materials' colours). Drag on the floor to draw a wall, drag a wall to move it, drag the dot at either
  end to turn and stretch it. Walls can stand at any angle and there can be up to 16. Each has its own height, and its
  own material (drywall to begin with): a glass booth window, a concrete partition, a curtain hung across the room, a
  gobo of acoustic panels.

Every material takes its own share of each band (below 800 Hz, 800 Hz to 8 kHz, above 8 kHz), the published figures,
and the rest it sends back. From them the room's reverb rings for as long in each band as Eyring's formula has it (what
the air takes as well): a room of bare concrete and tile rings on for seconds, bright; foam, carpet and panels leave it
nearly dead; curtains and carpet take the highs and leave the lows ringing. The more a room absorbs, the quieter its
ring, too.

Before the reverb, the **first reflections**: every instrument off the floor, the ceiling and each wall, from its image
beyond the surface, as much later than its own sound as that way round is longer, as loud as the image is far, coloured
by the surface's material, the air, and a loudspeaker's beaming as seen from there (and by any wall standing in the
way). You hear them from where they come: walk up to a concrete wall and it is there beside you; line it with foam and
it goes. They are rendered together as one second-order Ambisonic field, binaurally with the HRTF (lined up with the
direct sound, whatever the buffer) or in plain stereo, so they cost little however many instruments there are. Each
microphone hears its own reflections the same way, by its pattern.

A material also **scatters** a share of what it sends back rather than mirroring it: a flat wall little, brick and a
curtain's folds more as the waves get shorter, bookshelves much of it, and **diffuser panels** (wooden wells of
different depths) nearly all the mids and highs. What is scattered comes back spread out over some 20 ms and from all
over the surface rather than as a mirror's echo, so a room keeps its life without the flutter and the hard slap
between bare walls.

Sound finds its way round the walls. Behind one, an instrument is duller and seems to come from the edge its sound
bends round; the longer the detour, the duller it gets, highs first. A wall lower than the ceiling also lets sound
over the top. Walls that meet close the gap between them, so four walls to the ceiling make a booth that all but
shuts an instrument away, heard only through its walls: drywall lets a little through (the lows most), concrete next to
nothing, glass a little more in the highs, a curtain or a gobo a good deal. A wall built out from the side of the room
can only be passed at its free end.

The room is lit by a grid of lamps that grows with it, so a large room is no darker than the default one. Settings
has a Room lighting slider if it is still too dim or too bright for your screen.

The room goes back to the default each time SoundRoom starts, until rooms can be saved.

## Playing and sequencing

Every MIDI instrument in the room can be played by hand. Walk up to one and press E: the
computer keyboard becomes a small piano for it, and any MIDI controller plays it too (see Inputs, above). The drums
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

## How it's put together

```
game/                      Godot project: the room, player, instruments, HUD, menus, mix window, pattern editor (GDScript)
  scripts/catalog.gd       every kind of instrument (and the microphone) and the groups the instrument menu shows them in
  scripts/room.gd          the room's floor, ceiling and walls, built to whatever size and layout is set
  scripts/instrument_models.gd   what each instrument looks like, built from simple shapes
  scripts/mixer.gd         the mix window: channel strips, faders (fader.gd), pan pots (pan_control.gd), levels in the
                           room (mini_fader.gd) and meters (level_meter.gd)
  scripts/amp_panel.gd     an amp's knobs (knob.gd) and its pedalboard
  scripts/mic_panel.gd     a microphone's model, place, aim and gain, and the view from its capsule (mic_graph.gd draws
                           its response and pattern), a stereo pair's setup, and how far each instrument is from it
  scripts/plugin_browser.gd  the plug-ins installed, by type or by maker, for an insert or a Plug-in pedal
  scripts/session.gd       the open room: its file, saving, auto-save and backups
  scripts/rooms_page.gd    making a new room (from a template) and opening one
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
    radiation.*            how a cabinet's cones radiate: beaming, the near field, open and closed backs
    plugin_host*           plug-ins: which format a plug-in is in, Audio Units (macOS), VST3 (everywhere)
    plugin_window_*        a plug-in's own window, on each platform
    midi_input_*           MIDI keyboards, on each platform (CoreMIDI, WinMM)
    microphones.*          the microphone models: their pickup patterns, responses and sensitivities
    instruments.*          synthesized drums, the garage kit, bass, pad, bells and keys (each playable live or by pattern), live input
    plugin_synth.*         a plug-in instrument: an instrument plug-in played by MIDI, live and by pattern, to the sample
    amp.*                  the guitar and bass amps: preamp drive (oversampled), tone stack, presence, cabinet
    looper.*               the loop pedal: record, overdub, undo/redo, synced to the bars
    pedals.*               the pedals in front of an amp: tuner, gate, compressor, drives, modulation, delay, reverb, looper
    plugin_host*           the effect plug-ins installed on the computer: Audio Units on macOS, their windows, presets
    plugin_category.cpp    what kind of effect a plug-in seems to be, from its name
    sequencer.*            the clock (tempo, swing, playing from a step, loop playback), pattern notes, and the default groove
    recorder.* wav.*       recording: what armed tracks take in, written to WAV files on a thread of its own; reading them
    disk_stream.*          the recordings read from disk as they play: in chunks, a few seconds ahead, by a thread of its own
    spatializer.*          Steam Audio: distance, air absorption, wall filtering, binaural (HRTF), the reflections' Ambisonic field
    room_geometry.*        the walls: which way round them sound reaches the listener, and how much further that is
    materials.*            what each material absorbs, scatters and lets through, band by band, and the reverb a room of them has
    acoustics.h            how much each frequency band dims when sound bends around a wall edge
    midi_input.*           MIDI controllers, read straight into the audio thread (CoreMIDI on a Mac, WinMM on Windows)
    mix.*                  room reverb (feedback delay network, sized to the room) and output limiter
                           (the output meter and the distance law live in engine.* and spatializer.*)
    compensation.h         the delay lines delay compensation is made of
  src/godot/               the Godot extension wrapping the engine (SoundRoomAudio node)
  tests/engine_tests.cpp   offline checks: levels, binaural direction, walls, latency, MIDI, live input, sequencer, amps, pedals, plug-ins, loop pedal
game/tests/ui_check.gd     the game driven by pretend keys and clicks: title, playing, patterns, instruments, amps, room, menus,
                           presets, and rooms (making, saving, backups, opening)
prototypes/sound-room/     the original browser prototype, for reference
tools/                     build and dependency scripts
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

## Roadmap

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

## Third-party

- [Godot Engine](https://godotengine.org) and [godot-cpp](https://github.com/godotengine/godot-cpp) (MIT)
- [Steam Audio](https://github.com/ValveSoftware/steam-audio) (Apache 2.0)
- [miniaudio](https://github.com/mackron/miniaudio) (public domain / MIT-0)
- [VST 3 SDK](https://github.com/steinbergmedia/vst3sdk) (MIT; VST is a registered trademark of Steinberg Media Technologies GmbH)
