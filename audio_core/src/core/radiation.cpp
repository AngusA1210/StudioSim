#include "radiation.h"

#include <algorithm>
#include <cmath>

namespace sr {
namespace {

constexpr float kSpeed = 343.0f;  // metres a second
constexpr float kPiF = 3.14159265f;
constexpr float kBackLevel = 0.7f;    // an open back lets out a little less than the front (the panel it has, the chassis)
constexpr float kBackCutHz = 2500.0f; // and duller: the back of a cone is behind its basket and magnet
constexpr float kNearLowDb = 5.0f;    // the lows close up that far off are lost to the room behind (the baffle step)
constexpr float kCapHighDb = 4.0f;    // the dust cap's bite, right in front of it

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

// A piston of radius `a` heard at `at`, from its middle `centre`, facing `facing`.
RadiatedPath piston(Vec3 centre, Vec3 facing, float a, float breakup, Vec3 at, float ref_distance) {
    RadiatedPath p;
    const Vec3 to = minus(at, centre);
    const float r = lengthOf(to);
    const float d = dotOf(to, facing);                               // along its axis
    const float x = std::sqrt(std::max(r * r - d * d, 0.0f));        // and out from it
    const float angle = std::atan2(x, d);
    // How far from the cone's face it is (out to its edge), and so how far into its near field.
    const float rho = std::sqrt(d * d + std::max(x - a, 0.0f) * std::max(x - a, 0.0f));
    const float behind = d >= 0.0f ? 1.0f : std::clamp(1.0f + d / (0.5f * a), 0.0f, 1.0f);  // (no near field behind the box)
    const float near = a * a / (a * a + rho * rho) * behind;
    // The level: on a baffled piston's axis, 2 (sqrt(d^2 + a^2) - d) / a^2, which is 1 / d far off and levels off close up.
    const float level = 2.0f * (std::sqrt(rho * rho + a * a) - rho) / (a * a);
    p.nearness = ref_distance * level;
    p.gain = shadow(angle);
    // Far off, the beaming; close up, where across the cone (above its breakup only its middle moves).
    const float far_cut = beamCut(a, angle);
    const float near_cut = std::max(breakup * a / std::max(x, 2e-3f), 0.8f * breakup);
    const float cut = std::exp(near * std::log(std::min(near_cut, 2.0f * kFullRangeHz)) +
                               (1.0f - near) * std::log(std::min(far_cut, 2.0f * kFullRangeHz)));
    p.cut_hz = std::clamp(cut, 120.0f, 20000.0f);
    p.low_db = kNearLowDb * near;
    p.high_db = kCapHighDb * near * std::max(0.0f, 1.0f - x / (0.35f * a));
    p.distance = r;
    p.wave_radius = std::sqrt(r * r + a * a);
    p.from = r > 1e-6f ? Vec3{-to.x / r, -to.y / r, -to.z / r} : Vec3{facing.x, facing.y, facing.z};
    return p;
}

}  // namespace

float coneRadius(float inches) { return 0.0254f * inches * 0.41f; }
float breakupHz(float inches) { return 12000.0f / std::max(inches, 1.0f); }

int radiatedPaths(const Radiator& r) {
    const int cones = std::clamp(r.cones, 0, kMaxCones);
    return cones > 0 ? cones + (r.open_back ? 1 : 0) : 0;
}

RadiatedPath radiate(const Radiator& r, int path, Vec3 at, float ref_distance) {
    const int cones = std::clamp(r.cones, 0, kMaxCones);
    const float a = coneRadius(r.inches), breakup = breakupHz(r.inches);
    if (path < cones) {  // a cone: its share of the cabinet's sound
        RadiatedPath p = piston(r.cone[size_t(path)], r.facing, a, breakup, at, ref_distance);
        p.gain /= float(cones);
        return p;
    }
    // The open back: every cone's back at once, from the opening, facing the other way, in reverse polarity.
    const Vec3 behind{-r.facing.x, -r.facing.y, -r.facing.z};
    RadiatedPath p = piston(r.back, behind, std::min(a * std::sqrt(float(cones)), 0.3f), breakup, at, ref_distance);
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
    f.cut_hz = std::min(beamCut(a, angle), 20000.0f);
    f.gain = shadow(angle);
    if (r.open_back) {  // its back, heard from behind
        const float back = kPiF - angle;
        f.cut_hz = std::max(f.cut_hz, std::min(beamCut(a, back), kBackCutHz));
        f.gain = std::max(f.gain, kBackLevel * shadow(back));
    }
    return f;
}

float powerCutHz(const Radiator& r) { return std::min(beamCut(coneRadius(r.inches), 50.0f * kPiF / 180.0f), 20000.0f); }

}  // namespace sr
