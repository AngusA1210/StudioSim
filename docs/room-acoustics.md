# The room: size, walls and materials

The Room page of the menu changes the room itself, while the music plays:

- **Size**: width and length from 4 to 40 m, height from 2.4 to 12 m. The reverb follows: a bigger room rings for
  longer but more quietly, a small one is short and close. Instruments, walls and you are brought inside if the room
  shrinks past them, but a **locked** instrument stays where it is: the room can't be made smaller than it needs (0.6 m
  clear of each wall). The sliders move both of a pair of walls; on the floor plan each of the room's own walls can be
  dragged on its own, in or out, the wall opposite staying where it is (and everything keeping its place against it).
- **What it's made of**: its floor, its ceiling and each of its four walls (north is the way you first face), each a
  material from its menu: drywall, plaster, brick, concrete, wood panelling, glass, heavy curtain, acoustic foam,
  acoustic panels, diffuser panels or bookshelves for the walls; acoustic tiles and most of those for the ceiling; a
  wooden floor, tiles, concrete, a rug or carpet underfoot. Hover over one for what it does. A room starts with drywall walls, a wooden floor and an
  acoustic-tile ceiling, and rings for about 0.7 s. Kept with the room. Each looks like what it is, at its real
  size: the floor's planks, tiles, rug or carpet; brick in running bond, wood boards, plaster, drywall with its skirting
  board, curtain folds, foam wedges, fabric panels, a diffuser's wells between its fins, shelves of books; a suspended
  ceiling's tiles on their T-bars (`game/scripts/room_surfaces.gd`). Each is as shiny as it is: glazed tiles,
  varnished wood and sealed concrete mirror the instruments and their glow a little, blurred as rough as they are, and
  drywall, curtains, foam and carpet don't (Settings' **Reflections**).
- **Walls**: a floor plan of the room, seen from above with the instruments and yourself marked on it (the room's own
  walls in their materials' colours). Drag on the floor to draw a wall, drag a wall to move it, drag the dot at either
  end to turn and stretch it. Drag one of the room's own walls to move that wall alone. Walls can stand at any angle and there can be up to 16. Each has its own height, and its
  own material (drywall to begin with): a glass booth window, a concrete partition, a curtain hung across the room, a
  gobo of acoustic panels.

Every material takes its own share of each band (below 800 Hz, 800 Hz to 8 kHz, above 8 kHz), the published figures,
and the rest it sends back. From them the room's reverb rings for as long in each band as Eyring's formula has it (what
the air takes as well): a room of bare concrete and tile rings on for seconds, bright; foam, carpet and panels leave it
nearly dead; curtains and carpet take the highs and leave the lows ringing. The more a room absorbs, the quieter its
ring, too.

Before the reverb, the **reflections**: every instrument off the floor, the ceiling and each wall, from its image
beyond the surface, as much later than its own sound as that way round is longer, as loud as the image is far, coloured
by the surface's material, the air, and a loudspeaker's beaming as seen from there (and by any wall standing in the
way). You hear them from where they come: walk up to a concrete wall and it is there beside you; line it with foam and
it goes.

- **Off the walls standing in the room**: each face of a wall you have drawn is a mirror too, for an instrument and a
  listener (or microphone) both in front of it. Near its ends and its top the reflection fades, half as loud where it
  would strike the very edge and gone a little past it, as sound bends round an edge rather than stopping dead at it.
  A gobo of concrete beside a guitar amp sends it back; one of acoustic panels hardly at all.
- **Second reflections**: off one of the room's surfaces and then another (the ceiling then the floor, the east wall
  then the north one, between two parallel walls and back), from the image of the image, coloured by both materials.
  They fill in what follows the first reflections, before the reverb takes over. What either surface scatters is
  heard scattered off the second.

They are rendered together as one Ambisonic field (the second reflections at its first order, among so many), binaurally
with the HRTF (lined up with the direct sound, whatever the buffer, and evened out to sound as an instrument's own
binaural rendering does: Ambisonics this coarse would otherwise come out boomy) or in plain stereo, so they cost
little however many instruments there are. Each microphone hears its own reflections the same way, by its pattern.

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

A wall standing in the room stops an instrument's light as it does its sound: what glows behind it lights only its
own side (glass lets the light through). The room is lit by a grid of lamps that grows with it, so a large room is no darker than the default one. Settings
has a Room lighting slider if it is still too dim or too bright for your screen.

The room's size, walls and surfaces are saved with it (see [Rooms](rooms-and-recording.md)).
