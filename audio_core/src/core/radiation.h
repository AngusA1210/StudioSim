#pragma once

// How a loudspeaker cabinet's sound leaves it, for a microphone (or the listener) to hear it from where it is. An amp's
// cabinet isn't a point that sounds the same all round: each speaker is a cone in the baffle, and how it sounds depends
// on where you are against it, as a guitarist placing a close mic knows.
//
//  - Each cone is heard on its own way, from its own place: late by its own distance, so a mic between the cones of a
//    4x12 hears them comb-filter, and one up against a cone hears that cone far louder than the others.
//  - A cone beams as a piston in a baffle does: on its axis it is heard full-range; off it, the highs fall away, the
//    further off and the higher the more (the -3 dB point is where k a sin(angle) = 1.6, k = 2 pi f / c, a the cone's
//    radius). Behind the baffle only the lows wrap round the box, the highs shadowed.
//  - A cone is a surface, not a point, and every part of it is heard as late as it is far. It is heard as two pistons
//    in the baffle, one within the other (ConeShape): its body, the whole cone, which moves as one below its breakup
//    frequency and carries the lows and mids; and its cap, its middle round the dust cap, which is all of it that
//    still moves above that, and carries the highs. What a mic hears of each is the piston's own impulse response
//    there (Stepanishen's: at each moment, as much as the arc of the piston that far away): it starts when the sound
//    of its nearest part arrives, and goes on until its furthest's has. So:
//      - close to it (within about its radius) it is in its near field: its level no longer rises as 1 / distance but
//        levels off (on its axis, as sqrt(d^2 + a^2) - d), and falls away smoothly past the cone's edge, where the
//        cone is still near, rather than at once;
//      - across the cone the sound changes as it does on a real one: bright and biting at the dust cap, where the cap
//        is close and faces the mic; darker halfway out and darker still at the edge, where the cap is further off and
//        seen from the side, its highs spread out in time and so cancelled, while the body under the mic is as near as
//        ever;
//      - two mics on one cone are in phase as two real ones are: each hears the body from its nearest part, so one at
//        the edge and one at the cap, as far from the grille as each other, hear its lows and mids together. Nothing
//        is filtered for one mic that isn't for the other; their difference is in the geometry alone.
//    Close up there is no baffle step either (the lows aren't lost to the room behind it as they are far off), so
//    close mics hear more lows too.
//  - The wave is flatter close to a big cone than close to a small source, so a directional mic's proximity effect
//    there is less than its distance alone would make it.
//  - An open back lets the backs of the cones be heard as well, in reverse polarity and duller: behind an open-back
//    combo it is loud; in front, far off, the two cancel in the lows (an open back's lighter low end). A closed back
//    lets out only what wraps round the box.
//
// These are made into a level, a delay, an arrival direction, where the mic is against the cone (for its two impulse
// responses, which the audio thread works out: shapeTaps) and two filters (a low shelf for the near field's lows; a
// low-pass behind the box, and for a horn or an open back) for each cone, worked out on the game thread whenever a mic
// or the cabinet moves; the audio thread glides to them.

#include <array>

#include "spatializer.h"

namespace sr {

constexpr int kMaxCones = 8;
constexpr int kMaxRadiatedPaths = kMaxCones + 1;  // the cones, and an open back

// A cabinet's speakers, in the room.
struct Radiator {
    int cones = 0;                       // none: not a loudspeaker
    std::array<Vec3, kMaxCones> cone{};  // each cone's acoustic centre (its dust cap, a little behind the grille)
    Vec3 facing{0.0f, 0.0f, 1.0f};       // the way the baffle faces (a unit vector)
    float inches = 12.0f;                // the speakers' size, as speakers are sold
    float breakup_hz = 0.0f;             // where a cone starts to break up (0: as its size has it)
    float cap_db = 4.0f;                 // how much brighter it is right in front of a dust cap
    // A horn above a cone (a PA speaker's): above `crossover_hz` it covers `coverage` either side of its axis
    // (radians) evenly, and little beyond it; below, the cone beams as ever. No coverage: a plain cone.
    float coverage = 0.0f;
    float crossover_hz = 1800.0f;
    bool open_back = false;
    Vec3 back{};                         // the middle of an open back
    float width = 0.6f;                  // the baffle's width (metres)
};

float coneRadius(float inches);  // the part of a cone that radiates, as a piston (metres): a little under half its size
float breakupHz(float inches);   // where a cone starts to break up: lower for bigger cones

// A cone as a mic hears it radiate: where the mic is against it (metres along its axis from its dust cap's plane, and out
// from its axis), its radius and its cap's, and the frequency below which its body carries the sound and above which
// its cap (they part gently: the body's share falls away at 12 dB an octave, and the cap has the rest). A cone is a
// cone: its edge stands nearer the grille than its cap does (by kConeRise of its radius), so close up the body under a
// mic out towards the edge is that much nearer it (bodyAlong).
constexpr float kConeRise = 0.4f;
struct ConeShape {
    bool on = false;
    float along = 0.0f, across = 0.0f;
    float radius = 0.1f, cap = 0.05f;
    float split_hz = 1000.0f;
};
// What a mic there hears of the body and of the cap, sample by sample from when the body's nearest part is heard (the
// way's own delay): each band's impulse response, the body's adding up to 1 (the way's level is its own) and the cap's to
// how much louder or quieter the cap is there than the body, at the room's distance law. `body_taps` and `cap_taps`:
// how many of each there are (the rest nothing); `cap_from`: the cap's first.
constexpr int kShapeTaps = 96;
struct ShapeTaps {
    std::array<float, kShapeTaps> body{}, cap{};
    int body_taps = 1, cap_from = 0, cap_taps = 1;
};
void shapeTaps(const ConeShape& shape, float sample_rate, float falloff, ShapeTaps* out);
float bodyAlong(const ConeShape& shape);  // how far the cone's body is from the mic, along its axis
// How loud a piston of radius `a` is `along` its axis and `across` from it, at low frequencies, against a point source
// a metre away: 1 / distance far off, levelling off close up.
float pistonLevel(float along, float across, float a);
// The same for a cone's cap, which moves most at its middle and less towards its edge (radiation.cpp).
float capLevel(float along, float across, float a);

// One of a cabinet's ways to a point (paths 0 to cones - 1 are the cones, then the open back, if it has one).
struct RadiatedPath {
    float distance = 0.0f;       // metres: when it arrives
    // Its level: `gain` (its share of the cabinet, its shadow behind the box; an open back's negative) times `nearness`
    // raised to the room's distance law, `nearness` being ref_distance / distance for a point source (1 at
    // ref_distance), but levelling off close up.
    float nearness = 1.0f;
    float gain = 0.0f;
    float cut_hz = 20000.0f;     // the low-pass: how far off the cone's axis, and where across the cone
    float low_db = 0.0f;         // the low shelf (below kNearLowHz): the near field's lows
    float high_db = 0.0f;        // the high shelf (above kCapHighHz): the dust cap's bite
    float wave_radius = 1.0f;    // how curved the wave is there (metres), for a mic's proximity effect
    Vec3 from{0.0f, 0.0f, 1.0f}; // the way it arrives from, at that point (a unit vector)
    ConeShape shape;             // a cone's, heard as it radiates (off: as a point with those filters)
};
constexpr float kNearLowHz = 200.0f;
constexpr float kCapHighHz = 3000.0f;
constexpr float kFullRangeHz = 18000.0f;  // a low-pass this high is no low-pass at all

int radiatedPaths(const Radiator& r);  // how many ways it has to a point
// Path `path` to `at`: `ref_distance` is where a source is heard at its own level.
RadiatedPath radiate(const Radiator& r, int path, Vec3 at, float ref_distance);

// The cabinet as the listener hears it from `at` (far enough off, a cabinet is heard as one source, from the middle of
// its baffle): how much of its highs reach there (a low-pass), and how loud it is there against straight in front.
struct Facing {
    float cut_hz = 20000.0f;
    float gain = 1.0f;
    float high_db = 0.0f;  // (a part's: its highs, above kCapHighHz, off its axis)
};
Facing facingFrom(const Radiator& r, Vec3 centre, Vec3 at);
// What the room's reverb hears of it: its sound all round (its power response), which beaming leaves duller than what
// is heard on its axis: a one-pole low-pass's corner.
float powerCutHz(const Radiator& r);

// A part of an instrument that sounds on its own, from its own place, with a sound of its own (an acoustic kit's,
// instruments.h: KitPart). A drum's head is a disc with a near field close up (its level levelling off within about its
// radius, the lows fuller); it is no rigid cone, though: its many modes, and the stick, radiate widely, so off its axis
// it loses only some of its highs (6 dB edge on), and behind it, where the drum's shell is in the way, more (12 dB
// straight behind; its lows bend round). A cymbal is a plate: heard from both its faces, its sound mostly high, so all
// round alike but quieter edge on, with a near field of its own size.
struct SoundingPart {
    Vec3 centre{};
    Vec3 facing{0.0f, 1.0f, 0.0f};  // the way the head faces, out of the drum (a cymbal's: up, as it is mounted)
    float radius = 0.15f;           // metres
    bool plate = false;             // a cymbal
    int drum = -1;                  // which drum it is part of (its parts share its shell), or -1 (a cymbal)
    // A drum's inside (the kick's, heard through its port): a head facing into the drum, heard only within its shell,
    // `depth` metres deep from the head and as wide as it; and a mic in there hears everything else through the shell.
    bool inside = false;
    float depth = 0.0f;
    bool contains(Vec3 at) const;  // (whether `at` is within an inside's shell)
};
// What a drum's shell (and its heads, and the port it has) lets through to a mic inside it, of each band, as amplitudes.
constexpr std::array<float, 3> kShellThrough{0.3f, 0.06f, 0.02f};
// How much a mic at `at` hears of a head's middle (its fundamental and the stick) and of its rim (its overtones and
// ring): as it is placed across the head (how far from its axis, against its radius), the closer it is the more so;
// far off it hears the two as they are. A cymbal's likewise, from either face: its middle the stick's ping on its bell
// and bow, its rim the wash and sizzle out at its edge.
struct HeadLayers {
    float middle = 1.0f, rim = 1.0f;
};
HeadLayers headLayers(const SoundingPart& part, Vec3 at);
RadiatedPath radiatePart(const SoundingPart& part, Vec3 at, float ref_distance);
Facing facingFromPart(const SoundingPart& part, Vec3 at);

}  // namespace sr
