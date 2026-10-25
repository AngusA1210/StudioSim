# Playing together

Several players can be in one room at once, each on their own computer. One player **hosts** the room they have
open; the others **join** it. Everything that happens in the room is shared, the live inputs' sound goes to everyone,
and the players can talk to each other.

## Hosting and joining

**Play together…** on the title screen opens the page for it.

- **Host**: open a room (a Jam room or a Record room), then press Host. The page shows the address others join at, which is this computer's on
  the local network (192.168…), with the port (47130 unless you change it). To play over the internet, forward that
  port and the next one (47131: the sound between players), both UDP, to this computer in your router, and give the
  others your public address.
- **Join**: type the host's address (add `:port` if it isn't 47130) and press Join. Your room becomes a copy of
  theirs, and you go into it beside where the host stands. The room you had open is left as it was last saved. The
  copy goes in a folder of its own in **Together**, in your rooms folder: what you record goes there, and what the
  others record comes there. It is saved there when you save it, and it stays yours after you leave.

While you're together, a **TOGETHER** chip on screen shows how many are in the room and, for a player who joined,
the time a message takes to reach the host and back. The floor plan shows each other player as an arrowhead in their
colour. **Leave** (or **End the session**, as the host) is on the same page. A player who joined keeps their copy of
the room when they leave. To make or open another room, a player who joined leaves first.

## What everyone shares

- **The room**: its size, walls and surfaces, the tempo and swing, and its reverb; whether it is a Jam room or a
  Record room (the host's), and a Record room's loop range and playhead.
- **The instruments**: putting one in or taking one out, where each stands (one being carried moves for everyone as
  it goes), its name, colour and lock, its pattern, its level in the room, and its sound: an amp's head, cabinet,
  knobs and pedals, a microphone's model, pattern, gain and polarity, a Speaker's volume, inserts, a plug-in
  instrument's plug-in, and the plug-ins' own settings, sent every few seconds.
- **The patterns' clock**: Space starts or stops the patterns for everyone at once (see below).
- **A Record room's timeline**: its tracks' clips (MIDI and audio, takes and all, as each is edited), and its
  transport (see [Record rooms together](#record-rooms-together)).
- **Notes**: what each player plays, by the computer keyboard or a MIDI controller (with velocity and the sustain
  pedal), is heard by everyone from the instrument it is played on.
- **Live inputs**: a player who switches on a Speaker's or an amp's input plays through it, and nobody else can
  meanwhile (its label shows their name). Its sound goes to everyone (see below).
- **Voices**: each player can talk to the others (see below).
- **Each player**: their body, at their height and in their colour, with their name over it (from the title screen's
  **You** page), where they stand, the way they look, sitting at a kit or carrying an instrument. An instrument
  someone else is carrying can't be picked up.

Each player keeps their own:

- **The mix window**: faders, mute and solo, pans, folders, aux tracks, sends and the masters. A player who joins
  starts with the host's mix and goes on from there.
- **Inputs**: which instruments' inputs are on (every one starts off), and which hardware inputs the Speakers play
  and the voice comes in on.
- **What they hear**: the room from where they stand, or their mix (H); binaural or not; the free camera.

When two players change the same thing at the same moment, the host's order decides, and every copy ends up the
same. A plug-in that isn't installed on a player's computer stays empty there, but the others keep it. The same
plug-in in the other format (a VST3 for an Audio Unit) is used when only that one is installed.

## The clock, and latency

Each computer makes the room's sound itself, heard from where its player stands. What travels over the network is
what happens in the room, not its sound.

The session's clock is the host's. Each player works out how far their computer's clock is from it by asking the
host the time, as NTP does: the reply that comes back soonest is the truest. When the patterns start, the start is
set a third of a second ahead on that clock, so it reaches everyone first. Each player's patterns start then, less
their own output's latency, so the first beat is heard at the same moment everywhere. Every half second, each player
nudges their patterns, a few milliseconds at a time (up to ten while they're further out than that), to keep where
the session's clock says the music is. That
corrects for the sound cards' clocks running at slightly different speeds. A player joining while the patterns play
comes in on the next step. In the checks, two copies of SoundRoom on one computer keep their patterns within a
millisecond of each other.

A note played live is heard by the others as soon as it arrives, so as late as the network makes it. That's a few
milliseconds on a local network and tens over the internet, much as a player standing further away would be heard
later.

## Record rooms together

In a Record room the transport is everyone's. **Space** plays the timeline from the playhead (with the pre-roll of
whoever started it), or stops it. **Cmd-Space** records, or stops. Moving the playhead while it plays moves it for
everyone. The timeline starts at the same moment for everyone, as the patterns do, and stays in step, round the loop
too. Stopping puts the playhead back where playing began, or, if the player who stopped it has insertion following
playback, where the music stopped.

Each player records the tracks they have armed, and nobody else can arm those meanwhile (another player's R shows
dim in the edit window). Arming a Speaker or an amp makes you the one playing through it, since it records your
input. When the session records, everyone's armed tracks record at once, each on its own player's computer: the
notes they play, and the audio of their inputs, before the pedals, amp and inserts. Anyone can start the recording,
whether or not they have anything armed; while someone else records, the transport says REC (OTHERS). Loop Record
works together: the takes of each pass are kept, as alone. A count-in and punching in and out don't work together
yet; a pre-roll does.

A recording's clips reach everyone once it stops. Its audio file goes to the host, which sends it to each player
whose copy of the room refers to a file it hasn't got, a player joining later too. The clip is silent until its file
has come. The transfer goes in the background, about 8 MB a second at most from any one computer, and the TOGETHER
chip shows how much is still to come or to go. Takes are named for the player who recorded them ("Speaker_Andrew_01"),
so two players' takes never share a name. Each player's patterns aren't nudged while the session records, so a take
lands where it was played.

## Sound between players

A live input's sound is taken as it leaves the instrument, after its pedals, amp and inserts, on the computer of the
player playing through it. It goes to the others, whose copies of the instrument play it in place of their own input.
So each player hears it placed in the room from where they stand, as they hear everything else, and the microphones
in the room hear it too. Its plug-ins only need to be on that player's computer.

It is sent as Opus, the codec made for this: 48 kHz, in frames of 5 ms, at 128 kb/s each, which is plain to the ear on
a guitar or a voice. It goes on a port of its own beside the session's, through the host, which passes each player's
sound on to the others. Each computer holds what it receives back just long enough to ride out the network's
unevenness, and no longer. That's 5 to 15 ms on a local network, more over the internet, and it adjusts to how uneven
the network has lately been. The sound is played back a touch faster or slower (0.2 % at most) to keep that much in
hand, since no two sound cards' clocks quite agree. A frame that never comes is made up by Opus from the ones before
it. A sound played into one computer reaches another about 10 to 25 ms later on a local network, plus the network's
own delay over the internet.

**Voices**: on the Play together page, choose the input your voice comes in on (**Your voice**), then hold
**\`** to talk. The others hear you from your body's head, in the room like any sound, so a microphone near you hears
you too. Your own voice isn't sent back to you. While someone talks, their name says so. Choosing an input for your
voice opens the audio input for the whole session, so that holding the key never has to wait for it.

## What comes next

- Joining without forwarding a port: a session server that players meet through.
- A count-in and punching in and out, together.
