# Playing together

Several players can be in one room at once, each on their own computer. One player **hosts** the room they have
open; the others **join** it. This is the first stage of multiplayer: everything that happens in the room is shared,
but no audio goes over the network yet, so live inputs and microphones are still heard only on the computer they're
plugged into (see [What comes next](#what-comes-next)).

## Hosting and joining

**Play together…** on the title screen opens the page for it.

- **Host**: open a Jam room, then press Host. The page shows the address others join at, which is this computer's on
  the local network (192.168…), with the port (47130 unless you change it). To play over the internet, forward that
  port (UDP) to this computer in your router, and give the others your public address.
- **Join**: type the host's address (add `:port` if it isn't 47130) and press Join. Your room becomes a copy of
  theirs, and you go into it beside where the host stands. The room you had open is left as it was last saved. The
  copy has no file of its own; **Save As** keeps one.

While you're together, a **TOGETHER** chip on screen shows how many are in the room and, for a player who joined,
the time a message takes to reach the host and back. The floor plan shows each other player as an arrowhead in their
colour. **Leave** (or **End the session**, as the host) is on the same page. A player who joined keeps their copy of
the room when they leave. To make or open another room, a player who joined leaves first.

## What everyone shares

- **The room**: its size, walls and surfaces, the tempo and swing, and its reverb.
- **The instruments**: putting one in or taking one out, where each stands (one being carried moves for everyone as
  it goes), its name, colour and lock, its pattern, its level in the room, and its sound: an amp's head, cabinet,
  knobs and pedals, a microphone's model, pattern, gain and polarity, a Speaker's volume, inserts, a plug-in
  instrument's plug-in, and the plug-ins' own settings, sent every few seconds.
- **The patterns' clock**: Space starts or stops the patterns for everyone at once (see below).
- **Notes**: what each player plays, by the computer keyboard or a MIDI controller (with velocity and the sustain
  pedal), is heard by everyone from the instrument it is played on.
- **Each player**: their body, at their height and in their colour, with their name over it (from the title screen's
  **You** page), where they stand, the way they look, sitting at a kit or carrying an instrument. An instrument
  someone else is carrying can't be picked up.

Each player keeps their own:

- **The mix window**: faders, mute and solo, pans, folders, aux tracks, sends and the masters. A player who joins
  starts with the host's mix and goes on from there.
- **Inputs**: which instruments' inputs are on (every one starts off), and which hardware inputs the Speakers play.
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
nudges their patterns, by a few milliseconds at most, to keep where the session's clock says the music is. That
corrects for the sound cards' clocks running at slightly different speeds. A player joining while the patterns play
comes in on the next step. In the checks, two copies of SoundRoom on one computer keep their patterns within a
millisecond of each other.

A note played live is heard by the others as soon as it arrives, so as late as the network makes it. That's a few
milliseconds on a local network and tens over the internet, much as a player standing further away would be heard
later.

## What comes next

- **Audio between players**: a live input (a guitar into an amp, a Speaker) or a microphone on one computer, heard
  by everyone, streamed with low latency; and a voice channel.
- **Record rooms** together: the timeline, and recordings, which would have to be sent to everyone.
- Joining without forwarding a port: a session server that players meet through.
