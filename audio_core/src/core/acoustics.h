#pragma once

// How a wall edge dims sound that has to bend around it.

#include <algorithm>
#include <cmath>

namespace sr {

// Representative frequencies for Steam Audio's three bands (below 800 Hz, 800 Hz–8 kHz, above 8 kHz).
constexpr float kBandFrequency[3] = {300.0f, 2500.0f, 12000.0f};

// What leaks straight through a light partition, per band (amplitude).
constexpr float kWallTransmission[3] = {0.08f, 0.02f, 0.006f};

// Maekawa's barrier formula. `path_difference` is how much longer the route around the edge is than the
// straight line, in metres; negative means the line of sight clears the edge by that much.
// Long wavelengths bend easily, so lows lose little and highs lose a lot. At the shadow edge itself the loss is
// about 5 dB for every band, and it fades to nothing just outside the shadow, so there is no audible jump.
inline float barrierGain(float path_difference, float frequency) {
    const float fresnel = 2.0f * path_difference * frequency / 343.0f;
    if (fresnel <= -0.1f) return 1.0f;
    const float loss_db = std::min(10.0f * std::log10(3.0f + 20.0f * fresnel), 24.0f);
    return std::pow(10.0f, -loss_db / 20.0f);
}

// Per-band gain for a source heard by one or more routes around a wall (their energies add), plus what leaks
// through the wall when it blocks the line of sight.
inline void directPathGains(const float* path_differences, int count, bool blocked, float out_gains[3]) {
    for (int b = 0; b < 3; ++b) {
        float energy = blocked ? kWallTransmission[b] * kWallTransmission[b] : 0.0f;
        for (int i = 0; i < count; ++i) {
            const float g = barrierGain(path_differences[i], kBandFrequency[b]);
            energy += g * g;
        }
        out_gains[b] = count > 0 ? std::min(std::sqrt(energy), 1.0f) : 1.0f;
    }
}

}  // namespace sr
