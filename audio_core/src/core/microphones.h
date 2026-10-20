#pragma once

// The microphones a mic in the room can be, each with what makes it sound as it does:
//
//  - its pickup pattern: how much it hears from each way round, A + B cos(angle off its axis), where A is the pressure
//    part (the same all round, as an omni hears) and B the pressure-gradient part (front and back, opposite in
//    polarity, as a figure-8 hears). Each is given for three bands (below 800 Hz, to 8 kHz, above), since a real
//    mic's pattern widens in the lows and narrows in the highs. Omni is 1 + 0, cardioid 0.5 + 0.5, supercardioid
//    0.37 + 0.63, figure-8 0 + 1.
//  - the proximity effect that follows from it: the gradient part gains bass the closer the source, 6 dB an octave
//    below c / (2 pi r) (a figure-8 most, an omni not at all), up to a point;
//  - how much of a diffuse sound field (the room's reverb) it hears: A^2 + B^2 / 3 of its energy, so a cardioid hears
//    a third of the reverb an omni does, from the same place;
//  - its frequency response on axis, far off (as makers draw it): a few filters, as an equalizer has them;
//  - its sensitivity: how loud it is for the same sound, against the flat measurement mic. A dynamic or a ribbon
//    needs more gain, as real ones do;
//  - its self-noise, as makers give it (the sound level, A-weighted, that would make as much noise), to which the
//    preamp adds its own: the same at the preamp for every mic, so the more gain a quiet mic needs, the more of it.
// The room's sound levels are such that a full-scale sample, through the measurement mic at 0 dB of gain, is 120 dB
// SPL: an instrument heard at its own level, 1.5 m away, is around 90 to 105 dB SPL.
// Models of the kinds a studio has, not of any one maker's.

#include <array>
#include <cstdint>
#include <string>
#include <vector>

namespace sr {

enum class MicPattern : uint8_t { Omni, Cardioid, Supercardioid, Figure8 };
const char* micPatternName(MicPattern pattern);  // "omni", "cardioid", "supercardioid", "figure8"

struct MicPolar {
    std::array<float, 3> pressure{1.0f, 1.0f, 1.0f};  // A, low / mid / high
    std::array<float, 3> gradient{0.0f, 0.0f, 0.0f};  // B
};

struct MicFilter {
    enum Kind : uint8_t { Peak, LowShelf, HighShelf, HighPass, LowPass } kind = Peak;
    float hz = 1000.0f, db = 0.0f, q = 0.707f;
};

struct MicModel {
    std::string id, name, about;
    float sensitivity_db = 0.0f;
    float self_noise_db = 15.0f;  // dB(A) SPL
    std::vector<std::pair<MicPattern, MicPolar>> patterns;  // the patterns it can be switched to, its own first
    std::vector<MicFilter> response;
};

constexpr float kFullScaleSpl = 120.0f;    // dB SPL a full-scale sample stands for, through the measurement mic
constexpr float kPreampNoiseSpl = 12.0f;   // the preamp's own noise, as a sound level, through the measurement mic
// A model's noise, its own and its preamp's together, as a sound level (dB SPL).
float micNoiseSpl(const MicModel& model);

// Every model, in the order a menu lists them.
const std::vector<MicModel>& micModels();
int micModelIndex(const std::string& id);  // -1 if there is none

// An equalizer's filter, as the RBJ cookbook has them (transposed direct form II).
struct EqFilter {
    float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    float z1 = 0, z2 = 0;
    void design(const MicFilter& f, float sample_rate);
    float process(float x) {
        const float y = b0 * x + z1;
        z1 = b1 * x - a1 * y + z2;
        z2 = b2 * x - a2 * y;
        return y;
    }
    float magnitude(float hz, float sample_rate) const;  // its gain at a frequency (linear)
};

// A model's response on axis at a frequency, in dB (for drawing it, and for the checks).
float micResponseDb(const MicModel& model, float hz, float sample_rate = 48000.0f);

}  // namespace sr
