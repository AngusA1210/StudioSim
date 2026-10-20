#include "microphones.h"

#include <algorithm>
#include <cmath>
#include <complex>

namespace sr {
namespace {

constexpr float kPi = 3.14159265358979f;

MicPolar polar(std::array<float, 3> pressure, std::array<float, 3> gradient) {
    MicPolar p;
    p.pressure = pressure;
    p.gradient = gradient;
    return p;
}

std::vector<MicModel> makeModels() {
    using F = MicFilter;
    std::vector<MicModel> out;
    // A measurement mic: a quarter-inch pressure capsule, flat to beyond hearing and all round alike (a touch narrower
    // in the very highs).
    out.push_back({"flat", "Measurement (flat)", "Flat from the lowest lows to the highest highs, and hearing all round alike: the room as it is.",
                   0.0f, {{MicPattern::Omni, polar({1.0f, 1.0f, 0.95f}, {0.0f, 0.0f, 0.05f})}}, {}});
    // The workhorse instrument dynamic: cardioid, a bass roll-off (made up for close by the proximity effect), a
    // presence rise around 5.5 kHz, and little above 13 kHz. Much less sensitive than a condenser.
    out.push_back({"dynamic", "Dynamic (instrument)",
                   "A cardioid dynamic for snares, toms and guitar amps: lean far off, fuller close up, a presence lift for bite.",
                   -8.0f, {{MicPattern::Cardioid, polar({0.6f, 0.5f, 0.42f}, {0.4f, 0.5f, 0.58f})}},
                   {{F::HighPass, 80.0f, 0.0f, 0.6f}, {F::Peak, 5500.0f, 5.0f, 1.3f}, {F::Peak, 9000.0f, 2.0f, 2.0f}, {F::LowPass, 13000.0f, 0.0f, 0.7f}}});
    // A kick drum dynamic: a big diaphragm, its lows lifted, the boxy low mids scooped, the beater's click lifted.
    out.push_back({"kick", "Dynamic (kick drum)",
                   "A large-diaphragm dynamic for kick drum and bass cabinets: deep lows, the box scooped out, the beater's click lifted.",
                   -8.0f, {{MicPattern::Supercardioid, polar({0.5f, 0.37f, 0.3f}, {0.5f, 0.63f, 0.7f})}},
                   {{F::HighPass, 28.0f, 0.0f, 0.7f}, {F::Peak, 65.0f, 5.0f, 0.9f}, {F::Peak, 380.0f, -7.0f, 0.8f}, {F::Peak, 4000.0f, 6.0f, 1.1f},
                    {F::LowPass, 11000.0f, 0.0f, 0.7f}}});
    // A large-diaphragm condenser, side-address: three patterns, a little low warmth and an open top; its big
    // diaphragm makes even its omni hear less from behind in the highs.
    out.push_back({"condenser", "Condenser (large diaphragm)",
                   "A large-diaphragm condenser for vocals, room and overheads: detailed and open on top, cardioid, omni or figure-8.",
                   6.0f, {{MicPattern::Cardioid, polar({0.62f, 0.5f, 0.36f}, {0.38f, 0.5f, 0.64f})},
                          {MicPattern::Omni, polar({1.0f, 0.86f, 0.62f}, {0.0f, 0.14f, 0.38f})},
                          {MicPattern::Figure8, polar({0.06f, 0.02f, 0.08f}, {0.94f, 0.98f, 0.92f})}},
                   {{F::HighPass, 25.0f, 0.0f, 0.7f}, {F::Peak, 160.0f, 1.0f, 0.7f}, {F::Peak, 9500.0f, 3.0f, 1.0f}, {F::HighShelf, 14000.0f, -2.0f, 0.7f}}});
    // A small-diaphragm ("pencil") condenser: end-address, even off axis, a slight air lift; cardioid or omni capsule.
    out.push_back({"pencil", "Condenser (small diaphragm)",
                   "A pencil condenser for acoustic guitar, cymbals and stereo pairs: accurate and even, a little air on top; cardioid or omni.",
                   3.0f, {{MicPattern::Cardioid, polar({0.53f, 0.5f, 0.46f}, {0.47f, 0.5f, 0.54f})},
                          {MicPattern::Omni, polar({1.0f, 0.97f, 0.85f}, {0.0f, 0.03f, 0.15f})}},
                   {{F::HighPass, 30.0f, 0.0f, 0.7f}, {F::HighShelf, 10000.0f, 2.0f, 0.7f}}});
    // A ribbon: a pure figure-8 at every frequency (the back as loud as the front, in reverse polarity), smooth and
    // dark on top, the strongest proximity effect of all, and low output.
    out.push_back({"ribbon", "Ribbon",
                   "A figure-8 ribbon for guitar amps, brass and room: smooth and dark on top, front and back alike, big lows close up.",
                   -6.0f, {{MicPattern::Figure8, polar({0.0f, 0.0f, 0.0f}, {1.0f, 1.0f, 1.0f})}},
                   {{F::HighPass, 20.0f, 0.0f, 0.7f}, {F::Peak, 120.0f, 1.5f, 0.8f}, {F::LowPass, 9000.0f, 0.0f, 0.55f}}});
    return out;
}

}  // namespace

const char* micPatternName(MicPattern pattern) {
    switch (pattern) {
        case MicPattern::Omni: return "omni";
        case MicPattern::Cardioid: return "cardioid";
        case MicPattern::Supercardioid: return "supercardioid";
        case MicPattern::Figure8: return "figure8";
    }
    return "omni";
}

const std::vector<MicModel>& micModels() {
    static const std::vector<MicModel> models = makeModels();
    return models;
}

int micModelIndex(const std::string& id) {
    const auto& models = micModels();
    for (size_t i = 0; i < models.size(); ++i)
        if (models[i].id == id) return int(i);
    return -1;
}

void EqFilter::design(const MicFilter& f, float sr) {
    const float freq = std::clamp(f.hz, 10.0f, sr * 0.49f);
    const float w = 2.0f * kPi * freq / sr, c = std::cos(w), s = std::sin(w);
    const float q = std::max(f.q, 0.05f);
    const float alpha = s / (2.0f * q);
    const float a = std::pow(10.0f, f.db / 40.0f);
    float nb0 = 1, nb1 = 0, nb2 = 0, na0 = 1, na1 = 0, na2 = 0;
    switch (f.kind) {
        case MicFilter::Peak:
            nb0 = 1 + alpha * a; nb1 = -2 * c; nb2 = 1 - alpha * a;
            na0 = 1 + alpha / a; na1 = -2 * c; na2 = 1 - alpha / a;
            break;
        case MicFilter::LowShelf: {
            const float r = 2 * std::sqrt(a) * alpha;
            nb0 = a * ((a + 1) - (a - 1) * c + r); nb1 = 2 * a * ((a - 1) - (a + 1) * c); nb2 = a * ((a + 1) - (a - 1) * c - r);
            na0 = (a + 1) + (a - 1) * c + r; na1 = -2 * ((a - 1) + (a + 1) * c); na2 = (a + 1) + (a - 1) * c - r;
            break;
        }
        case MicFilter::HighShelf: {
            const float r = 2 * std::sqrt(a) * alpha;
            nb0 = a * ((a + 1) + (a - 1) * c + r); nb1 = -2 * a * ((a - 1) + (a + 1) * c); nb2 = a * ((a + 1) + (a - 1) * c - r);
            na0 = (a + 1) - (a - 1) * c + r; na1 = 2 * ((a - 1) - (a + 1) * c); na2 = (a + 1) - (a - 1) * c - r;
            break;
        }
        case MicFilter::HighPass:
            nb0 = (1 + c) / 2; nb1 = -(1 + c); nb2 = (1 + c) / 2;
            na0 = 1 + alpha; na1 = -2 * c; na2 = 1 - alpha;
            break;
        case MicFilter::LowPass:
            nb0 = (1 - c) / 2; nb1 = 1 - c; nb2 = (1 - c) / 2;
            na0 = 1 + alpha; na1 = -2 * c; na2 = 1 - alpha;
            break;
    }
    b0 = nb0 / na0; b1 = nb1 / na0; b2 = nb2 / na0;
    a1 = na1 / na0; a2 = na2 / na0;
}

float EqFilter::magnitude(float hz, float sr) const {
    const std::complex<float> z1 = std::polar(1.0f, -2.0f * kPi * hz / sr), z2 = z1 * z1;
    return std::abs((b0 + b1 * z1 + b2 * z2) / (1.0f + a1 * z1 + a2 * z2));
}

float micResponseDb(const MicModel& model, float hz, float sr) {
    float gain = 1.0f;
    for (const MicFilter& f : model.response) {
        EqFilter filter;
        filter.design(f, sr);
        gain *= filter.magnitude(hz, sr);
    }
    return 20.0f * std::log10(std::max(gain, 1e-9f));
}

}  // namespace sr
