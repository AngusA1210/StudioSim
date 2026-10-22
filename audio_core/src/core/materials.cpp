#include "materials.h"

#include <algorithm>
#include <cmath>

namespace sr {
namespace {

// Absorption: the octave figures 125, 250 and 500 Hz averaged for the low band, 1, 2 and 4 kHz for the middle, and
// 4 kHz (rising a little, for the porous ones) for the top. Transmission: a wall of each, as built (concrete 20 cm,
// brick and plastered brick 11 cm, drywall on studs, plywood on studs, 6 mm glass, heavy velour, foam, a gobo's
// mineral wool), as amplitudes from its sound reduction in each band.
const MaterialInfo kTable[] = {
    {"concrete", {0.012f, 0.020f, 0.030f}, {0.0080f, 0.0018f, 0.0010f}},
    {"brick", {0.030f, 0.053f, 0.070f}, {0.0126f, 0.0032f, 0.0018f}},
    {"plaster", {0.016f, 0.040f, 0.050f}, {0.0126f, 0.0032f, 0.0018f}},
    {"drywall", {0.147f, 0.067f, 0.090f}, {0.080f, 0.020f, 0.006f}},
    {"wood", {0.223f, 0.100f, 0.110f}, {0.110f, 0.035f, 0.015f}},
    {"glass", {0.093f, 0.023f, 0.020f}, {0.063f, 0.025f, 0.032f}},
    {"curtain", {0.347f, 0.690f, 0.650f}, {0.70f, 0.40f, 0.25f}},
    {"foam", {0.310f, 0.920f, 0.900f}, {0.80f, 0.50f, 0.30f}},
    {"acoustic_panel", {0.770f, 0.990f, 0.990f}, {0.45f, 0.15f, 0.06f}},
    {"carpet", {0.073f, 0.540f, 0.650f}, {0.0080f, 0.0018f, 0.0010f}},
    {"rug", {0.127f, 0.300f, 0.370f}, {0.0080f, 0.0018f, 0.0010f}},
    {"wood_floor", {0.120f, 0.067f, 0.070f}, {0.0080f, 0.0018f, 0.0010f}},
    {"tile", {0.010f, 0.017f, 0.020f}, {0.0080f, 0.0018f, 0.0010f}},
    {"ceiling_tile", {0.600f, 0.633f, 0.500f}, {0.30f, 0.10f, 0.05f}},
};
static_assert(sizeof(kTable) / sizeof(kTable[0]) == size_t(Material::kCount), "a figure for each material");

// What the air takes of each band, as energy, a metre (Steam Audio's coefficients, which are amplitudes, doubled).
constexpr float kAirEnergy[3] = {0.0004f, 0.0034f, 0.0364f};

}  // namespace

const MaterialInfo& materialInfo(Material material) {
    return kTable[std::clamp(int(material), 0, int(Material::kCount) - 1)];
}

Material materialFromId(const std::string& id, Material otherwise) {
    for (int m = 0; m < int(Material::kCount); ++m)
        if (id == kTable[m].id) return Material(m);
    return otherwise;
}

std::array<float, 3> reflection(Material material) {
    const MaterialInfo& info = materialInfo(material);
    std::array<float, 3> out{};
    for (int b = 0; b < 3; ++b) out[size_t(b)] = std::sqrt(std::max(1.0f - info.absorption[size_t(b)], 0.0f));
    return out;
}

RoomAcoustics roomAcoustics(float width, float height, float depth, const RoomSurfaces& surfaces,
                            const std::vector<StandingSurface>& standing) {
    const float volume = width * height * depth;
    const std::pair<float, Material> faces[] = {
        {width * depth, surfaces.floor}, {width * depth, surfaces.ceiling},  {width * height, surfaces.north},
        {width * height, surfaces.south}, {depth * height, surfaces.east},   {depth * height, surfaces.west},
    };
    RoomAcoustics out;
    for (int b = 0; b < 3; ++b) {
        float area = 0.0f, absorbed = 0.0f;  // (square metres, and the square metres of perfect absorber they amount to)
        for (const auto& [face, material] : faces) {
            area += face;
            absorbed += face * materialInfo(material).absorption[size_t(b)];
        }
        for (const StandingSurface& wall : standing) {
            area += 2.0f * wall.area;
            absorbed += 2.0f * wall.area * materialInfo(wall.material).absorption[size_t(b)];
        }
        const float mean = std::clamp(absorbed / std::max(area, 1.0f), 0.001f, 0.99f);
        // Eyring: each bounce takes `mean` of the sound, and there are (area / 4 volume) × c of them a second.
        const float taken = -area * std::log(1.0f - mean) + 4.0f * kAirEnergy[b] * volume;
        out.decay[size_t(b)] = std::clamp(0.161f * volume / std::max(taken, 0.01f), 0.1f, 10.0f);
        if (b == 1) {
            out.absorption = mean;
            out.constant = area * mean / (1.0f - mean);
        }
    }
    return out;
}

}  // namespace sr
