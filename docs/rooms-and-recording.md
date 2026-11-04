# Rooms, Jam rooms and Record rooms

A **room** is what a session is in a DAW: everything about it in one file. That covers its size and walls, and every
instrument where it stands, with its fader, mute and solo, its pattern (the MIDI notes, the pattern's length and
whether its loop is on), its inserts, an amp's head, cabinet, knobs and pedals, a Speaker's volume and input, and
every plug-in's settings. It also holds the master fader, the tempo and swing, and where you were standing. Each room has a folder of
its own, named after it, as a Pro Tools session does: the room's `.sroom` file (JSON), an **Audio Files** folder for
what is recorded in it, and a **Room Backups** folder. Rooms go in the **Rooms** folder of the **StudioSim folder**
(Settings), unless you choose another for a room as you make it. Run from Godot, the StudioSim folder is the
project's to begin with (`StudioSim/Rooms`, beside `game/`; git leaves it alone), and the app made of it uses the same
one; someone given the app who has never run it from Godot starts with `~/Music/StudioSim`.

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
and are kept in `StudioSim/Templates` as `.srtemplate` files.

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
