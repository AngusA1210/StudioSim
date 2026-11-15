#include "radiation.h"

#include <algorithm>
#include <cmath>

namespace sr {
namespace {

constexpr float kSpeed = 343.0f;  // metres a second
constexpr float kPiF = 3.14159265f;
constexpr float kBackLevel = 0.7f;    // an open back lets out a little less than the front (the panel it has, the chassis)
constexpr float kBackCutHz = 2500.0f; // and duller: the back of a cone is behind its basket and magnet
constexpr float kNearLowDb = 5.0f;
constexpr float kSplitOverBreakup = 2.0f;  // a cone's body carries the sound to an octave above where it starts to break up    // the lows close up that far off are lost to the room behind (the baffle step)

Vec3 minus(Vec3 a, Vec3 b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
float dotOf(Vec3 a, Vec3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
float lengthOf(Vec3 v) { return std::sqrt(dotOf(v, v)); }

// Where a piston of radius `a` in a baffle is 3 dB down at `angle` off its axis (radians), far off: k a sin = 1.6. The
// highs come from less than the whole cone (it breaks up), so it beams as a piston somewhat smaller than itself.
float beamCut(float a, float angle) {
    const float k = 1.6f * kSpeed / (2.0f * kPiF * 0.7f * a);
    if (angle <= 0.5f * kPiF) return k / std::max(std::sin(angle), 1e-3f);
    const float behind = (angle - 0.5f * kPiF) / (0.5f * kPiF);  // 0 in the baffle's plane, 1 straight behind
    return k * (1.0f - 0.75f * behind);  // round the box: only the lows
}

// Its level behind the baffle's plane, against in front (the box's shadow, which the lows wrap round).
float shadow(float angle) {
    return angle <= 0.5f * kPiF ? 1.0f : 1.0f - 0.35f * (angle - 0.5f * kPiF) / (0.5f * kPiF);
}

// How a cone (or a horn over it) beams far off, `angle` off its axis.
float farCut(const Radiator& r, float a, float angle) {
    if (r.coverage <= 0.0f || angle > 0.5f * kPiF) return beamCut(a, angle);
    if (angle <= r.coverage) return 2.0f * kFullRangeHz;  // (within the horn's coverage: even)
    const float past = std::clamp((angle - r.coverage) / 0.26f, 0.0f, 1.0f);  // its highs gone within 15 degrees past it
    const float horn = std::exp(std::log(2.0f * kFullRangeHz) + (std::log(r.crossover_hz) - std::log(2.0f * kFullRangeHz)) * past);
    return std::min(horn, std::max(beamCut(a, angle), r.crossover_hz));
}

// How much of a baffled piston of radius `a` is as far as `far` from a point `along` its axis and `across` from it: the
// part of the circle that far away (in the piston's plane, a circle of radius sigma round the point's foot) that lies
// on the piston, 0 to 1. This is the piston's impulse response there, moment by moment (Stepanishen 1971).
float arcOnPiston(float far, float along, float across, float a) {
    const double s2 = double(far) * double(far) - double(along) * double(along);  // (far off, nearly nothing left of much)
    if (s2 <= 0.0) return across <= a ? 1.0f : 0.0f;
    const float sigma = float(std::sqrt(s2));
    if (sigma <= a - across) return 1.0f;                       // all of the circle is on it
    if (sigma >= a + across || sigma <= across - a) return 0.0f;  // none of it is
    const float c = (sigma * sigma + across * across - a * a) / (2.0f * across * sigma);
    return std::acos(std::clamp(c, -1.0f, 1.0f)) / kPiF;
}

float nearestOf(float along, float across, float a) {  // the piston's nearest part, and its furthest
    const float out = std::max(across - a, 0.0f);
    return std::sqrt(along * along + out * out);
}
float furthestOf(float along, float across, float a) { return std::sqrt(along * along + (across + a) * (across + a)); }

// The impulse response in bins `step` metres of path long, bin 0 centred on `origin` metres: `bins` of them into
// `out` (each how much of the piston is heard in it, in metres of path). Returns how many are of any use.
int pistonBins(float along, float across, float a, float origin, float step, float* out, int bins) {
    constexpr int kWithin = 6;  // (places in each bin it is looked at)
    const float first = nearestOf(along, across, a), last = furthestOf(along, across, a);
    int used = 0;
    for (int n = 0; n < bins; ++n) {
        const float from = std::max(origin + (float(n) - 0.5f) * step, first), to = std::min(origin + (float(n) + 0.5f) * step, last);
        out[n] = 0.0f;
        if (to <= from) continue;
        float sum = 0.0f;
        for (int k = 0; k < kWithin; ++k) sum += arcOnPiston(from + (float(k) + 0.5f) * (to - from) / float(kWithin), along, across, a);
        out[n] = sum * (to - from) / float(kWithin);
        if (out[n] > 0.0f) used = n + 1;
    }
    return used;
}

// A cone's cap doesn't move as a rigid disc does, as much at its edge as at its middle: it moves most at its middle
// (the dust cap itself, and the voice coil under it) and less and less out towards the cone. So it is heard as four
// pistons, one within the next, each with its share of the cap's sound (far off, on its axis): a point at its very
// middle, then wider and wider ones out to the cap's radius. This is also what keeps it from having a rigid disc's
// sharp nulls off its axis, where the far half of a disc cancels the near half at one frequency exactly: off its axis
// a cone's highs fall away by degrees and bottom out, as a real one's do.
constexpr int kCapParts = 4;
constexpr float kCapRadius[kCapParts] = {0.12f, 0.5f, 0.8f, 1.0f};  // (of the cap's)
constexpr float kCapShare[kCapParts] = {0.15f, 0.25f, 0.3f, 0.3f};

// The cap's impulse response in bins (as pistonBins), out to `a`; returns how many are of any use.
int capBins(float along, float across, float a, float origin, float step, float* out, int bins) {
    float each[kShapeTaps];
    bins = std::min(bins, kShapeTaps);
    std::fill(out, out + bins, 0.0f);
    int used = 0;
    for (int k = 0; k < kCapParts; ++k) {
        const float r = kCapRadius[k] * a;
        const int n = pistonBins(along, across, r, origin, step, each, bins);
        for (int i = 0; i < n; ++i) out[i] += kCapShare[k] * each[i] / (r * r);
        used = std::max(used, n);
    }
    return used;
}

// A piston of radius `a` heard at `at`, from its middle `centre`, facing `facing`; `shaped`, as its body and its cap
// (a cabinet's cone: see ConeShape), rather than as a point with a low-pass for where it is heard from.
RadiatedPath piston(const Radiator& cab, Vec3 centre, Vec3 facing, float a, float breakup, Vec3 at, float ref_distance, bool shaped = false) {
    RadiatedPath p;
    const Vec3 to = minus(at, centre);
    const float r = lengthOf(to);
    const float d = dotOf(to, facing);                               // along its axis
    const float x = std::sqrt(std::max(r * r - d * d, 0.0f));        // and out from it
    const float angle = std::atan2(x, d);
    // How far from the cone's face it is, and so how far into its near field: in front of it, its distance from the face;
    // out past its edge, more and more its distance from its middle, as a sound spreading from there.
    const float rho = std::sqrt(std::max(d * d + x * x - std::min(x, a) * std::min(x, a), 0.0f));
    const float behind = d >= 0.0f ? 1.0f : std::clamp(1.0f + d / (0.5f * a), 0.0f, 1.0f);  // (no near field behind the box)
    const float near = a * a / (a * a + rho * rho) * behind;
    p.gain = shadow(angle);
    p.low_db = kNearLowDb * near;
    p.wave_radius = std::sqrt(r * r + a * a);
    p.from = r > 1e-6f ? Vec3{-to.x / r, -to.y / r, -to.z / r} : Vec3{facing.x, facing.y, facing.z};
    if (shaped) {
        // As it radiates: heard from when its nearest part is, at the level of all of it together. Behind the baffle it is
        // heard as from the baffle's plane, round the box: quieter (its shadow), and duller the further round.
        const float along = std::max(d, 0.0f);
        p.shape.on = true;
        p.shape.along = along;
        p.shape.across = x;
        p.shape.radius = a;
        // (its cap: the dust cap and the cone round it, out to some three fifths of its radius; smaller, and so brighter up close
        // and wider in its highs, for a speaker with more bite there)
        p.shape.cap = a * std::clamp(0.62f * std::pow(10.0f, -(cab.cap_db - 4.0f) / 12.0f), 0.4f, 0.8f);
        p.shape.split_hz = kSplitOverBreakup * breakup;
        const float body = bodyAlong(p.shape);
        p.nearness = ref_distance * pistonLevel(body, x, a);
        p.distance = d >= 0.0f ? nearestOf(body, x, a) : r;
        if (d < 0.0f) {
            const float round = std::clamp((angle - 0.5f * kPiF) / (0.5f * kPiF), 0.0f, 1.0f);  // 0 in the baffle's plane, 1 straight behind
            const float most = 0.25f * 1.6f * kSpeed / (2.0f * kPiF * 0.7f * a);
            p.cut_hz = std::clamp(std::exp(std::log(8000.0f) + (std::log(most) - std::log(8000.0f)) * round), 120.0f, 20000.0f);
        }
        return p;
    }
    // The level: on a baffled piston's axis, 2 (sqrt(d^2 + a^2) - d) / a^2, which is 1 / d far off and levels off close up.
    const float level = 2.0f * (std::sqrt(rho * rho + a * a) - rho) / (a * a);
    p.nearness = ref_distance * level;
    // Far off, the beaming; close up, where across the cone (above its breakup only its middle moves).
    const float far_cut = farCut(cab, a, angle);
    const float near_cut = std::max(breakup * a / std::max(x, 2e-3f), 0.8f * breakup);
    const float cut = std::exp(near * std::log(std::min(near_cut, 2.0f * kFullRangeHz)) +
                               (1.0f - near) * std::log(std::min(far_cut, 2.0f * kFullRangeHz)));
    p.cut_hz = std::clamp(cut, 120.0f, 20000.0f);
    p.high_db = cab.cap_db * near * std::max(0.0f, 1.0f - x / (0.35f * a));
    p.distance = r;
    return p;
}

}  // namespace

float pistonLevel(float along, float across, float a) {
    constexpr int kSteps = 96;
    const float first = nearestOf(along, across, a), last = furthestOf(along, across, a);
    float sum = 0.0f;
    for (int k = 0; k < kSteps; ++k) sum += arcOnPiston(first + (float(k) + 0.5f) * (last - first) / float(kSteps), along, across, a);
    return 2.0f * sum * (last - first) / float(kSteps) / (a * a);
}

float bodyAlong(const ConeShape& shape) {
    // (close up, the part of the cone under the mic; from further off, the cone as a whole, as far as its cap is)
    const float close = shape.radius * shape.radius / (shape.radius * shape.radius + shape.along * shape.along);
    return std::max(shape.along - kConeRise * close * std::min(shape.across, shape.radius), 0.005f);
}

float capLevel(float along, float across, float a) {
    float sum = 0.0f;
    for (int k = 0; k < kCapParts; ++k) sum += kCapShare[k] * pistonLevel(along, across, kCapRadius[k] * a);
    return sum;
}

void shapeTaps(const ConeShape& shape, float sample_rate, float falloff, ShapeTaps* out) {
    const float step = kSpeed / std::max(sample_rate, 1.0f);
    const float body_along = bodyAlong(shape);
    const float origin = nearestOf(body_along, shape.across, shape.radius);  // (when the way itself is heard)
    out->body_taps = std::max(pistonBins(body_along, shape.across, shape.radius, origin, step, out->body.data(), kShapeTaps), 1);
    float body = 0.0f, cap = 0.0f;
    for (int n = 0; n < out->body_taps; ++n) body += out->body[size_t(n)];
    if (body <= 0.0f) {
        out->body[0] = 1.0f;
        body = 1.0f;
    } else {
        for (int n = 0; n < out->body_taps; ++n) out->body[size_t(n)] /= body;
    }
    out->cap_taps = std::max(capBins(shape.along, shape.across, shape.cap, origin, step, out->cap.data(), kShapeTaps), 1);
    out->cap_from = 0;
    while (out->cap_from < out->cap_taps - 1 && out->cap[size_t(out->cap_from)] == 0.0f) ++out->cap_from;
    for (int n = 0; n < out->cap_taps; ++n) cap += out->cap[size_t(n)];
    // The cap against the body, there: each as loud as a piston its size is (the way's level is the body's).
    const float body_level = pistonLevel(body_along, shape.across, shape.radius);
    const float cap_level = capLevel(shape.along, shape.across, shape.cap);
    const float ratio = body_level > 0.0f ? std::pow(cap_level / body_level, falloff) : 1.0f;
    if (cap <= 0.0f) {
        out->cap[size_t(out->cap_from)] = ratio;
    } else {
        for (int n = 0; n < out->cap_taps; ++n) out->cap[size_t(n)] *= ratio / cap;
    }
}

float coneRadius(float inches) { return 0.0254f * inches * 0.41f; }
float breakupHz(float inches) { return 12000.0f / std::max(inches, 1.0f); }

int radiatedPaths(const Radiator& r) {
    const int cones = std::clamp(r.cones, 0, kMaxCones);
    return cones > 0 ? cones + (r.open_back ? 1 : 0) : 0;
}

RadiatedPath radiate(const Radiator& r, int path, Vec3 at, float ref_distance) {
    const int cones = std::clamp(r.cones, 0, kMaxCones);
    const float a = coneRadius(r.inches), breakup = r.breakup_hz > 0.0f ? r.breakup_hz : breakupHz(r.inches);
    if (path < cones) {  // a cone: its share of the cabinet's sound
        // (a horn over the cone: as before, its coverage being the horn's own)
        RadiatedPath p = piston(r, r.cone[size_t(path)], r.facing, a, breakup, at, ref_distance, r.coverage <= 0.0f);
        p.gain /= float(cones);
        return p;
    }
    // The open back: every cone's back at once, from the opening, facing the other way, in reverse polarity.
    const Vec3 behind{-r.facing.x, -r.facing.y, -r.facing.z};
    RadiatedPath p = piston(r, r.back, behind, std::min(a * std::sqrt(float(cones)), 0.3f), breakup, at, ref_distance);
    p.gain *= -kBackLevel;
    p.cut_hz = std::min(p.cut_hz, kBackCutHz);
    p.high_db = 0.0f;
    return p;
}

Facing facingFrom(const Radiator& r, Vec3 centre, Vec3 at) {
    Facing f;
    if (r.cones <= 0) return f;
    const Vec3 to = minus(at, centre);
    const float n = lengthOf(to);
    if (n < 1e-6f) return f;
    const float a = coneRadius(r.inches);
    const float angle = std::acos(std::clamp(dotOf(to, r.facing) / n, -1.0f, 1.0f));
    f.cut_hz = std::min(farCut(r, a, angle), 20000.0f);
    f.gain = shadow(angle);
    if (r.open_back) {  // its back, heard from behind
        const float back = kPiF - angle;
        f.cut_hz = std::max(f.cut_hz, std::min(beamCut(a, back), kBackCutHz));
        f.gain = std::max(f.gain, kBackLevel * shadow(back));
    }
    return f;
}

float powerCutHz(const Radiator& r) { return std::min(beamCut(coneRadius(r.inches), 50.0f * kPiF / 180.0f), 20000.0f); }

namespace {

// How loud a cymbal is `cosine` off its axis (either face): half as loud edge on.
float plateGain(float cosine) { return 0.5f + 0.5f * std::fabs(cosine); }

// What a drum's head keeps of its highs `angle` off its axis (dB): a little less the further off, and behind it (the
// shell in the way) less again.
constexpr float kHeadEdgeDb = 6.0f;
float headHighDb(float angle) {
    if (angle <= 0.5f * kPiF) return -kHeadEdgeDb * std::sin(angle) * std::sin(angle);
    return -kHeadEdgeDb * (1.0f + (angle - 0.5f * kPiF) / (0.5f * kPiF));
}

}  // namespace

RadiatedPath radiatePart(const SoundingPart& part, Vec3 at, float ref_distance) {
    const Radiator plain;  // (no horn; a head has no dust cap, and doesn't break up as a cone does)
    if (!part.plate) {
        RadiatedPath p = piston(plain, part.centre, part.facing, part.radius, 2.0f * kFullRangeHz, at, ref_distance);
        const Vec3 to = minus(at, part.centre);
        const float r = lengthOf(to);
        p.gain = 1.0f;  // (the lows bend round a drum: behind it, only its highs are lost)
        p.cut_hz = 20000.0f;
        p.high_db = headHighDb(r > 1e-6f ? std::acos(std::clamp(dotOf(to, part.facing) / r, -1.0f, 1.0f)) : 0.0f);
        return p;
    }
    // A cymbal: from whichever face is towards `at`, its highs all round.
    const Vec3 to = minus(at, part.centre);
    const float r = lengthOf(to), cosine = r > 1e-6f ? dotOf(to, part.facing) / r : 1.0f;
    const Vec3 face = cosine >= 0.0f ? part.facing : Vec3{-part.facing.x, -part.facing.y, -part.facing.z};
    RadiatedPath p = piston(plain, part.centre, face, part.radius, 2.0f * kFullRangeHz, at, ref_distance);
    p.gain = plateGain(cosine);
    p.cut_hz = 20000.0f;
    p.low_db = 0.0f;
    p.high_db = 0.0f;
    return p;
}

bool SoundingPart::contains(Vec3 at) const {
    if (!inside) return false;
    const Vec3 to = minus(at, centre);
    const float along = dotOf(to, facing);
    if (along <= 0.0f || along >= depth) return false;
    const Vec3 out{to.x - facing.x * along, to.y - facing.y * along, to.z - facing.z * along};
    return lengthOf(out) < radius;
}

// The middle: as the drum's fundamental is (all the head moving together, most at its middle, nothing at its edge),
// and the stick or beater striking there. The rim: as its overtones are (still at the middle, strongest out towards
// the edge, so they and the ring come forward the further out a mic is placed). Close up only: further off, the head
// is heard as a whole.
HeadLayers headLayers(const SoundingPart& part, Vec3 at) {
    HeadLayers out;
    const Vec3 to = minus(at, part.centre);
    if (part.plate) {  // a cymbal, from either face: its bell and bow (the stick's ping), and out to its edge (its wash)
        const float along = std::fabs(dotOf(to, part.facing));
        const Vec3 off{to.x - part.facing.x * dotOf(to, part.facing), to.y - part.facing.y * dotOf(to, part.facing),
                       to.z - part.facing.z * dotOf(to, part.facing)};
        const float a = part.radius, across = std::min(lengthOf(off) / a, 1.0f);
        const float near = a * a / (a * a + along * along);
        const float bell = across / 0.5f;
        out.middle = 1.0f + near * (std::clamp(1.0f - bell * bell, 0.25f, 1.0f) - 1.0f);
        out.rim = 1.0f + near * (0.45f + 0.9f * across - 1.0f);
        return out;
    }
    const float along = dotOf(to, part.facing);
    if (along <= 0.0f) return out;  // (behind it: as a whole)
    const Vec3 off{to.x - part.facing.x * along, to.y - part.facing.y * along, to.z - part.facing.z * along};
    const float a = part.radius, across = std::min(lengthOf(off) / a, 1.0f);
    const float near = a * a / (a * a + along * along);
    const float middle = std::clamp(1.0f - across * across, 0.2f, 1.0f), rim = 0.35f + 1.6f * across * (1.2f - across);
    out.middle = 1.0f + near * (middle - 1.0f);
    out.rim = 1.0f + near * (rim - 1.0f);
    return out;
}

Facing facingFromPart(const SoundingPart& part, Vec3 at) {
    Facing f;
    const Vec3 to = minus(at, part.centre);
    const float n = lengthOf(to);
    if (n < 1e-6f) return f;
    const float cosine = std::clamp(dotOf(to, part.facing) / n, -1.0f, 1.0f);
    if (part.plate) {
        f.gain = plateGain(cosine);
        return f;
    }
    f.high_db = headHighDb(std::acos(cosine));
    return f;
}

}  // namespace sr
