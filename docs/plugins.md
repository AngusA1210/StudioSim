# Plug-ins and presets

SoundRoom hosts the plug-ins installed on your computer in the formats their makers install besides Pro Tools' AAX:
**VST3** on macOS and Windows (with Steinberg's VST 3 SDK, MIT-licensed), and on a Mac **Audio Units** as well. They go
on a channel's **inserts** in the mix window (on any instrument or master) or on an amp's **Plug-in pedal**. Either way
the plug-in browser opens: your plug-ins grouped **by type** (EQ, dynamics, delay, reverb, amps and cabinets...) or **by
maker**, with a search box; a plug-in installed in both formats is listed twice, each marked AU or VST3. Choose one and
its own window opens, floating over the room. Plug-ins get the room's tempo, for those that keep time.

A plug-in's window leaves the keyboard with the room, so the computer keyboard goes on playing while you turn its
knobs, except while something in it is being typed into: a box of the system's own, or one the plug-in draws itself
(as JUCE plug-ins do, a preset's name, say), clicked or opened from one of its menus. Then the window has the keyboard
until the typing is done, and gives it back. (On Windows a plug-in's window is an ordinary one: a click in it gives it
the keyboard, and a click in the room takes it back.)

A VST3 is known by its class id, which is the same on a Mac and on Windows, so a room whose plug-ins are VST3s opens
on either with its plug-ins and their settings. A room made with Audio Units, opened on Windows, gets the VST3 version
of each where it is installed (its settings start fresh, as the two formats keep them differently), and says so.
SoundRoom finds VST3s by reading the description in each plug-in's bundle, without loading it; one without is loaded
once to be asked, and what it holds is remembered between sessions (until it is updated), so a licensed plug-in that
puts up a notice when loaded (an expired trial's, say) does so that once, not every time a room with plug-ins opens. A VST3's controls show their values as the plug-in writes them in automation lanes.

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
