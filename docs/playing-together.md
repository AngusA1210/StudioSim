# Playing together

Several players can be in one room at once, each on their own computer. One player **hosts** the room they have
open; the others **join** it. Everything that happens in the room is shared, the live inputs' sound goes to everyone,
and the players can talk to each other.

## Hosting and joining

**Play together…** on the title screen opens the page for it, in three tabs. No server is needed to play on one
network, nor over the internet where the host's router opens its ports.

- **Rooms**: the rooms hosted on this network, found by themselves, and those hosted over the internet, from the
  [room list](#the-room-list): their names, hosts, Jam or Record, how many are in them, whether they have a password,
  and where they are. Double-click one to join it (with its password, if it has one).
- **Host**: the room to host, which is the one open, or a new one or a saved one (**New room…** and **Open a
  room…** make or open it, then come back here). Then its **name** (the room's own, unless you give another), a
  **password** if it is to have one, whether it is **listed** under Rooms, the most **players** in it at once (you
  included), and what joining players may do (see [The host's rules](#the-hosts-rules)). Press **Host**: the page
  then shows the session, with where others join, who is in it, its rules, and **Into the room**.
- **Direct connect**: a room joined by its host's address (and `:port` if it isn't 47130), or by the session's
  code, with its password if it has one. A room on another network is joined this way, as is an unlisted one.

Joining, your room becomes a copy of theirs, and you go into it beside where the host stands. The room you had open
is left as it was last saved. The copy goes in a folder of its own in **Together**, in your rooms folder: what you
record goes there, and what the others record comes there. It is saved there when you save it, and it stays yours
after you leave.

**Over the internet**: tick it before hosting, and StudioSim asks your router, by UPnP, to open the session's port
and the next one (47131: the sound between players) to this computer while you host. Most home routers allow it.
The page then shows your public address, for the others to join at from anywhere under Direct connect, and a
listed room is put on the [room list](#the-room-list), for everyone's Rooms tab. The ports are closed again, and the
room taken off the list, when the session ends. If the router won't (UPnP switched off, or a network that is itself
behind another, as on some mobile and student connections), the page says why. Then forward both ports (UDP) to
this computer in the router by hand, or meet through a session server.

**Session server**: a program on a machine the internet can reach, which players meet through, for when a router
won't open its ports (see [Running a session server](session-server.md)). Put its address on the Host tab (and
`:port` if it isn't 47100). Everyone uses the same one. Hosting over the internet with one given, the page shows a
code ("K7Q-M2D") as well as the address, and the others can join with that from anywhere, whatever their routers
do. The two computers are introduced, and talk directly where their routers allow it (most do). Where they don't,
the server passes everything between them itself, a little later than directly, and the page says so.

**Password**: only those who give it can join. It keeps out anyone who comes across the room; it isn't encryption.

**When a room can't be reached**: the host's firewall is the usual reason. Windows asks, the first time a room is
hosted, whether to let Godot through Windows Defender Firewall: allow it for private networks, and set the network
itself to Private (Settings > Network & internet > its connection > Network profile type). If it was turned down
once, allow Godot in Windows Security > Firewall & network protection > Allow an app through firewall. A Mac with
its firewall on asks too. A Mac may also ask whether Godot (or the app it was started from, such as Terminal) can
find devices on the local network; it must be let (System Settings > Privacy & Security > Local Network): the Rooms
tab says when it can't ask the network. On one network, both computers must be on the same one, and not a guest Wi-Fi, which
often keeps its computers apart (over the internet, the host's router must have its ports open, as above). Both
must run the same version of StudioSim: a room hosted by another shows so under Rooms.

**Losing the connection**: a player whose connection to the host drops tries to get back in by themselves (by the
address or code they joined with), every few seconds for half a minute, and their copy of the room is brought up to
date again when they do. Their inputs and armed tracks are let go meanwhile, so they switch those on again. When the
host ends the session, nobody tries.

While you're together, a **TOGETHER** chip on screen shows how many are in the room and, for a player who joined,
the time a message takes to reach the host and back. The floor plan shows each other player as an arrowhead in their
colour. **Leave** (or **End the session**, as the host) is on the same page. A player who joined keeps their copy of
the room when they leave. To make or open another room, a player who joined leaves first.

## The host's rules

Every player can play the instruments, play through a live input and talk. Besides that, the host chooses what
joining players may do, on the Host tab, and can change it while the session goes on:

- **Move, add and take out instruments** (and mike up a kit, and lock one in place).
- **Change instruments' sound, patterns and names**: an amp's head, cabinet, knobs and pedals, a microphone's
  settings, inserts and plug-ins, levels in the room, patterns, names and colours.
- **Change the room**: its size, walls and surfaces, the tempo and swing, the reverb, and Jam or Record.
- **Play, stop and record, and edit the timeline**: the transport, arming tracks, and a Record room's clips, loop
  and playhead.

All but changing the room are let to begin with. A joining player who tries what they aren't let is told so ("The
host hasn't let players move, add or take out instruments"), and it stays as the host has it (the host's copy
decides, and puts back anything changed). The host can also **ask a player to leave**, beside their name in the
session; they can join again, with the password if it has one. A room with as many players as it allows turns
others away.

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
comes in on the next step. In the checks, two copies of StudioSim on one computer keep their patterns within a
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
works together: the takes of each pass are kept, as alone.

The settings of whoever starts the recording are the session's: a pre-roll, a count-in, and punching in and out.
A count-in is the same length for everyone, but only those recording hear its click. Punching records over the
loop range only; the session stops by itself at the punch-out (after the post-roll, if there is one), and the
playhead goes back to the punch-in.

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

## The room list

Rooms hosted over the internet are listed for everyone's Rooms tab by a small program on Cloudflare's free plan, at
`https://studiosim-rooms.aja662.workers.dev` (`ADDRESS` in `game/scripts/room_list.gd`): a Worker
(`services/room-list/worker.js`) keeping the rooms in a D1 database (its table is `schema.sql`, the Worker's binding
to it named `DB`). A hosted, listed room is put on it every 30 seconds, and taken off when the session ends; one not
heard from for 75 seconds drops off, and one address lists four rooms at most. It lists each room's name, host,
kind, players, whether it has a password, and the public address and port of the host's computer, as any game's
server list does. The password itself never goes to it, and only the host that listed a room can change or remove
it. It only lists: players connect straight to the host's computer.

That address must be the host's IPv4 address, the one its router opens and the sound between players goes to, so
the host reaches the list over IPv4 alone, though its computer may have IPv6 too. The free plan allows 100,000
requests a day: a room hosted all day is about 2,900, and an open Rooms tab about 720 an hour.

To change the Worker, paste the new `worker.js` over the old in the Worker's **Edit code** in Cloudflare's dashboard,
and deploy. `tools/build.sh` checks it first (`services/room-list/tests.mjs`, with Node or a Mac's own JavaScript
shell), and its SQL on SQLite, which D1 is (`python3 services/room-list/stand_in.py --check`); the game's checks host
a room on the list's stand-in, on the same computer, never on the list itself.
