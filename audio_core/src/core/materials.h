#pragma once

// What the room is made of, and what that does to sound. Each surface is one material, which absorbs a share of the
// sound that strikes it, band by band (the rest it reflects), and a wall standing in the room lets a little of each
// band through. The three bands are Steam Audio's: below 800 Hz, 800 Hz to 8 kHz, above 8 kHz. The figures are the
// published ones (absorption coefficients by octave, averaged over each band; transmission from the sound
// reduction a wall of each kind gives).
//
// From them, the reverb: how long the room rings in each band (Eyring's formula, with what the air takes as well),
// and how loud its ring is against the sound itself (the room constant: the more a room absorbs, the quieter it is).

#include <array>
#include <string>
#include <vector>

namespace sr {

enum class Material : int {
    Concrete, Brick, Plaster, Drywall, Wood, Glass, Curtain, Foam, AcousticPanel,  // walls (and the ceiling)
    Carpet, Rug, WoodFloor, Tile,                                                  // floors
    CeilingTile,                                                                   // suspended ceilings
    kCount
};
constexpr int kMaterials = int(Material::kCount);

struct MaterialInfo {
    const char* id;
    std::array<float, 3> absorption;    // the share of the sound's energy it takes, low / mid / high
    std::array<float, 3> transmission;  // a wall of it: the share of the sound's amplitude that comes through
};

const MaterialInfo& materialInfo(Material material);
Material materialFromId(const std::string& id, Material otherwise);
// What a surface sends back, band by band, as an amplitude.
std::array<float, 3> reflection(Material material);

// The room's own surfaces.
struct RoomSurfaces {
    Material floor = Material::WoodFloor, ceiling = Material::CeilingTile;
    Material north = Material::Drywall, south = Material::Drywall, east = Material::Drywall, west = Material::Drywall;
};

// A wall standing in the room, as far as the reverb is concerned: its two faces, and what they are.
struct StandingSurface {
    float area = 0.0f;  // one face, square metres
    Material material = Material::Drywall;
};

struct RoomAcoustics {
    std::array<float, 3> decay{};  // RT60 in each band, seconds
    float constant = 0.0f;         // the room constant in the mid band (m²): its reverberant level goes as 1 / √ this
    float absorption = 0.0f;       // its surfaces' average absorption, in the mid band
};
// A room `width` (x) by `depth` (z) by `height`, these surfaces, and these walls standing in it (both faces count).
RoomAcoustics roomAcoustics(float width, float height, float depth, const RoomSurfaces& surfaces,
                            const std::vector<StandingSurface>& standing = {});

}  // namespace sr
