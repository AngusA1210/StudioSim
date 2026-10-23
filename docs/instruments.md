# Instruments, microphones and amps

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
ring (about 136 Hz and 85 Hz), trashy hats, and in its own track a little crunch from being played loud and a garage's
concrete walls slapping back. The studio kit is tuned and damped: a punchy kick with a clear beater, a tight snare,
toms (about 146 Hz and 96 Hz) that sing and stop, clean hats and smooth cymbals. All three kits are on the same keys,
following the General MIDI drum map, except that the acoustic kits have a ride (D#, as at 51) where the drum machine
has a clap.

**An acoustic kit in the room is heard drum by drum**, as a real one is: each drum's two heads and each cymbal sound
from where they stand on the kit, so the microphones hear a kit as a studio's do.

- A mic close to a drum hears that drum far above the rest, with the others bleeding in as much as their distance
  has it (the hi-hat into the snare's mic, the kick's lows into everything), and each as late as it is far: an
  overhead hears the snare as much later than the snare's own mic as it is further, and a spaced pair of overheads
  hears the hi-hat on one side and the floor tom on the other.
- A drum's heads move together when it is hit, so a mic under the snare hears it in opposite polarity to one over it
  (flip the bottom mic's polarity, as in a studio), and far more of its wires, which are stretched across its bottom
  head. Out in front, the kick is mostly boom; its beater's click is on its batter side.
- Each head has a near field, as a speaker's cone does: close up its level levels off and its lows are fuller. Off
  its axis it loses some of its highs, and behind it, where the shell is in the way, more. A cymbal sounds from both
  its faces, quieter edge on.
- **Where across a head** a close mic is placed matters, as where across a speaker's cone does: over its middle it hears
  the drum's note and the stick (the whole head moving together, and struck there); out towards the edge, its
  overtones and ring, which are still at the middle and strongest further out. Further off, the head is heard whole.
- **The kick has a port**, a hole in its front head off its middle, and an inside. Just outside the port a mic hears
  more of the beater's click and the air rushing out with the boom than on the head. Lower a mic to the kick's height
  and put it in through the port, and it is **inside the kick**: the beater close and loud, the drum from within, and
  the rest of the kit (and the room) through the shell, far quieter and duller in the mids and highs, though the lows
  get through. Inside and out front the kick is in the same polarity (the batter pushes the air out through both), so
  line those two up by time, not by flipping one.
- Heard from a distance, a drum's two heads add up to the kit as it was tuned, so the kit sounds as it did from
  across the room, and from any side. You hear each part as late as it is further than the nearest, as the mics do, so
  a drum's two heads add and cancel as they would.
- A close mic on a drum is very loud: turn its gain down, as you would pad a mic in a studio. **Point it at** aims a
  mic at the nearest drum head or cymbal.

The kit's own track (its notes' sound, in the mix) is still the kit as one; the room hears the kit itself, and so do
the mics and you.

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
paler colour, to tell them apart. Everything in the room is saved with it (see [Rooms](rooms-and-recording.md)).

## Microphones

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
  effects between them). The timing is exact to a fraction of a sample, and its top end doesn't change with the
  fraction, so a mic moved a few millimetres sounds no duller or brighter. It is 6 dB quieter for each doubling of
  the distance (and louder closer than 1.5 m, the distance an instrument is heard at its own level, down to 10 cm),
  dulled a little by the air and more by a wall it has to bend round, with the room's reverb on top, as diffuse there
  as anywhere. Moving a mic (or an instrument) while it plays bends the pitch a touch, as moving a real one would. A
  muted instrument is silent in the room, so a mic hears nothing of it; but a solo only takes the others out of the
  mix, so soloing a mic's track lets you hear just what it hears, every instrument still playing in the room. A
  microphone isn't heard in the room itself, so no mic hears another (nor itself).
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

## Inputs

Every instrument has an input that can be on or off, as a track's input is in a DAW, and a green **i** under its
name shows when it is on. A MIDI instrument with its input on plays what the MIDI keyboard sends; several can be on
at once, so one keyboard can play a layer of instruments. A Speaker with its input on plays its hardware input; the
audio input opens when the first Speaker's input goes on and closes when the last goes off.

Sitting down at an instrument (E) switches its input on until you get up, so the MIDI keyboard plays whatever you are
at. Switch an input on yourself (I, or the I button in the mix window) and it stays on when you walk away. The
computer keyboard plays the instrument you are sitting at, along with any others whose input is on. Every input
starts switched off, so an open microphone never meets a pair of speakers by surprise.

## Amps' speakers

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
little of the highs), and the mic hears the room's walls and ceiling the same way (see [The room](room-acoustics.md)). The PA
**Speaker** is heard the same way: its 10-inch woofer, and the horn over it covering 45 degrees either side evenly
and little beyond. (radiation.h has the physics.)

## Amps, pedals and the loop pedal

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

### Effect pedals

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
| Plug-in | (its own window) | One of the effect plug-ins installed on your Mac, before the amp (see [Plug-ins](plugins.md)). |

Delay and Reverb let their echoes and tail ring on after they are switched off, as many real ones do.

### The loop pedal

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
